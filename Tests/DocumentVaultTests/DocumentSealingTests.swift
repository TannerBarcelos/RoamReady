import XCTest
@testable import DocumentVault

/// Runs on Linux through swift-crypto as well as on Apple platforms through CryptoKit.
final class DocumentSealingTests: XCTestCase {
    private let plaintext = Data("%PDF-1.7\n".utf8) + Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    private let document = UUID()
    private var file: DocumentFile { try! DocumentPolicy.inspect(plaintext, filename: "Manual.pdf") }

    func testStandardFilesAreStoredAsTheyAre() throws {
        let sealed = try DocumentSealing.seal(plaintext, protection: .standard, documentID: document)
        XCTAssertEqual(sealed.bytes, plaintext)
        XCTAssertNil(sealed.key)
        XCTAssertEqual(try DocumentSealing.open(sealed.bytes, key: nil, documentID: document, expecting: file), plaintext)
    }

    func testEndToEndFilesOpenOnlyForTheirOwnDocument() throws {
        let sealed = try DocumentSealing.seal(plaintext, protection: .endToEnd, documentID: document)
        XCTAssertNotEqual(sealed.bytes.prefix(64), plaintext.prefix(64))
        XCTAssertEqual(sealed.bytes.count, plaintext.count + DocumentSealing.overhead)
        XCTAssertEqual(sealed.key?.count, 32)
        XCTAssertEqual(try DocumentSealing.open(sealed.bytes, key: sealed.key, documentID: document, expecting: file), plaintext)
        XCTAssertThrowsError(try DocumentSealing.open(sealed.bytes, key: sealed.key, documentID: UUID(), expecting: file)) {
            XCTAssertEqual($0 as? DocumentError, .contentIntegrity)
        }
    }

    func testWrongKeyTamperingOrADifferentFileFailIntegrity() throws {
        var sealed = try DocumentSealing.seal(plaintext, protection: .endToEnd, documentID: document)
        let other = try DocumentSealing.seal(plaintext, protection: .endToEnd, documentID: document)
        XCTAssertThrowsError(try DocumentSealing.open(sealed.bytes, key: other.key, documentID: document, expecting: file))
        var bytes = sealed.bytes; bytes[bytes.count / 2] ^= 0x01
        XCTAssertThrowsError(try DocumentSealing.open(bytes, key: sealed.key, documentID: document, expecting: file)) {
            XCTAssertEqual($0 as? DocumentError, .contentIntegrity)
        }
        var altered = plaintext; altered[altered.count - 1] ^= 0x01
        XCTAssertThrowsError(try DocumentSealing.open(altered, key: nil, documentID: document, expecting: file)) {
            XCTAssertEqual($0 as? DocumentError, .contentIntegrity)
        }
        sealed = try DocumentSealing.seal(plaintext, protection: .endToEnd, documentID: document)
        XCTAssertNotEqual(sealed.bytes, other.bytes, "Each seal uses a fresh key and nonce")
    }
}
