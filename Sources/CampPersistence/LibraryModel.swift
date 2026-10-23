#if canImport(CoreData)
import Foundation
import CoreData

/// The Core Data model, built in code so the package needs no compiled `.momd`.
///
/// Until the CloudKit schema is promoted to Production (#6), this model may change freely; dev stores
/// open through lightweight migration. After promotion CloudKit only accepts additive changes: add
/// optional attributes or entities, never rename, retype, or remove one, and never change which
/// attributes are cloud-encrypted. A change Core Data cannot infer needs an `NSStagedMigrationManager`
/// stage from a frozen copy of the shipped model.
enum LibraryModel {
    static let library = "Library", device = "Device"
    static let version = "RoamReady.Library.1"
    static let documentEntity = "RR_document", documentContentEntity = "RR_documentContent", metadataEntity = "LocalMetadata"

    static func entityName(_ kind: RecordKind) -> String { "RR_" + kind.rawValue }

    /// Every attribute a record kind stores. Binary values hold JSON-encoded `RecordValue`s.
    static func fields(_ kind: RecordKind) -> [String: NSAttributeType] {
        var strings: [String] = [], numbers: [String] = [], binary: [String] = [], booleans: [String] = []
        switch kind {
        case .profile: strings = ["name", "experience"]
        case .rig:
            strings = ["id", "type", "make", "model", "floorplan", "emoji", "photoFilename"]
            numbers = ["year", "lengthFeet", "slideCount", "axleCount", "archivedAt"]
            binary = ["equipment"]; booleans = ["hasBunkhouse"]
        case .trip:
            strings = ["id", "campgroundName", "siteNumber", "notes", "rating", "campgroundID", "planningTimeZoneIdentifier",
                       "campgroundTimeZoneIdentifier", "rigID", "loop", "confirmationNumber", "bookingProvider", "bookingURL"]
            numbers = ["latitude", "longitude", "arrival", "departure", "position", "checkInMinutes", "checkOutMinutes",
                       "totalCost", "amountPaid", "cancellationDeadline", "completedAt"]
            binary = ["initialChecklistKeys", "site"]
        case .checklistItem: strings = ["id", "title", "detail", "section", "status", "owner", "phase"]; numbers = ["position"]
        case .templates: strings = ["id", "sourceURL", "rigID"]; numbers = ["version"]; binary = ["initialChecklistKeys"]
        case .photo: strings = ["id", "filename", "caption", "owner"]; numbers = ["createdAt", "position"]
        case .asset: strings = ["filename", "checksum"]
        case .favorite: strings = ["campgroundID", "name", "region"]; booleans = ["saved", "wantToGo", "favorite", "beenTo"]
        case .noteRevision: strings = ["owner", "body"]; numbers = ["createdAt"]
        }
        var result = Dictionary(uniqueKeysWithValues: strings.map { ($0, NSAttributeType.stringAttributeType) })
        for name in numbers { result[name] = .doubleAttributeType }
        for name in binary { result[name] = .binaryDataAttributeType }
        for name in booleans { result[name] = .booleanAttributeType }
        return result
    }

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
    /// so it is end-to-end encrypted even without Advanced Data Protection. Fixed once the schema
    /// reaches Production: CloudKit cannot change a deployed field's encryption.
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
    /// only its small key relies on CloudKit's end-to-end encrypted fields (see `DocumentCipher`).
    static let cloudEncryptedContentFields: Set<String> = ["contentKey"]

    static func make() -> NSManagedObjectModel {
        let model = NSManagedObjectModel(); model.versionIdentifiers = [version]
        var library = RecordKind.allCases.map { kind in
            entity(entityName(kind), fields: fields(kind), externalBytes: kind == .asset)
        }
        library.append(entity(documentEntity, fields: documentFields, externalBytes: false, cloudEncrypted: cloudEncryptedDocumentFields))
        library.append(entity(documentContentEntity, fields: documentContentFields, externalBytes: true, cloudEncrypted: cloudEncryptedContentFields))
        let metadata = NSEntityDescription(); metadata.name = metadataEntity; metadata.managedObjectClassName = "NSManagedObject"
        metadata.properties = [attribute("key", .stringAttributeType), attribute("value", .binaryDataAttributeType)]
        model.entities = library + [metadata]
        model.setEntities(library, forConfigurationName: Self.library)
        model.setEntities([metadata], forConfigurationName: device)
        return model
    }

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
}
#endif
