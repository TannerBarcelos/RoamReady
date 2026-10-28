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

    @Test func registrationInsuranceAndOtherAreNeverInScope() throws {
        try add(.registration, rig: rig)
        try add(.insurance, rig: rig)
        try add(.other, rig: rig)
        #expect(rig.generalAssistantScope().isEmpty)
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
}
