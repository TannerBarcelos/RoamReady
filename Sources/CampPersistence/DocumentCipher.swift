#if canImport(CryptoKit)
import Foundation
import CryptoKit
import CampCore

/// Chunked AES-256-GCM for end-to-end protected document files.
///
/// CloudKit's field encryption does not cover assets, and Core Data mirrors large binary values as
/// assets. So protected files are encrypted here with a random per-document key; the key itself is
/// stored in a Core Data attribute marked `allowsCloudEncryption`, which CloudKit end-to-end
/// encrypts with the user's iCloud Keychain. No separate key management exists.
///
/// Layout: `"RRDE"`, version byte, 4-byte big-endian chunk size, then each chunk as an AES-GCM
/// combined box (12-byte nonce, ciphertext, 16-byte tag). Each chunk's authenticated data binds the
/// document ID, the chunk index, and whether it is the final chunk, so chunks cannot be moved
/// between documents, reordered, or truncated at a chunk boundary without failing authentication.
enum DocumentCipher {
    static let scheme = "aes256gcm-chunked-v1"
    static let chunkSize = DocumentByteSource.chunkSize
    private static let magic = Data("RRDE".utf8), version: UInt8 = 1
    private static let headerLength = 9, overhead = 12 + 16

    static func newKey() -> SymmetricKey { SymmetricKey(size: .bits256) }

    /// Encrypts `source` into `destination`, returning the SHA-256 of the plaintext read so the
    /// caller can confirm it encrypted exactly the bytes that were inspected.
    static func encrypt(_ source: DocumentByteSource, to destination: URL, key: SymmetricKey, documentID: UUID) throws -> String {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var header = magic; header.append(version)
        withUnsafeBytes(of: UInt32(chunkSize).bigEndian) { header.append(contentsOf: $0) }
        try output.write(contentsOf: header)
        var hasher = DocumentHasher(), pending = Data(), index: UInt64 = 0
        func seal(_ plaintext: Data, final: Bool) throws {
            let box = try AES.GCM.seal(plaintext, using: key, authenticating: associatedData(documentID, index, final))
            guard let combined = box.combined else { throw DocumentError.contentIntegrity }
            try output.write(contentsOf: combined); index += 1
        }
        try source.forEachChunk { chunk in
            hasher.update(chunk); pending.append(chunk)
            // Hold back at least one byte: only the source's end decides which chunk is final.
            while pending.count > chunkSize {
                try seal(pending.prefix(chunkSize), final: false)
                pending = Data(pending.dropFirst(chunkSize))
            }
        }
        guard !pending.isEmpty else { throw DocumentError.emptyFile }
        try seal(pending, final: true)
        return hasher.finalize()
    }

    /// Decrypts and authenticates each chunk, passing plaintext to `body` in order. Tampering,
    /// reordering, truncation, or a wrong key throws `contentIntegrity` at the first bad chunk, so
    /// callers must treat output as provisional until this returns (export writes to a temporary file).
    static func decrypt(_ ciphertext: Data, key: SymmetricKey, documentID: UUID, _ body: (Data) throws -> Void) throws {
        guard ciphertext.count > headerLength + overhead,
              ciphertext.prefix(4) == magic, ciphertext[ciphertext.startIndex + 4] == version else { throw DocumentError.contentIntegrity }
        let size = ciphertext[(ciphertext.startIndex + 5)..<(ciphertext.startIndex + 9)].reduce(0) { $0 << 8 | Int($1) }
        guard size == chunkSize else { throw DocumentError.contentIntegrity }
        var offset = ciphertext.startIndex + headerLength, index: UInt64 = 0
        while offset < ciphertext.endIndex {
            let end = min(offset + size + overhead, ciphertext.endIndex)
            let final = end == ciphertext.endIndex
            let plaintext: Data
            do {
                let box = try AES.GCM.SealedBox(combined: ciphertext[offset..<end])
                plaintext = try AES.GCM.open(box, using: key, authenticating: associatedData(documentID, index, final))
            } catch { throw DocumentError.contentIntegrity }
            try body(plaintext)
            offset = end; index += 1
        }
    }

    private static func associatedData(_ documentID: UUID, _ index: UInt64, _ final: Bool) -> Data {
        var data = withUnsafeBytes(of: documentID.uuid) { Data($0) }
        withUnsafeBytes(of: index.bigEndian) { data.append(contentsOf: $0) }
        data.append(final ? 1 : 0)
        return data
    }
}
#endif
