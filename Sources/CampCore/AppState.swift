import Foundation

public struct AppState: Equatable, Sendable {
    public var profile: CamperProfile?
    /// Every rig, archived ones included. See `RigPolicy` for the active-rig limit.
    public var rigs: [Rig]
    public var trips: [Trip]
    /// Default setup and teardown lists, at most one per rig (`ChecklistTemplates.rigID`).
    public var rigDefaults: [ChecklistTemplates]
    public init(profile: CamperProfile? = nil, rigs: [Rig] = [], trips: [Trip] = [], rigDefaults: [ChecklistTemplates] = []) {
        self.profile = profile; self.rigs = rigs; self.trips = trips; self.rigDefaults = rigDefaults
    }
    /// Never fails because of more than one active rig: sync can produce that, and the library must
    /// stay readable while the owner resolves it (`needsRigResolution`). Mutations enforce the limit.
    public func validated() throws -> AppState {
        guard Set(trips.map(\.id)).count == trips.count, Set(rigs.map(\.id)).count == rigs.count else { throw CampError.duplicateIdentifiers }
        for trip in trips { try trip.validate() }
        for filename in rigs.compactMap(\.photoFilename) { try validateFilename(filename) }
        let owners = rigDefaults.map(\.rigID)
        guard owners.allSatisfy({ $0 != nil }), Set(owners).count == owners.count else { throw CampError.duplicateIdentifiers }
        for defaults in rigDefaults { try validateChecklist(defaults.setup + defaults.teardown) }
        return self
    }
}

/// Library export and the device-local projection cache use this form.
extension AppState: Codable {}
