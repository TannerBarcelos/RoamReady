import Foundation
import CryptoKit

/// Read compatibility for files sealed by older builds. New writes use SwiftData's
/// `.allowsCloudEncryption` and CloudKit's automatically encrypted assets, without app keys.
public enum LegacyDocumentSealing {
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
