#if canImport(CoreData)
import Foundation
@preconcurrency import CoreData
import CryptoKit
import CampCore

public struct NoteRevision: Identifiable, Sendable {
    public let id: String
    public let text: String
    public let date: Date
}

/// Core Data owns SQLite, external binary files, persistent history, and CloudKit mirroring.
/// Only value types leave the private managed-object context.
public final class SQLiteStore: @unchecked Sendable {
    let container: NSPersistentCloudKitContainer
    /// Serializes every read and write. Document APIs share it with library snapshots.
    let context: NSManagedObjectContext
    public let directory: URL
    public let cloudEnabled: Bool
    public var coordinator: NSPersistentStoreCoordinator { container.persistentStoreCoordinator }

    private init(container: NSPersistentCloudKitContainer, directory: URL, cloudEnabled: Bool) {
        self.container = container; self.directory = directory; self.cloudEnabled = cloudEnabled
        context = container.newBackgroundContext()
        context.automaticallyMergesChangesFromParent = true
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        context.undoManager = nil
        context.transactionAuthor = "RoamReady"
    }

    public static func open(directory: URL, cloudContainerIdentifier: String? = nil) async throws -> SQLiteStore {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Staging holds only transient copies from an interrupted document import.
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(stagingDirectoryName, isDirectory: true))
        // Bootstrap locally so a v1 import is verified before mirroring can upload anything.
        let local = try await load(directory: directory, cloudContainerIdentifier: nil)
        do {
            try await local.importPreviousDatabase()
            try await local.cleanUpInterruptedDocumentWrites()
            _ = try await local.snapshot()
        } catch {
            try? await local.close()
            throw error
        }
        guard let cloudContainerIdentifier else { return local }
        try await local.close()
        return try await load(directory: directory, cloudContainerIdentifier: cloudContainerIdentifier)
    }

    private static func load(directory: URL, cloudContainerIdentifier: String?) async throws -> SQLiteStore {
        let container = NSPersistentCloudKitContainer(name: "RoamReady", managedObjectModel: ManagedStoreModel.make())
        let libraryURL = directory.appendingPathComponent("RoamReadyManaged.sqlite")
        // Explicit, verified migration from a frozen model, before mirroring can start.
        let migration = try await ManagedStoreMigration.prepare(libraryURL: libraryURL, directory: directory)
        let library = NSPersistentStoreDescription(url: libraryURL)
        library.configuration = "Library"
        library.type = NSSQLiteStoreType
        library.shouldMigrateStoreAutomatically = true
        library.shouldInferMappingModelAutomatically = true
        library.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        library.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        if let cloudContainerIdentifier {
            library.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: cloudContainerIdentifier)
        }
        let local = NSPersistentStoreDescription(url: directory.appendingPathComponent("RoamReadyDevice.sqlite"))
        local.configuration = "Device"
        local.type = NSSQLiteStoreType
        for description in [library, local] {
            description.shouldMigrateStoreAutomatically = true
            description.shouldInferMappingModelAutomatically = true
            description.setOption(ManagedStoreMigration.stagedMigrationManager(), forKey: NSPersistentStoreStagedMigrationManagerOptionKey)
            // Zero deleted content so replaced plaintext (for example after a document is
            // re-encrypted) doesn't linger in free database pages. A Core Data store option.
            description.setOption(["secure_delete": "1"] as NSDictionary, forKey: NSSQLitePragmasOption)
            #if os(iOS)
            description.setOption(FileProtectionType.completeUntilFirstUserAuthentication.rawValue as NSString, forKey: NSPersistentStoreFileProtectionKey)
            #endif
        }
        // Load descriptions separately: completion is called once per store.
        container.persistentStoreDescriptions = [local]
        try await loadStores(container)
        container.persistentStoreDescriptions = [library]
        try await loadStores(container)
        let store = SQLiteStore(container: container, directory: directory, cloudEnabled: cloudContainerIdentifier != nil)
        do { try await store.recordSchemaVersion(migration) } catch { try? await store.close(); throw error }
        return store
    }

    /// Verify a migration against its pre-migration fingerprint, then record the version.
    /// A failed verification fails closed on every launch so a damaged library never mirrors;
    /// the frozen v2 copy in `Backups/` remains the recovery source.
    private func recordSchemaVersion(_ migration: ManagedStoreMigration.Pending?) async throws {
        var pending = migration
        let backup = ManagedStoreMigration.backupURL(in: directory)
        if pending == nil, try await metadata("managedSchemaV3") == nil, FileManager.default.fileExists(atPath: backup.path) {
            // Core Data converted the store but the app stopped before verifying it. Verify
            // against the preserved v2 copy instead of trusting the conversion.
            pending = ManagedStoreMigration.Pending(sourceVersion: ManagedStoreModel.v2Identifier,
                                                    fingerprint: try await ManagedStoreMigration.fingerprint(ofStoreAt: backup), backupURL: backup)
        }
        let resolved = pending
        try await context.perform { [self] in
            let marker = try meta("managedSchemaV3").map { String(decoding: $0, as: UTF8.self) }
            if let resolved {
                let migrated = try ManagedStoreMigration.fingerprint(context: context, model: ManagedStoreModel.v2())
                context.reset()
                guard migrated == resolved.fingerprint else {
                    try putMeta("managedSchemaV3", Data("verification-failed".utf8)); try context.save()
                    throw ManagedStoreMigrationError.verificationFailed
                }
                try putMeta("managedSchemaV3", Data("migrated-from-\(resolved.sourceVersion)".utf8))
                try putMeta("managedSchemaV3Backup", Data(resolved.backupURL.lastPathComponent.utf8))
            } else if marker == nil {
                try putMeta("managedSchemaV3", Data("created".utf8))
            } else if marker == "verification-failed" {
                throw ManagedStoreMigrationError.verificationFailed
            } else { return }
            do { try context.save() } catch { context.rollback(); throw error }
        }
    }

    static func loadStores(_ container: NSPersistentContainer) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            container.loadPersistentStores { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    public func close() async throws {
        try await context.perform { [self] in
            context.reset()
            for store in coordinator.persistentStores { try coordinator.remove(store) }
        }
    }

    public func snapshot() async throws -> LibrarySnapshot {
        try await context.perform { [self] in
            // Refault imported rows after remote notifications; no pending writes live here.
            context.refreshAllObjects()
            let saved = try meta("coherentProjection").map { try JSONDecoder().decode(CachedLibrary.self, from: $0).library }
            let documents = try coherentDocuments(records(), previous: saved)
            let library = try RecordProjection.snapshot(documents)
            try cache(library)
            return library
        }
    }

    /// Hide only incomplete imported graphs, not unrelated local edits or new local trips.
    private func coherentDocuments(_ actual: [ReplicaRecord], previous: LibrarySnapshot?) throws -> [ReplicaRecord] {
        let cached = try previous.map { try RecordProjection.documents($0) } ?? [:]
        var candidate = Dictionary(uniqueKeysWithValues: actual.map { ($0.key, $0) })
        for parent in actual where parent.deletion == nil && [.profile, .templates, .trip].contains(parent.kind) {
            var incomplete = false
            if let key = parent.fields["rigKey"]?.string, candidate[key] == nil || candidate[key]?.deletion != nil {
                if let old = cached[key] { candidate[key] = old } else { incomplete = true }
            }
            if case .array(let required) = parent.fields["initialChecklistKeys"] {
                for value in required {
                    guard let key = value.string else { throw ReplicationError.invalidRecord }
                    if candidate[key] == nil || (parent.kind == .templates && candidate[key]?.deletion != nil) {
                        if let old = cached[key] { candidate[key] = old } else { incomplete = true }
                    }
                }
            }
            if incomplete {
                candidate[parent.key] = cached[parent.key]
                if let old = cached[parent.key] {
                    let owner = parent.kind == .templates ? "templates:\(old.fields["id"]?.string ?? "")" : old.key
                    for doc in cached.values where doc.fields["owner"]?.string == owner { candidate[doc.key] = doc }
                    if let key = old.fields["rigKey"]?.string { candidate[key] = cached[key] }
                }
            }
        }
        return Array(candidate.values)
    }

    public func migrateLegacy(archiveURL: URL, favorites: Set<String>) async throws -> LibrarySnapshot {
        if try await metadata("legacyMigrationV1") != nil { return try await snapshot() }
        let legacy = try await FileAppStore(directory: archiveURL.deletingLastPathComponent()).load()
        let expected = LibrarySnapshot(state: legacy, favorites: favorites)
        try await save(from: LibrarySnapshot(), to: expected)
        // Metadata is device-only. Commit the idempotent import before its completion marker.
        try await setMetadata("legacyMigrationV1", value: Data("complete".utf8))
        return try await snapshot()
    }

    public func save(from baseline: LibrarySnapshot, to desired: LibrarySnapshot) async throws {
        try await context.perform { [self] in
            do {
                try apply(from: baseline, to: desired)
                if context.hasChanges { try context.save() }
            } catch { context.rollback(); throw error }
        }
        _ = try await snapshot()
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

    public func metadata(_ key: String) async throws -> Data? { try await context.perform { [self] in try meta(key) } }
    public func setMetadata(_ key: String, value: Data?) async throws {
        try await context.perform { [self] in
            do { try putMeta(key, value); try context.save() } catch { context.rollback(); throw error }
        }
    }
    public func asset(filename: String) async throws -> Data? {
        try await context.perform { [self] in
            context.refreshAllObjects()
            return try rows("asset:\(filename)", .asset).compactMap { $0.value(forKey: "bytes") as? Data }.first
        }
    }
    public func noteRevisions(tripID: UUID) async throws -> [NoteRevision] {
        try await context.perform { [self] in
            context.refreshAllObjects()
            return try records(kinds: [.noteRevision]).filter { $0.fields["owner"]?.string == "trip:\(tripID)" }.map {
                NoteRevision(id: $0.key, text: $0.fields["body"]?.string ?? "", date: Date(timeIntervalSinceReferenceDate: $0.fields["createdAt"]?.number ?? 0))
            }.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
        }
    }

    private func apply(from baseline: LibrarySnapshot, to desired: LibrarySnapshot) throws {
        let before = try RecordProjection.documents(baseline), after = try RecordProjection.documents(desired)
        for key in Set(before.keys).union(after.keys).sorted() {
            let previous = before[key], next = after[key]
            guard previous?.fields != next?.fields else { continue }
            let kind = (next ?? previous)!.kind
            let matches = try rows(key, kind)
            // Soft deletion is an application rule, not a replacement synchronization engine.
            if kind != .favorite && matches.contains(where: { $0.value(forKey: "removed") as? Bool == true }) { continue }
            let row = matches.first ?? insert(key, kind)
            if next == nil && kind != .favorite {
                for match in matches { match.setValue(true, forKey: "removed") }
                continue
            }
            let target = next?.fields ?? ["campgroundID": previous!.fields["campgroundID"]!, "saved": .bool(false)]
            for field in Set(previous?.fields.keys.map { $0 } ?? []).union(target.keys) where previous?.fields[field] != target[field] {
                try set(target[field] ?? .null, field: field, kind: kind, row: row)
            }
            if previous == nil && (kind == .trip || kind == .templates) || (kind == .templates && previous?.fields["id"] != next?.fields["id"]) {
                let owner = kind == .templates ? "templates:\(next?.fields["id"]?.string ?? "")" : key
                let keys = after.values.filter { $0.kind == .checklistItem && $0.fields["owner"]?.string == owner }.map(\.key).sorted()
                try set(.array(keys.map(RecordValue.string)), field: "initialChecklistKeys", kind: kind, row: row)
            }
            if kind == .trip, let note = next?.fields["notes"]?.string, previous?.fields["notes"]?.string != note {
                for text in Set([note, previous?.fields["notes"]?.string ?? ""]).filter({ !$0.isEmpty }) {
                    let revision = insert("noteRevision:\(UUID())", .noteRevision)
                    revision.setValue(key, forKey: "owner"); revision.setValue(text, forKey: "body")
                    revision.setValue(Date().timeIntervalSinceReferenceDate, forKey: "createdAt")
                }
            }
        }
        for filename in RecordProjection.referencedPhotos(desired.state).subtracting(RecordProjection.referencedPhotos(baseline.state)) {
            guard try rows("asset:\(filename)", .asset).isEmpty else { continue }
            guard filename == (filename as NSString).lastPathComponent, !filename.contains("..") else { throw ReplicationError.invalidRecord }
            let path = directory.appendingPathComponent("Media", isDirectory: true).appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: path.path) else { continue }
            let bytes = try Data(contentsOf: path), row = insert("asset:\(filename)", .asset)
            row.setValue(filename, forKey: "filename"); row.setValue(Self.checksum(bytes), forKey: "checksum")
            row.setValue(bytes, forKey: "bytes")
        }
    }

    private static func checksum(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func rows(_ key: String, _ kind: RecordKind) throws -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: LegacyStoreModel.name(kind))
        request.predicate = NSPredicate(format: "key == %@", key)
        return try context.fetch(request).sorted { identity($0) < identity($1) }
    }
    private func identity(_ row: NSManagedObject) -> String { row.value(forKey: "rowID") as? String ?? row.objectID.uriRepresentation().absoluteString }
    private func insert(_ key: String, _ kind: RecordKind) -> NSManagedObject {
        let row = NSEntityDescription.insertNewObject(forEntityName: LegacyStoreModel.name(kind), into: context)
        row.setValue(key, forKey: "key"); row.setValue(UUID().uuidString, forKey: "rowID")
        return row
    }
    private func records(kinds: [RecordKind] = RecordKind.allCases.filter { $0 != .asset && $0 != .noteRevision }) throws -> [ReplicaRecord] {
        try kinds.flatMap { kind in
            let fetched = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: LegacyStoreModel.name(kind)))
            // CloudKit does not support Core Data uniqueness constraints. Reconcile logical
            // identities deterministically, including singletons created offline on two devices.
            let groups = Dictionary(grouping: fetched) { $0.value(forKey: "key") as? String ?? "" }
            return try groups.keys.sorted().compactMap { key -> ReplicaRecord? in
                guard !key.isEmpty, let row = groups[key]?.sorted(by: { identity($0) < identity($1) }).first else { return nil }
                let deleted = groups[key]!.contains { $0.value(forKey: "removed") as? Bool == true }
                var fields: [String: RecordValue] = [:]
                for (field, type) in LegacyStoreModel.fields(kind) {
                    guard let value = row.value(forKey: field) else { continue }
                    switch type {
                    case .stringAttributeType: fields[field] = .string(value as! String)
                    case .doubleAttributeType: fields[field] = .number((value as! NSNumber).doubleValue)
                    case .booleanAttributeType: fields[field] = .bool((value as! NSNumber).boolValue)
                    default: fields[field] = try JSONDecoder().decode(RecordValue.self, from: value as! Data)
                    }
                }
                return ReplicaRecord(key: key, kind: kind, fields: fields, deletion: deleted ? .init(counter: 1, writer: "managed-deletion") : nil)
            }
        }
    }
    private func set(_ value: RecordValue, field: String, kind: RecordKind, row: NSManagedObject) throws {
        guard let type = LegacyStoreModel.fields(kind)[field] else { throw ReplicationError.invalidRecord }
        switch (type, value) {
        case (_, .null): row.setValue(nil, forKey: field)
        case (.stringAttributeType, .string(let v)): row.setValue(v, forKey: field)
        case (.doubleAttributeType, .number(let v)): guard v.isFinite else { throw ReplicationError.invalidRecord }; row.setValue(v, forKey: field)
        case (.booleanAttributeType, .bool(let v)): row.setValue(v, forKey: field)
        case (.binaryDataAttributeType, _): row.setValue(try JSONEncoder().encode(value), forKey: field)
        default: throw ReplicationError.invalidRecord
        }
    }
    private struct CachedLibrary: Codable {
        let state: AppState
        let favorites: Set<String>
        var library: LibrarySnapshot { LibrarySnapshot(state: state, favorites: favorites) }
    }
    private func cache(_ library: LibrarySnapshot) throws {
        let bytes = try JSONEncoder().encode(CachedLibrary(state: library.state, favorites: library.favorites))
        guard try meta("coherentProjection") != bytes else { return }
        try putMeta("coherentProjection", bytes); try context.save()
    }
    func meta(_ key: String) throws -> Data? {
        let request = NSFetchRequest<NSManagedObject>(entityName: "LocalMetadata")
        request.predicate = NSPredicate(format: "key == %@", key); request.fetchLimit = 1
        return try context.fetch(request).first?.value(forKey: "value") as? Data
    }
    /// Device-only metadata. Call inside `context.perform`.
    func putMeta(_ key: String, _ value: Data?) throws {
        let request = NSFetchRequest<NSManagedObject>(entityName: "LocalMetadata")
        request.predicate = NSPredicate(format: "key == %@", key); request.fetchLimit = 1
        let row = try context.fetch(request).first ?? NSEntityDescription.insertNewObject(forEntityName: "LocalMetadata", into: context)
        row.setValue(key, forKey: "key"); row.setValue(value, forKey: "value")
    }

    private func importPreviousDatabase() async throws {
        guard try await metadata("managedMigrationV2") == nil else { return }
        let source = directory.appendingPathComponent("RoamReady.sqlite")
        guard FileManager.default.fileExists(atPath: source.path) else {
            try await setMetadata("managedMigrationV2", value: Data("no-source".utf8)); return
        }
        let old = NSPersistentContainer(name: "RoamReadyLegacy", managedObjectModel: LegacyStoreModel.v1())
        let description = NSPersistentStoreDescription(url: source)
        description.isReadOnly = true; old.persistentStoreDescriptions = [description]
        try await Self.loadStores(old)
        let oldContext = old.newBackgroundContext()
        defer { for store in old.persistentStoreCoordinator.persistentStores { try? old.persistentStoreCoordinator.remove(store) } }
        struct Imported: Sendable { let record: ReplicaRecord; let bytes: Data? }
        struct Clocks: Decodable { let versions: [String: FieldVersion]; let deletion: FieldVersion? }
        let deferredCount = try await oldContext.perform {
            try oldContext.count(for: NSFetchRequest<NSManagedObject>(entityName: "IncomingRecord"))
        }
        let imported = try await oldContext.perform {
            return try RecordKind.allCases.flatMap { kind in
                try oldContext.fetch(NSFetchRequest<NSManagedObject>(entityName: LegacyStoreModel.name(kind))).map { row in
                    guard let key = row.value(forKey: "key") as? String, let data = row.value(forKey: "clocks") as? Data else { throw ReplicationError.invalidRecord }
                    let clocks = try JSONDecoder().decode(Clocks.self, from: data)
                    var fields: [String: RecordValue] = [:]
                    for field in clocks.versions.keys {
                        guard let value = row.value(forKey: field) else { fields[field] = .null; continue }
                        switch LegacyStoreModel.fields(kind)[field] {
                        case .stringAttributeType: fields[field] = .string(value as! String)
                        case .doubleAttributeType: fields[field] = .number((value as! NSNumber).doubleValue)
                        case .booleanAttributeType: fields[field] = .bool((value as! NSNumber).boolValue)
                        default: fields[field] = try JSONDecoder().decode(RecordValue.self, from: value as! Data)
                        }
                    }
                    return Imported(record: ReplicaRecord(key: key, kind: kind, fields: fields, versions: clocks.versions, deletion: clocks.deletion), bytes: kind == .asset ? row.value(forKey: "bytes") as? Data : nil)
                }
            }
        }
        let expected = try RecordProjection.snapshot(imported.map(\.record))
        try await context.perform { [self] in
            do {
                for item in imported {
                    let doc = item.record
                    guard try rows(doc.key, doc.kind).isEmpty else { continue }
                    let row = insert(doc.key, doc.kind)
                    for (field, value) in doc.fields { try set(value, field: field, kind: doc.kind, row: row) }
                    row.setValue(doc.deletion != nil, forKey: "removed")
                    if let bytes = item.bytes { row.setValue(bytes, forKey: "bytes") }
                }
                try context.save()
                guard try RecordProjection.snapshot(records()) == expected else { throw ReplicationError.incompleteLibrary }
                try cache(expected)
                // Do not re-import older JSON over the migrated SQLite library.
                try putMeta("legacyMigrationV1", Data("sqlite-source".utf8))
                try putMeta("managedMigrationV2", Data("complete".utf8))
                if deferredCount > 0 {
                    try putMeta("migrationNotice", Data("Your saved local library was migrated. Some incomplete downloads from the previous sync system remain preserved in the old database for recovery.".utf8))
                }
                try context.save()
            } catch { context.rollback(); throw error }
        }
    }
}

#endif
