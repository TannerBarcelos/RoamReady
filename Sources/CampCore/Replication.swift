import Foundation

/// Lamport ordering avoids relying on campsite devices having accurate wall clocks.
public struct FieldVersion: Codable, Equatable, Comparable, Sendable {
    public let counter: Int64
    public let writer: String
    public init(counter: Int64, writer: String) { self.counter = counter; self.writer = writer }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.counter == rhs.counter ? lhs.writer < rhs.writer : lhs.counter < rhs.counter
    }
}

public enum RecordValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: RecordValue]), array([RecordValue]), null
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: Self].self) { self = .object(v) }
        else { self = .array(try c.decode([Self].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public var string: String? { if case .string(let s) = self { s } else { nil } }
    public var number: Double? { if case .number(let n) = self { n } else { nil } }
}

public enum RecordKind: String, Codable, CaseIterable, Sendable {
    case profile, rig, trip, checklistItem, templates, photo, asset, favorite, noteRevision
}

/// A document maps to ONE database row / CloudKit record, never the entire library.
public struct ReplicaRecord: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public let key: String
    public let kind: RecordKind
    public var fields: [String: RecordValue]
    public var versions: [String: FieldVersion]
    /// Tombstones are permanent for this identity. Restoring creates a new identity.
    public var deletion: FieldVersion?
    public init(key: String, kind: RecordKind, fields: [String: RecordValue] = [:],
                versions: [String: FieldVersion] = [:], deletion: FieldVersion? = nil) {
        self.key = key; self.kind = kind; self.fields = fields; self.versions = versions; self.deletion = deletion
    }
    public var maximumCounter: Int64 { max(versions.values.map(\.counter).max() ?? 0, deletion?.counter ?? 0) }
    public func validated() throws -> Self {
        guard schemaVersion == 1, !key.isEmpty, key.utf8.count < 240,
              key.hasPrefix(kind.rawValue + ":"), maximumCounter >= 0, maximumCounter < Int64.max - 2,
              Set(fields.keys) == Set(versions.keys),
              versions.values.allSatisfy({ $0.counter > 0 && !$0.writer.isEmpty }),
              deletion.map({ $0.counter > 0 && !$0.writer.isEmpty }) ?? true else {
            throw ReplicationError.invalidRecord
        }
        return self
    }
    public func merging(_ other: Self) throws -> Self {
        _ = try validated(); _ = try other.validated()
        guard key == other.key, kind == other.kind else { throw ReplicationError.invalidRecord }
        var result = self
        for (field, version) in other.versions {
            if let current = result.versions[field], current == version,
               result.fields[field] != other.fields[field] { throw ReplicationError.invalidRecord }
            if result.versions[field].map({ $0 < version }) ?? true {
                result.fields[field] = other.fields[field]; result.versions[field] = version
            }
        }
        if let deleted = other.deletion, result.deletion.map({ $0 < deleted }) ?? true { result.deletion = deleted }
        return result
    }
}

public enum ReplicationError: Error, LocalizedError {
    case invalidRecord, incompleteLibrary, accountChanged, missingAsset, cloudLibraryRemoved
    public var errorDescription: String? {
        switch self {
        case .invalidRecord: "A saved or synced record has an unsupported or invalid format. Update RoamReady before trying again."
        case .incompleteLibrary: "Some related records have not arrived yet. Your saved records are preserved."
        case .accountChanged: "The iCloud account changed. Sync is paused to keep accounts separate. Your local library remains available."
        case .missingAsset: "The photo has not downloaded to this device yet."
        case .cloudLibraryRemoved: "Your iCloud library was removed. Sync is off; your local library remains available. Enable sync explicitly to upload it again."
        }
    }
}

public struct LibrarySnapshot: Equatable, Sendable {
    public var state: AppState
    public var favorites: Set<String>
    public init(state: AppState = AppState(), favorites: Set<String> = []) { self.state = state; self.favorites = favorites }
}

/// Codable domain types remain independent of Core Data / CloudKit.
public enum RecordProjection {
    public static func documents(_ snapshot: LibrarySnapshot) throws -> [String: ReplicaRecord] {
        _ = try snapshot.state.validated()
        var result: [String: ReplicaRecord] = [:]
        func add(_ key: String, _ kind: RecordKind, _ fields: [String: RecordValue]) {
            result[key] = ReplicaRecord(key: key, kind: kind, fields: fields)
        }
        func rig(_ value: Rig, key: String) throws { add(key, .rig, try fields(value)) }
        func items(_ values: [ChecklistItem], owner: String, phase: String) throws {
            for (position, item) in values.enumerated() {
                var f = try fields(item)
                f["owner"] = .string(owner); f["phase"] = .string(phase); f["position"] = .number(Double(position))
                add("checklistItem:\(owner):\(phase):\(item.id)", .checklistItem, f)
            }
        }
        if let profile = snapshot.state.profile {
            var f = try fields(profile); f.removeValue(forKey: "rig"); f["rigKey"] = .string("rig:profile")
            add("profile:current", .profile, f); try rig(profile.rig, key: "rig:profile")
        }
        if let templates = snapshot.state.templates {
            let f: [String: RecordValue] = ["id": .string(templates.id.uuidString), "version": .number(Double(templates.version)), "sourceURL": .string(templates.sourceURL)]
            add("templates:current", .templates, f)
            try items(templates.setup, owner: "templates:\(templates.id)", phase: "setup")
            try items(templates.teardown, owner: "templates:\(templates.id)", phase: "teardown")
        }
        for (tripPosition, trip) in snapshot.state.trips.enumerated() {
            let key = "trip:\(trip.id)"
            var f: [String: RecordValue] = [
                "id": .string(trip.id.uuidString), "campgroundName": .string(trip.campgroundName),
                "arrival": .number(trip.arrival.timeIntervalSinceReferenceDate), "departure": .number(trip.departure.timeIntervalSinceReferenceDate),
                "siteNumber": .string(trip.siteNumber), "notes": .string(trip.notes), "rating": .string(trip.rating.rawValue)
            ]
            if let latitude = trip.latitude { f["latitude"] = .number(latitude) }
            if let longitude = trip.longitude { f["longitude"] = .number(longitude) }
            if let id = trip.campgroundID { f["campgroundID"] = .string(id) }
            if let zone = trip.planningTimeZoneIdentifier { f["planningTimeZoneIdentifier"] = .string(zone) }
            if let zone = trip.campgroundTimeZoneIdentifier { f["campgroundTimeZoneIdentifier"] = .string(zone) }
            if let value = trip.rigSnapshot { let rigKey = "rig:\(trip.id)"; try rig(value, key: rigKey); f["rigKey"] = .string(rigKey) }
            f["position"] = .number(Double(tripPosition))
            add(key, .trip, f)
            try items(trip.setup, owner: key, phase: "setup"); try items(trip.teardown, owner: key, phase: "teardown")
            for (position, photo) in trip.photos.enumerated() {
                var p = try fields(photo); p["owner"] = .string(key); p["position"] = .number(Double(position))
                add("photo:\(photo.id)", .photo, p)
            }
        }
        for id in snapshot.favorites { add("favorite:\(id)", .favorite, ["campgroundID": .string(id), "saved": .bool(true)]) }
        return result
    }
    public static func snapshot(_ records: [ReplicaRecord]) throws -> LibrarySnapshot {
        let active = records.filter { $0.deletion == nil }
        let byKey = Dictionary(uniqueKeysWithValues: active.map { ($0.key, $0) })
        let allKeys = Set(records.map(\.key))
        for record in active where record.kind == .trip || record.kind == .templates {
            if case .array(let required) = record.fields["initialChecklistKeys"] {
                guard required.allSatisfy({ $0.string.map(allKeys.contains) ?? false }) else { throw ReplicationError.incompleteLibrary }
            }
        }
        let itemGroups = Dictionary(grouping: active.filter { $0.kind == .checklistItem }) {
            ($0.fields["owner"]?.string ?? "") + "|" + ($0.fields["phase"]?.string ?? "")
        }
        let photoGroups = Dictionary(grouping: active.filter { $0.kind == .photo }) { $0.fields["owner"]?.string ?? "" }
        func items(_ owner: String, _ phase: String) throws -> [ChecklistItem] {
            try (itemGroups[owner + "|" + phase] ?? [])
                .sorted { a, b in
                    let x = a.fields["position"]?.number ?? 0, y = b.fields["position"]?.number ?? 0
                    return x == y ? a.key < b.key : x < y
                }.map { try decode(ChecklistItem.self, $0.fields) }
        }
        var state = AppState()
        if var f = byKey["profile:current"]?.fields {
            guard let key = f.removeValue(forKey: "rigKey")?.string, let rig = byKey[key] else { throw ReplicationError.incompleteLibrary }
            f["rig"] = .object(rig.fields); state.profile = try decode(CamperProfile.self, f)
        }
        if var f = byKey["templates:current"]?.fields {
            guard let templateID = f["id"]?.string else { throw ReplicationError.incompleteLibrary }
            let templateOwner = "templates:\(templateID)"
            f["setup"] = .array(try items(templateOwner, "setup").map { .object(try fields($0)) })
            f["teardown"] = .array(try items(templateOwner, "teardown").map { .object(try fields($0)) })
            state.templates = try decode(ChecklistTemplates.self, f)
        }
        for record in active.filter({ $0.kind == .trip }).sorted(by: { ($0.fields["position"]?.number ?? 0) == ($1.fields["position"]?.number ?? 0) ? $0.key < $1.key : ($0.fields["position"]?.number ?? 0) < ($1.fields["position"]?.number ?? 0) }) {
            var f = record.fields
            if let key = f.removeValue(forKey: "rigKey")?.string {
                guard let rig = byKey[key] else { throw ReplicationError.incompleteLibrary }
                f["rigSnapshot"] = .object(rig.fields)
            }
            f["setup"] = .array(try items(record.key, "setup").map { .object(try fields($0)) })
            f["teardown"] = .array(try items(record.key, "teardown").map { .object(try fields($0)) })
            f["photos"] = .array((photoGroups[record.key] ?? [])
                .sorted { ($0.fields["position"]?.number ?? 0) == ($1.fields["position"]?.number ?? 0) ? $0.key < $1.key : ($0.fields["position"]?.number ?? 0) < ($1.fields["position"]?.number ?? 0) }.map { .object($0.fields) })
            state.trips.append(try decode(Trip.self, f))
        }
        return LibrarySnapshot(state: try state.validated(), favorites: Set(active.filter { $0.kind == .favorite && $0.fields["saved"] == .bool(true) }.compactMap { $0.fields["campgroundID"]?.string }))
    }
    public static func fields<T: Encodable>(_ value: T) throws -> [String: RecordValue] {
        try JSONDecoder().decode([String: RecordValue].self, from: JSONEncoder().encode(value))
    }
    public static func decode<T: Decodable>(_ type: T.Type, _ fields: [String: RecordValue]) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(fields))
    }
    public static func referencedPhotos(_ state: AppState) -> Set<String> {
        var names = state.trips.flatMap { $0.photos.map(\.filename) + [$0.rigSnapshot?.photoFilename].compactMap { $0 } }
        if let name = state.profile?.rig.photoFilename { names.append(name) }
        return Set(names)
    }
}
