import XCTest

@MainActor
final class WeatherPermissionsUITests: XCTestCase {
    private func launch(access: String, locale: String = "en_US") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-navigation-ui-test", "-permissions-ui-test", access,
                               "-weather-ui-test", "-AppleLocale", locale]
        app.launch()
        XCTAssertTrue(app.navigationTab("Home").waitForExistence(timeout: 10))
        return app
    }

    func testTemperatureIsReadOnlyAndIncludesFahrenheit() {
        let app = launch(access: "allowed")
        let temperature = app.staticTexts["currentTemperature"]
        XCTAssertTrue(temperature.waitForExistence(timeout: 5))
        XCTAssertTrue(temperature.label.contains("72°F"))
        XCTAssertFalse(app.buttons["currentTemperature"].exists)
        XCTAssertFalse(app.buttons["weatherPermissionRequired"].exists)
    }

    func testTemperatureIncludesCelsiusForMetricLocale() {
        let app = launch(access: "allowed", locale: "en_GB")
        let temperature = app.staticTexts["currentTemperature"]
        XCTAssertTrue(temperature.waitForExistence(timeout: 5))
        XCTAssertTrue(temperature.label.contains("22°C"))
    }

    func testDeniedLocationHidesCachedTemperatureAndOffersSettings() {
        let app = launch(access: "denied")
        let unavailable = app.buttons["weatherPermissionRequired"]
        XCTAssertTrue(unavailable.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["currentTemperature"].exists)
        unavailable.tap()
        let alert = app.alerts["Location access is off"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.buttons["Open Settings"].exists)
        alert.buttons["Cancel"].tap()
        app.navigationTab("Camp Finder").tap()
        let nearMe = app.buttons["Near me"]
        XCTAssertTrue(nearMe.waitForExistence(timeout: 5))
        XCTAssertFalse(nearMe.isEnabled)
        XCTAssertTrue(app.searchFields.firstMatch.isEnabled)
        XCTAssertTrue(app.buttons["Open Settings"].exists)
    }

    func testNativeLocationDenialStillReachesOnboarding() {
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .location)
        app.resetAuthorizationStatus(for: .camera)
        app.launchArguments = ["-workflow-ui-test", UUID().uuidString, "-permissions-system-ui-test"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let denyLabel = NSPredicate(format: "label == %@ OR label == %@", "Don’t Allow", "Don't Allow")
        let denyLocation = springboard.alerts.buttons.matching(denyLabel).firstMatch
        XCTAssertTrue(denyLocation.waitForExistence(timeout: 10))
        XCTAssertFalse(app.navigationBars["RoamReady"].exists, "Permissions must precede onboarding")
        denyLocation.tap()
        // Devices with a camera receive the second optional permission prompt.
        let onboarding = app.navigationBars["RoamReady"]
        if !onboarding.waitForExistence(timeout: 3) {
            let denyCamera = springboard.alerts.buttons.matching(denyLabel).firstMatch
            XCTAssertTrue(denyCamera.waitForExistence(timeout: 5))
            denyCamera.tap()
        }
        XCTAssertTrue(onboarding.waitForExistence(timeout: 10))
        app.terminate()
        app.launch()
        XCTAssertTrue(onboarding.waitForExistence(timeout: 10), "Answered permissions must not block a relaunch")
    }
}
