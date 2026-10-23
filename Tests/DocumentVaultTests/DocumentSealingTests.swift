import XCTest
@testable import DocumentVault

/// A fixed AES-GCM fixture from the legacy format; production code can only read that format.
final class DocumentSealingTests: XCTestCase {
    private let plaintext = Data("%PDF-1.7\nlegacy attachment\n".utf8)
    private let document = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let key = Data(base64Encoded: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=")!
    private let box = Data(base64Encoded: "AAECAwQFBgcICQoLYlKSXejU7CyHLfLs0IoBTeKi81WTEzIZVhPvIrYnY0tcLaHMOfhEUMhQNg==")!
    private var file: DocumentFile { try! DocumentPolicy.inspect(plaintext, filename: "Manual.pdf") }

    func testExistingSealedFilesOpenOnlyForTheirOwnDocument() throws {
        XCTAssertEqual(try LegacyDocumentSealing.open(box, key: key, documentID: document, expecting: file), plaintext)
        XCTAssertThrowsError(try LegacyDocumentSealing.open(box, key: key, documentID: UUID(), expecting: file))
    }

    func testWrongKeysTamperingAndMismatchedPlaintextAreRejected() throws {
        XCTAssertThrowsError(try LegacyDocumentSealing.open(box, key: Data(repeating: 0, count: 32), documentID: document, expecting: file))
        var altered = box; altered[20] ^= 1
        XCTAssertThrowsError(try LegacyDocumentSealing.open(altered, key: key, documentID: document, expecting: file))
        var wrong = plaintext; wrong[0] ^= 1
        XCTAssertThrowsError(try LegacyDocumentSealing.open(wrong, key: nil, documentID: document, expecting: file))
        XCTAssertEqual(try LegacyDocumentSealing.open(plaintext, key: nil, documentID: document, expecting: file), plaintext)
    }
}
