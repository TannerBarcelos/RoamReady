import XCTest
@testable import CampCore

/// #28: trips are bookings that reference a rig; each rig has its own default checklists.
final class RigPolicyTests: XCTestCase {
    private let arrival = Date(timeIntervalSince1970: 1_800_000_000)
    private let trailer = Rig(type: .travelTrailer, make: "Forest River", model: "No Boundaries", year: 2024,
                              equipment: Equipment(slideOuts: true), lengthFeet: 19.5)

    private func library() throws -> AppState {
        var state = AppState(profile: CamperProfile(name: "Sam"))
        try state.addRig(trailer)
        return state
    }
    private func addTrip(_ state: inout AppState, rigID: UUID? = nil) throws -> Trip {
        try state.createTrip(campgroundName: "Pines", arrival: arrival, departure: arrival.addingTimeInterval(86_400),
                             rigID: rigID ?? trailer.id)
    }

    func testCreatingATripCopiesTheRigsDefaults() throws {
        var state = try library()
        var defaults = try XCTUnwrap(state.defaults(for: trailer.id))
        defaults.setup = [ChecklistItem(title: "My own first step", status: .completed)]
        state.setDefaults(defaults, for: trailer.id)
        let trip = try addTrip(&state)
        XCTAssertEqual(trip.setup.map(\.title), ["My own first step"])
        XCTAssertEqual(trip.setup[0].status, .pending, "Progress always starts fresh")
        XCTAssertNotEqual(trip.setup[0].id, state.defaults(for: trailer.id)?.setup[0].id)
        XCTAssertEqual(trip.rigID, trailer.id)
    }

    func testTripListsAndRigDefaultsNeverChangeEachOther() throws {
        var state = try library()
        let defaultsBefore = try XCTUnwrap(state.defaults(for: trailer.id))
        let trip = try addTrip(&state)
        let index = try XCTUnwrap(state.trips.firstIndex { $0.id == trip.id })
        // Every kind of trip edit: tick, skip, rename, annotate, add, delete, reorder.
        state.trips[index].setup[0].status = .completed
        state.trips[index].setup[1].status = .skipped
        state.trips[index].setup[2].title = "Renamed for this trip"
        state.trips[index].setup[3].detail = "Trip note"
        state.trips[index].setup.append(ChecklistItem(title: "Trip-only step"))
        state.trips[index].teardown.removeFirst()
        state.trips[index].setup.swapAt(0, 4)
        XCTAssertEqual(state.defaults(for: trailer.id), defaultsBefore)

        let tripBefore = state.trips[index]
        var edited = defaultsBefore
        edited.setup[0].title = "Changed default"
        state.setDefaults(edited, for: trailer.id)
        try state.resetDefaults(for: trailer.id)
        XCTAssertEqual(state.trips[index], tripBefore)
    }

    func testSaveAsDefaultsWritesOnlyToTheTripsRig() throws {
        var state = try library()
        let trip = try addTrip(&state)
        let tent = Rig(type: .tent, equipment: .none)
        try state.replaceRig(trailer.id, with: tent)
        let tentDefaults = state.defaults(for: tent.id)
        let index = try XCTUnwrap(state.trips.firstIndex { $0.id == trip.id })
        state.trips[index].setup = [ChecklistItem(title: "Saved from trip", status: .completed)]
        try state.saveTripChecklistsAsDefaults(trip.id)
        XCTAssertEqual(state.defaults(for: trailer.id)?.setup.map(\.title), ["Saved from trip"])
        XCTAssertEqual(state.defaults(for: trailer.id)?.setup.first?.status, .pending)
        XCTAssertEqual(state.defaults(for: tent.id), tentDefaults, "Another rig's defaults are untouched")
        XCTAssertEqual(state.trips[index].setup.map(\.title), ["Saved from trip"])
    }

    func testEditingARigChangesWhatEveryTripShows() throws {
        var state = try library()
        let first = try addTrip(&state), second = try addTrip(&state)
        var edited = trailer; edited.model = "No Boundaries NB19.5"
        try state.updateRig(edited)
        XCTAssertEqual(state.rig(for: first)?.model, "No Boundaries NB19.5")
        XCTAssertEqual(state.rig(for: second)?.model, "No Boundaries NB19.5")
    }

    func testReplacingARigArchivesItAndPastTripsStillShowIt() throws {
        var state = try library()
        let past = try addTrip(&state)
        let motorhome = Rig(type: .motorhome, make: "Winnebago", model: "View", year: 2025, lengthFeet: 25)
        try state.replaceRig(trailer.id, with: motorhome)
        XCTAssertEqual(state.activeRigs.map(\.id), [motorhome.id])
        XCTAssertEqual(state.rig(for: past)?.id, trailer.id)
        XCTAssertTrue(try XCTUnwrap(state.rig(for: past)).isArchived)
        XCTAssertNotNil(state.defaults(for: motorhome.id), "The new rig gets its own defaults")
        XCTAssertThrowsError(try addTrip(&state, rigID: trailer.id)) { XCTAssertEqual($0 as? CampError, .rigArchived) }
        XCTAssertEqual(try addTrip(&state, rigID: motorhome.id).rigID, motorhome.id)
    }

    func testASecondActiveRigIsRefused() throws {
        var state = try library()
        XCTAssertThrowsError(try state.addRig(Rig(type: .tent, equipment: .none))) { XCTAssertEqual($0 as? CampError, .rigLimitReached) }
        let tent = Rig(type: .tent, equipment: .none)
        try state.replaceRig(trailer.id, with: tent)
        XCTAssertThrowsError(try state.unarchiveRig(trailer.id)) { XCTAssertEqual($0 as? CampError, .rigLimitReached) }
        var reactivated = try XCTUnwrap(state.rig(trailer.id)); reactivated.archivedAt = nil
        XCTAssertThrowsError(try state.updateRig(reactivated)) { XCTAssertEqual($0 as? CampError, .rigLimitReached) }
        // A failed replacement changes nothing.
        let before = state
        XCTAssertThrowsError(try state.replaceRig(UUID(), with: Rig())) { XCTAssertEqual($0 as? CampError, .rigNotFound) }
        XCTAssertEqual(state, before)
    }

    func testTheStoreGuardRefusesNewActiveRigsButAllowsResolvingASyncRace() throws {
        let baseline = try library()
        var second = baseline
        second.rigs.append(Rig(type: .tent, equipment: .none))
        XCTAssertThrowsError(try second.validateRigLimit(comparedTo: baseline)) { XCTAssertEqual($0 as? CampError, .rigLimitReached) }
        // Two devices each added a rig offline: both stay readable, and the owner can still edit and archive.
        XCTAssertNoThrow(try second.validated())
        XCTAssertTrue(second.needsRigResolution)
        var edited = second; edited.profile?.name = "Still editable"
        XCTAssertNoThrow(try edited.validateRigLimit(comparedTo: second))
        var resolved = second; try resolved.archiveRig(trailer.id)
        XCTAssertNoThrow(try resolved.validateRigLimit(comparedTo: second))
        XCTAssertFalse(resolved.needsRigResolution)
    }

    func testHardDeleteIsRefusedWhileTripsUseTheRig() throws {
        var state = try library()
        let trip = try addTrip(&state)
        XCTAssertThrowsError(try state.deleteRig(trailer.id)) { XCTAssertEqual($0 as? CampError, .rigInUse) }
        state.trips.removeAll { $0.id == trip.id }
        try state.deleteRig(trailer.id)
        XCTAssertNil(state.rig(trailer.id))
        XCTAssertNil(state.defaults(for: trailer.id))
    }

    func testAMissingRigNeverFailsValidation() throws {
        var state = try library()
        let trip = try addTrip(&state)
        state.rigs = []; state.rigDefaults = []
        XCTAssertNoThrow(try state.validated())
        XCTAssertNil(state.rig(for: trip))
        XCTAssertThrowsError(try state.saveTripChecklistsAsDefaults(trip.id)) { XCTAssertEqual($0 as? CampError, .rigNotFound) }
    }

    func testBookingValidation() throws {
        var trip = try Trip.create(campgroundName: "Pines", arrival: arrival, departure: arrival.addingTimeInterval(86_400), rig: trailer)
        trip.bookingURL = "http://insecure.example"
        XCTAssertThrowsError(try trip.validate()) { XCTAssertEqual($0 as? CampError, .invalidBookingLink) }
        trip.bookingURL = "javascript:alert(1)"
        XCTAssertThrowsError(try trip.validate()) { XCTAssertEqual($0 as? CampError, .invalidBookingLink) }
        trip.bookingURL = "https://www.recreation.gov/account/orders"
        XCTAssertNoThrow(try trip.validate())
        XCTAssertNotNil(trip.bookingLink)
        trip.totalCost = -1
        XCTAssertThrowsError(try trip.validate()) { XCTAssertEqual($0 as? CampError, .invalidBookingAmount) }
        trip.totalCost = .nan
        XCTAssertThrowsError(try trip.validate()) { XCTAssertEqual($0 as? CampError, .invalidBookingAmount) }
        trip.totalCost = 120
        trip.departure = arrival.addingTimeInterval(-1)
        XCTAssertThrowsError(try trip.validate()) { XCTAssertEqual($0 as? CampError, .invalidDates) }
    }

    func testBookingFieldsAreOptionalAndBlankTextIsNotStored() throws {
        var draft = Trip(campgroundName: "Walk-up site", arrival: arrival, departure: arrival)
        draft.siteNumber = " 12 "; draft.confirmationNumber = "   "; draft.loop = "A"
        var trip = try Trip.create(campgroundName: draft.campgroundName, arrival: arrival, departure: arrival, rig: trailer)
        XCTAssertFalse(trip.hasBookingDetails)
        trip.copyBookingDetails(from: draft)
        XCTAssertEqual(trip.siteNumber, "12")
        XCTAssertNil(trip.confirmationNumber)
        XCTAssertEqual(trip.loop, "A")
        XCTAssertTrue(trip.hasBookingDetails)
    }
}
