import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// How a document's file bytes are stored, and how they are checked when read back.
///
/// Why the app encrypts some files itself: `CKRecord.encryptedValues` (SwiftData's
/// `.allowsCloudEncryption`) cannot hold a `CKAsset`, and large binary values sync as assets. Assets
/// are encrypted at rest with Apple-held keys, which is end-to-end only when the user turned on
/// Advanced Data Protection. So `.endToEnd` files are sealed here with CryptoKit's AES-256-GCM using
/// a random key per stored file, and only that 32-byte key relies on CloudKit: it lives in an
/// `.allowsCloudEncryption` attribute, end-to-end encrypted with the user's iCloud Keychain.
public enum DocumentSealing {
    /// Recorded with sealed bytes so a future format can be told apart.
    public static let scheme = "aes256gcm-v1"
    /// AES-GCM's nonce and tag around the ciphertext.
    public static let overhead = 12 + 16

    public struct Sealed: Sendable {
        public let bytes: Data
        /// The file key, or nil when the bytes are stored as they are.
        public let key: Data?
    }

    /// The bytes to store. The authenticated data binds them to `documentID`, so sealed bytes can't
    /// be moved to another document.
    public static func seal(_ plaintext: Data, protection: DocumentProtection, documentID: UUID) throws -> Sealed {
        guard protection == .endToEnd else { return Sealed(bytes: plaintext, key: nil) }
        let key = SymmetricKey(size: .bits256)
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: associatedData(documentID))
        guard let combined = box.combined else { throw DocumentError.contentIntegrity }
        return Sealed(bytes: combined, key: key.withUnsafeBytes { Data($0) })
    }

    /// The verified original bytes. A wrong key, another document's bytes, any tampering, or bytes
    /// that don't match the recorded file throw `contentIntegrity`.
    public static func open(_ stored: Data, key: Data?, documentID: UUID, expecting file: DocumentFile) throws -> Data {
        var plaintext = stored
        if let key {
            guard key.count == 32 else { throw DocumentError.contentIntegrity }
            do {
                plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: stored), using: SymmetricKey(data: key),
                                             authenticating: associatedData(documentID))
            } catch { throw DocumentError.contentIntegrity }
        }
        guard plaintext.count == file.byteCount, DocumentDigest.sha256(plaintext) == file.checksum else {
            throw DocumentError.contentIntegrity
        }
        return plaintext
    }

    private static func associatedData(_ documentID: UUID) -> Data { withUnsafeBytes(of: documentID.uuid) { Data($0) } }
}
