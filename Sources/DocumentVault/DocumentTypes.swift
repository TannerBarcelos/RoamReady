import Foundation

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
    /// and the store never lowers an existing document's protection.
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

public enum DocumentError: Error, LocalizedError, Equatable, Sendable {
    case emptyFile, fileTooLarge(limit: Int), unsupportedFileType, missingTitle, titleTooLong, notesTooLong
    case invalidDates, invalidLink, insecureLink, linkOnly
    case contentNotDownloaded, contentIntegrity, protectionNeedsContent
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
        case .linkOnly: "This link isn’t saved for offline use. Connect to open it, or save a copy of its contents."
        case .contentNotDownloaded: "This document hasn’t downloaded to this device yet. Connect to iCloud and try again."
        case .contentIntegrity: "The saved file doesn’t match its original. It was not opened."
        case .protectionNeedsContent: "Download this document to this device before changing it to a protected type, so its file can be encrypted."
        }
    }
}
