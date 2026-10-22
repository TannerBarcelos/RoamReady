import Foundation
import CampCore

/// Records as builds before #28 wrote them: the profile embeds its rig through `rigKey` (`rig:profile`),
/// one library-wide `templates:current`, and every trip holds its own rig copy at `rig:<trip id>`.
/// Saved campgrounds are single bookmarks (`campgroundID` and `saved`), read back as "Want to go".
/// Built from a current single-rig library, so migrating the result must give that library back.
enum LegacyLayout {
    static func documents(_ snapshot: LibrarySnapshot) throws -> [String: ReplicaRecord] {
        var current = snapshot
        let rig = current.state.activeRigs.first
        let tripRigs = Dictionary(uniqueKeysWithValues: current.state.trips.compactMap { trip in current.state.rig(for: trip).map { (trip.id, $0) } })
        for index in current.state.trips.indices { current.state.trips[index].rigID = nil }
        current.state.rigs = []
        let defaults = rig.flatMap { current.state.defaults(for: $0.id) }
        current.state.rigDefaults = []
        var records = try RecordProjection.documents(current)
        for (key, record) in records where record.kind == .favorite {
            records[key]?.fields = ["campgroundID": record.fields["campgroundID"]!, "saved": .bool(true)]
        }
        func rigRecord(_ rig: Rig, key: String) throws {
            var copy = rig; copy.archivedAt = nil
            records[key] = ReplicaRecord(key: key, kind: .rig, fields: try RecordProjection.fields(copy))
        }
        if let rig, current.state.profile != nil {
            records["profile:current"]?.fields["rigKey"] = .string("rig:profile")
            try rigRecord(rig, key: "rig:profile")
        }
        if let defaults {
            var owned = defaults; owned.rigID = UUID()
            let withDefaults = try RecordProjection.documents(LibrarySnapshot(state: AppState(rigs: [Rig(id: owned.rigID!)], rigDefaults: [owned])))
            for record in withDefaults.values where record.kind == .checklistItem { records[record.key] = record }
            records[RecordProjection.legacyTemplatesKey] = ReplicaRecord(
                key: RecordProjection.legacyTemplatesKey, kind: .templates,
                fields: ["id": .string(defaults.id.uuidString), "version": .number(Double(defaults.version)), "sourceURL": .string(defaults.sourceURL)])
        }
        for (tripID, tripRig) in tripRigs {
            records["trip:\(tripID)"]?.fields["rigKey"] = .string("rig:\(tripID)")
            try rigRecord(tripRig, key: "rig:\(tripID)")
        }
        return records
    }
}
