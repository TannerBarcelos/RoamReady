import XCTest

/// Exercises production onboarding and SwiftData through the UI with a separate on-disk library.
@MainActor
final class LibraryWorkflowUITests: XCTestCase {
    func testOnboardingTripAndCustomStepSurviveRelaunch() {
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

        let tripAction = app.tabBars.buttons["Trip"]
        XCTAssertTrue(tripAction.waitForExistence(timeout: 10))
        tripAction.tap()
        let campground = app.textFields["tripCampgroundName"]
        XCTAssertTrue(campground.waitForExistence(timeout: 5))
        campground.tap()
        campground.typeText("Workflow Pines")
        app.buttons["Save"].tap()
        app.tabBars.buttons["Plan"].tap()
        let booking = app.staticTexts["Workflow Pines"].firstMatch
        XCTAssertTrue(booking.waitForExistence(timeout: 5))
        booking.tap()
        app.staticTexts["Setup"].firstMatch.tap()
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
        XCTAssertTrue(app.tabBars.buttons["Plan"].waitForExistence(timeout: 15), "Onboarding must not return")
        app.tabBars.buttons["Plan"].tap()
        XCTAssertTrue(booking.waitForExistence(timeout: 5), "Booking survives reopening the disk store")
        booking.tap()
        app.staticTexts["Setup"].firstMatch.tap()
        let savedStep = app.descendants(matching: .any)["checklistStep-Pack the blue kettle"].firstMatch
        for _ in 0..<12 {
            if savedStep.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(savedStep.exists, "Custom checklist content survives app termination")
    }
}
