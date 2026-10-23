import Foundation
import CampPersistence
import DocumentVault

/// Readable copies of verified document bytes for Quick Look and sharing. The library is the
/// durable source; this cache is disposable and is rebuilt from it when missing.
struct DocumentFileCache: Sendable {
    let directory: URL

    /// A readable file holding the document's verified original bytes. Paths are keyed by checksum,
    /// so replaced contents never reuse a stale copy.
    @MainActor
    func url(for document: StoredDocument) async throws -> URL {
        let snapshot = try document.contentSnapshot()
        let directory = directory
        let url = try await Task.detached(priority: .userInitiated) {
            let url = directory.appending(path: snapshot.file.checksum, directoryHint: .isDirectory).appending(path: snapshot.file.filename)
            let bytes = try snapshot.verifiedBytes()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            try bytes.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return url
        }.value
        try Task.checkCancellation()
        return url
    }

    /// Decrypted copies get the same data protection class as the library.
    func protect(_ url: URL) {
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
    }
}

/// Reading picked files and downloading links. Files are at most `DocumentPolicy.maximumByteCount`.
enum DocumentImport {
    /// The bytes of a file chosen in the system document picker, downloading it from a file
    /// provider if needed.
    static func read(pickedURL url: URL) async throws -> ImportFile {
        try await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var coordinationError: NSError?
            var result: Result<ImportFile, any Error> = .failure(CocoaError(.fileReadUnknown))
            NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinationError) { readable in
                result = Result {
                    try ImportFile(copying: readable, maximumByteCount: DocumentPolicy.maximumByteCount, filename: url.lastPathComponent)
                }
            }
            if let coordinationError { throw coordinationError }
            return try result.get()
        }.value
    }

    /// Explicitly download a linked document's contents. Only an HTTPS PDF or image within the size
    /// limit is accepted.
    static func download(_ link: URL) async throws -> ImportFile {
        let url = try DocumentPolicy.validatedLink(link)
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (file, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw DocumentDownloadError.unavailable }
        // App Transport Security already blocks plain-HTTP redirects; check the final URL anyway.
        guard http.url?.scheme?.lowercased() == "https" else { throw DocumentError.insecureLink }
        return try await Task.detached(priority: .userInitiated) {
            let staged = try ImportFile(copying: file, maximumByteCount: DocumentPolicy.maximumByteCount,
                                        filename: response.suggestedFilename ?? url.lastPathComponent)
            _ = try staged.inspectDocument()
            return staged
        }.value
    }
}

enum DocumentDownloadError: LocalizedError {
    case unavailable
    var errorDescription: String? {
        switch self {
        case .unavailable: "The link couldn’t be downloaded. Check the address or try again later."
        }
    }
}
