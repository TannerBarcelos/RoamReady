import Foundation
import CampCore

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

/// Value projection of one managed record.
public struct StoredRecord: Codable, Equatable, Sendable {
    public let key: String
    public let kind: RecordKind
    public var fields: [String: RecordValue]
    /// A removed record. Its tombstone keeps the deletion syncing.
    public var isDeleted: Bool
    public init(key: String, kind: RecordKind, fields: [String: RecordValue] = [:], isDeleted: Bool = false) {
        self.key = key; self.kind = kind; self.fields = fields; self.isDeleted = isDeleted
    }
}

/// Maps the Codable domain types to flat records and back, independent of Core Data / CloudKit.
///
/// Record layout: `profile:current`; `rig:<rig id>` per rig (archived ones included);
/// `templates:rig:<rig id>` per rig's default lists, whose items are owned by `templates:<templates id>`;
/// `trip:<trip id>` with a `rigID` reference; `photo:<id>` and `checklistItem:<owner>:<phase>:<id>`
/// owned by their trip or templates; `favorite:<campground id>` per saved campground.
public enum RecordProjection {
    public static func rigKey(_ id: UUID) -> String { "rig:\(id)" }
    public static func defaultsKey(rigID: UUID) -> String { "templates:rig:\(rigID)" }

    /// Trip fields that are optional values on `Trip` and stored as-is.
    static let optionalTripStrings = ["campgroundID", "planningTimeZoneIdentifier", "campgroundTimeZoneIdentifier",
                                      "loop", "confirmationNumber", "bookingProvider", "bookingURL"]
    static let optionalTripNumbers = ["latitude", "longitude", "checkInMinutes", "checkOutMinutes", "totalCost", "amountPaid"]

    public static func documents(_ snapshot: LibrarySnapshot) throws -> [String: StoredRecord] {
        _ = try snapshot.state.validated()
        var result: [String: StoredRecord] = [:]
        func add(_ key: String, _ kind: RecordKind, _ fields: [String: RecordValue]) {
            result[key] = StoredRecord(key: key, kind: kind, fields: fields)
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
            guard let rigID = templates.rigID else { throw LibraryError.invalidRecord }
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

    public static func snapshot(_ records: [StoredRecord]) throws -> LibrarySnapshot {
        let active = records.filter { !$0.isDeleted }
        let byKey = Dictionary(uniqueKeysWithValues: active.map { ($0.key, $0) })
        let allKeys = Set(records.map(\.key))
        for record in active where record.kind == .trip || record.kind == .templates {
            if case .array(let required) = record.fields["initialChecklistKeys"] {
                guard required.allSatisfy({ $0.string.map(allKeys.contains) ?? false }) else { throw LibraryError.incompleteLibrary }
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
        func templates(_ record: StoredRecord) throws -> ChecklistTemplates {
            var f = record.fields
            f.removeValue(forKey: "initialChecklistKeys")
            guard let templateID = f["id"]?.string else { throw LibraryError.incompleteLibrary }
            f["setup"] = .array(try items("templates:\(templateID)", "setup").map { .object(try fields($0)) })
            f["teardown"] = .array(try items("templates:\(templateID)", "teardown").map { .object(try fields($0)) })
            return try decode(ChecklistTemplates.self, f)
        }
        func rig(_ record: StoredRecord) throws -> Rig { try decode(Rig.self, record.fields) }

        var state = AppState()
        if let f = byKey["profile:current"]?.fields { state.profile = try decode(CamperProfile.self, f) }
        state.rigs = try active.filter { $0.kind == .rig }
            .map(rig)
            .sorted { ($0.isArchived ? 1 : 0, $0.id.uuidString) < ($1.isArchived ? 1 : 0, $1.id.uuidString) }
        state.rigDefaults = try active.filter { $0.kind == .templates }.sorted { $0.key < $1.key }.map(templates)
        func byPosition(_ a: StoredRecord, _ b: StoredRecord) -> Bool {
            let x = a.fields["position"]?.number ?? 0, y = b.fields["position"]?.number ?? 0
            return x == y ? a.key < b.key : x < y
        }
        for record in active.filter({ $0.kind == .trip }).sorted(by: byPosition) {
            var f = record.fields
            f.removeValue(forKey: "initialChecklistKeys")
            f["setup"] = .array(try items(record.key, "setup").map { .object(try fields($0)) })
            f["teardown"] = .array(try items(record.key, "teardown").map { .object(try fields($0)) })
            f["photos"] = .array((photoGroups[record.key] ?? []).sorted(by: byPosition).map { .object($0.fields) })
            state.trips.append(try decode(Trip.self, f))
        }
        var saved: [String: SavedCampground] = [:]
        for record in active where record.kind == .favorite && record.fields["saved"] == .bool(true) {
            guard let id = record.fields["campgroundID"]?.string else { continue }
            func flag(_ name: String) -> Bool? { if case .bool(let value) = record.fields[name] { value } else { nil } }
            saved[id] = SavedCampground(campgroundID: id, name: record.fields["name"]?.string ?? "",
                                        region: record.fields["region"]?.string ?? "",
                                        wantToGo: flag("wantToGo") ?? false, favorite: flag("favorite") ?? false, beenTo: flag("beenTo"))
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
