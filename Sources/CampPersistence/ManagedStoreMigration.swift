#if canImport(CoreData)
import Foundation
@preconcurrency import CoreData
import CampCore

public enum ManagedStoreMigrationError: Error, LocalizedError {
    case unrecognizedStoreVersion, verificationFailed
    public var errorDescription: String? {
        switch self {
        case .unrecognizedStoreVersion: "Your library was saved by a different version of RoamReady. Update the app before opening it. Nothing was changed."
        case .verificationFailed: "Your library couldn’t be verified after updating its format. A copy of the previous library is preserved on this device."
        }
    }
}

/// Explicit, verified migration between frozen managed models. Only known source versions
/// (v2 and v3) are migrated; anything else is refused rather than inferred.
///
/// Before the Library store loads, the source version is identified against the frozen models,
/// each stage's mapping is confirmed to be inferable before anything changes, the store is copied
/// with Core Data's supported store-replacement API (including WAL and external binary files),
/// and every existing row and attachment byte is fingerprinted before and after so the migrated
/// library is proven equal.
///
/// The conversion itself is an in-place lightweight migration driven by a staged migration
/// manager that is handed the frozen models directly (they are built in code, so there is no
/// compiled bundle model for Core Data to discover). In-place migration keeps persistent history
/// and CloudKit mirroring metadata, which a copy-to-new-store migration would discard and cause
/// a full re-upload.
enum ManagedStoreMigration {
    /// One lightweight stage between each pair of neighbouring frozen versions, ending at current.
    static func stagedMigrationManager() -> NSStagedMigrationManager {
        let models = ManagedStoreModel.versions.map { ($0.identifier, ManagedStoreModel.immutable($0.make())) }
        let stages = zip(models, models.dropFirst()).map { from, to in
            let stage = NSCustomMigrationStage(migratingFrom: NSManagedObjectModelReference(model: from.1, versionChecksum: from.1.versionChecksum),
                                               to: NSManagedObjectModelReference(model: to.1, versionChecksum: to.1.versionChecksum))
            stage.label = "RoamReady \(from.0) to \(to.0)"
            return stage
        }
        return NSStagedMigrationManager(stages)
    }

    struct Pending: Sendable {
        let sourceVersion: String
        let fingerprint: String
        let backupURL: URL
    }
    static let backupDirectory = "Backups"
    /// One preserved copy per source version, e.g. `Backups/RoamReadyManaged-RoamReady.Managed.v2.sqlite`.
    static func backupURL(in directory: URL, version: String) -> URL {
        directory.appendingPathComponent(backupDirectory, isDirectory: true).appendingPathComponent("RoamReadyManaged-\(version).sqlite")
    }
    /// The newest preserved backup, used to re-verify a migration the app stopped during.
    static func existingBackup(in directory: URL) -> (version: String, url: URL)? {
        for version in ManagedStoreModel.versions.dropLast().reversed().map(\.identifier) {
            let url = backupURL(in: directory, version: version)
            if FileManager.default.fileExists(atPath: url.path) { return (version, url) }
        }
        return nil
    }

    /// Call before loading the Library store. Returns nil when no migration is required.
    static func prepare(libraryURL: URL, directory: URL) async throws -> Pending? {
        guard FileManager.default.fileExists(atPath: libraryURL.path) else { return nil }
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: libraryURL)
        let models = ManagedStoreModel.versions.map { ($0.identifier, $0.make()) }
        guard let sourceIndex = models.lastIndex(where: { $0.1.isConfiguration(withName: ManagedStoreModel.library, compatibleWithStoreMetadata: metadata) }) else {
            throw ManagedStoreMigrationError.unrecognizedStoreVersion
        }
        if sourceIndex == models.count - 1 { return nil }
        let (version, source) = models[sourceIndex]
        for index in sourceIndex..<(models.count - 1) {
            _ = try NSMappingModel.inferredMappingModel(forSourceModel: models[index].1, destinationModel: models[index + 1].1)
        }
        let sourceFingerprint = try await Self.fingerprint(ofStoreAt: libraryURL, version: version)
        let backup = backupURL(in: directory, version: version)
        // An earlier interrupted attempt already copied this same unmigrated store.
        if !FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: source)
            let options: [AnyHashable: Any] = [NSPersistentHistoryTrackingKey: true as NSNumber]
            try coordinator.replacePersistentStore(at: backup, destinationOptions: options, withPersistentStoreFrom: libraryURL,
                                                   sourceOptions: options, type: .sqlite)
        }
        return Pending(sourceVersion: version, fingerprint: sourceFingerprint, backupURL: backup)
    }

    /// Fingerprint of a store file in a frozen `version`, opened read-only with that model.
    static func fingerprint(ofStoreAt url: URL, version: String) async throws -> String {
        guard let model = ManagedStoreModel.model(version) else { throw ManagedStoreMigrationError.unrecognizedStoreVersion }
        let container = NSPersistentContainer(name: "RoamReadyMigrationSource", managedObjectModel: model)
        let description = NSPersistentStoreDescription(url: url)
        description.configuration = ManagedStoreModel.library; description.type = NSSQLiteStoreType
        description.isReadOnly = true
        description.shouldMigrateStoreAutomatically = false; description.shouldInferMappingModelAutomatically = false
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        container.persistentStoreDescriptions = [description]
        try await SQLiteStore.loadStores(container)
        defer { for store in container.persistentStoreCoordinator.persistentStores { try? container.persistentStoreCoordinator.remove(store) } }
        let context = container.newBackgroundContext()
        return try await context.perform { try fingerprint(context: context, model: model) }
    }

    /// Canonical digest of every library row the source model defines, including attachment bytes
    /// (photos). Uses the source model's attributes, so it is comparable before and after migration.
    static func fingerprint(context: NSManagedObjectContext, model: NSManagedObjectModel) throws -> String {
        var rows: [String] = []
        for kind in ManagedStoreModel.v2RecordKinds {
            let name = LegacyStoreModel.name(kind)
            guard let entity = model.entitiesByName[name] else { throw ManagedStoreMigrationError.verificationFailed }
            let keys = entity.attributesByName.keys.sorted()
            for row in try context.fetch(NSFetchRequest<NSManagedObject>(entityName: name)) {
                var values: [String: String] = ["entity": name]
                for key in keys {
                    switch row.value(forKey: key) {
                    case nil: values[key] = "nil"
                    case let data as Data: values[key] = "sha256:" + DocumentDigest.sha256(data)
                    case let number as NSNumber: values[key] = "n:" + number.stringValue
                    case let string as String: values[key] = "s:" + string
                    case let other?: values[key] = "?:" + String(describing: other)
                    }
                }
                let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                rows.append(String(decoding: try encoder.encode(values), as: UTF8.self))
                // Release attachment bytes as soon as they are hashed.
                context.refresh(row, mergeChanges: false)
            }
        }
        return DocumentDigest.sha256(Data(rows.sorted().joined(separator: "\n").utf8)) + ":\(rows.count)"
    }
}
#endif
