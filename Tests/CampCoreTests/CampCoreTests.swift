import Foundation
import XCTest
@testable import CampCore

// Each test keeps its mutable fixtures local; XCTest owns the test lifecycle.
final class CampCoreTests: XCTestCase, @unchecked Sendable {
    private let arrival = Date(timeIntervalSince1970: 1_800_000_000)

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func trip(rig: Rig = Rig(), templates: ChecklistTemplates? = nil) throws -> Trip {
        try Trip.create(campgroundName: "Pine Creek", arrival: arrival,
                        departure: arrival.addingTimeInterval(172_800), rig: rig, templates: templates)
    }

    func testReopenRetainsProfileTripChecklistsMemoriesAndPhotoReferences() async throws {
        let location = try directory()
        let store = FileAppStore(directory: location)
        let initial = try await store.load()
        XCTAssertEqual(initial, AppState())
        let rig = Rig(type: .travelTrailer, make: "Example", model: "Trail", year: 2025)
        var journey = try trip(rig: rig)
        journey.setup[0].status = .completed
        journey.setup[1].status = .skipped
        journey.teardown[0].detail = "Remember the borrowed chairs."
        journey.siteNumber = "B12"
        journey.notes = "Quiet, shaded; bring a longer water hose."
        journey.rating = .wouldReturn
        journey.photos = [TripPhoto(filename: "memory.jpg", caption: "Our site", createdAt: arrival)]
        let state = AppState(profile: CamperProfile(name: "Sam", experience: .comfortable, rig: rig),
                             trips: [journey], templates: ChecklistFactory.templates(for: rig))
        try await store.save(state)
        let reopened = try await FileAppStore(directory: location).load()
        XCTAssertEqual(reopened, state)
        XCTAssertEqual(reopened.trips[0].setupProgress, 2.0 / Double(journey.setup.count), accuracy: 0.00001)
    }

    func testEachTripGetsFreshChecklistIDsAndStatusesAndIndependentText() throws {
        var templates = ChecklistFactory.templates(for: Rig())
        templates.setup[0].status = .completed
        var first = try trip(templates: templates)
        let second = try trip(templates: templates)
        XCTAssertNotEqual(first.setup[0].id, second.setup[0].id)
        XCTAssertNotEqual(first.setup[0].id, templates.setup[0].id)
        XCTAssertEqual(first.setup[0].status, .pending)
        first.setup[0].title = "My trip-only step"
        first.setup[0].status = .skipped
        templates.setup[0].title = "My new reusable instruction"
        let third = try trip(templates: templates)
        XCTAssertNotEqual(second.setup[0].title, first.setup[0].title)
        XCTAssertNotEqual(second.setup[0].title, third.setup[0].title)
        XCTAssertEqual(third.setup[0].title, templates.setup[0].title)
        XCTAssertEqual(second.setup[0].status, .pending)
    }

    func testRigEquipmentFiltersBothPhasesAndTentNeverGetsRVProcedures() {
        let bare = ChecklistFactory.templates(for: Rig(type: .motorhome, equipment: .none))
        let equipped = ChecklistFactory.templates(for: Rig(type: .travelTrailer, equipment: Equipment(slideOuts: true)))
        let tent = ChecklistFactory.templates(for: Rig(type: .tent, equipment: Equipment(slideOuts: true)))
        let car = ChecklistFactory.templates(for: Rig(type: .carCamping))
        let bareTitles = (bare.setup + bare.teardown).map(\.title).joined(separator: " ").lowercased()
        let equippedTitles = (equipped.setup + equipped.teardown).map(\.title).joined(separator: " ").lowercased()
        let tentTitles = (tent.setup + tent.teardown).map(\.title).joined(separator: " ").lowercased()
        XCTAssertFalse(bareTitles.contains("shore power"))
        XCTAssertFalse(bareTitles.contains("slides"))
        XCTAssertFalse(bareTitles.contains("propane"))
        XCTAssertFalse(bareTitles.contains("unhitch"))
        XCTAssertTrue(equippedTitles.contains("shore power"))
        XCTAssertTrue(equippedTitles.contains("slides"))
        XCTAssertTrue(equippedTitles.contains("unhitch"))
        XCTAssertTrue(tentTitles.contains("tent"))
        for absent in ["hitch", "slides", "shore power", "leveling", "wastewater"] {
            XCTAssertFalse(tentTitles.contains(absent), "Tent contains RV instruction: \(absent)")
        }
        XCTAssertFalse(car.setup.contains { $0.title == "Pitch and secure your tent" })
        XCTAssertTrue(car.setup.contains { $0.title == "Prepare your sleeping space" })
    }

    func testInvalidTripDatesAndCoordinatesRejected() throws {
        XCTAssertThrowsError(try Trip.create(campgroundName: "Camp", arrival: arrival,
                                            departure: arrival.addingTimeInterval(-1), rig: Rig())) {
            XCTAssertEqual($0 as? CampError, .invalidDates)
        }
        XCTAssertThrowsError(try Trip.create(campgroundName: "  ", arrival: arrival, departure: arrival, rig: Rig())) {
            XCTAssertEqual($0 as? CampError, .missingCampground)
        }
        XCTAssertThrowsError(try Trip.create(campgroundName: "Camp", arrival: arrival, departure: arrival,
                                            rig: Rig(), latitude: 91, longitude: 0)) {
            XCTAssertEqual($0 as? CampError, .invalidCoordinates)
        }
        XCTAssertNoThrow(try Trip.create(campgroundName: "Day visit", arrival: arrival, departure: arrival, rig: Rig()))
    }

    func testFutureSchemaRejectedWithoutChangingArchiveEvenOnSave() async throws {
        let store = FileAppStore(directory: try directory())
        let original = Data(#"{"schemaVersion":999,"state":{"trips":[]}}"#.utf8)
        try original.write(to: store.fileURL)
        do {
            _ = try await store.load()
            XCTFail("Future schema unexpectedly opened")
        } catch { XCTAssertEqual(error as? CampError, .unsupportedSchema(999)) }
        do {
            try await store.save(AppState())
            XCTFail("Future schema unexpectedly overwritten")
        } catch { XCTAssertEqual(error as? CampError, .unsupportedSchema(999)) }
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
    }

    func testCorruptionDoesNotBecomeAnEmptyStore() async throws {
        let store = FileAppStore(directory: try directory())
        let original = Data("not valid JSON".utf8)
        try original.write(to: store.fileURL)
        do { _ = try await store.load(); XCTFail("Corrupt file unexpectedly opened") } catch {}
        do { try await store.save(AppState()); XCTFail("Corrupt file unexpectedly overwritten") } catch {}
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
    }

    func testVersionZeroMigratesInMemoryThenWritesCurrentEnvelope() async throws {
        let store = FileAppStore(directory: try directory())
        let original = Data(#"{"schemaVersion":0,"trips":[]}"#.utf8)
        try original.write(to: store.fileURL)
        let state = try await store.load()
        XCTAssertEqual(state, AppState())
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
        try await store.save(state)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertNotNil(object["state"])
    }

    func testValidationFailurePreservesPreviouslySavedState() async throws {
        let store = FileAppStore(directory: try directory())
        let original = AppState(trips: [try trip()])
        try await store.save(original)
        var invalid = original
        invalid.trips[0].departure = arrival.addingTimeInterval(-100)
        do { try await store.save(invalid); XCTFail("Invalid date saved") }
        catch { XCTAssertEqual(error as? CampError, .invalidDates) }
        let reopened = try await store.load()
        XCTAssertEqual(reopened, original)
    }

    func testPhotoReferencesCannotEscapeLocalMediaDirectory() throws {
        var state = AppState(trips: [try trip()])
        state.trips[0].photos = [TripPhoto(filename: "../outside.jpg")]
        XCTAssertThrowsError(try state.validated()) { XCTAssertEqual($0 as? CampError, .invalidPhotoFilename) }
    }

    func testDiskErrorsPropagate() async throws {
        let location = try directory().appendingPathComponent("occupied")
        try Data("file instead of folder".utf8).write(to: location)
        let store = FileAppStore(directory: location)
        do { try await store.save(AppState()); XCTFail("Expected filesystem failure") } catch {}
    }

    func testRVsRequireYearMakeModelAndLengthButTentsDoNot() throws {
        var rig = Rig(type: .travelTrailer, make: "Forest River", model: "No Boundaries NB19.5", year: 2024)
        XCTAssertThrowsError(try rig.validateDetails()) { XCTAssertEqual($0 as? CampError, .incompleteRig) }
        rig.lengthFeet = 23.5
        XCTAssertNoThrow(try rig.validateDetails())
        rig.model = "   "
        XCTAssertFalse(rig.hasRequiredDetails)
        XCTAssertTrue(Rig(type: .tent, equipment: .none).hasRequiredDetails)
        XCTAssertTrue(Rig(type: .carCamping, equipment: .none).hasRequiredDetails)
    }

    func testRigDetailRangesAreEnforcedOnSave() {
        let valid = Rig(type: .fifthWheel, make: "Jayco", model: "Eagle", year: 2025, lengthFeet: 38, slideCount: 4, axleCount: 2, hasBunkhouse: true)
        XCTAssertNoThrow(try valid.validateDetails())
        var none = valid; none.slideCount = 0
        XCTAssertNoThrow(try none.validateDetails(), "0 records an explicit 'no slide-outs'")
        func changed(_ change: (inout Rig) -> Void) -> Rig { var rig = valid; change(&rig); return rig }
        for broken in [changed { $0.year = 1800 }, changed { $0.lengthFeet = 0 }, changed { $0.lengthFeet = .infinity },
                       changed { $0.slideCount = -1 }, changed { $0.slideCount = 9 }, changed { $0.axleCount = 0 }, changed { $0.axleCount = 9 }] {
            XCTAssertThrowsError(try broken.validateDetails()) { XCTAssertEqual($0 as? CampError, .invalidRigDetails) }
        }
    }

    func testRigsSavedBeforeDetailFieldsStillDecode() throws {
        let legacy = Data(#"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","type":"travelTrailer","make":"Jayco","model":"Jay Flight","year":2021,"floorplan":"","emoji":"🚐","equipment":{"shorePower":true,"freshWater":true,"sewer":true,"slideOuts":false,"propane":true}}"#.utf8)
        let rig = try JSONDecoder().decode(Rig.self, from: legacy)
        XCTAssertNil(rig.lengthFeet); XCTAssertNil(rig.slideCount); XCTAssertNil(rig.axleCount); XCTAssertNil(rig.hasBunkhouse)
        XCTAssertFalse(rig.hasRequiredDetails, "Older profiles load, then prompt for length on the next edit")
        XCTAssertNoThrow(try AppState(profile: CamperProfile(rig: rig)).validated())
    }

    func testDetailSummaryListsOnlyEnteredFacts() {
        XCTAssertEqual(Rig(year: 2024, lengthFeet: 19.5, slideCount: 1, axleCount: 1, hasBunkhouse: true).detailSummary,
                       "2024 · 19.5 ft · 1 slide · 1 axle · Bunkhouse")
        XCTAssertEqual(Rig(lengthFeet: 38, slideCount: 3, axleCount: 2, hasBunkhouse: false).detailSummary, "38 ft · 3 slides · 2 axles")
        XCTAssertEqual(Rig().detailSummary, "")
    }

    func testBlankFormHidesTheErrorUntilTheOwnerStartsTyping() {
        var rig = Rig(type: .fifthWheel)
        XCTAssertNil(rig.visibleDetailsProblem)
        XCTAssertEqual(rig.detailsProblem, CampError.incompleteRig.errorDescription)
        rig.make = "Jayco"
        XCTAssertEqual(rig.visibleDetailsProblem, CampError.incompleteRig.errorDescription)
        rig.model = "Eagle"; rig.year = 1800; rig.lengthFeet = 38
        XCTAssertEqual(rig.visibleDetailsProblem, CampError.invalidRigDetails.errorDescription)
        rig.year = 2025
        XCTAssertNil(rig.visibleDetailsProblem)
        var legacy = Rig(type: .travelTrailer, make: "Jayco", model: "Jay Flight", year: 2021)
        XCTAssertNotNil(legacy.visibleDetailsProblem, "An older profile missing length shows the prompt immediately")
        legacy.make = "   "; legacy.model = ""; legacy.year = nil
        XCTAssertNil(legacy.visibleDetailsProblem)
    }

    func testSlideCountDrivesSlideOutStepsOnlyWhenSpecified() {
        var rig = Rig(type: .travelTrailer, equipment: Equipment(slideOuts: true))
        rig.setSlideCount(nil)
        XCTAssertTrue(rig.equipment.slideOuts, "Not specified leaves an existing answer alone")
        rig.setSlideCount(0)
        XCTAssertFalse(rig.equipment.slideOuts)
        XCTAssertFalse(ChecklistFactory.templates(for: rig).setup.contains { $0.title == "Prepare and extend slides" })
        rig.setSlideCount(2)
        XCTAssertEqual(rig.slideCount, 2); XCTAssertTrue(rig.equipment.slideOuts)
        XCTAssertTrue(ChecklistFactory.templates(for: rig).setup.contains { $0.title == "Prepare and extend slides" })
        rig.setSlideCount(nil)
        XCTAssertNil(rig.slideCount); XCTAssertTrue(rig.equipment.slideOuts)
    }

    func testChangingRigTypeClearsTypeSpecificDetails() {
        var rig = Rig(type: .travelTrailer, make: "Forest River", model: "No Boundaries", year: 2024, floorplan: "NB19.5",
                      emoji: "🏕️", photoFilename: "rig.jpg", equipment: Equipment(slideOuts: true),
                      lengthFeet: 19.5, slideCount: 1, axleCount: 1, hasBunkhouse: true)
        rig.type = .tent
        rig.resetDetailsForType()
        XCTAssertEqual(rig.make, ""); XCTAssertEqual(rig.model, ""); XCTAssertEqual(rig.floorplan, "")
        XCTAssertNil(rig.year); XCTAssertNil(rig.lengthFeet); XCTAssertNil(rig.slideCount)
        XCTAssertNil(rig.axleCount); XCTAssertNil(rig.hasBunkhouse)
        XCTAssertEqual(rig.equipment, .none); XCTAssertEqual(rig.emoji, RigType.tent.defaultEmoji)
        XCTAssertEqual(rig.photoFilename, "rig.jpg", "The owner's photo is kept")
        rig.type = .motorhome
        rig.resetDetailsForType()
        XCTAssertEqual(rig.equipment, Equipment())
    }

    func testYearAndLengthTextParsing() {
        XCTAssertEqual(Rig.parseYear("2024"), 2024)
        XCTAssertEqual(Rig.parseYear(" 20a24 "), 2024)
        XCTAssertEqual(Rig.parseYear("202456"), 2024)
        XCTAssertNil(Rig.parseYear(""))
        XCTAssertNil(Rig.parseYear("abc"))
        XCTAssertNil(Rig.parseYear("٢٠٢٤"), "Non-ASCII digits are rejected")
        XCTAssertEqual(Rig.parseLength("19.5"), 19.5)
        XCTAssertEqual(Rig.parseLength(" 23,5 "), 23.5)
        XCTAssertEqual(Rig.parseLength("38"), 38)
        for bad in ["", "abc", "0", "-3", "inf", "nan", "1e999"] { XCTAssertNil(Rig.parseLength(bad), bad) }
        let rig = Rig(year: 2024, lengthFeet: 19.5)
        XCTAssertEqual(rig.yearText, "2024"); XCTAssertEqual(rig.lengthText, "19.5")
        XCTAssertEqual(Rig(lengthFeet: 38).lengthText, "38")
        XCTAssertEqual(Rig.parseLength(rig.lengthText), rig.lengthFeet, "Displayed text parses back to the stored value")
        XCTAssertEqual(Rig().yearText, ""); XCTAssertEqual(Rig().lengthText, "")
    }

    func testRigSnapshotOnTripsKeepsDetailsAfterProfileEdits() throws {
        var rig = Rig(type: .travelTrailer, make: "Forest River", model: "No Boundaries NB19.5", year: 2024,
                      lengthFeet: 19.5, slideCount: 0, axleCount: 1, hasBunkhouse: false)
        let trip = try Trip.create(campgroundName: "Pines", arrival: arrival, departure: arrival, rig: rig)
        rig.lengthFeet = 24; rig.setSlideCount(1)
        XCTAssertEqual(trip.rigSnapshot?.lengthFeet, 19.5)
        XCTAssertEqual(trip.rigSnapshot?.slideCount, 0)
    }
}
