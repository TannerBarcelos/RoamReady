#if DEBUG
import Foundation
import SwiftData
import CampPersistence
import DocumentSearch
import DocumentVault

/// `-document-readiness-fixture` (with `-navigation-ui-test` and `-document-assistant-fixture`) adds a second
/// synthetic document to the fixture rig whose indexing is held open: the water heater manual becomes ready
/// while "Scanned Service Record" stays being read, until the test taps "Finish test scan" in the chat. That
/// makes the ready-plus-unfinished case, and the later retry, deterministic. Everything is invented and the
/// search index starts empty on every launch.
@MainActor
enum DocumentReadinessFixture {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-document-readiness-fixture") }
    static let scanID = UUID(uuidString: "00000000-0000-4000-8000-0000000000C3")!
    private(set) static var isReleased = false

    static func seed(rig: Rig, in context: ModelContext) throws {
        let record = try DocumentAssistantFixture.payload(filename: "Scanned Service Record.pdf", pages: [
            ("SERVICE RECORD", "The anode rod was replaced on May 12, 2024 by the dealer service department.")
        ])
        try StoredDocument.add(DocumentMetadata(title: "Scanned Service Record", category: .maintenance), contents: record, rig: rig, in: context)
            .documentID = scanID
    }

    static func release() { isReleased = true }

    /// Indexes the held document last, so everything else is ready while it waits.
    static func ordered(_ documents: [LibraryDocument]) -> [LibraryDocument] {
        guard isRequested else { return documents }
        return documents.filter { $0.id != scanID.uuidString } + documents.filter { $0.id == scanID.uuidString }
    }

    /// Holds the scan's read open until released. Cancellation (closing the library session) ends the wait.
    static func holdIfNeeded(_ document: LibraryDocument) async throws {
        guard isRequested, document.id == scanID.uuidString else { return }
        while !isReleased { try await Task.sleep(for: .milliseconds(50)) }
    }
}
#endif
