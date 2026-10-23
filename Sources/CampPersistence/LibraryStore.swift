#if canImport(CoreData)
import Foundation
@preconcurrency import CoreData
import CampCore
import DocumentVault

public struct NoteRevision: Identifiable, Sendable {
    public let id: String
    public let text: String
    public let date: Date
}

/// Core Data owns SQLite, external binary files, persistent history, and CloudKit mirroring.
/// Only value types leave the private managed-object context.
public final class LibraryStore: @unchecked Sendable {
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

    public static func open(directory: URL, cloudContainerIdentifier: String? = nil) async throws -> LibraryStore {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Staging holds only transient copies from an interrupted document import.
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(stagingDirectoryName, isDirectory: true))
        // Open locally first so interrupted writes are cleaned up and the library is proven readable
        // before mirroring can upload anything.
        let local = try await load(directory: directory, cloudContainerIdentifier: nil)
        do {
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

    private static func load(directory: URL, cloudContainerIdentifier: String?) async throws -> LibraryStore {
        let container = NSPersistentCloudKitContainer(name: "RoamReady", managedObjectModel: LibraryModel.make())
        let library = NSPersistentStoreDescription(url: directory.appendingPathComponent("RoamReadyManaged.sqlite"))
        library.configuration = LibraryModel.library
        library.type = NSSQLiteStoreType
        library.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        library.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        if let cloudContainerIdentifier {
            library.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: cloudContainerIdentifier)
        }
        let local = NSPersistentStoreDescription(url: directory.appendingPathComponent("RoamReadyDevice.sqlite"))
        local.configuration = LibraryModel.device
        local.type = NSSQLiteStoreType
        for description in [library, local] {
            description.shouldMigrateStoreAutomatically = true
            description.shouldInferMappingModelAutomatically = true
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
        return LibraryStore(container: container, directory: directory, cloudEnabled: cloudContainerIdentifier != nil)
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
    private func coherentDocuments(_ actual: [StoredRecord], previous: LibrarySnapshot?) throws -> [StoredRecord] {
        let cached = try previous.map { try RecordProjection.documents($0) } ?? [:]
        var candidate = Dictionary(uniqueKeysWithValues: actual.map { ($0.key, $0) })
        for parent in actual where !parent.isDeleted && (parent.kind == .templates || parent.kind == .trip) {
            var incomplete = false
            if case .array(let required) = parent.fields["initialChecklistKeys"] {
                for value in required {
                    guard let key = value.string else { throw LibraryError.invalidRecord }
                    if candidate[key] == nil || (parent.kind == .templates && candidate[key]?.isDeleted == true) {
                        if let old = cached[key] { candidate[key] = old } else { incomplete = true }
                    }
                }
            }
            if incomplete {
                candidate[parent.key] = cached[parent.key]
                if let old = cached[parent.key] {
                    let owner = parent.kind == .templates ? "templates:\(old.fields["id"]?.string ?? "")" : old.key
                    for doc in cached.values where doc.fields["owner"]?.string == owner { candidate[doc.key] = doc }
                }
            }
        }
        return Array(candidate.values)
    }

    public func save(from baseline: LibrarySnapshot, to desired: LibrarySnapshot) async throws {
        // The active-rig limit is enforced here too, so no caller can exceed it silently.
        try desired.state.validateRigLimit(comparedTo: baseline.state)
        let purged: Set<String> = try await context.perform { [self] () throws -> Set<String> in
            do {
                let purged = try apply(from: baseline, to: desired)
                if context.hasChanges { try context.save() }
                return purged
            } catch { context.rollback(); throw error }
        }
        // Local copies go only after the commit that released them succeeded.
        let media = directory.appendingPathComponent("Media", isDirectory: true)
        for filename in purged { try? FileManager.default.removeItem(at: media.appendingPathComponent(filename)) }
        _ = try await snapshot()
    }

    public func export(to url: URL) async throws {
        let library = try await snapshot()
        struct Export: Encodable { let schemaVersion = 1; let state: AppState; let savedCampgrounds: [SavedCampground] }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Export(state: library.state,
                                             savedCampgrounds: library.saved.values.sorted { $0.campgroundID < $1.campgroundID }))
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
            return try records(kinds: [.noteRevision]).filter { !$0.isDeleted && $0.fields["owner"]?.string == "trip:\(tripID)" }.map {
                NoteRevision(id: $0.key, text: $0.fields["body"]?.string ?? "", date: Date(timeIntervalSinceReferenceDate: $0.fields["createdAt"]?.number ?? 0))
            }.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
        }
    }

    /// Returns photo filenames whose bytes were purged because nothing references them any more.
    private func apply(from baseline: LibrarySnapshot, to desired: LibrarySnapshot) throws -> Set<String> {
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
                if kind == .trip {
                    for match in matches { match.setValue(nil, forKey: "notes") }
                    try removeNoteRevisions(owner: key)
                }
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
            guard filename == (filename as NSString).lastPathComponent, !filename.contains("..") else { throw LibraryError.invalidRecord }
            let path = directory.appendingPathComponent("Media", isDirectory: true).appendingPathComponent(filename)
            let existing = try rows("asset:\(filename)", .asset)
            if !existing.isEmpty {
                // A purged asset that is referenced again is revived from the local copy when present.
                guard existing.allSatisfy({ $0.value(forKey: "removed") as? Bool == true }),
                      let bytes = try? Data(contentsOf: path) else { continue }
                existing[0].setValue(false, forKey: "removed"); existing[0].setValue(bytes, forKey: "bytes")
                existing[0].setValue(Self.checksum(bytes), forKey: "checksum")
                continue
            }
            guard FileManager.default.fileExists(atPath: path.path) else { continue }
            let bytes = try Data(contentsOf: path), row = insert("asset:\(filename)", .asset)
            row.setValue(filename, forKey: "filename"); row.setValue(Self.checksum(bytes), forKey: "checksum")
            row.setValue(bytes, forKey: "bytes")
        }
        // Purge photos this change released, unless a live row (including one synced from another
        // device) still references them. Removing the bytes also frees the user's iCloud storage.
        let released = RecordProjection.referencedPhotos(baseline.state).subtracting(RecordProjection.referencedPhotos(desired.state))
        guard !released.isEmpty else { return [] }
        let live = try records(kinds: [.rig, .photo]).filter { !$0.isDeleted }
        let stillReferenced = Set(live.compactMap { ($0.fields["photoFilename"] ?? $0.fields["filename"])?.string })
        var purged = Set<String>()
        for filename in released.subtracting(stillReferenced) {
            for row in try rows("asset:\(filename)", .asset) {
                row.setValue(true, forKey: "removed"); row.setValue(nil, forKey: "bytes")
            }
            purged.insert(filename)
        }
        return purged
    }

    /// A deleted trip's note history goes with it. The text is cleared so it doesn't linger
    /// in the store or in iCloud; the tombstone keeps the deletion syncing.
    private func removeNoteRevisions(owner: String) throws {
        let request = NSFetchRequest<NSManagedObject>(entityName: LibraryModel.entityName(.noteRevision))
        request.predicate = NSPredicate(format: "owner == %@", owner)
        for row in try context.fetch(request) {
            row.setValue(true, forKey: "removed"); row.setValue(nil, forKey: "body")
        }
    }

    private static func checksum(_ data: Data) -> String { DocumentDigest.sha256(data) }
    private func rows(_ key: String, _ kind: RecordKind) throws -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: LibraryModel.entityName(kind))
        request.predicate = NSPredicate(format: "key == %@", key)
        return try context.fetch(request).sorted { identity($0) < identity($1) }
    }
    private func identity(_ row: NSManagedObject) -> String { row.value(forKey: "rowID") as? String ?? row.objectID.uriRepresentation().absoluteString }
    private func insert(_ key: String, _ kind: RecordKind) -> NSManagedObject {
        let row = NSEntityDescription.insertNewObject(forEntityName: LibraryModel.entityName(kind), into: context)
        row.setValue(key, forKey: "key"); row.setValue(UUID().uuidString, forKey: "rowID")
        return row
    }
    private func records(kinds: [RecordKind] = RecordKind.allCases.filter { $0 != .asset && $0 != .noteRevision }) throws -> [StoredRecord] {
        try kinds.flatMap { kind in
            let fetched = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: LibraryModel.entityName(kind)))
            // CloudKit does not support Core Data uniqueness constraints. Reconcile logical
            // identities deterministically, including singletons created offline on two devices.
            let groups = Dictionary(grouping: fetched) { $0.value(forKey: "key") as? String ?? "" }
            return try groups.keys.sorted().compactMap { key -> StoredRecord? in
                guard !key.isEmpty, let row = groups[key]?.sorted(by: { identity($0) < identity($1) }).first else { return nil }
                let deleted = groups[key]!.contains { $0.value(forKey: "removed") as? Bool == true }
                var fields: [String: RecordValue] = [:]
                for (field, type) in LibraryModel.fields(kind) {
                    guard let value = row.value(forKey: field) else { continue }
                    switch type {
                    case .stringAttributeType: fields[field] = .string(value as! String)
                    case .doubleAttributeType: fields[field] = .number((value as! NSNumber).doubleValue)
                    case .booleanAttributeType: fields[field] = .bool((value as! NSNumber).boolValue)
                    default: fields[field] = try JSONDecoder().decode(RecordValue.self, from: value as! Data)
                    }
                }
                return StoredRecord(key: key, kind: kind, fields: fields, isDeleted: deleted)
            }
        }
    }
    private func set(_ value: RecordValue, field: String, kind: RecordKind, row: NSManagedObject) throws {
        guard let type = LibraryModel.fields(kind)[field] else { throw LibraryError.invalidRecord }
        switch (type, value) {
        case (_, .null): row.setValue(nil, forKey: field)
        case (.stringAttributeType, .string(let v)): row.setValue(v, forKey: field)
        case (.doubleAttributeType, .number(let v)): guard v.isFinite else { throw LibraryError.invalidRecord }; row.setValue(v, forKey: field)
        case (.booleanAttributeType, .bool(let v)): row.setValue(v, forKey: field)
        case (.binaryDataAttributeType, _): row.setValue(try JSONEncoder().encode(value), forKey: field)
        default: throw LibraryError.invalidRecord
        }
    }
    private struct CachedLibrary: Codable {
        let state: AppState
        let saved: [String: SavedCampground]
        var library: LibrarySnapshot { LibrarySnapshot(state: state, saved: saved) }
    }
    private func cache(_ library: LibrarySnapshot) throws {
        let bytes = try JSONEncoder().encode(CachedLibrary(state: library.state, saved: library.saved))
        guard try meta("coherentProjection") != bytes else { return }
        try putMeta("coherentProjection", bytes); try context.save()
    }
    func meta(_ key: String) throws -> Data? {
        let request = NSFetchRequest<NSManagedObject>(entityName: LibraryModel.metadataEntity)
        request.predicate = NSPredicate(format: "key == %@", key); request.fetchLimit = 1
        return try context.fetch(request).first?.value(forKey: "value") as? Data
    }
    /// Device-only metadata. Call inside `context.perform`.
    func putMeta(_ key: String, _ value: Data?) throws {
        let request = NSFetchRequest<NSManagedObject>(entityName: LibraryModel.metadataEntity)
        request.predicate = NSPredicate(format: "key == %@", key); request.fetchLimit = 1
        let row = try context.fetch(request).first ?? NSEntityDescription.insertNewObject(forEntityName: LibraryModel.metadataEntity, into: context)
        row.setValue(key, forKey: "key"); row.setValue(value, forKey: "value")
    }


}

#endif
