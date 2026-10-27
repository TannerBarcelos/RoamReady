import XCTest

/// Exercises production onboarding and SwiftData through the UI with a separate on-disk library.
@MainActor
final class LibraryWorkflowUITests: XCTestCase {
    func testOnboardingTripAndCustomStepSurviveRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-workflow-ui-test", UUID().uuidString]
        app.launch()
        let tent = app.buttons["Tent"]
        XCTAssertTrue(app.navigationBars["RoamReady"].waitForExistence(timeout: 15))
        for _ in 0..<8 {
            if tent.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(tent.isHittable)
        tent.tap()
        app.buttons["Set up my tent"].tap()
        app.buttons["Looks like home"].tap()
        app.buttons["Let’s go camping"].tap()

        let tripAction = app.navigationTab("Trip")
        XCTAssertTrue(tripAction.waitForExistence(timeout: 10))
        tripAction.tap()
        let campground = app.textFields["tripCampgroundName"]
        XCTAssertTrue(campground.waitForExistence(timeout: 5))
        campground.tap()
        campground.typeText("Workflow Pines")
        app.buttons["Save"].tap()
        app.navigationTab("Plan").tap()
        let booking = app.descendants(matching: .any)["tripRow-Workflow Pines"].firstMatch
        XCTAssertTrue(booking.waitForExistence(timeout: 5))
        booking.tap()
        app.descendants(matching: .any)["tripChecklist-setup"].firstMatch.tap()
        // The add action is below the generated checklist on smaller devices.
        let addStep = app.buttons["Add a step"]
        for _ in 0..<12 {
            if addStep.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(addStep.isHittable)
        addStep.tap()
        let title = app.descendants(matching: .any)["checklistStepTitle"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("Pack the blue kettle")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["checklistStep-Pack the blue kettle"].firstMatch.waitForExistence(timeout: 5))

        app.terminate()
        app.launch()
        XCTAssertTrue(app.navigationTab("Plan").waitForExistence(timeout: 15), "Onboarding must not return")
        app.navigationTab("Plan").tap()
        XCTAssertTrue(booking.waitForExistence(timeout: 5), "Booking survives reopening the disk store")
        booking.tap()
        app.descendants(matching: .any)["tripChecklist-setup"].firstMatch.tap()
        let savedStep = app.descendants(matching: .any)["checklistStep-Pack the blue kettle"].firstMatch
        for _ in 0..<12 {
            if savedStep.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(savedStep.exists, "Custom checklist content survives app termination")

        // Verify the real preference, then relaunch at the largest accessibility text size.
        app.navigationTab("Profile").tap()
        let darkOption = app.buttons["appearanceOption-dark"]
        scrollTo(darkOption, in: app)
        darkOption.tap()
        XCTAssertTrue(darkOption.isSelected)
        app.terminate()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.navigationTab("Profile").waitForExistence(timeout: 15))
        app.navigationTab("Profile").tap()
        let accessibleDark = app.buttons["appearanceOption-dark"]
        scrollTo(accessibleDark, in: app)
        XCTAssertTrue(accessibleDark.isSelected, "Appearance survives app termination")
        try app.performAccessibilityAudit(for: [.dynamicType, .textClipped]) { issue in
            print("Accessibility audit: \(issue.compactDescription)\n\(issue.detailedDescription)")
            return false // Report every finding; never waive an issue to make CI pass.
        }
    }

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 {
            if element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }
}
