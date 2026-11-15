import XCTest

/// Read-only access after a subscription lapses: everything stays readable, and edits open the plans.
@MainActor
final class StoreAccessUITests: XCTestCase {
    private func launch(_ access: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-assistant-ui-test", "unsupported", "-navigation-ui-test", "-store-ui-test", access]
        app.launch()
        XCTAssertTrue(app.navigationTab("Home").waitForExistence(timeout: 10))
        return app
    }

    private func paywall(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'paywall' OR label == 'RoamReady Pro'")).firstMatch
    }

    func testReadOnlyKeepsTripsReadableAndAddingATripOpensThePlans() {
        let app = launch("read-only")
        XCTAssertTrue(app.buttons["readOnlyNotice"].waitForExistence(timeout: 5))
        let trip = app.buttons["tripRow-Current Pines"]
        XCTAssertTrue(trip.waitForExistence(timeout: 5), "Saved trips stay visible without a purchase")
        app.navigationTab("Trip").tap()
        XCTAssertTrue(paywall(app).waitForExistence(timeout: 10))
        XCTAssertFalse(app.navigationBars["Add trip"].exists, "The new-trip form must not open while read-only")
    }

    func testReadOnlyChecklistTapOpensThePlansWithoutChangingTheStep() {
        let app = launch("read-only")
        app.buttons["tripRow-Current Pines"].tap()
        let checklist = app.descendants(matching: .any)["tripChecklist-setup"].firstMatch
        for _ in 0..<8 where !checklist.isHittable { app.swipeUp() }
        checklist.tap()
        let circle = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Mark complete'")).firstMatch
        XCTAssertTrue(circle.waitForExistence(timeout: 5))
        let label = circle.label
        circle.tap()
        XCTAssertTrue(paywall(app).waitForExistence(timeout: 10))
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(app.buttons[label].waitForExistence(timeout: 5), "The step stays unchanged")
    }

    func testFullAccessHasNoNoticeAndOpensTheForm() {
        let app = launch("full")
        XCTAssertTrue(app.buttons["tripRow-Current Pines"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["readOnlyNotice"].exists)
        app.navigationTab("Trip").tap()
        XCTAssertFalse(paywall(app).waitForExistence(timeout: 3))
    }
}
