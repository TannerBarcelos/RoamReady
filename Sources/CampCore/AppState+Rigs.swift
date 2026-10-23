import Foundation

/// The single place the active-rig limit lives. A future paid tier changes only this value
/// (sold through StoreKit in-app purchase).
public enum RigPolicy {
    public static let maxActiveRigs = 1
}

/// Rig and per-rig default checklist operations. Every rule is enforced here, not only in the UI.
public extension AppState {
    var activeRigs: [Rig] { rigs.filter { !$0.isArchived } }
    var archivedRigs: [Rig] { rigs.filter(\.isArchived) }
    /// Sync can merge two devices' rigs into more active rigs than the policy allows. Nothing is
    /// hidden or deleted; the owner is asked to archive one.
    var needsRigResolution: Bool { activeRigs.count > RigPolicy.maxActiveRigs }
    var canAddActiveRig: Bool { activeRigs.count < RigPolicy.maxActiveRigs }

    func rig(_ id: UUID?) -> Rig? { id.flatMap { id in rigs.first { $0.id == id } } }
    /// The trip's rig through its reference, or nil when it is missing (shown as "Rig unavailable").
    func rig(for trip: Trip) -> Rig? { rig(trip.rigID) }
    func defaults(for rigID: UUID) -> ChecklistTemplates? { rigDefaults.first { $0.rigID == rigID } }
    func trips(usingRig rigID: UUID) -> [Trip] { trips.filter { $0.rigID == rigID } }

    /// Adds a rig with default lists generated from its type.
    mutating func addRig(_ rig: Rig) throws {
        guard self.rig(rig.id) == nil else { throw CampError.duplicateIdentifiers }
        if !rig.isArchived { guard canAddActiveRig else { throw CampError.rigLimitReached } }
        rigs.append(rig)
        setDefaults(ChecklistFactory.templates(for: rig), for: rig.id)
    }

    /// Edits the rig in place. Every trip that uses it shows the new details, past trips included.
    mutating func updateRig(_ rig: Rig) throws {
        guard let index = rigs.firstIndex(where: { $0.id == rig.id }) else { throw CampError.rigNotFound }
        if rigs[index].isArchived && !rig.isArchived { guard canAddActiveRig else { throw CampError.rigLimitReached } }
        rigs[index] = rig
    }

    mutating func archiveRig(_ id: UUID, at date: Date = Date()) throws {
        guard let index = rigs.firstIndex(where: { $0.id == id }) else { throw CampError.rigNotFound }
        if rigs[index].archivedAt == nil { rigs[index].archivedAt = date }
    }

    mutating func unarchiveRig(_ id: UUID) throws {
        guard let index = rigs.firstIndex(where: { $0.id == id }) else { throw CampError.rigNotFound }
        guard rigs[index].isArchived else { return }
        guard canAddActiveRig else { throw CampError.rigLimitReached }
        rigs[index].archivedAt = nil
    }

    /// "Replace rig": archive the current rig, then add the new one with its own defaults.
    /// Past trips keep showing the archived rig.
    mutating func replaceRig(_ id: UUID, with replacement: Rig, at date: Date = Date()) throws {
        var next = self
        try next.archiveRig(id, at: date)
        try next.addRig(replacement)
        self = next
    }

    /// Hard delete is only allowed while no trip uses the rig. Its default lists go with it.
    mutating func deleteRig(_ id: UUID) throws {
        guard rig(id) != nil else { throw CampError.rigNotFound }
        guard trips(usingRig: id).isEmpty else { throw CampError.rigInUse }
        rigs.removeAll { $0.id == id }
        rigDefaults.removeAll { $0.rigID == id }
    }

    /// Replaces a rig's defaults with fresh copies. Existing trips are never touched.
    mutating func setDefaults(_ templates: ChecklistTemplates, for rigID: UUID) {
        let fresh = templates.freshCopy(rigID: rigID)
        rigDefaults.removeAll { $0.rigID == rigID }
        rigDefaults.append(fresh)
    }

    /// "Reset defaults for rig": regenerate from the rig's type. Existing trips are never touched.
    mutating func resetDefaults(for rigID: UUID) throws {
        guard let rig = rig(rigID) else { throw CampError.rigNotFound }
        setDefaults(ChecklistFactory.templates(for: rig), for: rigID)
    }

    /// "Save as defaults for <rig>": the trip's current lists become its own rig's defaults, as
    /// pending copies. Writes only to that rig.
    mutating func saveTripChecklistsAsDefaults(_ tripID: UUID) throws {
        guard let trip = trips.first(where: { $0.id == tripID }) else { return }
        guard let rig = rig(for: trip) else { throw CampError.rigNotFound }
        let source = defaults(for: rig.id) ?? ChecklistFactory.templates(for: rig)
        var templates = source
        templates.setup = trip.setup; templates.teardown = trip.teardown
        setDefaults(templates, for: rig.id)
    }

    /// Creates a trip with fresh copies of the chosen active rig's defaults.
    mutating func createTrip(campgroundName: String, arrival: Date, departure: Date, rigID: UUID,
                             latitude: Double? = nil, longitude: Double? = nil, campgroundID: String? = nil,
                             campgroundTimeZoneIdentifier: String? = nil, configure: (inout Trip) -> Void = { _ in }) throws -> Trip {
        guard let rig = rig(rigID) else { throw CampError.rigNotFound }
        guard !rig.isArchived else { throw CampError.rigArchived }
        var trip = try Trip.create(campgroundName: campgroundName, arrival: arrival, departure: departure, rig: rig,
                                   defaults: defaults(for: rigID), latitude: latitude, longitude: longitude,
                                   campgroundID: campgroundID, campgroundTimeZoneIdentifier: campgroundTimeZoneIdentifier)
        configure(&trip)
        try trip.validate()
        try trip.validateBooking()
        trips.append(trip)
        return trip
    }

    /// The store's guard: a change may not raise the number of active rigs above the policy.
    /// A library that already exceeds it (after a sync race) can still be edited and reduced.
    func validateRigLimit(comparedTo baseline: AppState) throws {
        let after = activeRigs.count
        guard after <= RigPolicy.maxActiveRigs || after <= baseline.activeRigs.count else { throw CampError.rigLimitReached }
    }
}
