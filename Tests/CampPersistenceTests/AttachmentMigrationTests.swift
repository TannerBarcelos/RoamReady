import Foundation
import SwiftData
import Testing
import CampCore
import DocumentVault
@testable import CampPersistence

@MainActor
struct AttachmentMigrationTests {
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
