import XCTest
@testable import DocumentVault

/// Runs on Linux through swift-crypto as well as on Apple platforms through CryptoKit.
final class DocumentCipherTests: XCTestCase {
    private let plaintext = Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    private let document = UUID()

    func testSealedChunkOpensOnlyAtItsOwnPosition() throws {
        let key = DocumentCipher.newKey()
        let sealed = try DocumentCipher.seal(plaintext, key: key, documentID: document, index: 2, final: false)
        XCTAssertEqual(sealed.count, plaintext.count + DocumentCipher.overhead)
        XCTAssertEqual(try DocumentCipher.open(sealed, key: key, documentID: document, index: 2, final: false), plaintext)

        for (documentID, index, final) in [(UUID(), 2, false), (document, 3, false), (document, 2, true)] {
            XCTAssertThrowsError(try DocumentCipher.open(sealed, key: key, documentID: documentID, index: index, final: final)) {
                XCTAssertEqual($0 as? DocumentError, .contentIntegrity)
            }
        }
    }

    func testWrongKeyOrTamperedBytesFailAuthentication() throws {
        let key = DocumentCipher.newKey()
        var sealed = try DocumentCipher.seal(plaintext, key: key, documentID: document, index: 0, final: true)
        XCTAssertThrowsError(try DocumentCipher.open(sealed, key: DocumentCipher.newKey(), documentID: document, index: 0, final: true))
        sealed[sealed.count / 2] ^= 0x01
        XCTAssertThrowsError(try DocumentCipher.open(sealed, key: key, documentID: document, index: 0, final: true)) {
            XCTAssertEqual($0 as? DocumentError, .contentIntegrity)
        }
    }

    func testEachSealUsesAFreshNonce() throws {
        let key = DocumentCipher.newKey()
        let first = try DocumentCipher.seal(plaintext, key: key, documentID: document, index: 0, final: true)
        let second = try DocumentCipher.seal(plaintext, key: key, documentID: document, index: 0, final: true)
        XCTAssertNotEqual(first, second)
    }
}
