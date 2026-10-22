import Foundation
import CampCore

/// Readable copies of verified document bytes for Quick Look and sharing. The Core Data store is
/// the durable source; this cache is disposable and is rebuilt from it when missing.
struct DocumentFileCache: Sendable {
    let directory: URL

    /// Paths are keyed by checksum, so replaced contents never reuse a stale copy.
    func url(for file: DocumentFile) -> URL {
        directory.appendingPathComponent(file.checksum, isDirectory: true)
            .appendingPathComponent(DocumentPolicy.sanitizedFilename(file.filename, for: file.contentType))
    }

    func cachedURL(for file: DocumentFile) -> URL? {
        let url = url(for: file)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        return size == file.byteCount ? url : nil
    }

    func write(_ contents: DocumentContents) async throws -> URL {
        let destination = url(for: contents.file)
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.bytes.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }.value
        return destination
    }

    /// Account changes remove readable copies; the store keeps the originals.
    func removeAll() { try? FileManager.default.removeItem(at: directory) }
}

enum DocumentImport {
    /// Read a file chosen in the system document picker, downloading it from a file provider if
    /// needed. The bytes are returned untouched.
    static func read(pickedURL url: URL) async throws -> (data: Data, filename: String) {
        try await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var coordinationError: NSError?
            var result: Result<Data, any Error> = .failure(CocoaError(.fileReadUnknown))
            NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinationError) { readable in
                result = Result {
                    let size = try readable.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= DocumentPolicy.maximumByteCount else { throw DocumentError.fileTooLarge(limit: DocumentPolicy.maximumByteCount) }
                    return try Data(contentsOf: readable)
                }
            }
            if let coordinationError { throw coordinationError }
            return (try result.get(), url.lastPathComponent)
        }.value
    }

    /// Explicitly download a linked document's contents. Only HTTPS responses are accepted, and
    /// the bytes must be a supported PDF or image; the repository validates them again.
    /// The body is streamed and bounded: an oversized or non-document response is abandoned
    /// early instead of being downloaded in full.
    static func download(_ link: URL, limit: Int = DocumentPolicy.maximumByteCount) async throws -> (data: Data, filename: String) {
        let url = try DocumentPolicy.validatedLink(link)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (stream, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw DocumentDownloadError.unavailable }
        // App Transport Security already blocks plain-HTTP redirects; check the final URL anyway.
        guard http.url?.scheme?.lowercased() == "https" else { throw DocumentError.insecureLink }
        var buffer = try BoundedDocumentBuffer(limit: limit, expectedLength: http.expectedContentLength)
        let chunkSize = 64 * 1024
        var chunk: [UInt8] = []; chunk.reserveCapacity(chunkSize)
        do {
            for try await byte in stream {
                chunk.append(byte)
                if chunk.count == chunkSize { try buffer.append(chunk); chunk.removeAll(keepingCapacity: true) }
            }
            try buffer.append(chunk)
            return (try buffer.finish(), response.suggestedFilename ?? url.lastPathComponent)
        } catch DocumentError.unsupportedFileType {
            throw DocumentDownloadError.notADocument
        }
    }
}

enum DocumentDownloadError: LocalizedError {
    case unavailable, notADocument
    var errorDescription: String? {
        switch self {
        case .unavailable: "The link couldn’t be downloaded. Check the address or try again later."
        case .notADocument: "This link opens a web page, not a PDF or image, so it can only be opened online."
        }
    }
}
