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

    @Test func registrationIsStoredNormalizedEncryptedAndKeptOnEdit() throws {
        var draft = trailer
        draft.vin = "1hgcm 82633-a004352"; draft.licensePlate = " 8abc  123 "; draft.plateRegion = " CA "
        let rig = try Rig.add(draft, to: context)
        #expect(rig.vin == "1HGCM82633A004352" && rig.licensePlate == "8ABC 123" && rig.plateRegion == "CA")
        #expect(rig.draft.vin == rig.vin && rig.plateSummary == "8ABC 123 · CA")
        var edited = rig.draft; edited.lengthFeet = 24
        try rig.update(edited)
        #expect(rig.vin == "1HGCM82633A004352", "Editing other details keeps the registration")
        var broken = rig.draft; broken.vin = "1HGCM82633A00435"
        #expect(throws: CampError.invalidVIN) { try rig.update(broken) }
        #expect(rig.vin == "1HGCM82633A004352", "A refused edit changes nothing")
        let tent = try rig.replace(with: RigDraft(type: .tent, equipment: .none, vin: "1HGCM82633A004352"))
        #expect(tent.vin.isEmpty, "A tent has no registration")
        let entity = try #require(LibraryStore.schema.entities.first { $0.name == "Rig" })
        for name in ["vin", "licensePlate", "plateRegion"] {
            #expect(try #require(entity.attributesByName[name]).options.contains(.allowsCloudEncryption), "\(name)")
        }
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

    @Test func priorityAndNotesTravelWithAStepIntoDefaultsAndNewTrips() throws {
        let rig = try Rig.add(trailer, to: context)
        let first = try trip(rig: rig)
        let step = first.steps(.setup)[0]
        var edited = step.draft
        edited.notes = "Chocks are in the front bin"; edited.priority = .high; edited.status = .completed
        step.apply(edited)
        #expect(step.notes == "Chocks are in the front bin" && step.priority == .high)
        #expect(step.draft == edited)
        first.addStep(ChecklistStepDraft(title: "Fill the kettle", notes: "Filtered water", priority: .low), to: .teardown)
        #expect(first.steps(.teardown).last?.priority == .low, "Added steps keep their priority")
        try first.saveChecklistsAsDefaults()
        let saved = try #require(rig.defaultTemplate.setup.first)
        #expect(saved.notes == "Chocks are in the front bin" && saved.priority == .high && saved.status == .pending,
                "Defaults keep notes and priority; only progress resets")
        let next = try trip("Lakeside", rig: rig)
        #expect(next.steps(.setup)[0].priority == .high && next.steps(.setup)[0].notes == "Chocks are in the front bin")
        #expect(next.steps(.teardown).last?.notes == "Filtered water")
        next.steps(.setup)[0].priority = ChecklistPriority.none
        #expect(first.steps(.setup)[0].priority == .high, "Each trip owns its copy")
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
        let pinesID = CampgroundIdentity.local(UUID()).campgroundID
        let lakesideID = CampgroundIdentity.local(UUID()).campgroundID
        let trip = try trip(rig: Rig.add(trailer, to: context))
        trip.campgroundID = pinesID
        let afterwards = arrival.addingTimeInterval(10 * 86_400)
        func lists() throws -> CampgroundLists {
            CampgroundLists(saved: try context.fetch(FetchDescriptor<SavedCampground>()), trips: [trip], now: afterwards)
        }
        #expect(try lists().campgroundIDs(on: .beenTo) == [pinesID])
        try SavedCampground.set(pinesID, name: "Pines", region: "CO", on: .beenTo, false, in: context)
        #expect(try !lists().contains(pinesID, on: .beenTo), "The removal sticks")
        try SavedCampground.set(lakesideID, name: "Lakeside", region: "UT", on: .wantToGo, true, in: context)
        try SavedCampground.set(lakesideID, name: "", region: "", on: .favorite, true, in: context)
        #expect(try lists().name(lakesideID) == "Lakeside", "A blank name doesn't erase the saved one")
        #expect(try lists().count == 1, "One campground on two lists counts once")
        try SavedCampground.set(lakesideID, name: "", region: "", on: .wantToGo, false, in: context)
        try SavedCampground.set(lakesideID, name: "", region: "", on: .favorite, false, in: context)
        #expect(try lists().entry(lakesideID) == nil, "An entry on no list is deleted")
        #expect(try lists().count == 0)
        trip.campgroundID = nil
        #expect(try lists().otherPlaces == [trip.campgroundName], "A trip entered by name still counts as a place camped")
        #expect(try lists().count == 1)
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
        return try StoredDocument.add(DocumentMetadata(title: "Doc", category: category, protection: protection),
                                      contents: DocumentPayload(bytes: Self.pdf, filename: "file.pdf"), in: context)
    }

    @Test func allNewFilesUseAppleEncryptionWithoutApplicationKeys() throws {
        for category in DocumentCategory.standard {
            let document = try addFile(category)
            #expect(document.protection == .endToEnd)
            #expect(document.content?.protectedBytes == Self.pdf)
            #expect(document.content?.bytes == nil && document.content?.key == nil)
            #expect(try document.contents() == Self.pdf && document.availability == .offline)
        }
        let attributes = [("Rig", "protectedPhoto"), ("TripPhoto", "protectedImage"), ("DocumentContent", "protectedBytes")]
        for (entityName, attributeName) in attributes {
            let entity = try #require(LibraryStore.schema.entities.first { $0.name == entityName })
            let attribute = try #require(entity.attributesByName[attributeName])
            #expect(attribute.options.contains(.externalStorage))
            #expect(attribute.options.contains(.allowsCloudEncryption), "Small inline attachments need encrypted fields too")
        }
        try context.save()
    }

    @Test func tamperedOrMissingBytesAreNeverReturned() throws {
        let document = try addFile(.insurance)
        document.content?.protectedBytes?[40] ^= 0x01
        #expect(throws: DocumentError.contentIntegrity) { try document.contents() }
        document.content?.protectedBytes = nil
        #expect(document.availability == .awaitingDownload)
        #expect(throws: DocumentError.contentNotDownloaded) { try document.contents() }
    }

    @Test func changingMetadataDoesNotRequireDownloadingOrRewritingTheFile() throws {
        let document = try addFile(.manual)
        document.content?.protectedBytes = nil
        var metadata = document.metadata; metadata.category = .registration
        try document.update(metadata)
        #expect(document.category == .registration && document.availability == .awaitingDownload)
        #expect(document.content?.key == nil && document.content?.bytes == nil)
    }

    @Test func legacyFilesRemainReadableAndReplacementUsesAppleEncryption() throws {
        let original = Data("%PDF-1.7\nlegacy attachment\n".utf8)
        let file = try DocumentPolicy.inspect(original, filename: "old.pdf")
        let document = try addFile(.insurance)
        document.documentID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        document.checksum = file.checksum; document.byteCount = file.byteCount
        document.content?.checksum = file.checksum
        document.content?.protectedBytes = nil
        document.content?.bytes = Data(base64Encoded: "AAECAwQFBgcICQoLYlKSXejU7CyHLfLs0IoBTeKi81WTEzIZVhPvIrYnY0tcLaHMOfhEUMhQNg==")!
        document.content?.key = Data(base64Encoded: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=")!
        #expect(try document.contents() == original)
        try document.update(DocumentMetadata(title: "Renamed", category: .manual))
        #expect(try document.contents() == original, "Metadata edits preserve the legacy format")
        document.content?.key = nil
        #expect(document.availability == .awaitingDownload)
        #expect(throws: DocumentError.contentNotDownloaded) { try document.contents() }
        document.attach(try DocumentPayload(bytes: Self.pdf, filename: "new.pdf"))
        #expect(document.content?.bytes == nil && document.content?.key == nil)
        #expect(try document.contents() == Self.pdf)
    }

    @Test func oldPhotoFieldsRemainVisibleAndNewPhotosUseEncryptedFields() throws {
        let rig = try Rig.add(trailer, to: context)
        rig.photo = Data([1, 2, 3])
        #expect(rig.draft.photo == rig.photo)
        var draft = rig.draft; draft.photo = Data([4, 5, 6])
        try rig.update(draft)
        #expect(rig.photo == nil && rig.protectedPhoto == draft.photo && rig.photoData == draft.photo)
        let photo = TripPhoto(image: Data([7, 8, 9]))
        context.insert(photo)
        #expect(photo.image == nil && photo.imageData == photo.protectedImage)
        photo.protectedImage = nil; photo.image = Data([1])
        #expect(photo.imageData == Data([1]))
    }

    @Test func linksStayOnlineOnlyUntilTheirContentsAreSaved() throws {
        let link = try StoredDocument.add(DocumentMetadata(title: "Manual", category: .manual), link: URL(string: "https://example.com/m.pdf"), in: context)
        #expect(link.availability == .onlineOnly)
        #expect(throws: DocumentError.linkOnly) { try link.contents() }
        link.attach(try DocumentPayload(bytes: Self.pdf, filename: "m.pdf"))
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
            trip.steps(.setup)[0].notes = "Bring the long hose"; trip.steps(.setup)[0].priority = .medium
            try StoredDocument.add(DocumentMetadata(title: "Card", category: .insurance), contents: DocumentPayload(bytes: Self.pdf, filename: "c.pdf"), rig: rig, in: context)
            try context.save()
        }
        // Keep the container alive while its models are read; a context doesn't own its container.
        let reopenedContainer = try LibraryStore.container(at: url, cloudKitContainer: nil)
        let reopened = reopenedContainer.mainContext
        #expect(try reopened.profile()?.name == "Sam")
        let trip = try #require(try reopened.fetch(FetchDescriptor<Trip>()).first)
        #expect(trip.rig?.model == "No Boundaries" && trip.steps(.setup)[0].status == .skipped)
        #expect(trip.steps(.setup)[0].notes == "Bring the long hose" && trip.steps(.setup)[0].priority == .medium)
        #expect(try reopened.rigs().first?.attachedDocuments.first?.contents() == Self.pdf)
    }

    @Test func theExportHoldsTheLibraryAndVerifiedDocuments() throws {
        let rig = try Rig.add(trailer, to: context)
        _ = try trip(rig: rig)
        let file = try addFile(.insurance); file.rig = rig
        _ = try StoredDocument.add(DocumentMetadata(title: "Link"), link: URL(string: "https://example.com"), in: context)
        let missing = try addFile(.manual); missing.content?.protectedBytes = nil
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
