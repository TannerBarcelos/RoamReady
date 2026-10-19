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

    func testCatalogDecodesDeclaredRigTypesAndRejectsUnsupportedVersions() throws {
        let data = Data(#"{"schemaVersion":1,"coverageNote":"Sample only","records":[{"id":"one","make":"Example","model":"Trail","year":2025,"rigType":"travelTrailer","sourceURL":"https://example.com/rig","imageRights":"No redistribution rights established"}]}"#.utf8)
        let catalog = try RigCatalog.decode(data)
        XCTAssertEqual(catalog.records.first?.rigType, .travelTrailer)
        XCTAssertNil(catalog.records.first?.imageURL)
        let future = Data(#"{"schemaVersion":2,"coverageNote":"New schema","records":[]}"#.utf8)
        XCTAssertThrowsError(try RigCatalog.decode(future)) { XCTAssertEqual($0 as? CampError, .unsupportedSchema(2)) }
    }
}
