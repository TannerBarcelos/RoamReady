import Foundation
import SwiftData
import Testing
import CampCore
import DocumentVault
@testable import CampPersistence

/// The general Assistant's allow-list: one rule, read live from the library.
@MainActor @Suite(.serialized)
struct AssistantDocumentScopeTests {
    let container: ModelContainer
    let context: ModelContext
    let rig: Rig
    static let pdf = Data("%PDF-1.7\n1 0 obj\n<<>>\nendobj\n%%EOF\n".utf8) + Data((0..<2_000).map { UInt8(truncatingIfNeeded: $0) })

    init() throws {
        container = try LibraryStore.inMemory()
        context = container.mainContext
        rig = try Rig.add(RigDraft(type: .travelTrailer, make: "Forest River", model: "No Boundaries", year: 2024, lengthFeet: 19.5), to: context)
    }

    @discardableResult
    private func add(_ category: DocumentCategory, title: String = "Doc", rig: Rig?, trip: Trip? = nil, file: Bool = true) throws -> StoredDocument {
        try StoredDocument.add(DocumentMetadata(title: title, category: category),
                               contents: file ? DocumentPayload(bytes: Self.pdf, filename: "file.pdf") : nil,
                               link: file ? nil : URL(string: "https://example.com/m.pdf"), rig: rig, trip: trip, in: context)
    }

    @Test func searchableCategoriesAttachedToTheActiveRigAreInScope() throws {
        let manual = try add(.manual, rig: rig)
        let service = try add(.maintenance, rig: rig)
        let warranty = try add(.warranty, rig: rig)
        let reservation = try add(.reservation, rig: rig)
        #expect(rig.generalAssistantScope().documentIDs == [manual.documentID, service.documentID, warranty.documentID, reservation.documentID])
    }

    @Test func photographedPaperworkIsInScopeLikeAPDF() throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data((0..<2_000).map { UInt8(truncatingIfNeeded: $0) })
        let photo = try StoredDocument.add(DocumentMetadata(title: "Photo of warranty card", category: .warranty),
                                           contents: DocumentPayload(bytes: jpeg, filename: "card.jpg"), link: nil, rig: rig, in: context)
        #expect(photo.file?.contentType == .jpeg)
        #expect(rig.generalAssistantScope().documentIDs == [photo.documentID])
        // The category rule still applies to images.
        try photo.update(DocumentMetadata(title: "Photo", category: .insurance))
        #expect(rig.generalAssistantScope().isEmpty)
    }

    @Test func registrationInsuranceAndOtherAreNeverInScope() throws {
        try add(.registration, rig: rig)
        try add(.insurance, rig: rig)
        try add(.other, rig: rig)
        #expect(rig.generalAssistantScope().isEmpty)
    }

    @Test func everyCategoryFollowsTheEligibilityRule() throws {
        let included: [DocumentCategory] = [.manual, .maintenance, .warranty, .reservation]
        for category in included {
            let doc = try add(category, rig: rig)
            #expect(doc.isAssistantSearchable)
            doc.includeInAssistant = true
            #expect(doc.isAssistantSearchable)
        }
        for category in [DocumentCategory.registration, .insurance] {
            let doc = try add(category, rig: rig)
            #expect(!doc.isAssistantSearchable)
            // The opt-in never lets these in, even if one is stored (older build, sync, stale index row).
            doc.includeInAssistant = true
            #expect(!doc.isAssistantSearchable)
            #expect(!rig.generalAssistantScope().documentIDs.contains(doc.documentID))
        }
        #expect(rig.generalAssistantScope().documentIDs.count == included.count)
    }

    @Test func otherIsOffUntilOptedInAndOffAgainImmediately() throws {
        let other = try add(.other, rig: rig)
        #expect(!other.includeInAssistant)
        #expect(rig.generalAssistantScope().isEmpty)
        #expect(try context.indexableDocuments().isEmpty)
        other.includeInAssistant = true
        #expect(rig.generalAssistantScope().documentIDs == [other.documentID])
        #expect(try context.indexableDocuments().map(\.documentID) == [other.documentID])
        other.includeInAssistant = false
        #expect(rig.generalAssistantScope().isEmpty)
        #expect(try context.indexableDocuments().isEmpty)
    }

    @Test func optedInOtherStillNeedsSavedContentAndAScope() throws {
        let link = try add(.other, rig: rig, file: false)
        link.includeInAssistant = true
        #expect(!link.isAssistantSearchable)
        link.attach(try DocumentPayload(bytes: Self.pdf, filename: "saved.pdf"))
        #expect(link.isAssistantSearchable && rig.generalAssistantScope().documentIDs == [link.documentID])
        let unattached = try add(.other, rig: nil)
        unattached.includeInAssistant = true
        #expect(unattached.isAssistantSearchable && !unattached.isInGeneralScope(of: rig))
    }

    @Test func recategorizingAnOptedInOtherDocumentDropsItFromScope() throws {
        let other = try add(.other, rig: rig)
        other.includeInAssistant = true
        try other.update(DocumentMetadata(title: "Card", category: .insurance))
        #expect(rig.generalAssistantScope().isEmpty)
        try other.update(DocumentMetadata(title: "Card", category: .other))
        #expect(rig.generalAssistantScope().documentIDs == [other.documentID])
    }

    @Test func linksWithoutSavedContentUnattachedAndOtherOwnersAreOutOfScope() throws {
        try add(.manual, rig: rig, file: false)
        try add(.manual, rig: nil)
        let otherRig = Rig()
        context.insert(otherRig)
        try add(.manual, title: "Other rig", rig: otherRig)
        let trip = try Trip.create(TripDraft(campgroundName: "Pines", arrival: .now, departure: .now.addingTimeInterval(86_400)), rig: rig, in: context)
        try add(.reservation, rig: nil, trip: trip)
        #expect(rig.generalAssistantScope().isEmpty)
    }

    @Test func scopeIsReadLiveSoDeletionAndRecategorizingTakeEffectImmediately() throws {
        let manual = try add(.manual, rig: rig)
        #expect(rig.generalAssistantScope().documentIDs == [manual.documentID])
        try manual.update(DocumentMetadata(title: "Manual", category: .insurance))
        #expect(rig.generalAssistantScope().isEmpty)
        try manual.update(DocumentMetadata(title: "Manual", category: .manual))
        context.delete(manual)
        #expect(rig.generalAssistantScope().isEmpty)
    }

    @Test func liveFactsCarryTheChecksumUsedToDetectReplacedFiles() throws {
        let manual = try add(.manual, title: "Water Heater", rig: rig)
        let live = try #require(rig.generalAssistantScope().live[manual.documentID])
        #expect(live.title == "Water Heater")
        #expect(live.category == "Manual")
        #expect(live.checksum == manual.checksum)
        #expect(live.isInScope)
        manual.attach(try DocumentPayload(bytes: Self.pdf + Data([1, 2, 3]), filename: "new.pdf"))
        #expect(rig.generalAssistantScope().live[manual.documentID]?.checksum != live.checksum)
    }

    @Test func indexingListsOnlySearchableDocumentsAndCapturesBytesOnRequest() throws {
        let manual = try add(.manual, rig: rig)
        try add(.insurance, rig: rig)
        try add(.manual, rig: nil, file: false)
        let checksum = try #require(manual.checksum)
        let listed = try context.indexableDocuments()
        #expect(listed == [IndexableDocument(documentID: manual.documentID, checksum: checksum)])
        let job = try #require(try context.indexJob(documentID: manual.documentID, checksum: checksum))
        #expect(try job.content.verifiedBytes() == Self.pdf)
        #expect(try context.indexJob(documentID: manual.documentID, checksum: "stale") == nil)
    }

    // MARK: Assignment

    private func newTrip(_ name: String) throws -> Trip {
        try Trip.create(TripDraft(campgroundName: name, arrival: .now, departure: .now.addingTimeInterval(86_400)), rig: rig, in: context)
    }

    @Test func assigningToATripClearsTheRigAndToARigClearsTheTrip() throws {
        let manual = try add(.manual, rig: rig)
        let trip = try newTrip("Pines")
        let before = (manual.checksum, manual.content?.protectedBytes)
        manual.assign(to: .trip(trip))
        #expect(manual.rig == nil && manual.trip === trip)
        #expect(manual.assignment == .trip(trip))
        #expect(rig.generalAssistantScope().isEmpty)
        manual.assign(to: .rig(rig))
        #expect(manual.trip == nil && manual.rig === rig)
        #expect(rig.generalAssistantScope().documentIDs == [manual.documentID])
        #expect(manual.checksum == before.0 && manual.content?.protectedBytes == before.1)
        #expect(try manual.contents() == Self.pdf)
    }

    @Test func archivedRigsCanOwnDocumentsButTheirScopeIsTheirOwn() throws {
        let archived = Rig()
        context.insert(archived)
        archived.archivedAt = .now
        let manual = try add(.manual, rig: nil)
        manual.assign(to: .rig(archived))
        #expect(manual.assignment == .rig(archived))
        #expect(rig.generalAssistantScope().isEmpty)
    }

    @Test func unattachedDocumentsAreOutOfScopeEvenWhenOtherwiseEligible() throws {
        let manual = try add(.manual, rig: rig)
        manual.assign(to: .unattached)
        #expect(manual.isUnattached && manual.isAssistantSearchable)
        #expect(rig.generalAssistantScope().isEmpty)
        // Index rows may be stale; the live scope is what gates answers.
        #expect(rig.generalAssistantScope().live[manual.documentID] == nil)
    }

    @Test func assignmentNeverBypassesCategoryOrContentRules() throws {
        let insurance = try add(.insurance, rig: nil)
        let other = try add(.other, rig: nil)
        let link = try add(.manual, rig: nil, file: false)
        for document in [insurance, other, link] { document.assign(to: .rig(rig)) }
        #expect(rig.generalAssistantScope().isEmpty)
        #expect(try context.indexableDocuments().isEmpty)
    }

    @Test func assignmentMakesAnEligibleUnattachedDocumentIndexable() throws {
        let manual = try add(.manual, rig: nil)
        #expect(try context.indexableDocuments().count == 1)
        manual.assign(to: .rig(rig))
        #expect(rig.generalAssistantScope().documentIDs == [manual.documentID])
    }

    @Test func aDeletedTripsReservationStaysUnattachedUntilAssignedToAnotherTrip() throws {
        let first = try newTrip("First")
        let second = try newTrip("Second")
        let reservation = try add(.reservation, rig: nil, trip: first)
        context.delete(first)
        try context.save()
        #expect(reservation.isUnattached)
        #expect(rig.generalAssistantScope().isEmpty)
        #expect(second.documents?.isEmpty ?? true)
        reservation.assign(to: .trip(second))
        try context.save()
        #expect(second.documents?.map(\.documentID) == [reservation.documentID])
        #expect(reservation.isAssistantSearchable && !reservation.isUnattached)
        // Trip scope itself is resolved by the trip-scope work; a trip's document is never in the rig's general scope.
        #expect(rig.generalAssistantScope().isEmpty)
    }

    @Test func restoringThePriorAssignmentAfterAFailedSaveKeepsTheOldOwner() throws {
        let manual = try add(.manual, rig: rig)
        let prior = manual.assignment
        manual.assign(to: .trip(try newTrip("Pines")))
        manual.assign(to: prior)
        #expect(manual.rig === rig && manual.trip == nil)
    }
}
