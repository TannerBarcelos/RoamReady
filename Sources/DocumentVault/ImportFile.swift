import Foundation

/// An app-owned, bounded copy of a provider's temporary file. Its last owner removes it.
/// Copy inside the FileRepresentation or file-coordination callback, before its URL expires.
public final class ImportFile: Sendable {
    public let url: URL
    public let filename: String
    private let directory: URL

    public init(copying source: URL, maximumByteCount: Int, filename: String? = nil) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "RoamReady-Import-\(UUID().uuidString)", directoryHint: .isDirectory)
        self.directory = directory
        self.filename = filename ?? source.lastPathComponent
        url = directory.appending(path: "Content")
        do {
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { throw DocumentError.unsupportedFileType }
            guard (values.fileSize ?? 0) <= maximumByteCount else { throw DocumentError.fileTooLarge(limit: maximumByteCount) }
            #if os(iOS)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            #else
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            #endif
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: url)
            defer { try? output.close() }
            var count = 0
            while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                count += chunk.count
                guard count <= maximumByteCount else { throw DocumentError.fileTooLarge(limit: maximumByteCount) }
                try output.write(contentsOf: chunk)
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    /// SwiftData accepts Data. Materialize only this bounded, app-owned file, off the UI thread.
    public func documentPayload() throws -> DocumentPayload {
        try DocumentPayload(bytes: Data(contentsOf: url), filename: filename)
    }

    /// Validate without keeping the document in a view's state.
    public func inspectDocument() throws -> DocumentFile {
        try DocumentPolicy.inspect(fileAt: url, filename: filename)
    }
}

/// Verified original bytes ready for a model save. Construct away from the UI thread;
/// the model needn't hash a large attachment a second time during insertion.
public struct DocumentPayload: Sendable {
    public let bytes: Data
    public let file: DocumentFile

    public init(bytes: Data, filename: String) throws {
        file = try DocumentPolicy.inspect(bytes, filename: filename)
        self.bytes = bytes
    }
}
