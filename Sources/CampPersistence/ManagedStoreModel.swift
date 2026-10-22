#if canImport(CoreData)
import Foundation
import CoreData
import CampCore

/// Versioned managed models. Shipped versions are frozen: never edit `v2()` or anything it
/// reads. Add a new version, keep the previous one buildable, and migrate explicitly
/// (see `ManagedStoreMigration`). `SQLiteStoreTests` pins each frozen shape.
enum ManagedStoreModel {
    static let library = "Library", device = "Device"
    static let v2Identifier = "RoamReady.Managed.v2", v3Identifier = "RoamReady.Managed.v3"
    static let documentEntity = "RR_document", documentContentEntity = "RR_documentContent"

    /// The model new and migrated stores open with.
    static func make() -> NSManagedObjectModel { v3() }

    /// FROZEN: first managed CloudKit mirroring model.
    static func v2() -> NSManagedObjectModel { build(version: v2Identifier, includesDocuments: false) }

    /// v2 plus the shared document vault. Purely additive, so a lightweight mapping exists.
    static func v3() -> NSManagedObjectModel { build(version: v3Identifier, includesDocuments: true) }

    /// A model's version checksum is only stable once it can no longer be edited. Attaching it
    /// to a coordinator locks it; read `versionChecksum` only from models returned here.
    static func immutable(_ model: NSManagedObjectModel) -> NSManagedObjectModel {
        _ = NSPersistentStoreCoordinator(managedObjectModel: model)
        return model
    }

    /// Record kinds present in v2. Fixed here so a future `RecordKind` case cannot alter it.
    static let v2RecordKinds: [RecordKind] = [.profile, .rig, .trip, .checklistItem, .templates, .photo, .asset, .favorite, .noteRevision]

    /// Document metadata. Bytes live in a separate entity so listings never fault them.
    static let documentFields: [String: NSAttributeType] = [
        "id": .stringAttributeType, "ownerKind": .stringAttributeType, "ownerID": .stringAttributeType,
        "title": .stringAttributeType, "category": .stringAttributeType, "notes": .stringAttributeType,
        "linkURL": .stringAttributeType, "filename": .stringAttributeType, "contentType": .stringAttributeType,
        "checksum": .stringAttributeType, "byteCount": .integer64AttributeType, "protection": .stringAttributeType,
        "issuedOn": .doubleAttributeType, "expiresOn": .doubleAttributeType,
        "createdAt": .doubleAttributeType, "updatedAt": .doubleAttributeType
    ]
    /// Personal metadata stored in CloudKit `encryptedValues`, keyed by the user's iCloud Keychain,
    /// so it is end-to-end encrypted even without Advanced Data Protection. CloudKit cannot change
    /// a field's encryption after the schema is deployed to production, so this set is fixed for v3.
    static let cloudEncryptedDocumentFields: Set<String> = ["title", "notes", "linkURL", "filename"]
    /// One row per 1 MiB chunk of a stored file version, so neither Core Data nor CloudKit ever
    /// handles a whole large file as one value. `versionID` groups the chunks written together;
    /// a file is available only when one version has all of its chunks. `checksum` and `byteCount` describe the whole
    /// original plaintext (identifying the version); `chunkIndex`, `chunkCount`, and `chunkChecksum`
    /// (SHA-256 of the chunk's plaintext) describe this chunk. For end-to-end protected files,
    /// `bytes` holds a `DocumentCipher` box and `contentKey` the version's key.
    static let documentContentFields: [String: NSAttributeType] = [
        "documentID": .stringAttributeType, "versionID": .stringAttributeType, "checksum": .stringAttributeType, "byteCount": .integer64AttributeType,
        "chunkIndex": .integer64AttributeType, "chunkCount": .integer64AttributeType, "chunkChecksum": .stringAttributeType,
        "encryption": .stringAttributeType, "contentKey": .binaryDataAttributeType
    ]
    /// CloudKit field encryption does not apply to assets, so the file is encrypted by the app and
    /// only its small key relies on CloudKit's end-to-end encrypted fields.
    static let cloudEncryptedContentFields: Set<String> = ["contentKey"]

    private static func attribute(_ name: String, _ type: NSAttributeType) -> NSAttributeDescription {
        let value = NSAttributeDescription(); value.name = name; value.attributeType = type; value.isOptional = true; return value
    }

    /// CloudKit-compatible entity: optional attributes or defaults, no uniqueness constraints,
    /// no relationships. Logical identity is the `key` attribute, reconciled by `rowID`.
    private static func entity(_ name: String, fields: [String: NSAttributeType], externalBytes: Bool,
                               cloudEncrypted: Set<String> = []) -> NSEntityDescription {
        let entity = NSEntityDescription(); entity.name = name; entity.managedObjectClassName = "NSManagedObject"
        let deleted = attribute("removed", .booleanAttributeType); deleted.defaultValue = false
        var properties = [attribute("key", .stringAttributeType), attribute("rowID", .stringAttributeType), deleted]
        properties += fields.sorted { $0.key < $1.key }.map { field in
            let value = attribute(field.key, field.value)
            if cloudEncrypted.contains(field.key) { value.allowsCloudEncryption = true }
            return value
        }
        if externalBytes {
            // Core Data decides whether bytes stay inline in SQLite or move to its external files.
            let bytes = attribute("bytes", .binaryDataAttributeType); bytes.allowsExternalBinaryDataStorage = true
            properties.append(bytes)
        }
        entity.properties = properties
        return entity
    }

    private static func build(version: String, includesDocuments: Bool) -> NSManagedObjectModel {
        let model = NSManagedObjectModel(); model.versionIdentifiers = [version]
        var library = v2RecordKinds.map { kind in
            entity(LegacyStoreModel.name(kind), fields: LegacyStoreModel.fields(kind), externalBytes: kind == .asset)
        }
        if includesDocuments {
            library.append(entity(documentEntity, fields: documentFields, externalBytes: false, cloudEncrypted: cloudEncryptedDocumentFields))
            library.append(entity(documentContentEntity, fields: documentContentFields, externalBytes: true, cloudEncrypted: cloudEncryptedContentFields))
        }
        let metadata = NSEntityDescription(); metadata.name = "LocalMetadata"; metadata.managedObjectClassName = "NSManagedObject"
        metadata.properties = [attribute("key", .stringAttributeType), attribute("value", .binaryDataAttributeType)]
        model.entities = library + [metadata]
        model.setEntities(library, forConfigurationName: Self.library)
        model.setEntities([metadata], forConfigurationName: device)
        return model
    }
}
#endif
