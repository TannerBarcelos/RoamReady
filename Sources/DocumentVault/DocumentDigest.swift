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
}
