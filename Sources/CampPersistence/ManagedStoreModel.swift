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

    /// Record kinds present in v2. Fixed here so a future `RecordKind` case cannot alter it.
    static let v2RecordKinds: [RecordKind] = [.profile, .rig, .trip, .checklistItem, .templates, .photo, .asset, .favorite, .noteRevision]

    /// Document metadata. Bytes live in a separate entity so listings never fault them.
    static let documentFields: [String: NSAttributeType] = [
        "id": .stringAttributeType, "ownerKind": .stringAttributeType, "ownerID": .stringAttributeType,
        "title": .stringAttributeType, "category": .stringAttributeType, "notes": .stringAttributeType,
        "linkURL": .stringAttributeType, "filename": .stringAttributeType, "contentType": .stringAttributeType,
        "checksum": .stringAttributeType, "byteCount": .integer64AttributeType,
        "issuedOn": .doubleAttributeType, "expiresOn": .doubleAttributeType,
        "createdAt": .doubleAttributeType, "updatedAt": .doubleAttributeType
    ]
    static let documentContentFields: [String: NSAttributeType] = [
        "documentID": .stringAttributeType, "checksum": .stringAttributeType, "byteCount": .integer64AttributeType
    ]

    private static func attribute(_ name: String, _ type: NSAttributeType) -> NSAttributeDescription {
        let value = NSAttributeDescription(); value.name = name; value.attributeType = type; value.isOptional = true; return value
    }

    /// CloudKit-compatible entity: optional attributes or defaults, no uniqueness constraints,
    /// no relationships. Logical identity is the `key` attribute, reconciled by `rowID`.
    private static func entity(_ name: String, fields: [String: NSAttributeType], externalBytes: Bool) -> NSEntityDescription {
        let entity = NSEntityDescription(); entity.name = name; entity.managedObjectClassName = "NSManagedObject"
        let deleted = attribute("removed", .booleanAttributeType); deleted.defaultValue = false
        var properties = [attribute("key", .stringAttributeType), attribute("rowID", .stringAttributeType), deleted]
        properties += fields.sorted { $0.key < $1.key }.map { attribute($0.key, $0.value) }
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
            library.append(entity(documentEntity, fields: documentFields, externalBytes: false))
            library.append(entity(documentContentEntity, fields: documentContentFields, externalBytes: true))
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
