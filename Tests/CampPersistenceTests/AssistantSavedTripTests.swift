import Foundation
import SwiftData
import Testing
import CampCore
@testable import CampPersistence

private struct ConflictGenerator: CampingResponseGenerating {
    func respond(to prompt: String, instructions: String) async throws -> String {
        "Your saved trip says 2 p.m. The confirmation says 3 p.m. Please confirm with the campground."
    }
}

@MainActor @Suite(.serialized)
struct AssistantSavedTripTests {
    @Test func aConflictAnswerLeavesTheSavedTripUnchanged() async throws {
        let container = try LibraryStore.inMemory()
        let context = container.mainContext
        defer { withExtendedLifetime(container) {} }
        let rig = try Rig.add(RigDraft(type: .travelTrailer, make: "Forest River", model: "No Boundaries", year: 2024, lengthFeet: 19.5), to: context)
        var draft = TripDraft(campgroundName: "Pines", arrival: Date(timeIntervalSince1970: 1_800_000_000), departure: Date(timeIntervalSince1970: 1_800_172_800))
        draft.checkInMinutes = 14 * 60; draft.confirmationNumber = "PL-889"; draft.siteNumber = "A-203"
        let trip = try Trip.create(draft, rig: rig, in: context)
        try context.save()
        let before = TripDraft(trip)

        let request = CampingHelpRequest(question: "What time is check-in?", steps: [], rigType: rig.type, step: nil, scope: .checklist,
                                         tripFacts: TripBookingFacts(trip))
        _ = try await CampingGeneration.answer(to: request, using: ConflictGenerator())

        #expect(TripDraft(trip) == before)
        #expect(trip.checkInMinutes == 14 * 60)
        #expect(!context.hasChanges)
    }
}
