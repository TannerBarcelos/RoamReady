import XCTest

/// Captures layout baselines for docs/validation/duo-baselines. It runs only when the
/// ROAMREADY_BASELINE_DIR environment variable is set (pass TEST_RUNNER_ROAMREADY_BASELINE_DIR
/// to xcodebuild), so the regular UI test run skips it. See docs/validation.md.
@MainActor
final class LayoutBaselineUITests: XCTestCase {
    private var directory: URL!
    private var prefix = "baseline"

    override func setUp() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["ROAMREADY_BASELINE_DIR"], !path.isEmpty else {
            throw XCTSkip("Set ROAMREADY_BASELINE_DIR to capture layout baselines")
        }
        directory = URL(filePath: path, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        prefix = environment["ROAMREADY_BASELINE_PREFIX"] ?? prefix
        continueAfterFailure = true
    }

    override func tearDown() async throws {
        XCUIDevice.shared.orientation = .portrait
    }

    func testCapturePortrait() throws { try captureAll(.portrait, name: "portrait") }

    func testCaptureLandscape() throws { try captureAll(.landscapeLeft, name: "landscape") }

    private func captureAll(_ orientation: UIDeviceOrientation, name: String) throws {
        // A fresh install with no launch flags opens the real (empty) library, so onboarding shows.
        var app = launch(orientation, arguments: [])
        _ = app.wait(for: .runningForeground, timeout: 10)
        save("onboarding", name)

        app = launch(orientation)
        save("home", name)

        app = launch(orientation)
        _ = tapWhenHittable("tripRow-Current Pines", in: app)
        XCTAssertTrue(app.navigationBars["Current Pines"].waitForExistence(timeout: 5))
        save("trip-detail", name)
        if tapWhenHittable("tripChecklist-setup", in: app) {
            XCTAssertTrue(app.navigationBars["Setup"].waitForExistence(timeout: 5))
            save("checklist", name)
        }

        app = launch(orientation)
        app.navigationTab("Camp Finder").tap()
        sleep(4) // Let map tiles load.
        save("camp-finder", name)

        app = launch(orientation)
        app.navigationTab("Profile").tap()
        XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: 5))
        save("profile", name)

        app = launch(orientation)
        let assistant = app.buttons["openAssistant"].firstMatch
        XCTAssertTrue(assistant.waitForExistence(timeout: 5))
        save("assistant-entry", name)
        assistant.tap()
        XCTAssertTrue(app.buttons["closeAssistant"].waitForExistence(timeout: 5))
        save("assistant-sheet", name)
        app.terminate()
    }

    private func launch(_ orientation: UIDeviceOrientation,
                        arguments: [String] = ["-assistant-ui-test", "ready", "-navigation-ui-test"]) -> XCUIApplication {
        let app = XCUIApplication()
        app.terminate()
        XCUIDevice.shared.orientation = orientation
        app.launchArguments = arguments
        app.launch()
        XCUIDevice.shared.orientation = orientation
        if !arguments.isEmpty { XCTAssertTrue(app.navigationTab("Home").waitForExistence(timeout: 10)) }
        return app
    }

    /// Lists load rows lazily, so scroll until the row exists and clears the tab bar.
    @discardableResult
    private func tapWhenHittable(_ identifier: String, in app: XCUIApplication) -> Bool {
        let element = app.descendants(matching: .any)[identifier].firstMatch
        for _ in 0..<10 where !(element.exists && element.isHittable) {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
        }
        guard element.exists && element.isHittable else {
            XCTFail("\(identifier) isn’t reachable")
            return false
        }
        element.tap()
        return true
    }

    private func save(_ screen: String, _ orientation: String) {
        sleep(2) // Let navigation and sheet animations settle.
        let data = XCUIScreen.main.screenshot().pngRepresentation
        let url = directory.appending(path: "\(prefix)-\(orientation)-\(screen).png")
        do { try data.write(to: url) } catch { XCTFail("Couldn’t write \(url.path): \(error)") }
    }
}
