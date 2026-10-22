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
/// are migrated; anything else is refused rather than inferred.
///
/// v2 → v3: compatibility is checked against the frozen v2 model, the mapping is confirmed to
/// be inferable before anything changes, the v2 store is copied with Core Data's supported
/// store-replacement API (including WAL and external binary files), and every v2 row and
/// attachment byte is fingerprinted before and after so the migrated library is proven equal.
///
/// The conversion itself is an in-place lightweight migration driven by a staged migration
/// manager that is handed the frozen source model directly (the models are built in code, so
/// there is no compiled bundle model for Core Data to discover). In-place migration keeps
/// persistent history and CloudKit mirroring metadata, which a copy-to-new-store migration
/// would discard and cause a full re-upload.
enum ManagedStoreMigration {
    /// Ordered stages from every frozen version to the current model.
    static func stagedMigrationManager() -> NSStagedMigrationManager {
        let v2 = ManagedStoreModel.v2(), v3 = ManagedStoreModel.v3()
        let stage = NSCustomMigrationStage(migratingFrom: NSManagedObjectModelReference(model: v2, versionChecksum: v2.versionChecksum),
                                           to: NSManagedObjectModelReference(model: v3, versionChecksum: v3.versionChecksum))
        stage.label = "RoamReady managed v2 to v3: shared document vault"
        return NSStagedMigrationManager([stage])
    }

    struct Pending: Sendable {
        let sourceVersion: String
        let fingerprint: String
        let backupURL: URL
    }
    static let backupDirectory = "Backups"
    static func backupURL(in directory: URL) -> URL {
        directory.appendingPathComponent(backupDirectory, isDirectory: true).appendingPathComponent("RoamReadyManaged-v2.sqlite")
    }

    /// Call before loading the Library store. Returns nil when no migration is required.
    static func prepare(libraryURL: URL, directory: URL) async throws -> Pending? {
        guard FileManager.default.fileExists(atPath: libraryURL.path) else { return nil }
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: libraryURL)
        let current = ManagedStoreModel.v3(), previous = ManagedStoreModel.v2()
        if current.isConfiguration(withName: ManagedStoreModel.library, compatibleWithStoreMetadata: metadata) { return nil }
        guard previous.isConfiguration(withName: ManagedStoreModel.library, compatibleWithStoreMetadata: metadata) else {
            throw ManagedStoreMigrationError.unrecognizedStoreVersion
        }
        _ = try NSMappingModel.inferredMappingModel(forSourceModel: previous, destinationModel: current)
        let sourceFingerprint = try await Self.fingerprint(ofStoreAt: libraryURL)
        let backup = backupURL(in: directory)
        // An earlier interrupted attempt already copied this same unmigrated v2 store.
        if !FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: previous)
            let options: [AnyHashable: Any] = [NSPersistentHistoryTrackingKey: true as NSNumber]
            try coordinator.replacePersistentStore(at: backup, destinationOptions: options, withPersistentStoreFrom: libraryURL,
                                                   sourceOptions: options, type: .sqlite)
        }
        return Pending(sourceVersion: ManagedStoreModel.v2Identifier, fingerprint: sourceFingerprint, backupURL: backup)
    }

    /// Fingerprint of a v2 store file, opened read-only with the frozen v2 model.
    static func fingerprint(ofStoreAt url: URL) async throws -> String {
        let model = ManagedStoreModel.v2()
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

    /// Canonical digest of every v2 Library row, including attachment bytes (photos).
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
