import Foundation
import SwiftData
import Testing
import CampCore
import DocumentVault
@testable import CampPersistence

/// A cited source is resolved against the library when it is opened, never when the answer was written.
@MainActor @Suite(.serialized)
struct SourceAvailabilityTests {
    let container: ModelContainer
    let context: ModelContext
    static let pdf = Data("%PDF-1.7\n1 0 obj\n<<>>\nendobj\n%%EOF\n".utf8) + Data((0..<2_000).map { UInt8(truncatingIfNeeded: $0) })

    init() throws {
        container = try LibraryStore.inMemory()
        context = container.mainContext
    }

    private func cite(_ document: StoredDocument) throws -> DocumentSource {
        DocumentSource(id: "S1", documentID: document.documentID, checksum: try #require(document.checksum),
                       title: document.title, category: "Manual", page: 2)
    }

    private func addManual() throws -> StoredDocument {
        try StoredDocument.add(DocumentMetadata(title: "Heater", category: .manual),
                               contents: DocumentPayload(bytes: Self.pdf, filename: "m.pdf"), in: context)
    }

    @Test func untouchedDocumentIsCurrent() throws {
        let manual = try addManual()
        #expect(context.availability(of: try cite(manual)) == .current)
    }

    @Test func replacingTheFileMakesTheCitationChangedNotCurrent() throws {
        let manual = try addManual()
        let source = try cite(manual)
        manual.attach(try DocumentPayload(bytes: Self.pdf + Data([9]), filename: "new.pdf"))
        #expect(context.availability(of: source) == .changed)
    }

    @Test func deletingTheDocumentMakesTheCitationDeleted() throws {
        let manual = try addManual()
        let source = try cite(manual)
        context.delete(manual)
        try context.save()
        #expect(context.availability(of: source) == .deleted)
    }

    @Test func renamingOrRecategorizingKeepsASourceCurrentBecauseTheFileIsTheSame() throws {
        let manual = try addManual()
        let source = try cite(manual)
        try manual.update(DocumentMetadata(title: "Renamed", category: .insurance))
        #expect(context.availability(of: source) == .current)
    }
}
