#if canImport(CoreData)
import Foundation
@preconcurrency import CoreData
import CryptoKit
import CampCore

public struct PendingRecord: Sendable {
    public let record: ReplicaRecord
    public let revision: Int64
    public let asset: Data?
}
public struct NoteRevision: Identifiable, Sendable {
    public let id: String
    public let text: String
    public let date: Date
}

/// All managed objects stay on one private context queue. Only Sendable values leave it.
public final class SQLiteStore: @unchecked Sendable {
    private let container: NSPersistentContainer
    private let context: NSManagedObjectContext
    public let directory: URL
    private init(container: NSPersistentContainer, directory: URL) {
        self.container = container; self.directory = directory
        context = container.newBackgroundContext()
        context.mergePolicy = NSErrorMergePolicy
        context.undoManager = nil
        context.transactionAuthor = "RoamReady"
    }
    public static func open(directory: URL) async throws -> SQLiteStore {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let container = NSPersistentContainer(name: "RoamReady", managedObjectModel: StoreModel.v1())
        let description = NSPersistentStoreDescription(url: directory.appendingPathComponent("RoamReady.sqlite"))
        description.type = NSSQLiteStoreType
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        description.setOption(["journal_mode": "WAL", "synchronous": "FULL"] as NSDictionary, forKey: NSSQLitePragmasOption)
        #if os(iOS)
        description.setOption(FileProtectionType.completeUntilFirstUserAuthentication.rawValue as NSString, forKey: NSPersistentStoreFileProtectionKey)
        #endif
        container.persistentStoreDescriptions = [description]
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            container.loadPersistentStores { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        return SQLiteStore(container: container, directory: directory)
    }
    public func close() async throws {
        try await context.perform { [self] in
            context.reset()
            for store in container.persistentStoreCoordinator.persistentStores {
                try container.persistentStoreCoordinator.remove(store)
            }
        }
    }
    public func snapshot() async throws -> LibrarySnapshot {
        try await context.perform { [self] in try RecordProjection.snapshot(allRecords(projectionOnly: true)) }
    }
    public func migrateLegacy(archiveURL: URL, favorites: Set<String>) async throws -> LibrarySnapshot {
        if try await metadata("legacyMigrationV1") != nil { return try await snapshot() }
        let legacy = try await FileAppStore(directory: archiveURL.deletingLastPathComponent()).load()
        let expected = LibrarySnapshot(state: legacy, favorites: favorites)
        return try await context.perform { [self] in
            if try meta("legacyMigrationV1") != nil { return try RecordProjection.snapshot(allRecords()) }
            do {
                // One SQLite transaction includes records, asset bytes, outbox flags, and marker.
                try apply(from: LibrarySnapshot(), to: expected)
                let actual = try RecordProjection.snapshot(allRecords())
                guard actual == expected else { throw ReplicationError.incompleteLibrary }
                try putMeta("legacyMigrationV1", Data("complete".utf8))
                try context.save()
                return actual
            } catch { context.rollback(); throw error }
        }
    }
    public func save(from baseline: LibrarySnapshot, to desired: LibrarySnapshot) async throws {
        try await context.perform { [self] in
            do { try apply(from: baseline, to: desired); try promoteIncoming(); if context.hasChanges { try context.save() } }
            catch { context.rollback(); throw error }
        }
    }
    public func export(to url: URL) async throws {
        let library = try await snapshot()
        struct Export: Encodable { let schemaVersion = 1; let state: AppState; let savedCampgroundIDs: [String] }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Export(state: library.state, savedCampgroundIDs: library.favorites.sorted()))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
    public func pending(limit: Int = 25) async throws -> [PendingRecord] {
        try await context.perform { [self] in
            var result: [PendingRecord] = []; var byteCount = 0
            for kind in RecordKind.allCases {
                let request = NSFetchRequest<NSManagedObject>(entityName: StoreModel.name(kind))
                request.predicate = NSPredicate(format: "dirty == YES")
                request.sortDescriptors = [NSSortDescriptor(key: "key", ascending: true)]
                request.fetchLimit = max(0, limit - result.count)
                if request.fetchLimit == 0 { break }
                for row in try context.fetch(request) {
                    let asset = kind == .asset ? row.value(forKey: "bytes") as? Data : nil
                    if !result.isEmpty && byteCount + (asset?.count ?? 0) > 15_000_000 { return result }
                    result.append(PendingRecord(record: try read(row, kind), revision: row.value(forKey: "revision") as? Int64 ?? 0, asset: asset))
                    byteCount += asset?.count ?? 0
                }
            }
            return result
        }
    }
    public func acknowledge(key: String, kind: RecordKind, revision: Int64) async throws {
        try await context.perform { [self] in
            do {
                if let row = try find(key, kind), row.value(forKey: "revision") as? Int64 == revision {
                    row.setValue(false, forKey: "dirty"); try context.save()
                }
            } catch { context.rollback(); throw error }
        }
    }
    /// Persist incoming pages and their token together; only promote coherent graphs.
    /// Partial new parents stay staged across app termination; existing local trips still open offline.
    public func receive(_ changes: [(ReplicaRecord, Data?)], deletedKeys: [String] = [], token: Data? = nil) async throws {
        try await context.perform { [self] in
            do {
                for (remote, bytes) in changes {
                    _ = try remote.validated()
                    guard Set(remote.fields.keys).isSubset(of: Set(StoreModel.fields(remote.kind).keys)) else { throw ReplicationError.invalidRecord }
                    if remote.kind == .asset, let bytes {
                        guard remote.fields["checksum"]?.string == Self.checksum(bytes) else { throw ReplicationError.invalidRecord }
                    }
                    try putCounter(max(try counter(), remote.maximumCounter))
                    try stage(remote, bytes: bytes, forceUpload: false)
                }
                for key in deletedKeys {
                    guard let prefix = key.split(separator: ":").first, let kind = RecordKind(rawValue: String(prefix)) else { throw ReplicationError.invalidRecord }
                    let existing = try find(key, kind)
                    var record = try existing.map { try read($0, kind) } ?? ReplicaRecord(key: key, kind: kind)
                    let next = try counter() + 1
                    record.deletion = FieldVersion(counter: next, writer: "cloud-deletion")
                    try putCounter(next)
                    try stage(record, bytes: nil, forceUpload: true)
                }
                try promoteIncoming()
                if let token { try putMeta("cloudToken", token) }
                if context.hasChanges { try context.save() }
            } catch { context.rollback(); throw error }
        }
    }
    public func hasStagedDownloads() async throws -> Bool {
        try await context.perform { [self] in
            let request = NSFetchRequest<NSManagedObject>(entityName: "IncomingRecord"); request.fetchLimit = 1
            return try context.count(for: request) > 0
        }
    }
    private func stage(_ remote: ReplicaRecord, bytes: Data?, forceUpload: Bool) throws {
        let request = NSFetchRequest<NSManagedObject>(entityName: "IncomingRecord")
        request.predicate = NSPredicate(format: "key == %@", remote.key); request.fetchLimit = 1
        let row = try context.fetch(request).first ?? NSEntityDescription.insertNewObject(forEntityName: "IncomingRecord", into: context)
        let previous = try (row.value(forKey: "payload") as? Data).map { try JSONDecoder().decode(ReplicaRecord.self, from: $0) }
        let combined = try previous.map { try $0.merging(remote) } ?? remote
        row.setValue(remote.key, forKey: "key")
        row.setValue(try JSONEncoder().encode(combined), forKey: "payload")
        if let bytes { row.setValue(bytes, forKey: "bytes") }
        row.setValue(forceUpload || (row.value(forKey: "forceUpload") as? Bool ?? false), forKey: "forceUpload")
    }
    private func promoteIncoming() throws {
        let stages = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "IncomingRecord"))
        guard !stages.isEmpty else { return }
        let existing = try allRecords()
        let original = Dictionary(uniqueKeysWithValues: existing.map { ($0.key, $0) })
        var candidate = original
        var staged: [String: ReplicaRecord] = [:]
        for row in stages {
            let doc = try JSONDecoder().decode(ReplicaRecord.self, from: row.value(forKey: "payload") as! Data)
            staged[doc.key] = doc
            candidate[doc.key] = try original[doc.key].map { try $0.merging(doc) } ?? doc
        }
        var blocked: Set<String> = []
        // Keep both sides of retained dependencies coherent, including out-of-order deletions.
        var changed = true
        while changed {
            changed = false
            for doc in Array(candidate.values) where doc.deletion == nil {
                if case .array(let keys) = doc.fields["initialChecklistKeys"],
                   !keys.allSatisfy({ $0.string.map { candidate[$0] != nil } ?? false }),
                   !blocked.contains(doc.key) {
                    blocked.insert(doc.key); candidate[doc.key] = original[doc.key]; changed = true
                    continue
                }
                if doc.kind == .templates, case .array(let initial) = doc.fields["initialChecklistKeys"] {
                    for value in initial {
                        guard let key = value.string, candidate[key]?.deletion != nil,
                              let previous = original[key], previous.deletion == nil, !blocked.contains(key) else { continue }
                        blocked.insert(key); candidate[key] = previous; changed = true
                    }
                }
                if let rigKey = doc.fields["rigKey"]?.string,
                   candidate[rigKey] == nil || candidate[rigKey]?.deletion != nil {
                    if let oldRig = original[rigKey], oldRig.deletion == nil, !blocked.contains(rigKey) {
                        blocked.insert(rigKey); candidate[rigKey] = oldRig; changed = true
                    } else if !blocked.contains(doc.key) {
                        blocked.insert(doc.key); candidate[doc.key] = original[doc.key]; changed = true
                    }
                }
            }
        }
        _ = try RecordProjection.snapshot(Array(candidate.values))
        for stage in stages {
            let key = stage.value(forKey: "key") as! String
            guard !blocked.contains(key), let document = candidate[key], let remote = staged[key] else { continue }
            let row = try find(key, document.kind)
            let dirty = document != remote || (stage.value(forKey: "forceUpload") as? Bool ?? false)
            let updated = try write(document, dirty: dirty, existing: row)
            if document.kind == .asset, let bytes = stage.value(forKey: "bytes") as? Data {
                guard document.fields["checksum"]?.string == Self.checksum(bytes) else { throw ReplicationError.invalidRecord }
                updated.setValue(bytes, forKey: "bytes")
            }
            context.delete(stage)
        }
    }
    public func markAllForUpload() async throws {
        try await context.perform { [self] in
            do {
                for kind in RecordKind.allCases {
                    for row in try context.fetch(NSFetchRequest<NSManagedObject>(entityName: StoreModel.name(kind))) {
                        row.setValue(true, forKey: "dirty")
                    }
                }
                try context.save()
            } catch { context.rollback(); throw error }
        }
    }
    public func metadata(_ key: String) async throws -> Data? { try await context.perform { [self] in try meta(key) } }
    public func setMetadata(_ key: String, value: Data?) async throws {
        try await context.perform { [self] in
            do { try putMeta(key, value); try context.save() } catch { context.rollback(); throw error }
        }
    }
    public func asset(filename: String) async throws -> Data? {
        try await context.perform { [self] in try find("asset:\(filename)", .asset)?.value(forKey: "bytes") as? Data }
    }
    public func noteRevisions(tripID: UUID) async throws -> [NoteRevision] {
        try await context.perform { [self] in
            let request = NSFetchRequest<NSManagedObject>(entityName: StoreModel.name(.noteRevision))
            request.predicate = NSPredicate(format: "owner == %@", "trip:\(tripID)")
            return try context.fetch(request).map { row in
                let record = try read(row, .noteRevision)
                return NoteRevision(id: record.key, text: record.fields["body"]?.string ?? "", date: Date(timeIntervalSinceReferenceDate: record.fields["createdAt"]?.number ?? 0))
            }.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
        }
    }
    private func apply(from baseline: LibrarySnapshot, to desired: LibrarySnapshot) throws {
        let before = try RecordProjection.documents(baseline), after = try RecordProjection.documents(desired)
        let nextCounter = try counter() + 1
        let writer: String
        if let data = try meta("writer"), let existing = String(data: data, encoding: .utf8) { writer = existing }
        else { writer = UUID().uuidString; try putMeta("writer", Data(writer.utf8)) }
        let version = FieldVersion(counter: nextCounter, writer: writer)
        for key in Set(before.keys).union(after.keys).sorted() {
            let previous = before[key], next = after[key]
            guard previous?.fields != next?.fields else { continue }
            let kind = (next ?? previous)!.kind
            let existing = try find(key, kind)
            var record = try existing.map { try read($0, kind) } ?? ReplicaRecord(key: key, kind: kind)
            guard record.deletion == nil else { continue } // A stale offline edit cannot undo deletion.
            if next == nil && kind != .favorite { record.deletion = version }
            else {
                let target = next?.fields ?? ["campgroundID": previous!.fields["campgroundID"]!, "saved": .bool(false)]
                for field in Set(previous?.fields.keys.map { $0 } ?? []).union(target.keys) {
                    if previous?.fields[field] != target[field] {
                        record.fields[field] = target[field] ?? .null; record.versions[field] = version
                    }
                }
            }
            if (existing == nil && kind == .trip) || (kind == .templates && (existing == nil || previous?.fields["id"] != next?.fields["id"])) {
                let owner = kind == .templates ? "templates:\(next?.fields["id"]?.string ?? "")" : key
                let keys = after.values.filter { $0.kind == .checklistItem && $0.fields["owner"]?.string == owner }.map(\.key).sorted()
                record.fields["initialChecklistKeys"] = .array(keys.map(RecordValue.string))
                record.versions["initialChecklistKeys"] = version
            }
            _ = try write(record, dirty: true, existing: existing)
            if kind == .trip, let note = next?.fields["notes"]?.string, previous?.fields["notes"]?.string != note {
                // Immutable versions preserve text even if simultaneous note edits resolve differently.
                for text in Set([note, previous?.fields["notes"]?.string ?? ""]).filter({ !$0.isEmpty }) {
                    let revisionKey = "noteRevision:\(UUID())"
                    let fields: [String: RecordValue] = ["owner": .string(key), "body": .string(text), "createdAt": .number(Date().timeIntervalSinceReferenceDate)]
                    _ = try write(ReplicaRecord(key: revisionKey, kind: .noteRevision, fields: fields, versions: fields.mapValues { _ in version }), dirty: true)
                }
            }
        }
        for filename in RecordProjection.referencedPhotos(desired.state).subtracting(RecordProjection.referencedPhotos(baseline.state)) {
            let key = "asset:\(filename)"
            guard try find(key, .asset) == nil else { continue }
            let path = directory.appendingPathComponent("Media", isDirectory: true).appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: path.path) else { continue } // Missing legacy files stay recoverable.
            let bytes = try Data(contentsOf: path)
            let fields: [String: RecordValue] = ["filename": .string(filename), "checksum": .string(Self.checksum(bytes))]
            let row = try write(ReplicaRecord(key: key, kind: .asset, fields: fields, versions: fields.mapValues { _ in version }), dirty: true)
            row.setValue(bytes, forKey: "bytes")
        }
        try putCounter(nextCounter)
    }
    private static func checksum(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func counter() throws -> Int64 { try meta("counter").flatMap { String(data: $0, encoding: .utf8).flatMap(Int64.init) } ?? 0 }
    private func putCounter(_ value: Int64) throws { try putMeta("counter", Data(String(value).utf8)) }
    private func allRecords(projectionOnly: Bool = false) throws -> [ReplicaRecord] {
        try RecordKind.allCases.filter { !projectionOnly || ($0 != .asset && $0 != .noteRevision) }.flatMap { kind in
            try context.fetch(NSFetchRequest<NSManagedObject>(entityName: StoreModel.name(kind))).map { try read($0, kind) }
        }
    }
    private func find(_ key: String, _ kind: RecordKind) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: StoreModel.name(kind))
        request.predicate = NSPredicate(format: "key == %@", key); request.fetchLimit = 1
        return try context.fetch(request).first
    }
    private struct Clocks: Codable { let versions: [String: FieldVersion]; let deletion: FieldVersion? }
    private func read(_ row: NSManagedObject, _ kind: RecordKind) throws -> ReplicaRecord {
        guard let key = row.value(forKey: "key") as? String, let data = row.value(forKey: "clocks") as? Data else { throw ReplicationError.invalidRecord }
        let clocks = try JSONDecoder().decode(Clocks.self, from: data)
        var fields: [String: RecordValue] = [:]
        for field in clocks.versions.keys {
            guard let type = StoreModel.fields(kind)[field] else { throw ReplicationError.invalidRecord }
            guard let value = row.value(forKey: field) else { fields[field] = .null; continue }
            switch type {
            case .stringAttributeType: fields[field] = .string(value as! String)
            case .doubleAttributeType: fields[field] = .number((value as! NSNumber).doubleValue)
            case .booleanAttributeType: fields[field] = .bool((value as! NSNumber).boolValue)
            default: fields[field] = try JSONDecoder().decode(RecordValue.self, from: value as! Data)
            }
        }
        return try ReplicaRecord(key: key, kind: kind, fields: fields, versions: clocks.versions, deletion: clocks.deletion).validated()
    }
    @discardableResult private func write(_ record: ReplicaRecord, dirty: Bool, existing: NSManagedObject? = nil) throws -> NSManagedObject {
        _ = try record.validated()
        let row = existing ?? NSEntityDescription.insertNewObject(forEntityName: StoreModel.name(record.kind), into: context)
        row.setValue(record.key, forKey: "key")
        row.setValue(try JSONEncoder().encode(Clocks(versions: record.versions, deletion: record.deletion)), forKey: "clocks")
        for (key, value) in record.fields {
            guard let type = StoreModel.fields(record.kind)[key] else { throw ReplicationError.invalidRecord }
            switch (type, value) {
            case (_, .null): row.setValue(nil, forKey: key)
            case (.stringAttributeType, .string(let v)): row.setValue(v, forKey: key)
            case (.doubleAttributeType, .number(let v)): guard v.isFinite else { throw ReplicationError.invalidRecord }; row.setValue(v, forKey: key)
            case (.booleanAttributeType, .bool(let v)): row.setValue(v, forKey: key)
            case (.binaryDataAttributeType, _): row.setValue(try JSONEncoder().encode(value), forKey: key)
            default: throw ReplicationError.invalidRecord
            }
        }
        row.setValue(dirty, forKey: "dirty")
        row.setValue((row.value(forKey: "revision") as? Int64 ?? 0) + 1, forKey: "revision")
        return row
    }
    private func meta(_ key: String) throws -> Data? {
        let request = NSFetchRequest<NSManagedObject>(entityName: "LocalMetadata")
        request.predicate = NSPredicate(format: "key == %@", key); request.fetchLimit = 1
        return try context.fetch(request).first?.value(forKey: "value") as? Data
    }
    private func putMeta(_ key: String, _ value: Data?) throws {
        let request = NSFetchRequest<NSManagedObject>(entityName: "LocalMetadata")
        request.predicate = NSPredicate(format: "key == %@", key); request.fetchLimit = 1
        let row = try context.fetch(request).first ?? NSEntityDescription.insertNewObject(forEntityName: "LocalMetadata", into: context)
        row.setValue(key, forKey: "key"); row.setValue(value, forKey: "value")
    }
}

/// Freeze v1. Add future model versions explicitly; never silently mutate this schema.
enum StoreModel {
    static func name(_ kind: RecordKind) -> String { "RR_" + kind.rawValue }
    static func fields(_ kind: RecordKind) -> [String: NSAttributeType] {
        var strings: [String] = [], numbers: [String] = [], binary: [String] = [], booleans: [String] = []
        switch kind {
        case .profile: strings = ["name", "experience", "rigKey"]
        case .rig: strings = ["id", "type", "make", "model", "floorplan", "emoji", "photoFilename"]; numbers = ["year"]; binary = ["equipment"]
        case .trip:
            strings = ["id", "campgroundName", "siteNumber", "notes", "rating", "rigKey", "campgroundID", "planningTimeZoneIdentifier", "campgroundTimeZoneIdentifier"]
            numbers = ["latitude", "longitude", "arrival", "departure", "position"]; binary = ["initialChecklistKeys"]
        case .checklistItem: strings = ["id", "title", "detail", "section", "status", "owner", "phase"]; numbers = ["position"]
        case .templates: strings = ["id", "sourceURL"]; numbers = ["version"]; binary = ["initialChecklistKeys"]
        case .photo: strings = ["id", "filename", "caption", "owner"]; numbers = ["createdAt", "position"]
        case .asset: strings = ["filename", "checksum"]
        case .favorite: strings = ["campgroundID"]; booleans = ["saved"]
        case .noteRevision: strings = ["owner", "body"]; numbers = ["createdAt"]
        }
        var result = Dictionary(uniqueKeysWithValues: strings.map { ($0, NSAttributeType.stringAttributeType) })
        for n in numbers { result[n] = .doubleAttributeType }
        for n in binary { result[n] = .binaryDataAttributeType }
        for n in booleans { result[n] = .booleanAttributeType }
        return result
    }
    static func v1() -> NSManagedObjectModel {
        func attribute(_ name: String, _ type: NSAttributeType, optional: Bool = true) -> NSAttributeDescription {
            let a = NSAttributeDescription(); a.name = name; a.attributeType = type; a.isOptional = optional; return a
        }
        let model = NSManagedObjectModel(); model.versionIdentifiers = ["RoamReady.v1"]
        model.entities = RecordKind.allCases.map { kind in
            let entity = NSEntityDescription(); entity.name = name(kind); entity.managedObjectClassName = "NSManagedObject"
            let dirty = attribute("dirty", .booleanAttributeType, optional: false); dirty.defaultValue = false
            let revision = attribute("revision", .integer64AttributeType, optional: false); revision.defaultValue = 0
            var properties = [attribute("key", .stringAttributeType, optional: false), attribute("clocks", .binaryDataAttributeType, optional: false), dirty, revision]
            properties += fields(kind).sorted { $0.key < $1.key }.map { attribute($0.key, $0.value) }
            if kind == .asset { let bytes = attribute("bytes", .binaryDataAttributeType); bytes.allowsExternalBinaryDataStorage = true; properties.append(bytes) }
            entity.properties = properties; entity.uniquenessConstraints = [["key"]]
            entity.indexes = [NSFetchIndexDescription(name: name(kind) + "_outbox", elements: [
                NSFetchIndexElementDescription(property: dirty, collationType: .binary),
                NSFetchIndexElementDescription(property: properties[0], collationType: .binary)
            ])]
            return entity
        }
        let meta = NSEntityDescription(); meta.name = "LocalMetadata"; meta.managedObjectClassName = "NSManagedObject"
        meta.properties = [attribute("key", .stringAttributeType, optional: false), attribute("value", .binaryDataAttributeType)]
        meta.uniquenessConstraints = [["key"]]; model.entities.append(meta)
        let incoming = NSEntityDescription(); incoming.name = "IncomingRecord"; incoming.managedObjectClassName = "NSManagedObject"
        let bytes = attribute("bytes", .binaryDataAttributeType); bytes.allowsExternalBinaryDataStorage = true
        let force = attribute("forceUpload", .booleanAttributeType, optional: false); force.defaultValue = false
        incoming.properties = [attribute("key", .stringAttributeType, optional: false), attribute("payload", .binaryDataAttributeType, optional: false), bytes, force]
        incoming.uniquenessConstraints = [["key"]]; model.entities.append(incoming)
        return model
    }
}
#endif
