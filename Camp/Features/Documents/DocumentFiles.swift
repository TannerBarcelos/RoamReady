import Foundation
import CoreTransferable
import UniformTypeIdentifiers
import CampCore
import DocumentVault

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

    /// Decrypted copies get the same data protection class as the store.
    func protect(_ url: URL) {
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
    }

    /// Account changes remove readable copies; the store keeps the originals.
    func removeAll() { try? FileManager.default.removeItem(at: directory) }
}

/// Temporary local copies of picked or downloaded files. Imports work from files, never from a
/// whole-file buffer, so large manuals don't need to fit in memory.
enum DocumentImport {
    static let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RoamReadyImports", isDirectory: true)

    static func temporaryLocation(named name: String) throws -> URL {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let last = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        return folder.appendingPathComponent(last.isEmpty || last == "." || last == ".." ? "Document" : last)
    }

    /// Removes a temporary copy and its folder.
    static func discard(_ url: URL) {
        guard url.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path) else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// Copy a file chosen in the system document picker, downloading it from a file provider if
    /// needed. The copy is byte-for-byte; nothing is read into memory.
    static func copy(pickedURL url: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var coordinationError: NSError?
            var result: Result<URL, any Error> = .failure(CocoaError(.fileReadUnknown))
            NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinationError) { readable in
                result = Result {
                    let size = try readable.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= DocumentPolicy.maximumByteCount else { throw DocumentError.fileTooLarge(limit: DocumentPolicy.maximumByteCount) }
                    let destination = try temporaryLocation(named: url.lastPathComponent)
                    try FileManager.default.copyItem(at: readable, to: destination)
                    return destination
                }
            }
            if let coordinationError { throw coordinationError }
            return try result.get()
        }.value
    }

    /// Explicitly download a linked document's contents to a temporary file. Bytes are written to
    /// disk as they arrive, and `BoundedDocumentWriter` abandons the download as soon as it is too
    /// large or isn't a PDF or image. Only HTTPS responses are accepted.
    static func download(_ link: URL) async throws -> (url: URL, filename: String) {
        try await StreamingDownload(url: DocumentPolicy.validatedLink(link)).run()
    }
}

/// A photo from the system picker, received as a file in its stored encoding.
struct ImportedPhotoFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let destination = try DocumentImport.temporaryLocation(named: received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return ImportedPhotoFile(url: destination)
        }
    }
}

/// One delegate-driven data task that streams the response body into a bounded file.
private final class StreamingDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    private let queue: OperationQueue
    // Mutable state is touched only by delegate callbacks on `queue`, which is serial.
    private var writer: BoundedDocumentWriter?
    private var filename: String
    private var failure: (any Error)?
    private var continuation: CheckedContinuation<(url: URL, filename: String), any Error>?

    init(url: URL) {
        self.url = url; filename = url.lastPathComponent
        queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
    }

    func run() async throws -> (url: URL, filename: String) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.addOperation {
                    self.continuation = continuation
                    task.resume()
                }
            }
        } onCancel: { task.cancel() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            failure = DocumentDownloadError.unavailable; completionHandler(.cancel); return
        }
        // App Transport Security already blocks plain-HTTP redirects; check the final URL anyway.
        guard http.url?.scheme?.lowercased() == "https" else { failure = DocumentError.insecureLink; completionHandler(.cancel); return }
        filename = response.suggestedFilename ?? filename
        do {
            // A declared size over the limit is refused before any body is read.
            writer = try BoundedDocumentWriter(destination: DocumentImport.temporaryLocation(named: filename), expectedLength: http.expectedContentLength)
            completionHandler(.allow)
        } catch { failure = error; completionHandler(.cancel) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil, let writer else { return }
        do { try writer.append(data) } catch { failure = error; dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let result: Result<(url: URL, filename: String), any Error>
        if let outcome = failure ?? error {
            writer?.discard(); result = .failure(Self.userFacing(outcome))
        } else if let writer {
            do { result = .success((try writer.finish(), filename)) }
            catch { writer.discard(); result = .failure(Self.userFacing(error)) }
        } else {
            result = .failure(DocumentDownloadError.unavailable)
        }
        continuation?.resume(with: result); continuation = nil
    }

    private static func userFacing(_ error: any Error) -> any Error {
        (error as? DocumentError) == .unsupportedFileType ? DocumentDownloadError.notADocument : error
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
