import XCTest
@testable import DocumentVault

final class DocumentPolicyTests: XCTestCase {
    static let pdf = Data("%PDF-1.7\n1 0 obj\n<<>>\nendobj\ntrailer\n<<>>\n%%EOF\n".utf8) + Data([0x00, 0xFF, 0x0D, 0x0A])
    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D])

    func testDigestMatchesKnownVectors() {
        XCTAssertEqual(DocumentDigest.sha256(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(DocumentDigest.sha256(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(DocumentDigest.sha256(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        let million = Data(repeating: UInt8(ascii: "a"), count: 1_000_000)
        XCTAssertEqual(DocumentDigest.sha256(million), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    func testContentTypeIsDetectedFromBytesNotExtension() {
        XCTAssertEqual(DocumentContentType.detect(Self.pdf), .pdf)
        XCTAssertEqual(DocumentContentType.detect(Self.png), .png)
        XCTAssertEqual(DocumentContentType.detect(Data([0xFF, 0xD8, 0xFF, 0xE0])), .jpeg)
        XCTAssertEqual(DocumentContentType.detect(Data("GIF89a".utf8)), .gif)
        XCTAssertEqual(DocumentContentType.detect(Data([0x49, 0x49, 0x2A, 0x00])), .tiff)
        XCTAssertEqual(DocumentContentType.detect(Data("RIFF\0\0\0\0WEBPVP8 ".utf8)), .webp)
        XCTAssertEqual(DocumentContentType.detect(Data([0, 0, 0, 0x18]) + Data("ftypheic".utf8)), .heic)
        XCTAssertEqual(DocumentContentType.detect(Data([0, 0, 0, 0x18]) + Data("ftypmif1".utf8)), .heif)
        XCTAssertNil(DocumentContentType.detect(Data("PK\u{3}\u{4}zip".utf8)))
        XCTAssertNil(DocumentContentType.detect(Data("<html>".utf8)))
        XCTAssertNil(DocumentContentType.detect(Data([0, 0, 0, 0x18]) + Data("ftypavif".utf8)))
        XCTAssertNil(DocumentContentType.detect(Data()))
    }

    func testInvalidImportsAreRejected() {
        XCTAssertThrowsError(try DocumentPolicy.inspect(Data(), filename: "a.pdf")) { XCTAssertEqual($0 as? DocumentError, .emptyFile) }
        XCTAssertThrowsError(try DocumentPolicy.inspect(Data("not a pdf".utf8), filename: "manual.pdf")) { XCTAssertEqual($0 as? DocumentError, .unsupportedFileType) }
        let huge = Data("%PDF-".utf8) + Data(count: DocumentPolicy.maximumByteCount)
        XCTAssertThrowsError(try DocumentPolicy.inspect(huge, filename: "big.pdf")) {
            XCTAssertEqual($0 as? DocumentError, .fileTooLarge(limit: DocumentPolicy.maximumByteCount))
        }
    }

    func testInspectionDescribesOriginalBytesAndSanitizesNames() throws {
        let file = try DocumentPolicy.inspect(Self.pdf, filename: "../../Owner's Manual.PDF")
        XCTAssertEqual(file.contentType, .pdf)
        XCTAssertEqual(file.byteCount, Self.pdf.count)
        XCTAssertEqual(file.checksum, DocumentDigest.sha256(Self.pdf))
        XCTAssertEqual(file.filename, "Owner's Manual.pdf")
        XCTAssertEqual(DocumentPolicy.sanitizedFilename("photo.pdf", for: .png), "photo.png")
        XCTAssertEqual(DocumentPolicy.sanitizedFilename("..", for: .pdf), "Document.pdf")
        XCTAssertEqual(DocumentPolicy.sanitizedFilename("a\\b\u{0}c:d", for: .jpeg), "bcd.jpg")
        XCTAssertEqual(DocumentPolicy.suggestedTitle(filename: "2026_Registration.pdf"), "2026 Registration")
    }

    func testLinksMustBeSecureAndComplete() throws {
        XCTAssertEqual(try DocumentPolicy.link(from: " example.com/manual.pdf ").absoluteString, "https://example.com/manual.pdf")
        XCTAssertEqual(try DocumentPolicy.link(from: "HTTPS://Example.com/a").host, "Example.com")
        XCTAssertThrowsError(try DocumentPolicy.link(from: "http://example.com")) { XCTAssertEqual($0 as? DocumentError, .insecureLink) }
        for bad in ["", "ftp://example.com/file", "https://", "https://user:secret@example.com/x", "javascript:alert(1)", "file:///etc/passwd"] {
            XCTAssertThrowsError(try DocumentPolicy.link(from: bad), bad)
        }
    }

    func testMetadataValidation() throws {
        let trimmed = try DocumentPolicy.validated(DocumentMetadata(title: "  Insurance card \n", category: .insurance))
        XCTAssertEqual(trimmed.title, "Insurance card")
        XCTAssertThrowsError(try DocumentPolicy.validated(DocumentMetadata(title: "  "))) { XCTAssertEqual($0 as? DocumentError, .missingTitle) }
        XCTAssertThrowsError(try DocumentPolicy.validated(DocumentMetadata(title: String(repeating: "a", count: 201))))
        let issued = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertThrowsError(try DocumentPolicy.validated(DocumentMetadata(title: "Policy", issuedOn: issued, expiresOn: issued.addingTimeInterval(-1)))) {
            XCTAssertEqual($0 as? DocumentError, .invalidDates)
        }
        XCTAssertNoThrow(try DocumentPolicy.validated(DocumentMetadata(title: "Policy", issuedOn: issued, expiresOn: issued)))
    }

    func testUnknownCategoryRoundTrips() throws {
        let future = DocumentCategory(rawValue: "towingPermit")
        let decoded = try JSONDecoder().decode(DocumentCategory.self, from: JSONEncoder().encode(future))
        XCTAssertEqual(decoded, future)
        XCTAssertEqual(DocumentCategory.insurance.title, "Insurance")
    }

    func testAllNewContentUsesAppleManagedEncryption() throws {
        for category in DocumentCategory.standard {
            let validated = try DocumentPolicy.validated(DocumentMetadata(title: "Doc", category: category))
            XCTAssertEqual(validated.protection, .endToEnd, category.rawValue)
        }
        XCTAssertEqual(DocumentCategory.sensitive, [.registration, .insurance, .reservation])
        let optIn = try DocumentPolicy.validated(DocumentMetadata(title: "Title deed", category: .other, protection: .endToEnd))
        XCTAssertEqual(optIn.protection, .endToEnd)
        XCTAssertLessThan(DocumentProtection.standard, .endToEnd)
    }
}
