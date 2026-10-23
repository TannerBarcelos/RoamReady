#if canImport(SwiftData)
import Foundation
import SwiftData
import Testing
import CampCore
import DocumentVault
@testable import CampPersistence

/// Library rules against a real SwiftData store (in memory unless a test needs a file).
@MainActor @Suite(.serialized)
struct LibraryTests {
    let container: ModelContainer
    let context: ModelContext
    let trailer = RigDraft(type: .travelTrailer, make: "Forest River", model: "No Boundaries", year: 2024, lengthFeet: 19.5)
    let arrival = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        container = try LibraryStore.inMemory()
        context = container.mainContext
    }

    private func trip(_ name: String = "Pines", rig: Rig) throws -> Trip {
        try Trip.create(TripDraft(campgroundName: name, arrival: arrival, departure: arrival.addingTimeInterval(172_800)), rig: rig, in: context)
    }

    // MARK: Rigs

    @Test func addingARigGeneratesItsDefaultsAndASecondActiveRigIsRefused() throws {
        let rig = try Rig.add(trailer, to: context)
        #expect(rig.defaultTemplate == ChecklistFactory.template(for: trailer))
        #expect(throws: CampError.rigLimitReached) { try Rig.add(trailer, to: context) }
        #expect(throws: CampError.incompleteRig) { try Rig.add(RigDraft(type: .motorhome), to: context) }
        try context.save()
        #expect(try context.activeRigs().count == 1)
    }

    @Test func editingARigChangesWhatEveryTripShows() throws {
        let rig = try Rig.add(trailer, to: context)
        let past = try trip(rig: rig), next = try trip("Lakeside", rig: rig)
        var edited = rig.draft; edited.lengthFeet = 24
        try rig.update(edited)
        #expect(past.rig?.lengthFeet == 24 && next.rig?.lengthFeet == 24)
    }

    @Test func replacingArchivesTheRigAndPastTripsKeepIt() throws {
        let old = try Rig.add(trailer, to: context)
        let past = try trip(rig: old)
        let new = try old.replace(with: RigDraft(type: .motorhome, make: "Winnebago", model: "View", year: 2025, lengthFeet: 25))
        #expect(old.isArchived && !new.isArchived)
        #expect(past.rig === old)
        #expect(try context.activeRigs().map(\.model) == ["View"])
        #expect(throws: CampError.rigArchived) { try trip(rig: old) }
        #expect(throws: CampError.rigLimitReached) { try old.unarchive() }
        new.archive()
        try old.unarchive()
        #expect(!old.isArchived)
    }

    @Test func aRigCanBeDeletedOnlyWhileNoTripUsesIt() throws {
        let rig = try Rig.add(trailer, to: context)
        let manual = try StoredDocument.add(DocumentMetadata(title: "Manual", category: .manual), link: URL(string: "https://example.com/m.pdf"), rig: rig, in: context)
        let used = try trip(rig: rig)
        #expect(throws: CampError.rigInUse) { try rig.delete() }
        context.delete(used)
        try context.save()
        try rig.delete()
        try context.save()
        #expect(try context.rigs().isEmpty)
        #expect(try context.fetchCount(FetchDescriptor<ChecklistStep>()) == 0, "Its default lists go with it")
        #expect(manual.rig == nil, "Its documents become unattached")
    }

    @Test func aSyncRaceThatProducesTwoActiveRigsStaysReadable() throws {
        let first = try Rig.add(trailer, to: context)
        let second = Rig(); context.insert(second)
        #expect(try context.rigs().needsRigResolution)
        second.archive()
        #expect(try !context.rigs().needsRigResolution)
        _ = first
    }

    // MARK: Trips and checklists

    @Test func aNewTripGetsPendingCopiesOfItsRigsDefaults() throws {
        let rig = try Rig.add(trailer, to: context)
        var defaults = rig.defaultTemplate
        defaults.setup = [ChecklistStepDraft(title: "Custom first step", status: .completed)]
        rig.setDefaults(defaults)
        let trip = try trip(rig: rig)
        #expect(trip.steps(.setup).map(\.title) == ["Custom first step"])
        #expect(trip.steps(.setup).allSatisfy { $0.status == .pending })
        #expect(trip.steps(.teardown).count == defaults.teardown.count)
        #expect(trip.rig === rig)
    }

    @Test func tripListsAndRigDefaultsNeverChangeEachOther() throws {
        let rig = try Rig.add(trailer, to: context)
        let first = try trip(rig: rig), second = try trip("Lakeside", rig: rig)
        let before = rig.defaultTemplate
        first.steps(.setup)[0].status = .completed
        first.steps(.setup)[1].apply(ChecklistStepDraft(title: "Renamed"))
        first.addStep(ChecklistStepDraft(title: "Extra"), to: .setup)
        first.removeSteps([first.steps(.teardown)[0]])
        var reordered = first.steps(.setup); reordered.swapAt(0, 1); first.reorder(reordered)
        #expect(rig.defaultTemplate == before)
        #expect(second.steps(.setup).map(\.title) == before.setup.map(\.title))
        #expect(first.steps(.setup).first?.title == "Renamed" && first.steps(.setup).last?.title == "Extra")
        rig.resetDefaults()
        #expect(first.steps(.setup).last?.title == "Extra", "Resetting defaults leaves trips alone")
    }

    @Test func saveAsDefaultsWritesOnlyToTheTripsRigWithEveryStepUnchecked() throws {
        let rig = try Rig.add(trailer, to: context)
        let trip = try trip(rig: rig)
        trip.steps(.setup)[0].status = .completed
        trip.addStep(ChecklistStepDraft(title: "Fill the kettle"), to: .setup)
        try trip.saveChecklistsAsDefaults()
        #expect(rig.defaultTemplate.setup.last?.title == "Fill the kettle")
        #expect(rig.defaultTemplate.setup.allSatisfy { $0.status == .pending })
        #expect(trip.steps(.setup)[0].status == .completed, "The trip keeps its progress")
    }

    @Test func editingATripKeepsItsChecklistsAndValidatesTheBooking() throws {
        let rig = try Rig.add(trailer, to: context)
        let trip = try trip(rig: rig)
        trip.steps(.setup)[0].status = .completed
        var draft = TripDraft(trip)
        draft.campgroundName = "  Renamed  "; draft.confirmationNumber = "  "; draft.bookingURL = "https://www.recreation.gov/x"
        try trip.update(draft, rig: rig)
        #expect(trip.campgroundName == "Renamed" && trip.confirmationNumber == nil)
        #expect(trip.steps(.setup)[0].status == .completed)
        draft.bookingURL = "http://insecure.example"
        #expect(throws: CampError.invalidBookingLink) { try trip.update(draft, rig: rig) }
        #expect(trip.bookingURL == "https://www.recreation.gov/x", "A refused edit changes nothing")
    }

    @Test func addingATripStoresItsSiteDetailsAndFirstNotes() throws {
        let rig = try Rig.add(trailer, to: context)
        var draft = TripDraft(campgroundName: "Pines", arrival: arrival, departure: arrival)
        draft.site = SiteDetails(parking: .pullThrough, maxLengthFeet: 18, electric: .amp30)
        draft.notes = "  Level pad near the creek "
        let trip = try Trip.create(draft, rig: rig, in: context)
        #expect(trip.site == draft.site && trip.notes == "Level pad near the creek")
        #expect(trip.site?.isTooShort(for: rig) == true, "A 19.5 ft trailer doesn't fit an 18 ft site")
        var edited = TripDraft(trip); edited.site = SiteDetails()
        try trip.update(edited, rig: rig)
        #expect(trip.site == nil, "Clearing every field stores no site details")
        #expect(trip.notes == "Level pad near the creek", "Editing the booking never touches notes")
    }

    @Test func deletingATripRemovesItsHistoryButKeepsItsDocuments() throws {
        let rig = try Rig.add(trailer, to: context)
        let trip = try trip(rig: rig)
        trip.notes = "Shady site"; trip.saveNoteRevision()
        trip.addPhoto(Data([0xFF, 0xD8, 0xFF]))
        let confirmation = try StoredDocument.add(DocumentMetadata(title: "Confirmation", category: .reservation),
                                                  link: URL(string: "https://example.com/c"), trip: trip, in: context)
        try context.save()
        context.delete(trip)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<ChecklistStep>()) == rig.defaultSteps?.count)
        #expect(try context.fetchCount(FetchDescriptor<TripPhoto>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<NoteRevision>()) == 0)
        #expect(confirmation.trip == nil, "It moves to Unattached documents")
        #expect(rig.defaultSteps?.isEmpty == false, "The rig and its defaults are untouched")
    }

    @Test func noteRevisionsKeepEachSavedVersionOnce() throws {
        let trip = try trip(rig: Rig.add(trailer, to: context))
        trip.notes = "First"; trip.saveNoteRevision(); trip.saveNoteRevision()
        trip.notes = "Second"; trip.saveNoteRevision()
        #expect(trip.revisions.map(\.body).sorted() == ["First", "Second"])
    }

    @Test func markingCompleteEarlyIsReversible() throws {
        let trip = try trip(rig: Rig.add(trailer, to: context))
        trip.setCompleted(true, at: arrival)
        #expect(trip.isCompleted(asOf: arrival))
        trip.setCompleted(false)
        #expect(!trip.isCompleted(asOf: arrival))
    }

    // MARK: Saved campgrounds

    @Test func completedTripsPutTheirCampgroundOnBeenHereUnlessTheOwnerRemovesIt() throws {
        let trip = try trip(rig: Rig.add(trailer, to: context))
        trip.campgroundID = "ridb-1"
        let afterwards = arrival.addingTimeInterval(10 * 86_400)
        func lists() throws -> CampgroundLists {
            CampgroundLists(saved: try context.fetch(FetchDescriptor<SavedCampground>()), trips: [trip], now: afterwards)
        }
        #expect(try lists().campgroundIDs(on: .beenTo) == ["ridb-1"])
        try SavedCampground.set("ridb-1", name: "Pines", region: "CO", on: .beenTo, false, in: context)
        #expect(try !lists().contains("ridb-1", on: .beenTo), "The removal sticks")
        try SavedCampground.set("ridb-2", name: "Lakeside", region: "UT", on: .wantToGo, true, in: context)
        try SavedCampground.set("ridb-2", name: "", region: "", on: .favorite, true, in: context)
        #expect(try lists().name("ridb-2") == "Lakeside", "A blank name doesn't erase the saved one")
        try SavedCampground.set("ridb-2", name: "", region: "", on: .wantToGo, false, in: context)
        try SavedCampground.set("ridb-2", name: "", region: "", on: .favorite, false, in: context)
        #expect(try lists().entry("ridb-2") == nil, "An entry on no list is deleted")
    }

    @Test func anAppleMapsPlaceIsSavedByItsIdentifierOnly() throws {
        try SavedCampground.set("apple:I6FD7682FD36BB3BE", name: "Pine Flat", region: "Sonora, CA", on: .wantToGo, true, in: context)
        let lists = CampgroundLists(saved: try context.fetch(FetchDescriptor<SavedCampground>()), trips: [])
        let entry = try #require(lists.entry("apple:I6FD7682FD36BB3BE"))
        #expect(entry.name.isEmpty && entry.region.isEmpty, "Apple Maps' details are looked up when shown, never stored")
        #expect(lists.contains("apple:I6FD7682FD36BB3BE", on: .wantToGo))
        #expect(lists.name("apple:I6FD7682FD36BB3BE") == nil)
    }

    // MARK: Documents

    static let pdf = Data("%PDF-1.7\n1 0 obj\n<<>>\nendobj\n%%EOF\n".utf8) + Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0) })

    private func addFile(_ category: DocumentCategory, protection: DocumentProtection = .standard) throws -> StoredDocument {
        let file = try DocumentPolicy.inspect(Self.pdf, filename: "file.pdf")
        return try StoredDocument.add(DocumentMetadata(title: "Doc", category: category, protection: protection),
                                      contents: (Self.pdf, file), in: context)
    }

    @Test func filesAreStoredExactlyAndSensitiveTypesAreEncrypted() throws {
        let manual = try addFile(.manual), insurance = try addFile(.insurance)
        try context.save()
        #expect(manual.protection == .standard && manual.content?.bytes == Self.pdf && manual.content?.key == nil)
        #expect(insurance.protection == .endToEnd && insurance.content?.key?.count == 32)
        #expect(insurance.content?.bytes != Self.pdf, "No plaintext in the mirrored attribute")
        #expect(try manual.contents() == Self.pdf && insurance.contents() == Self.pdf)
        #expect(manual.availability == .offline)
    }

    @Test func tamperedOrMissingBytesAreNeverReturned() throws {
        let document = try addFile(.insurance)
        document.content?.bytes?[40] ^= 0x01
        #expect(throws: DocumentError.contentIntegrity) { try document.contents() }
        document.content?.bytes = nil
        #expect(document.availability == .awaitingDownload)
        #expect(throws: DocumentError.contentNotDownloaded) { try document.contents() }
    }

    @Test func raisingProtectionReEncryptsAndItIsNeverLowered() throws {
        let document = try addFile(.manual)
        var metadata = document.metadata; metadata.category = .registration
        try document.update(metadata)
        #expect(document.protection == .endToEnd && document.content?.key != nil)
        #expect(try document.contents() == Self.pdf)
        metadata.category = .manual; metadata.protection = .standard
        try document.update(metadata)
        #expect(document.protection == .endToEnd)
    }

    @Test func linksStayOnlineOnlyUntilTheirContentsAreSaved() throws {
        let link = try StoredDocument.add(DocumentMetadata(title: "Manual", category: .manual), link: URL(string: "https://example.com/m.pdf"), in: context)
        #expect(link.availability == .onlineOnly)
        #expect(throws: DocumentError.linkOnly) { try link.contents() }
        try link.attach(Self.pdf, file: DocumentPolicy.inspect(Self.pdf, filename: "m.pdf"))
        #expect(link.availability == .offline && link.linkURL != nil)
        #expect(throws: DocumentError.insecureLink) {
            try StoredDocument.add(DocumentMetadata(title: "Bad"), link: URL(string: "http://example.com"), in: context)
        }
    }

    // MARK: Durability and export

    @Test func theLibraryReopensFromDiskWithEverythingIntact() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "Library.store")
        do {
            let disk = try LibraryStore.container(at: url, cloudKitContainer: nil)
            let context = disk.mainContext
            context.insert(CamperProfile(name: "Sam", experience: .comfortable))
            let rig = try Rig.add(trailer, to: context)
            let trip = try Trip.create(TripDraft(campgroundName: "Pines", arrival: arrival, departure: arrival), rig: rig, in: context)
            trip.steps(.setup)[0].status = .skipped
            try StoredDocument.add(DocumentMetadata(title: "Card", category: .insurance), contents: (Self.pdf, try DocumentPolicy.inspect(Self.pdf, filename: "c.pdf")), rig: rig, in: context)
            try context.save()
        }
        // Keep the container alive while its models are read; a context doesn't own its container.
        let reopenedContainer = try LibraryStore.container(at: url, cloudKitContainer: nil)
        let reopened = reopenedContainer.mainContext
        #expect(try reopened.profile()?.name == "Sam")
        let trip = try #require(try reopened.fetch(FetchDescriptor<Trip>()).first)
        #expect(trip.rig?.model == "No Boundaries" && trip.steps(.setup)[0].status == .skipped)
        #expect(try reopened.rigs().first?.attachedDocuments.first?.contents() == Self.pdf)
    }

    @Test func theExportHoldsTheLibraryAndVerifiedDocuments() throws {
        let rig = try Rig.add(trailer, to: context)
        _ = try trip(rig: rig)
        let file = try addFile(.insurance); file.rig = rig
        _ = try StoredDocument.add(DocumentMetadata(title: "Link"), link: URL(string: "https://example.com"), in: context)
        let missing = try addFile(.manual); missing.content?.bytes = nil
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appending(path: "Export.zip")
        let summary = try LibraryExport.write(from: context, to: archive, workspace: directory.appending(path: "work"))
        #expect(summary == LibraryExport.Summary(included: 1, linkOnly: 1, notDownloaded: 1))
        #expect((try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0)
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "work").path), "The workspace is removed")
    }
}

#endif
