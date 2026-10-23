#if canImport(CoreData)
import Foundation
import CampCore
import DocumentVault

/// One document's entry in an export's `documents.json`.
public struct ExportedDocument: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// The verified original file is in the archive at `path`.
        case included
        /// A link without saved contents; the link is the whole document.
        case linkOnly
        /// The file has not downloaded to this device, so it could not be included.
        case notDownloaded
    }
    public let id: UUID
    public let ownerKind: String
    public let ownerID: UUID
    public let title: String
    public let category: String
    public let notes: String
    public let issuedOn: Date?
    public let expiresOn: Date?
    public let link: URL?
    public let protection: String
    public let filename: String?
    public let contentType: String?
    public let byteCount: Int?
    public let sha256: String?
    public let createdAt: Date
    public let status: Status
    /// Relative path inside the archive when `status == .included`.
    public let path: String?
}

public struct ExportSummary: Equatable, Sendable {
    public let included: Int
    public let linkOnly: Int
    public let notDownloaded: Int
}

extension LibraryStore {
    /// Writes a zip archive containing `library.json` (trips, checklists, notes, saved
    /// campgrounds), `documents.json` (every document's details), and `Documents/` with each
    /// document's verified original file. End-to-end encrypted documents are exported readable:
    /// the archive is the user's own copy and is not protected by iCloud encryption.
    ///
    /// Files are written chunk by chunk and zipped by the system file coordinator, so no
    /// document is held in memory as a whole.
    @discardableResult
    public func exportArchive(to archiveURL: URL) async throws -> ExportSummary {
        let workspace = directory.appendingPathComponent(Self.stagingDirectoryName, isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = workspace.appendingPathComponent("RoamReady Export", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        try await export(to: root.appendingPathComponent("library.json"))

        var entries: [ExportedDocument] = []
        for document in try await documents(ownedBy: nil) {
            var status = ExportedDocument.Status.linkOnly, path: String?
            if let file = document.file {
                let relative = "Documents/\(document.id.uuidString.prefix(8)) \(DocumentPolicy.sanitizedFilename(file.filename, for: file.contentType))"
                do {
                    try await exportContents(ofDocument: document.id, to: root.appendingPathComponent(relative))
                    status = .included; path = relative
                } catch DocumentError.contentNotDownloaded {
                    status = .notDownloaded
                }
            }
            let m = document.metadata
            entries.append(ExportedDocument(id: document.id, ownerKind: document.owner.kind.rawValue, ownerID: document.owner.id, title: m.title,
                                            category: m.category.rawValue, notes: m.notes, issuedOn: m.issuedOn, expiresOn: m.expiresOn,
                                            link: document.link, protection: m.protection.rawValue, filename: document.file?.filename,
                                            contentType: document.file?.contentType.rawValue, byteCount: document.file?.byteCount,
                                            sha256: document.file?.checksum, createdAt: document.createdAt, status: status, path: path))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        struct Manifest: Encodable { let schemaVersion = 1; let documents: [ExportedDocument] }
        try encoder.encode(Manifest(documents: entries)).write(to: root.appendingPathComponent("documents.json"), options: .atomic)

        try Self.zip(root, to: archiveURL)
        return ExportSummary(included: entries.filter { $0.status == .included }.count,
                             linkOnly: entries.filter { $0.status == .linkOnly }.count,
                             notDownloaded: entries.filter { $0.status == .notDownloaded }.count)
    }

    /// The system zips a directory when it is coordinated for uploading; no archive code ships here.
    private static func zip(_ folder: URL, to destination: URL) throws {
        var coordinationError: NSError?, result: Result<Void, any Error> = .failure(CocoaError(.fileWriteUnknown))
        NSFileCoordinator().coordinate(readingItemAt: folder, options: [.forUploading], error: &coordinationError) { zipped in
            result = Result {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                // The coordinator's archive is temporary; it must be copied before the block returns.
                try FileManager.default.copyItem(at: zipped, to: destination)
            }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
    }
}
#endif
