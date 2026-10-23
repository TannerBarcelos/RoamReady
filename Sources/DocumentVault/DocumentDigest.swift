import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Lowercase hexadecimal SHA-256 used to verify that stored document bytes are the originals.
/// CryptoKit on Apple platforms; Apple's API-identical swift-crypto elsewhere.
public enum DocumentDigest {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func inspectFile(at url: URL, maximumByteCount: Int) throws -> (checksum: String, byteCount: Int, signature: Data) {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hash = SHA256(), count = 0, signature = Data()
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            count += chunk.count
            guard count <= maximumByteCount else { throw DocumentError.fileTooLarge(limit: maximumByteCount) }
            if signature.isEmpty { signature = Data(chunk.prefix(16)) }
            hash.update(data: chunk)
        }
        return (hash.finalize().map { String(format: "%02x", $0) }.joined(), count, signature)
    }
}
