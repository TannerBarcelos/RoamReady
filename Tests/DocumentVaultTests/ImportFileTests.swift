import XCTest
@testable import DocumentVault

final class ImportFileTests: XCTestCase {
    func testStagingOutlivesProviderURLAndCleansUpAfterItsLastOwner() throws {
        let source = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: source) }
        let original = Data("%PDF-1.7\n".utf8) + Data(repeating: 42, count: 2 * 1024 * 1024)
        try original.write(to: source)
        var staged: ImportFile? = try ImportFile(copying: source, maximumByteCount: DocumentPolicy.maximumByteCount, filename: "Manual.pdf")
        let url = try XCTUnwrap(staged?.url)
        try FileManager.default.removeItem(at: source)
        let inspected = try XCTUnwrap(staged).inspectDocument()
        XCTAssertEqual(inspected, try DocumentPolicy.inspect(original, filename: "Manual.pdf"))
        let payload = try XCTUnwrap(staged).documentPayload()
        XCTAssertEqual(payload.bytes, original)
        XCTAssertEqual(payload.file, inspected)
        staged = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testStagingRejectsOversizedAndNonFileInputs() throws {
        let source = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: source) }
        try Data(repeating: 0, count: 100).write(to: source)
        XCTAssertThrowsError(try ImportFile(copying: source, maximumByteCount: 99)) {
            XCTAssertEqual($0 as? DocumentError, .fileTooLarge(limit: 99))
        }
        XCTAssertThrowsError(try ImportFile(copying: source.deletingLastPathComponent(), maximumByteCount: 100))
    }

    func testStreamingInspectionRejectsEmptyAndDisguisedDocuments() throws {
        let source = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: source) }
        try Data().write(to: source)
        XCTAssertThrowsError(try DocumentPolicy.inspect(fileAt: source, filename: "x.pdf")) {
            XCTAssertEqual($0 as? DocumentError, .emptyFile)
        }
        try Data("<html>not a PDF</html>".utf8).write(to: source)
        XCTAssertThrowsError(try DocumentPolicy.inspect(fileAt: source, filename: "x.pdf")) {
            XCTAssertEqual($0 as? DocumentError, .unsupportedFileType)
        }
    }
}
