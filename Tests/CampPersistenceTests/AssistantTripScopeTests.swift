import Foundation
import SwiftData
import Testing
import CampCore
import DocumentVault
@testable import CampPersistence

/// Two rigs and three trips (two on one rig): each scope sees only its own paperwork.
@MainActor @Suite(.serialized)
struct AssistantTripScopeTests {
    let container: ModelContainer
    let context: ModelContext
    let rigA: Rig
    let rigB: Rig
    let tripA1: Trip
    let tripA2: Trip
    let tripB: Trip
    static let pdf = Data("%PDF-1.7\n1 0 obj\n<<>>\nendobj\n%%EOF\n".utf8) + Data((0..<2_000).map { UInt8(truncatingIfNeeded: $0) })

    init() throws {
        container = try LibraryStore.inMemory()
        context = container.mainContext
        let a = try Rig.add(RigDraft(type: .travelTrailer, make: "Forest River", model: "No Boundaries", year: 2024, lengthFeet: 19.5), to: context)
        let dates = (Date.now, Date.now.addingTimeInterval(86_400))
        tripA1 = try Trip.create(TripDraft(campgroundName: "Pines", arrival: dates.0, departure: dates.1), rig: a, in: context)
        tripA2 = try Trip.create(TripDraft(campgroundName: "Lakeside", arrival: dates.0, departure: dates.1), rig: a, in: context)
        // Sync can leave two active rigs even though the app only lets an owner add one.
        a.archive()
        let b = try Rig.add(RigDraft(type: .camperVan, make: "Winnebago", model: "Revel", year: 2023, lengthFeet: 19), to: context)
        tripB = try Trip.create(TripDraft(campgroundName: "Ridge", arrival: dates.0, departure: dates.1), rig: b, in: context)
        a.archivedAt = nil
        rigA = a
        rigB = b
    }

    @discardableResult
    private func add(_ category: DocumentCategory, _ title: String, rig: Rig? = nil, trip: Trip? = nil) throws -> StoredDocument {
        try StoredDocument.add(DocumentMetadata(title: title, category: category),
                               contents: DocumentPayload(bytes: Self.pdf, filename: "file.pdf"),
                               link: nil, rig: rig, trip: trip, in: context)
    }

    @Test func tripChatSearchesItsOwnDocumentsAndItsRigsDocuments() throws {
        let manual = try add(.manual, "A manual", rig: rigA)
        let confirmation = try add(.reservation, "Pines confirmation", trip: tripA1)
        #expect(tripA1.tripAssistantScope().documentIDs == [manual.documentID, confirmation.documentID])
    }

    @Test func tripChatNeverSeesAnotherTripOrAnotherRig() throws {
        let manualA = try add(.manual, "A manual", rig: rigA)
        try add(.manual, "B manual", rig: rigB)
        let pines = try add(.reservation, "Pines confirmation", trip: tripA1)
        let lakeside = try add(.reservation, "Lakeside confirmation", trip: tripA2)
        try add(.reservation, "Ridge confirmation", trip: tripB)
        #expect(tripA1.tripAssistantScope().documentIDs == [manualA.documentID, pines.documentID])
        #expect(tripA2.tripAssistantScope().documentIDs == [manualA.documentID, lakeside.documentID])
        #expect(!tripA1.tripAssistantScope().documentIDs.contains(lakeside.documentID))
    }

    @Test func aTripDocumentAlsoTaggedWithTheRigStaysOutOfSiblingTrips() throws {
        let both = try add(.reservation, "Pines confirmation", rig: rigA, trip: tripA1)
        #expect(tripA1.tripAssistantScope().documentIDs == [both.documentID])
        #expect(tripA2.tripAssistantScope().isEmpty)
        #expect(rigA.generalAssistantScope().isEmpty)
    }

    @Test func generalChatNeverReturnsATripOwnedDocument() throws {
        let manual = try add(.manual, "A manual", rig: rigA)
        try add(.reservation, "Pines confirmation", trip: tripA1)
        let scope = context.documentScope(for: .general(rig: rigA))
        #expect(scope.documentIDs == [manual.documentID])
    }

    @Test func aPastTripOnAnArchivedRigStillUsesThatRigsDocuments() throws {
        let manual = try add(.manual, "A manual", rig: rigA)
        let confirmation = try add(.reservation, "Pines confirmation", trip: tripA1)
        rigA.archive()
        let target = AssistantScopeTarget.trip(tripA1)
        #expect(target.summary.rigIsArchived)
        #expect(context.documentScope(for: target).documentIDs == [manual.documentID, confirmation.documentID])
        // The same archived rig is not a General Assistant scope.
        #expect(context.documentScope(for: .general(rig: rigA)).isEmpty)
    }

    @Test func aReplacementRigDoesNotLeakIntoTheArchivedRigsTrips() throws {
        rigB.archive()
        let oldManual = try add(.manual, "Old manual", rig: rigA)
        let newRig = try rigA.replace(with: RigDraft(type: .fifthWheel, make: "Grand Design", model: "Reflection", year: 2025, lengthFeet: 38))
        let newManual = try add(.manual, "New manual", rig: newRig)
        #expect(context.documentScope(for: .trip(tripA1)).documentIDs == [oldManual.documentID])
        #expect(context.documentScope(for: .general(rig: newRig)).documentIDs == [newManual.documentID])
    }

    @Test func eligibilityRulesStillApplyInATripScope() throws {
        try add(.insurance, "Insurance", trip: tripA1)
        try add(.registration, "Registration", rig: rigA)
        try add(.other, "Notes", trip: tripA1)
        #expect(tripA1.tripAssistantScope().isEmpty)
    }

    @Test func aTargetResolvesFromItsSnapshotNotFromWhatTheScreenShowsNow() throws {
        try add(.manual, "A manual", rig: rigA)
        let manualB = try add(.manual, "B manual", rig: rigB)
        let snapshot = AssistantScopeTarget.general(rig: rigA)
        // The active rig changes after the question was asked.
        rigA.archive()
        #expect(context.documentScope(for: snapshot).isEmpty)
        #expect(context.documentScope(for: .general(rig: rigB)).documentIDs == [manualB.documentID])
    }

    @Test func deletedTripsAndTripsMovedToAnotherRigHaveNoScope() throws {
        try add(.manual, "A manual", rig: rigA)
        let target = AssistantScopeTarget.trip(tripA2)
        tripA2.rig = rigB
        #expect(context.documentScope(for: target).isEmpty)
        let deleted = AssistantScopeTarget.trip(tripA1)
        context.delete(tripA1)
        #expect(context.documentScope(for: deleted).isEmpty)
    }

    @Test func scopeIdentityIgnoresNamesButSeparatesRigsAndTrips() {
        #expect(AssistantScopeTarget.general(rig: rigA) == .general(rig: rigA))
        #expect(AssistantScopeTarget.general(rig: rigA) != .general(rig: rigB))
        #expect(AssistantScopeTarget.general(rig: rigA) != .trip(tripA1))
        #expect(AssistantScopeTarget.trip(tripA1) != .trip(tripA2))
        let before = AssistantScopeTarget.trip(tripA1)
        tripA1.campgroundName = "Renamed"
        #expect(before == .trip(tripA1))
        #expect(AssistantScopeTarget.trip(tripA1).summary.text == "Trip: Renamed · Rig: Forest River No Boundaries")
    }
}
