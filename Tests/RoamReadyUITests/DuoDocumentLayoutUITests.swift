import XCTest

@MainActor
final class DuoDocumentLayoutUITests: XCTestCase {
    func testDocumentMetadataRemainsReadableAtLargestTextSize() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-assistant-ui-test", "ready", "-navigation-ui-test", "-layout-ui-test",
                               "-document-layout-fixture", "-UIPreferredContentSizeCategoryName",
                               "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let trip = app.buttons["tripRow-Current Pines"]
        XCTAssertTrue(trip.waitForExistence(timeout: 10))
        for _ in 0..<8 where !trip.isHittable { app.swipeUp() }
        XCTAssertTrue(trip.isHittable)
        trip.tap()

        let documents = app.buttons.matching(NSPredicate(format: "label CONTAINS 'View confirmation & documents'")).firstMatch
        for _ in 0..<15 where !documents.isHittable { app.swipeUp() }
        XCTAssertTrue(documents.isHittable)
        documents.tap()

        let record = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Annual water heater inspection and service record'")).firstMatch
        for _ in 0..<10 where !record.isHittable { app.swipeUp() }
        XCTAssertTrue(record.isHittable)
        XCTAssertTrue(record.label.contains("Service & maintenance"))
        XCTAssertTrue(record.label.contains("Expires"))
        // No Dynamic Type waiver: this new row must fit its full title, category, and expiry.
        try app.performAccessibilityAudit(for: [.dynamicType, .textClipped])
    }
}
