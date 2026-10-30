import XCTest

@MainActor
final class NavigationUITests: XCTestCase {
    private func launch(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-assistant-ui-test", "ready", "-navigation-ui-test"] + extraArguments
        app.launch()
        XCTAssertTrue(app.navigationTab("Home").waitForExistence(timeout: 10))
        return app
    }

    func testHomeKeepsOverlappingAndUpcomingTripsWithoutPlanTab() {
        let app = launch()
        if app.tabBars.firstMatch.exists { XCTAssertEqual(app.tabBars.buttons.count, 4) }
        XCTAssertFalse(app.navigationTab("Plan").exists)
        XCTAssertTrue(app.staticTexts["Current Pines"].exists)
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Overlapping Creek"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Upcoming Lake"].exists)
        XCTAssertFalse(app.staticTexts["Past Meadows"].exists)
        app.staticTexts["Upcoming Lake"].tap()
        XCTAssertTrue(app.navigationBars["Upcoming Lake"].waitForExistence(timeout: 5))
    }

    func testProfileOwnsTripHistoryAndCampgrounds() {
        let app = launch()
        app.navigationTab("Profile").tap()
        XCTAssertTrue(app.buttons["tripHistoryLink"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["savedCampgroundsLink"].exists)
        XCTAssertFalse(app.buttons["appearanceOption-system"].exists)
        XCTAssertFalse(app.buttons["prepareLibraryExport"].exists)
        app.buttons["tripHistoryLink"].tap()
        XCTAssertTrue(app.navigationBars["Trip history"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Past Meadows"].exists)
        XCTAssertFalse(app.staticTexts["Upcoming Lake"].exists)
        app.staticTexts["Past Meadows"].tap()
        XCTAssertTrue(app.navigationBars["Past Meadows"].waitForExistence(timeout: 5))
        // The Duo cover display moves bar buttons into a side rail, outside the navigation bar.
        app.buttons["BackButton"].firstMatch.tap()
        app.buttons["BackButton"].firstMatch.tap()
        app.buttons["savedCampgroundsLink"].tap()
        XCTAssertTrue(app.navigationBars["Your campgrounds"].waitForExistence(timeout: 5))
    }

    func testSettingsContainsAppearanceAndLibraryTools() {
        let app = launch()
        app.navigationTab("Profile").tap()
        app.buttons["openAppSettings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["appearanceOption-system"].exists)
        let export = app.buttons["prepareLibraryExport"]
        for _ in 0..<5 {
            if export.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(export.isHittable)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: 5))
    }

    func testRigThumbnailIsAnAccessibleImage() {
        let app = launch()
        app.navigationTab("Profile").tap()
        let thumbnail = app.images["Your travel trailer"]
        for _ in 0..<5 {
            if thumbnail.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(thumbnail.isHittable, "The rig thumbnail needs a labeled image role for VoiceOver")
        XCTAssertEqual(thumbnail.staticTexts.count, 0, "Decorative emoji must not be exposed as a second text element")
    }

    func testAddTripStillPresentsFromProfileAndReturnsToIt() {
        let app = launch()
        app.navigationTab("Profile").tap()
        app.navigationTab("Trip").tap()
        XCTAssertTrue(app.navigationBars["Add trip"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationTab("Profile").isSelected)
    }

    /// Fast, deterministic version of the Profile audit in the disk workflow test: the fixture library
    /// has a rig, so the scrolled rig section is reachable without onboarding.
    func testProfileRigSectionPassesDynamicTypeAuditAtLargestSize() throws {
        let app = launch(extraArguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        app.navigationTab("Profile").tap()
        try audit(app)
        scrollToRigControls(in: app)
        // #93: scrolled to the rig section, the audit reports SwiftUI nodes as "partially unsupported"
        // even though the same rows pass unscrolled and their text grows (see the test below).
        try audit(app, waivingDynamicType: true)
    }

    /// Backs the #93 waiver: the rig section's text really scales between the default and largest sizes.
    func testProfileRigSectionTextGrowsAtLargestSize() {
        let texts = ["Forest River No Boundaries", "Used by 4 trips", "Reset default checklists", "Replace rig"]
        let regular = rigTextHeights(texts, extraArguments: [])
        let largest = rigTextHeights(texts, extraArguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        for text in texts {
            guard let small = regular[text], let large = largest[text] else { return XCTFail("\(text) not found") }
            XCTAssertGreaterThan(large, small * 1.5, "\(text) should grow with Dynamic Type")
        }
    }

    private func rigTextHeights(_ texts: [String], extraArguments: [String]) -> [String: CGFloat] {
        let app = launch(extraArguments: extraArguments)
        app.navigationTab("Profile").tap()
        var heights: [String: CGFloat] = [:]
        // Texts are listed top to bottom, so scrolling down reaches each one in turn.
        for text in texts {
            let element = app.staticTexts[text].firstMatch
            for _ in 0..<12 {
                if element.exists && element.isHittable { break }
                app.swipeUp()
            }
            if element.exists { heights[text] = element.frame.height }
        }
        app.terminate()
        return heights
    }

    private func scrollToRigControls(in app: XCUIApplication) {
        let replace = app.buttons["replaceRig"]
        for _ in 0..<12 {
            if replace.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(replace.isHittable)
    }

    private func audit(_ app: XCUIApplication, waivingDynamicType: Bool = false) throws {
        try app.performAccessibilityAudit(for: [.dynamicType, .textClipped]) { issue in
            print("Accessibility audit: \(issue.auditType.rawValue) \(issue.compactDescription)\n\(issue.detailedDescription)")
            if let element = issue.element { print("Audit element: \(element.debugDescription)") }
            // Only the scrolled Dynamic Type false positive from #93 is waived; clipping always fails.
            return waivingDynamicType && issue.auditType == .dynamicType
        }
    }
}
