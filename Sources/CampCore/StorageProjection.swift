import Foundation

/// Compatibility value for decoding the previous development store only.
public struct FieldVersion: Codable, Equatable, Sendable {
    public let counter: Int64
    public let writer: String
    public init(counter: Int64, writer: String) { self.counter = counter; self.writer = writer }
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

/// Value projection of one managed record. Versions are retained only for legacy decoding.
public struct ReplicaRecord: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public let key: String
    public let kind: RecordKind
    public var fields: [String: RecordValue]
    public var versions: [String: FieldVersion]
    /// Non-nil marks a removed record in the domain projection.
    public var deletion: FieldVersion?
    public init(key: String, kind: RecordKind, fields: [String: RecordValue] = [:],
                versions: [String: FieldVersion] = [:], deletion: FieldVersion? = nil) {
        self.key = key; self.kind = kind; self.fields = fields; self.versions = versions; self.deletion = deletion
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
    /// Saved campgrounds by campground ID.
    public var saved: [String: SavedCampground]
    public init(state: AppState = AppState(), saved: [String: SavedCampground] = [:]) { self.state = state; self.saved = saved }
    /// Campgrounds saved before lists existed (a single bookmark) are on "Want to go".
    public init(state: AppState = AppState(), favorites: Set<String>) {
        self.init(state: state, saved: Dictionary(uniqueKeysWithValues: favorites.map { ($0, SavedCampground(campgroundID: $0, wantToGo: true)) }))
    }
    /// Every saved campground's ID, whatever its lists.
    public var favorites: Set<String> { Set(saved.keys) }
}

/// Codable domain types remain independent of Core Data / CloudKit.
///
/// Record layout: `profile:current`; `rig:<rig id>` per rig (archived ones included);
/// `templates:rig:<rig id>` per rig's default lists, whose items are owned by `templates:<templates id>`;
/// `trip:<trip id>` with a `rigID` reference. Libraries saved before #28 used `rigKey` references to a
/// profile rig (`rig:profile`) and per-trip rig copies, plus one `templates:current`; `snapshot`
/// converts them with `RigMigration` and `legacyRigLayoutKeys` names what a persisted migration replaces.
public enum RecordProjection {
    public static func rigKey(_ id: UUID) -> String { "rig:\(id)" }
    public static func defaultsKey(rigID: UUID) -> String { "templates:rig:\(rigID)" }
    public static let legacyTemplatesKey = "templates:current"

    /// Trip fields that are optional values on `Trip` and stored as-is.
    static let optionalTripStrings = ["campgroundID", "planningTimeZoneIdentifier", "campgroundTimeZoneIdentifier",
                                      "loop", "confirmationNumber", "bookingProvider", "bookingURL"]
    static let optionalTripNumbers = ["latitude", "longitude", "checkInMinutes", "checkOutMinutes", "totalCost", "amountPaid"]

    public static func documents(_ snapshot: LibrarySnapshot) throws -> [String: ReplicaRecord] {
        _ = try snapshot.state.validated()
        var result: [String: ReplicaRecord] = [:]
        func add(_ key: String, _ kind: RecordKind, _ fields: [String: RecordValue]) {
            result[key] = ReplicaRecord(key: key, kind: kind, fields: fields)
        }
        func items(_ values: [ChecklistItem], owner: String, phase: String) throws {
            for (position, item) in values.enumerated() {
                var f = try fields(item)
                f["owner"] = .string(owner); f["phase"] = .string(phase); f["position"] = .number(Double(position))
                add("checklistItem:\(owner):\(phase):\(item.id)", .checklistItem, f)
            }
        }
        if let profile = snapshot.state.profile { add("profile:current", .profile, try fields(profile)) }
        // `archivedAt` encodes as reference-date seconds, Date's default Codable form.
        for rig in snapshot.state.rigs { add(rigKey(rig.id), .rig, try fields(rig)) }
        for templates in snapshot.state.rigDefaults {
            guard let rigID = templates.rigID else { throw ReplicationError.invalidRecord }
            add(defaultsKey(rigID: rigID), .templates, ["id": .string(templates.id.uuidString), "version": .number(Double(templates.version)),
                                                        "sourceURL": .string(templates.sourceURL), "rigID": .string(rigID.uuidString)])
            try items(templates.setup, owner: "templates:\(templates.id)", phase: "setup")
            try items(templates.teardown, owner: "templates:\(templates.id)", phase: "teardown")
        }
        for (tripPosition, trip) in snapshot.state.trips.enumerated() {
            let key = "trip:\(trip.id)"
            let all = try fields(trip)
            var f: [String: RecordValue] = [
                "id": .string(trip.id.uuidString), "campgroundName": .string(trip.campgroundName),
                "arrival": .number(trip.arrival.timeIntervalSinceReferenceDate), "departure": .number(trip.departure.timeIntervalSinceReferenceDate),
                "siteNumber": .string(trip.siteNumber), "notes": .string(trip.notes), "rating": .string(trip.rating.rawValue)
            ]
            for name in optionalTripStrings + optionalTripNumbers { if let value = all[name], value != .null { f[name] = value } }
            if let rigID = trip.rigID { f["rigID"] = .string(rigID.uuidString) }
            if let deadline = trip.cancellationDeadline { f["cancellationDeadline"] = .number(deadline.timeIntervalSinceReferenceDate) }
            if let completedAt = trip.completedAt { f["completedAt"] = .number(completedAt.timeIntervalSinceReferenceDate) }
            f["position"] = .number(Double(tripPosition))
            add(key, .trip, f)
            try items(trip.setup, owner: key, phase: "setup"); try items(trip.teardown, owner: key, phase: "teardown")
            for (position, photo) in trip.photos.enumerated() {
                var p = try fields(photo); p["owner"] = .string(key); p["position"] = .number(Double(position))
                add("photo:\(photo.id)", .photo, p)
            }
        }
        for entry in snapshot.saved.values where !entry.isEmpty {
            var f: [String: RecordValue] = ["campgroundID": .string(entry.campgroundID), "saved": .bool(true),
                                            "wantToGo": .bool(entry.wantToGo), "favorite": .bool(entry.favorite)]
            if !entry.name.isEmpty { f["name"] = .string(entry.name) }
            if !entry.region.isEmpty { f["region"] = .string(entry.region) }
            if let beenTo = entry.beenTo { f["beenTo"] = .bool(beenTo) }
            add("favorite:\(entry.campgroundID)", .favorite, f)
        }
        return result
    }

    /// Keys of active records in the pre-#28 layout: `rigKey` references and their rigs, and the
    /// library-wide templates. Empty once a library has been migrated.
    public static func legacyRigLayoutKeys(_ records: [ReplicaRecord]) -> Set<String> {
        var keys = Set<String>()
        for record in records where record.deletion == nil {
            if let rigKey = record.fields["rigKey"]?.string, record.kind == .profile || record.kind == .trip {
                keys.insert(record.key); keys.insert(rigKey)
            }
            if record.kind == .templates && record.fields["rigID"]?.string == nil { keys.insert(record.key) }
        }
        return keys
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
        func templates(_ record: ReplicaRecord) throws -> ChecklistTemplates {
            var f = record.fields
            f.removeValue(forKey: "initialChecklistKeys")
            guard let templateID = f["id"]?.string else { throw ReplicationError.incompleteLibrary }
            f["setup"] = .array(try items("templates:\(templateID)", "setup").map { .object(try fields($0)) })
            f["teardown"] = .array(try items("templates:\(templateID)", "teardown").map { .object(try fields($0)) })
            return try decode(ChecklistTemplates.self, f)
        }
        func rig(_ record: ReplicaRecord) throws -> Rig { try decode(Rig.self, record.fields) }

        var state = AppState()
        var profileRig: Rig?
        var snapshots: [UUID: Rig] = [:]
        let legacyRigKeys = Set(active.compactMap { $0.kind == .profile || $0.kind == .trip ? $0.fields["rigKey"]?.string : nil })
        if var f = byKey["profile:current"]?.fields {
            if let key = f.removeValue(forKey: "rigKey")?.string {
                guard let record = byKey[key] else { throw ReplicationError.incompleteLibrary }
                profileRig = try rig(record)
            }
            state.profile = try decode(CamperProfile.self, f)
        }
        state.rigs = try active.filter { $0.kind == .rig && !legacyRigKeys.contains($0.key) }
            .map(rig)
            .sorted { ($0.isArchived ? 1 : 0, $0.id.uuidString) < ($1.isArchived ? 1 : 0, $1.id.uuidString) }
        var legacyTemplates: ChecklistTemplates?
        for record in active.filter({ $0.kind == .templates }).sorted(by: { $0.key < $1.key }) {
            if record.fields["rigID"]?.string == nil {
                if record.key == legacyTemplatesKey { legacyTemplates = try templates(record) }
            } else {
                state.rigDefaults.append(try templates(record))
            }
        }
        for record in active.filter({ $0.kind == .trip }).sorted(by: { ($0.fields["position"]?.number ?? 0) == ($1.fields["position"]?.number ?? 0) ? $0.key < $1.key : ($0.fields["position"]?.number ?? 0) < ($1.fields["position"]?.number ?? 0) }) {
            var f = record.fields
            f.removeValue(forKey: "initialChecklistKeys")
            let legacyRig = try f.removeValue(forKey: "rigKey")?.string.map { key -> Rig in
                guard let record = byKey[key] else { throw ReplicationError.incompleteLibrary }
                return try rig(record)
            }
            f["setup"] = .array(try items(record.key, "setup").map { .object(try fields($0)) })
            f["teardown"] = .array(try items(record.key, "teardown").map { .object(try fields($0)) })
            f["photos"] = .array((photoGroups[record.key] ?? [])
                .sorted { ($0.fields["position"]?.number ?? 0) == ($1.fields["position"]?.number ?? 0) ? $0.key < $1.key : ($0.fields["position"]?.number ?? 0) < ($1.fields["position"]?.number ?? 0) }.map { .object($0.fields) })
            let trip = try decode(Trip.self, f)
            if let legacyRig, trip.rigID == nil { snapshots[trip.id] = legacyRig }
            state.trips.append(trip)
        }
        if profileRig != nil || legacyTemplates != nil || !snapshots.isEmpty {
            RigMigration.migrate(&state, profileRig: profileRig, legacyTemplates: legacyTemplates, snapshots: snapshots)
        }
        var saved: [String: SavedCampground] = [:]
        for record in active where record.kind == .favorite && record.fields["saved"] == .bool(true) {
            guard let id = record.fields["campgroundID"]?.string else { continue }
            func flag(_ name: String) -> Bool? { if case .bool(let value) = record.fields[name] { value } else { nil } }
            // A record from before lists has only `saved`: the old bookmark, kept as "Want to go".
            let legacy = flag("wantToGo") == nil && flag("favorite") == nil && flag("beenTo") == nil
            saved[id] = SavedCampground(campgroundID: id, name: record.fields["name"]?.string ?? "",
                                        region: record.fields["region"]?.string ?? "",
                                        wantToGo: flag("wantToGo") ?? legacy, favorite: flag("favorite") ?? false, beenTo: flag("beenTo"))
        }
        return LibrarySnapshot(state: try state.validated(), saved: saved)
    }
    public static func fields<T: Encodable>(_ value: T) throws -> [String: RecordValue] {
        try JSONDecoder().decode([String: RecordValue].self, from: JSONEncoder().encode(value))
    }
    public static func decode<T: Decodable>(_ type: T.Type, _ fields: [String: RecordValue]) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(fields))
    }
    /// Trip photos and every rig's photo, archived rigs included.
    public static func referencedPhotos(_ state: AppState) -> Set<String> {
        Set(state.trips.flatMap { $0.photos.map(\.filename) } + state.rigs.compactMap(\.photoFilename))
    }
}
