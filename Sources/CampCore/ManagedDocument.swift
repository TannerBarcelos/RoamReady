import Foundation

/// The rig or trip a document belongs to. Other features attach documents to one of these
/// owners rather than inventing their own attachment storage.
public struct DocumentOwner: Hashable, Codable, Sendable, CustomStringConvertible {
    public enum Kind: String, Codable, CaseIterable, Sendable { case rig, trip }
    public let kind: Kind
    public let id: UUID
    public init(kind: Kind, id: UUID) { self.kind = kind; self.id = id }
    public static func rig(_ id: UUID) -> DocumentOwner { DocumentOwner(kind: .rig, id: id) }
    public static func trip(_ id: UUID) -> DocumentOwner { DocumentOwner(kind: .trip, id: id) }
    public var description: String { "\(kind.rawValue):\(id.uuidString)" }
}

/// Open set of categories. Unknown values written by a newer app version are preserved.
public struct DocumentCategory: RawRepresentable, Hashable, Codable, Sendable, Identifiable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var id: String { rawValue }
    public static let manual = DocumentCategory(rawValue: "manual")
    public static let registration = DocumentCategory(rawValue: "registration")
    public static let insurance = DocumentCategory(rawValue: "insurance")
    public static let warranty = DocumentCategory(rawValue: "warranty")
    public static let maintenance = DocumentCategory(rawValue: "maintenance")
    public static let reservation = DocumentCategory(rawValue: "reservation")
    public static let other = DocumentCategory(rawValue: "other")
    public static let standard: [DocumentCategory] = [.manual, .registration, .insurance, .warranty, .maintenance, .reservation, .other]
    /// Types that usually carry identity, policy, plate, VIN, address, or payment details.
    /// Their files are always end-to-end encrypted in iCloud.
    public static let sensitive: Set<DocumentCategory> = [.registration, .insurance, .reservation]
    public var isSensitive: Bool { Self.sensitive.contains(self) }
    public var title: String {
        switch self {
        case .manual: "Manual"
        case .registration: "Registration"
        case .insurance: "Insurance"
        case .warranty: "Warranty"
        case .maintenance: "Service & maintenance"
        case .reservation: "Reservation"
        case .other: "Other"
        default: rawValue.isEmpty ? "Other" : rawValue.capitalized
        }
    }
}

/// File formats accepted for upload. The type is detected from the bytes, never trusted from
/// a filename extension.
public enum DocumentContentType: String, Codable, CaseIterable, Sendable {
    case pdf, jpeg, png, heic, heif, gif, tiff, webp
    public var uniformTypeIdentifier: String {
        switch self {
        case .pdf: "com.adobe.pdf"
        case .jpeg: "public.jpeg"
        case .png: "public.png"
        case .heic: "public.heic"
        case .heif: "public.heif"
        case .gif: "com.compuserve.gif"
        case .tiff: "public.tiff"
        case .webp: "org.webmproject.webp"
        }
    }
    public var mimeType: String {
        switch self {
        case .pdf: "application/pdf"
        case .jpeg: "image/jpeg"
        case .png: "image/png"
        case .heic: "image/heic"
        case .heif: "image/heif"
        case .gif: "image/gif"
        case .tiff: "image/tiff"
        case .webp: "image/webp"
        }
    }
    public var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .tiff: "tiff"
        default: rawValue
        }
    }
    public var isImage: Bool { self != .pdf }

    /// Recognize the format from its leading signature bytes.
    public static func detect(_ data: Data) -> DocumentContentType? {
        let b = [UInt8](data.prefix(16))
        func starts(_ signature: [UInt8], at offset: Int = 0) -> Bool {
            b.count >= offset + signature.count && Array(b[offset..<offset + signature.count]) == signature
        }
        func ascii(_ text: String, at offset: Int = 0) -> Bool { starts(Array(text.utf8), at: offset) }
        if ascii("%PDF-") { return .pdf }
        if starts([0xFF, 0xD8, 0xFF]) { return .jpeg }
        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if ascii("GIF87a") || ascii("GIF89a") { return .gif }
        if starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) { return .tiff }
        if ascii("RIFF") && ascii("WEBP", at: 8) { return .webp }
        if ascii("ftyp", at: 4), b.count >= 12 {
            let brand = String(decoding: b[8..<12], as: UTF8.self)
            if ["heic", "heix", "heim", "heis", "hevc", "hevx"].contains(brand) { return .heic }
            if ["mif1", "msf1", "heif"].contains(brand) { return .heif }
        }
        return nil
    }
}

/// How a document's file is protected in iCloud. Document text fields are always end-to-end
/// encrypted; this controls the file bytes.
public enum DocumentProtection: String, Codable, CaseIterable, Comparable, Sendable {
    /// Encrypted at rest by Apple (end-to-end only with Advanced Data Protection).
    case standard
    /// Encrypted on this device with a per-document key that only syncs end-to-end encrypted.
    case endToEnd
    public static func < (a: Self, b: Self) -> Bool { a == .standard && b == .endToEnd }
}

public struct DocumentMetadata: Equatable, Codable, Sendable {
    public var title: String
    public var category: DocumentCategory
    public var notes: String
    /// Effective, issue, or purchase date shown with the document.
    public var issuedOn: Date?
    /// Expiration or renewal date, for example registration or insurance.
    public var expiresOn: Date?
    /// The requested protection. Sensitive categories are raised to `.endToEnd` by validation,
    /// and repositories never lower an existing document's protection.
    public var protection: DocumentProtection
    public init(title: String, category: DocumentCategory = .other, notes: String = "",
                issuedOn: Date? = nil, expiresOn: Date? = nil, protection: DocumentProtection = .standard) {
        self.title = title; self.category = category; self.notes = notes; self.protection = protection
        self.issuedOn = issuedOn; self.expiresOn = expiresOn
    }
}

/// Facts about stored original bytes. `checksum` is the SHA-256 of exactly those bytes.
public struct DocumentFile: Equatable, Codable, Sendable {
    public var filename: String
    public var contentType: DocumentContentType
    public var byteCount: Int
    public var checksum: String
    public init(filename: String, contentType: DocumentContentType, byteCount: Int, checksum: String) {
        self.filename = filename; self.contentType = contentType; self.byteCount = byteCount; self.checksum = checksum
    }
}

public enum DocumentAvailability: Equatable, Sendable {
    /// Original bytes are stored on this device and open without a connection.
    case offline
    /// Bytes exist in the library but have not been downloaded to this device yet.
    case awaitingDownload
    /// A link whose contents were never imported. Opening it needs a connection.
    case onlineOnly
}

public struct ManagedDocument: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var owner: DocumentOwner
    public var metadata: DocumentMetadata
    /// HTTPS reference. It remains online-only unless contents are explicitly imported into `file`.
    public var link: URL?
    public var file: DocumentFile?
    public var createdAt: Date
    public var updatedAt: Date
    /// Whether this device currently holds the bytes described by `file`.
    public var isContentAvailable: Bool
    public init(id: UUID, owner: DocumentOwner, metadata: DocumentMetadata, link: URL? = nil, file: DocumentFile? = nil,
                createdAt: Date, updatedAt: Date, isContentAvailable: Bool) {
        self.id = id; self.owner = owner; self.metadata = metadata; self.link = link; self.file = file
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.isContentAvailable = isContentAvailable
    }
    public var availability: DocumentAvailability {
        guard file != nil else { return .onlineOnly }
        return isContentAvailable ? .offline : .awaitingDownload
    }
}

/// Verified original bytes returned by a repository.
public struct DocumentContents: Sendable {
    public let file: DocumentFile
    public let bytes: Data
    public init(file: DocumentFile, bytes: Data) { self.file = file; self.bytes = bytes }
}

public enum DocumentSource: Sendable {
    /// Original bytes, stored exactly as provided.
    case file(Data, filename: String)
    /// Original bytes read from a local file in chunks, so large files are never fully in memory.
    /// The repository reads it during the call; the caller owns and removes the file afterwards.
    case fileAt(URL, filename: String)
    case link(URL)
}

public struct DocumentDraft: Sendable {
    public var id: UUID
    public var owner: DocumentOwner
    public var metadata: DocumentMetadata
    public var source: DocumentSource
    public var createdAt: Date
    /// Recovery can pass the archived identifier and creation date to restore a document.
    public init(id: UUID = UUID(), owner: DocumentOwner, metadata: DocumentMetadata, source: DocumentSource, createdAt: Date = Date()) {
        self.id = id; self.owner = owner; self.metadata = metadata; self.source = source; self.createdAt = createdAt
    }
}

public enum DocumentError: Error, LocalizedError, Equatable, Sendable {
    case emptyFile, fileTooLarge(limit: Int), unsupportedFileType, missingTitle, titleTooLong, notesTooLong
    case invalidDates, invalidLink, insecureLink, notALink, linkOnly
    case documentNotFound, duplicateDocument, contentNotDownloaded, contentIntegrity, protectionNeedsContent
    public var errorDescription: String? {
        switch self {
        case .emptyFile: "The file is empty."
        case .fileTooLarge(let limit): "The file is larger than \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file))."
        case .unsupportedFileType: "Only PDF and image files (JPEG, PNG, HEIC, GIF, TIFF, or WebP) can be saved."
        case .missingTitle: "Enter a title for the document."
        case .titleTooLong: "The title is too long."
        case .notesTooLong: "The notes are too long."
        case .invalidDates: "The expiration date must be on or after the issue date."
        case .invalidLink: "Enter a complete web address."
        case .insecureLink: "Only secure https:// links can be saved."
        case .notALink: "Only linked documents can import their contents."
        case .linkOnly: "This link isn’t saved for offline use. Connect to open it, or save a copy of its contents."
        case .documentNotFound: "This document is no longer available."
        case .duplicateDocument: "This document already exists."
        case .contentNotDownloaded: "This document hasn’t downloaded to this device yet. Connect to iCloud and try again."
        case .contentIntegrity: "The saved file doesn’t match its original. It was not opened."
        case .protectionNeedsContent: "Download this document to this device before changing it to a protected type, so its file can be encrypted."
        }
    }
}

/// Validation shared by every repository so all features enforce the same rules.
public enum DocumentPolicy {
    /// Conservative limit until large CloudKit transfers are validated on devices.
    /// Files are streamed, so this bounds storage and iCloud quota use rather than memory.
    /// CloudKit assets allow far larger files; raise only after device transfer testing.
    public static let maximumByteCount = 250 * 1024 * 1024
    public static let maximumTitleLength = 200
    public static let maximumNotesLength = 10_000

    public static func validated(_ metadata: DocumentMetadata) throws -> DocumentMetadata {
        var result = metadata
        result.title = metadata.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.title.isEmpty else { throw DocumentError.missingTitle }
        guard result.title.count <= maximumTitleLength else { throw DocumentError.titleTooLong }
        guard result.notes.count <= maximumNotesLength else { throw DocumentError.notesTooLong }
        for date in [result.issuedOn, result.expiresOn].compactMap({ $0 }) {
            guard date.timeIntervalSinceReferenceDate.isFinite else { throw DocumentError.invalidDates }
        }
        if let issued = result.issuedOn, let expires = result.expiresOn, expires < issued { throw DocumentError.invalidDates }
        result.protection = requiredProtection(for: result)
        return result
    }

    public static func validatedLink(_ url: URL) throws -> URL {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), let scheme = components.scheme?.lowercased() else {
            throw DocumentError.invalidLink
        }
        guard scheme == "https" else { throw scheme == "http" ? DocumentError.insecureLink : DocumentError.invalidLink }
        guard let host = components.host, !host.isEmpty, !host.contains(" ") else { throw DocumentError.invalidLink }
        // Embedded credentials would sync in plain metadata.
        guard components.user == nil, components.password == nil else { throw DocumentError.invalidLink }
        return url
    }

    /// Parse typed or pasted text. A bare host gets https://; http:// is rejected, not upgraded.
    public static func link(from text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DocumentError.invalidLink }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: candidate) else { throw DocumentError.invalidLink }
        return try validatedLink(url)
    }

    /// The protection a document must have: sensitive types are always end-to-end encrypted.
    public static func requiredProtection(for metadata: DocumentMetadata) -> DocumentProtection {
        metadata.category.isSensitive ? .endToEnd : metadata.protection
    }

    /// Describe original bytes without changing them.
    public static func inspect(_ bytes: Data, filename: String) throws -> DocumentFile {
        try inspect(.data(bytes), filename: filename)
    }

    /// Describe original bytes, reading a file in chunks. The type comes from the leading bytes.
    public static func inspect(_ source: DocumentByteSource, filename: String) throws -> DocumentFile {
        let count = try source.byteCount()
        guard count > 0 else { throw DocumentError.emptyFile }
        guard count <= maximumByteCount else { throw DocumentError.fileTooLarge(limit: maximumByteCount) }
        var hasher = DocumentHasher(), type: DocumentContentType?, seen = 0
        try source.forEachChunk { chunk in
            if type == nil {
                guard let detected = DocumentContentType.detect(chunk) else { throw DocumentError.unsupportedFileType }
                type = detected
            }
            hasher.update(chunk); seen += chunk.count
        }
        // A file that changed while being read is not the file the user picked.
        guard seen == count, let type else { throw DocumentError.unsupportedFileType }
        return DocumentFile(filename: sanitizedFilename(filename, for: type), contentType: type, byteCount: count, checksum: hasher.finalize())
    }

    /// A display and export name only. Never used as a path without a containing directory.
    public static func sanitizedFilename(_ name: String, for type: DocumentContentType) -> String {
        let last = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let cleaned = String(last.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != ":" })
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        var stem = cleaned
        if let dot = cleaned.lastIndex(of: "."), dot != cleaned.startIndex { stem = String(cleaned[..<dot]) }
        stem = String(stem.prefix(120)).trimmingCharacters(in: .whitespacesAndNewlines)
        return (stem.isEmpty ? "Document" : stem) + "." + type.fileExtension
    }

    /// A reasonable default title for an imported file or link.
    public static func suggestedTitle(filename: String) -> String {
        let last = filename.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? filename
        let stem = last.lastIndex(of: ".").map { String(last[..<$0]) } ?? last
        let title = stem.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return String((title.isEmpty ? "Document" : title).prefix(maximumTitleLength))
    }
}

/// Original bytes in memory or in a local file, read in fixed-size chunks.
public enum DocumentByteSource: Sendable {
    case data(Data)
    case file(URL)
    /// 1 MiB keeps memory flat while staying fast for hashing and encryption.
    public static let chunkSize = 1 << 20

    public func byteCount() throws -> Int {
        switch self {
        case .data(let data): return data.count
        case .file(let url):
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes[.size] as? NSNumber)?.intValue ?? 0
        }
    }

    /// Calls `body` with consecutive chunks. The first chunk is at least 16 bytes when the
    /// source is, so callers can identify the format from it.
    public func forEachChunk(size: Int = chunkSize, _ body: (Data) throws -> Void) throws {
        switch self {
        case .data(let data):
            var offset = data.startIndex
            while offset < data.endIndex {
                let end = data.index(offset, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
                try body(data[offset..<end]); offset = end
            }
        case .file(let url):
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: size), !chunk.isEmpty { try body(chunk) }
        }
    }
}

/// Writes a streamed download to disk while enforcing the document rules as bytes arrive, so an
/// oversized file or a non-document (for example an HTML page) is abandoned early and memory
/// stays flat regardless of file size.
public final class BoundedDocumentWriter {
    public let destination: URL
    public let limit: Int
    public private(set) var byteCount = 0
    private var handle: FileHandle?
    private var head = Data()
    private var checkedSignature = false
    /// Enough leading bytes to identify every supported signature.
    static let signatureLength = 16

    public init(destination: URL, limit: Int = DocumentPolicy.maximumByteCount, expectedLength: Int64 = -1) throws {
        guard expectedLength <= Int64(limit) else { throw DocumentError.fileTooLarge(limit: limit) }
        self.destination = destination; self.limit = limit
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        handle = try FileHandle(forWritingTo: destination)
    }

    public func append(_ chunk: Data) throws {
        guard let handle else { throw CocoaError(.fileWriteUnknown) }
        guard byteCount + chunk.count <= limit else { throw DocumentError.fileTooLarge(limit: limit) }
        if !checkedSignature {
            head.append(chunk.prefix(Self.signatureLength - head.count))
            if head.count >= Self.signatureLength {
                guard DocumentContentType.detect(head) != nil else { throw DocumentError.unsupportedFileType }
                checkedSignature = true
            }
        }
        try handle.write(contentsOf: chunk)
        byteCount += chunk.count
    }

    /// Closes the file and returns it once it is a complete, supported document.
    public func finish() throws -> URL {
        try close()
        guard byteCount > 0 else { throw DocumentError.emptyFile }
        guard DocumentContentType.detect(head) != nil else { throw DocumentError.unsupportedFileType }
        return destination
    }

    /// Stops writing and removes the partial file.
    public func discard() {
        try? close()
        try? FileManager.default.removeItem(at: destination)
    }

    private func close() throws {
        try handle?.close(); handle = nil
    }
}
