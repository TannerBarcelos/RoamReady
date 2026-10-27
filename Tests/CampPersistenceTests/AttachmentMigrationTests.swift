import Foundation
import SwiftData
import Testing
import CampCore
import DocumentVault
@testable import CampPersistence

@MainActor
struct AttachmentMigrationTests {
    @Test func prioritiesWrittenByThePreviousModelSurviveMigration() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "Library.store")
        do {
            let old = try ModelContainer(for: PriorityChecklistSchema.ChecklistStep.self,
                configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
            for priority in ChecklistPriority.allCases {
                let step = PriorityChecklistSchema.ChecklistStep()
                step.title = priority.rawValue; step.priority = priority
                step.notes = "Keep these notes"
                old.mainContext.insert(step)
            }
            try old.mainContext.save()
        }
        let migrated = try LibraryStore.container(at: url, cloudKitContainer: nil)
        let steps = try migrated.mainContext.fetch(FetchDescriptor<ChecklistStep>())
        #expect(steps.count == ChecklistPriority.allCases.count)
        for step in steps {
            #expect(step.priority.rawValue == step.title)
            #expect(step.draft.notes == "Keep these notes")
        }
    }

    @Test func assistantContextLoadsRigDefaultsAndTripStepsFromAnOlderLibrary() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "Library.store")
        do {
            let old = try ModelContainer(for: LegacyLibrarySchema.schema,
                configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
            let context = old.mainContext
            let rig = LegacyLibrarySchema.Rig(); context.insert(rig)
            let trip = LegacyLibrarySchema.Trip(); trip.rig = rig; context.insert(trip)
            let defaultStep = LegacyLibrarySchema.ChecklistStep()
            defaultStep.title = "Chock the wheels"; defaultStep.rig = rig; context.insert(defaultStep)
            let tripStep = LegacyLibrarySchema.ChecklistStep()
            tripStep.title = "Disconnect shore power"; tripStep.phase = .teardown
            tripStep.trip = trip; context.insert(tripStep)
            try context.save()
        }
        do {
            let migrated = try LibraryStore.container(at: url, cloudKitContainer: nil)
            let context = migrated.mainContext
            let rig = try #require(try context.activeRigs().first)
            let trip = try #require(try context.fetch(FetchDescriptor<Trip>()).first)
            // These are the same draft reads AssistantView.ask() makes before generation.
            let generalContext = rig.defaultTemplate.setup + rig.defaultTemplate.teardown
            let tripContext = (trip.steps(.setup) + trip.steps(.teardown)).map(\.draft)
            #expect(generalContext == [ChecklistStepDraft(title: "Chock the wheels", section: "")])
            #expect(tripContext == [ChecklistStepDraft(title: "Disconnect shore power", section: "")])
            trip.steps(.teardown)[0].priority = .high
            try context.save()
        }
        let reopened = try LibraryStore.container(at: url, cloudKitContainer: nil)
        let trip = try #require(try reopened.mainContext.fetch(FetchDescriptor<Trip>()).first)
        #expect(trip.steps(.teardown)[0].draft.priority == .high)
        let rig = try #require(try reopened.mainContext.activeRigs().first)
        #expect(rig.defaultTemplate.setup.first?.priority == ChecklistPriority.none)
    }

    @Test func anExistingStoreMigratesWithoutLosingPhotosOrEncryptedDocuments() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "Library.store")
        let plaintext = Data("%PDF-1.7\nlegacy attachment\n".utf8)
        let file = try DocumentPolicy.inspect(plaintext, filename: "old.pdf")
        do {
            let old = try ModelContainer(for: LegacyLibrarySchema.schema,
                configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
            let context = old.mainContext
            let rig = LegacyLibrarySchema.Rig()
            rig.photo = Data([1, 2, 3]); context.insert(rig)
            let trip = LegacyLibrarySchema.Trip()
            trip.rig = rig; context.insert(trip)
            let step = LegacyLibrarySchema.ChecklistStep()
            step.title = "Legacy step"; step.trip = trip; context.insert(step)
            let photo = LegacyLibrarySchema.TripPhoto(image: Data([4, 5, 6]))
            photo.trip = trip; context.insert(photo)
            let document = LegacyLibrarySchema.StoredDocument()
            document.documentID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
            document.title = "Legacy insurance"; document.categoryValue = "insurance"
            document.filename = file.filename; document.contentTypeValue = file.contentType.rawValue
            document.byteCount = file.byteCount; document.checksum = file.checksum
            document.protectionValue = "endToEnd"; document.trip = trip; context.insert(document)
            let content = LegacyLibrarySchema.DocumentContent()
            content.bytes = Data(base64Encoded: "AAECAwQFBgcICQoLYlKSXejU7CyHLfLs0IoBTeKi81WTEzIZVhPvIrYnY0tcLaHMOfhEUMhQNg==")!
            content.key = Data(base64Encoded: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=")!
            content.checksum = file.checksum; content.document = document; context.insert(content)
            try context.save()
        }
        let migrated = try LibraryStore.container(at: url, cloudKitContainer: nil)
        let context = migrated.mainContext
        let rig = try #require(try context.rigs().first)
        #expect(rig.photoData == Data([1, 2, 3]))
        let trip = try #require(try context.fetch(FetchDescriptor<Trip>()).first)
        #expect(trip.rig === rig && trip.sortedPhotos.first?.imageData == Data([4, 5, 6]))
        #expect(rig.vin.isEmpty && rig.licensePlate.isEmpty && rig.plateRegion.isEmpty, "New registration fields start empty")
        let step = try #require(trip.steps(.setup).first)
        #expect(step.title == "Legacy step" && step.notes.isEmpty && step.priority == ChecklistPriority.none, "Existing steps gain no priority or notes")
        let document = try #require(try context.fetch(FetchDescriptor<StoredDocument>()).first)
        #expect(document.trip === trip && document.title == "Legacy insurance")
        #expect(try document.contents() == plaintext)
        // A large replacement exercises external binary storage, alongside the small inline fixture.
        let large = plaintext + Data(repeating: 42, count: 2 * 1024 * 1024)
        document.attach(try DocumentPayload(bytes: large, filename: "replacement.pdf"))
        try context.save()
        #expect(document.content?.key == nil && document.content?.bytes == nil)
        #expect(try document.contents() == large)
    }
}

/// The persisted priority field before the nullable backing property. Only the checklist entity
/// is needed here: this fixture checks that migration retains every previously written enum case.
private enum PriorityChecklistSchema {
    @Model final class ChecklistStep {
        var title: String = ""
        var detail: String = ""
        var section: String = ""
        var status: ChecklistStatus = ChecklistStatus.pending
        var notes: String = ""
        var priority: ChecklistPriority = ChecklistPriority.none
        var phase: ChecklistPhase = ChecklistPhase.setup
        var position: Int = 0
        init() {}
    }
}
