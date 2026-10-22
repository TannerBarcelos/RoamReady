#if canImport(CryptoKit)
import Foundation
import CryptoKit
import CampCore

/// Chunked AES-256-GCM for end-to-end protected document files.
///
/// CloudKit's field encryption does not cover assets, and Core Data mirrors large binary values as
/// assets. So protected files are encrypted here with a random key per stored file version; the key
/// itself is stored in a Core Data attribute marked `allowsCloudEncryption`, which CloudKit
/// end-to-end encrypts with the user's iCloud Keychain. No separate key management exists.
///
/// Each stored chunk row holds one AES-GCM combined box (12-byte nonce, ciphertext, 16-byte tag).
/// Its authenticated data binds the document ID, the chunk index, and whether it is the final
/// chunk, so chunks cannot be moved between documents, reordered, or dropped from the end
/// without failing authentication.
enum DocumentCipher {
    static let scheme = "aes256gcm-chunks-v1"
    static let chunkSize = DocumentByteSource.chunkSize
    static let overhead = 12 + 16

    static func newKey() -> SymmetricKey { SymmetricKey(size: .bits256) }

    static func seal(_ plaintext: Data, key: SymmetricKey, documentID: UUID, index: Int, final: Bool) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: associatedData(documentID, index, final))
        guard let combined = box.combined else { throw DocumentError.contentIntegrity }
        return combined
    }

    /// Any tampering, wrong key, wrong position, or wrong document throws `contentIntegrity`.
    static func open(_ sealed: Data, key: SymmetricKey, documentID: UUID, index: Int, final: Bool) throws -> Data {
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key, authenticating: associatedData(documentID, index, final))
        } catch { throw DocumentError.contentIntegrity }
    }

    private static func associatedData(_ documentID: UUID, _ index: Int, _ final: Bool) -> Data {
        var data = withUnsafeBytes(of: documentID.uuid) { Data($0) }
        withUnsafeBytes(of: UInt64(index).bigEndian) { data.append(contentsOf: $0) }
        data.append(final ? 1 : 0)
        return data
    }
}
#endif
