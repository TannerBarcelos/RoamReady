import Foundation

/// The rules every document follows, whichever screen adds or edits it.
public enum DocumentPolicy {
    /// An app limit bounding the Data SwiftData accepts, not a claimed native CloudKit limit.
    public static let maximumByteCount = 50 * 1024 * 1024
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
        result.protection = .endToEnd
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

    /// Describe original bytes without changing them. The type comes from the leading bytes,
    /// never from the filename.
    public static func inspect(_ bytes: Data, filename: String) throws -> DocumentFile {
        guard !bytes.isEmpty else { throw DocumentError.emptyFile }
        guard bytes.count <= maximumByteCount else { throw DocumentError.fileTooLarge(limit: maximumByteCount) }
        guard let type = DocumentContentType.detect(bytes) else { throw DocumentError.unsupportedFileType }
        return DocumentFile(filename: sanitizedFilename(filename, for: type), contentType: type,
                            byteCount: bytes.count, checksum: DocumentDigest.sha256(bytes))
    }

    /// Hash and detect the format in bounded chunks without materializing an entire import.
    public static func inspect(fileAt url: URL, filename: String) throws -> DocumentFile {
        let result = try DocumentDigest.inspectFile(at: url, maximumByteCount: maximumByteCount)
        guard result.byteCount > 0 else { throw DocumentError.emptyFile }
        guard let type = DocumentContentType.detect(result.signature) else { throw DocumentError.unsupportedFileType }
        return DocumentFile(filename: sanitizedFilename(filename, for: type), contentType: type,
                            byteCount: result.byteCount, checksum: result.checksum)
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
