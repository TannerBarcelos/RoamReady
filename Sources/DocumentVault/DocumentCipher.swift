import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Chunked AES-256-GCM for end-to-end protected document files.
///
/// Why this exists alongside CloudKit's own encryption: `CKRecord.encryptedValues` (Core Data's
/// `allowsCloudEncryption`) cannot hold a `CKAsset`, and Core Data mirrors large binary values as
/// assets. Assets are encrypted at rest with Apple-held keys, which is not end-to-end unless the user
/// turned on Advanced Data Protection. So protected files are sealed here with CryptoKit using a
/// random key per stored file version, and only that 32-byte key relies on CloudKit: it is stored in
/// an `allowsCloudEncryption` attribute, end-to-end encrypted with the user's iCloud Keychain. No
/// separate key management exists.
///
/// Each stored chunk row holds one AES-GCM combined box (12-byte nonce, ciphertext, 16-byte tag).
/// Its authenticated data binds the document ID, the chunk index, and whether it is the final
/// chunk, so chunks cannot be moved between documents, reordered, or dropped from the end
/// without failing authentication.
public enum DocumentCipher {
    public static let scheme = "aes256gcm-chunks-v1"
    public static let chunkSize = DocumentByteSource.chunkSize
    public static let overhead = 12 + 16

    public static func newKey() -> SymmetricKey { SymmetricKey(size: .bits256) }

    public static func seal(_ plaintext: Data, key: SymmetricKey, documentID: UUID, index: Int, final: Bool) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: associatedData(documentID, index, final))
        guard let combined = box.combined else { throw DocumentError.contentIntegrity }
        return combined
    }

    /// Any tampering, wrong key, wrong position, or wrong document throws `contentIntegrity`.
    public static func open(_ sealed: Data, key: SymmetricKey, documentID: UUID, index: Int, final: Bool) throws -> Data {
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
