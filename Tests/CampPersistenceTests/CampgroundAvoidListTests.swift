import Foundation
import SwiftData
import Testing
import CampCore
@testable import CampPersistence

/// The "Would not go" and "Would not return" lists against a real SwiftData store.
@MainActor @Suite(.serialized)
struct CampgroundAvoidListTests {
    let container: ModelContainer
    let context: ModelContext
    let id = CampgroundIdentity.local(UUID()).campgroundID
    let arrival = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        container = try LibraryStore.inMemory()
        context = container.mainContext
    }

    private func set(_ list: CampgroundList, _ included: Bool = true) throws {
        try SavedCampground.set(id, name: "Pines", region: "CO", on: list, included, in: context)
    }

    private func lists(trips: [Trip] = [], now: Date = .now) throws -> CampgroundLists {
        CampgroundLists(saved: try context.fetch(FetchDescriptor<SavedCampground>()), trips: trips, now: now)
    }

    private func on(_ list: CampgroundList, trips: [Trip] = [], now: Date = .now) throws -> Bool {
        try lists(trips: trips, now: now).contains(id, on: list)
    }

    private func completedTrip() throws -> (trip: Trip, after: Date) {
        let rig = try Rig.add(RigDraft(type: .travelTrailer, make: "Forest River", model: "No Boundaries", year: 2024, lengthFeet: 19.5), to: context)
        let trip = try Trip.create(TripDraft(campgroundName: "Pines", arrival: arrival, departure: arrival.addingTimeInterval(172_800)), rig: rig, in: context)
        trip.campgroundID = id
        return (trip, arrival.addingTimeInterval(10 * 86_400))
    }

    @Test func newRowsAndMissingEntriesAreOnNeitherAvoidList() throws {
        #expect(SavedCampground(campgroundID: id).wouldNotGo == false)
        #expect(SavedCampground(campgroundID: id).wouldNotReturn == false)
        #expect(try !on(.wouldNotGo) && !on(.wouldNotReturn))
        try set(.wantToGo)
        #expect(try !on(.wouldNotGo) && !on(.wouldNotReturn))
    }

    @Test func wouldNotGoTakesThePlaceOffWantToGoAndFavorites() throws {
        try set(.wantToGo); try set(.favorite)
        try set(.wouldNotGo)
        #expect(try on(.wouldNotGo) && !on(.wantToGo) && !on(.favorite))
        #expect(try !on(.beenTo), "Avoiding a place doesn't mark it as visited")
    }

    @Test func wouldNotReturnTakesThePlaceOffWantToGoAndFavoritesAndMarksItBeenTo() throws {
        try set(.wantToGo); try set(.favorite)
        try set(.wouldNotReturn)
        #expect(try on(.wouldNotReturn) && !on(.wantToGo) && !on(.favorite))
        #expect(try on(.beenTo))
        #expect(try lists().entry(id)?.beenTo == true)
    }

    @Test func addingToWantToGoOrFavoritesRemovesBothAvoidMarks() throws {
        try set(.wouldNotGo)
        try set(.wantToGo)
        #expect(try on(.wantToGo) && !on(.wouldNotGo) && !on(.wouldNotReturn))
        try set(.wouldNotReturn)
        #expect(try on(.wouldNotReturn) && !on(.wantToGo))
        try set(.favorite)
        #expect(try on(.favorite) && !on(.wouldNotReturn) && !on(.wouldNotGo))
        #expect(try on(.beenTo), "Been to stays; only the avoid mark goes")
    }

    @Test func theAvoidListsExcludeEachOther() throws {
        try set(.wouldNotGo)
        try set(.wouldNotReturn)
        #expect(try on(.wouldNotReturn) && !on(.wouldNotGo))
        let entry = try #require(try lists().entry(id))
        #expect(entry.wouldNotReturn && !entry.wouldNotGo)
        try set(.wouldNotGo)
        #expect(try !on(.wouldNotGo), "Been to explicitly, so it stays on Would not return")
        #expect(try on(.wouldNotReturn))
    }

    @Test func wouldNotGoForAPlaceMarkedBeenToLandsOnWouldNotReturn() throws {
        try set(.beenTo)
        try set(.wouldNotGo)
        #expect(try on(.wouldNotReturn) && !on(.wouldNotGo) && on(.beenTo))
        #expect(try lists().entry(id)?.wouldNotGo == false)
    }

    @Test func removingFromWouldNotReturnLeavesBeenToAsItWas() throws {
        try set(.wouldNotReturn)
        try set(.wouldNotReturn, false)
        #expect(try !on(.wouldNotReturn) && on(.beenTo))
        #expect(try lists().entry(id)?.beenTo == true)
    }

    @Test func removingFromWouldNotGoDeletesAnEntryWithNothingElse() throws {
        try set(.wouldNotGo)
        #expect(try lists().entry(id) != nil, "An entry only on an avoid list is kept")
        try set(.wouldNotGo, false)
        #expect(try lists().entry(id) == nil)
        try set(.wouldNotReturn)
        try set(.wouldNotReturn, false)
        #expect(try lists().entry(id) != nil, "Been to is still set")
    }

    @Test func settingBeenToFalseRemovesThePlaceFromWouldNotReturn() throws {
        try set(.wouldNotReturn)
        try set(.beenTo, false)
        #expect(try !on(.wouldNotReturn) && !on(.wouldNotGo) && !on(.beenTo))
        #expect(try lists().entry(id)?.wouldNotReturn == false)
    }

    @Test func anEntryOnlyOnAnAvoidListIsNotCleanedUp() throws {
        try set(.wantToGo)
        try set(.wouldNotGo)
        #expect(try lists().entry(id)?.wouldNotGo == true)
        #expect(try lists().count == 1)
        #expect(try lists().campgroundIDs(on: .wouldNotGo) == [id])
        #expect(try lists().name(id) == "Pines")
    }

    @Test func aCompletedTripMovesAWouldNotGoPlaceToWouldNotReturnWithoutRewritingIt() throws {
        let (trip, after) = try completedTrip()
        let before = arrival.addingTimeInterval(-86_400)
        try set(.wouldNotGo)
        #expect(try on(.wouldNotGo, trips: [trip], now: before) && !on(.wouldNotReturn, trips: [trip], now: before),
                "Before the trip it is still a place to avoid")
        #expect(try on(.wouldNotReturn, trips: [trip], now: after) && !on(.wouldNotGo, trips: [trip], now: after))
        #expect(try lists().entry(id)?.wouldNotGo == true, "The saved entry is unchanged")
        try set(.wouldNotReturn, false)
        #expect(try !on(.wouldNotReturn, trips: [trip], now: after) && !on(.wouldNotGo, trips: [trip], now: after),
                "Removing it from the list it appears on clears the mark")
    }

    @Test func addingWouldNotGoAfterACompletedTripLandsOnWouldNotReturn() throws {
        let (trip, after) = try completedTrip()
        try set(.wouldNotGo)
        #expect(try on(.wouldNotReturn, trips: [trip], now: after) && !on(.wouldNotGo, trips: [trip], now: after))
    }

    @Test func turningBeenToOffPutsACompletedTripPlaceBackOnWouldNotGo() throws {
        let (trip, after) = try completedTrip()
        try set(.wouldNotGo)
        try set(.beenTo, false)
        #expect(try on(.wouldNotGo, trips: [trip], now: after) && !on(.wouldNotReturn, trips: [trip], now: after))
    }

    @Test func theExportIncludesBothMarks() throws {
        try set(.wouldNotReturn)
        try SavedCampground.set("local:other", name: "Dusty", region: "", on: .wouldNotGo, true, in: context)
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appending(path: "Export.zip")
        try LibraryExport.write(from: context, to: archive, workspace: directory.appending(path: "work"))
        let unzip = Process()
        unzip.executableURL = URL(filePath: "/usr/bin/unzip")
        unzip.arguments = ["-p", archive.path, "*library.json"]
        let output = Pipe()
        unzip.standardOutput = output
        try unzip.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        unzip.waitUntilExit()
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["schemaVersion"] as? Int == 5)
        let saved = try #require(json["savedCampgrounds"] as? [[String: Any]])
        let byID = Dictionary(uniqueKeysWithValues: saved.map { ($0["campgroundID"] as! String, $0) })
        #expect(byID[id]?["wouldNotReturn"] as? Bool == true && byID[id]?["wouldNotGo"] as? Bool == false)
        #expect(byID["local:other"]?["wouldNotGo"] as? Bool == true && byID["local:other"]?["wouldNotReturn"] as? Bool == false)
    }
}
