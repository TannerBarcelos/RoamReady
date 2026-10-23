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
        var hasher = DocumentHasher()
        hasher.update(data)
        return hasher.finalize()
    }
}

/// Incremental SHA-256 so large files are hashed chunk by chunk instead of in one buffer.
public struct DocumentHasher {
    private var inner = SHA256()
    public init() {}
    public mutating func update(_ data: Data) { inner.update(data: data) }
    public func finalize() -> String { inner.finalize().map { String(format: "%02x", $0) }.joined() }
}
