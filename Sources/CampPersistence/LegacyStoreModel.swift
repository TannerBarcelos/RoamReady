#if canImport(CoreData)
import Foundation
import CoreData
import CampCore

/// Freeze v1. Add future model versions explicitly; never silently mutate this schema.
enum LegacyStoreModel {
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
    /// Current managed (CloudKit-mirrored) attributes: v1 plus additive, optional fields.
    /// Lightweight migration infers these; deploy the CloudKit schema again before release.
    static func managedFields(_ kind: RecordKind) -> [String: NSAttributeType] {
        var result = fields(kind)
        if kind == .rig {
            for n in ["lengthFeet", "slideCount", "axleCount"] { result[n] = .doubleAttributeType }
            result["hasBunkhouse"] = .booleanAttributeType
        }
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
