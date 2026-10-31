import XCTest

@MainActor
final class TripPhotoUITests: XCTestCase {
    override func tearDown() async throws {
        XCUIDevice.shared.orientation = .portrait
    }

    func testPhotoGridShowsOnlyUniformTappableImages() {
        let app = openTripPhotos(extraArguments: ["-photo-grid-fixture"])
        let lastPhoto = app.buttons.matching(identifier: "tripPhotoThumbnail")
            .matching(NSPredicate(format: "label == 'Trip photo'")).firstMatch
        for _ in 0..<8 where !lastPhoto.isHittable { app.swipeUp() }
        let photos = app.buttons.matching(identifier: "tripPhotoThumbnail").allElementsBoundByIndex
        XCTAssertEqual(photos.count, 3)
        XCTAssertFalse(app.staticTexts["Site 14 from the road"].exists, "Captions belong in the detail view")
        XCTAssertFalse(app.staticTexts["Portrait photo"].exists)
        for (index, photo) in photos.enumerated() {
            XCTAssertGreaterThan(photo.frame.width, 0)
            XCTAssertEqual(photo.frame.width, photo.frame.height, accuracy: 1)
            XCTAssertEqual(photo.frame.width, photos[0].frame.width, accuracy: 1)
            for other in photos.dropFirst(index + 1) {
                XCTAssertFalse(photo.frame.intersects(other.frame), "Photo buttons must not overlap")
            }
        }
        lastPhoto.tap()
        assertPhotoLoaded(in: app)
        XCTAssertTrue(app.buttons["Share photo"].waitForExistence(timeout: 5))
    }

    func testPhotoLoadsAndStaysVisibleWhileEditingResizingAndReopening() throws {
        let app = openTripPhotos()
        tapReachable(app.buttons["Site 14 from the road"], in: app)
        assertPhotoLoaded(in: app)

        let caption = app.textFields["tripPhotoCaption"].exists
            ? app.textFields["tripPhotoCaption"] : app.textViews["tripPhotoCaption"]
        XCTAssertTrue(caption.waitForExistence(timeout: 5))
        caption.tap()
        caption.typeText(" at sunset")
        let updatedCaption = try XCTUnwrap(caption.value as? String)
        XCTAssertTrue(updatedCaption.contains("sunset"))
        assertPhotoLoaded(in: app)

        app.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Photos & site notes"].waitForExistence(timeout: 5))
        tapReachable(app.buttons[updatedCaption], in: app)
        assertPhotoLoaded(in: app)
        XCUIDevice.shared.orientation = .landscapeLeft
        assertPhotoLoaded(in: app)
        XCUIDevice.shared.orientation = .portrait
        assertPhotoLoaded(in: app)
    }

    func testUnreadablePhotoShowsAnErrorAndRetryFinishes() {
        let app = openTripPhotos(extraArguments: ["-unreadable-photo-fixture"])
        tapReachable(app.buttons["Unreadable photo"], in: app)
        XCTAssertTrue(app.staticTexts["Couldn’t load photo"].waitForExistence(timeout: 5))
        app.buttons["Retry"].tap()
        XCTAssertTrue(app.staticTexts["Couldn’t load photo"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["localPhotoLoading"].exists)
        XCTAssertFalse(app.images["localPhotoImage"].exists)
    }

    private func openTripPhotos(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-assistant-ui-test", "ready", "-navigation-ui-test", "-layout-ui-test",
                               "-permissions-ui-test", "denied", "-weather-ui-test"] + extraArguments
        app.launch()
        XCTAssertTrue(app.navigationTab("Home").waitForExistence(timeout: 10))
        app.buttons["tripRow-Current Pines"].tap()
        tapReachable(app.buttons["Photos & site notes"], in: app)
        XCTAssertTrue(app.navigationBars["Photos & site notes"].waitForExistence(timeout: 5))
        return app
    }

    private func tapReachable(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable)
        element.tap()
    }

    private func assertPhotoLoaded(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let preview = app.descendants(matching: .any)["tripPhotoPreview"].firstMatch
        let image = preview.images["localPhotoImage"].firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 5), "The preview must finish decoding", file: file, line: line)
        XCTAssertGreaterThan(image.frame.width, 0, file: file, line: line)
        XCTAssertGreaterThan(image.frame.height, 0, file: file, line: line)
        XCTAssertFalse(preview.descendants(matching: .any)["localPhotoLoading"].exists, file: file, line: line)
        XCTAssertFalse(preview.descendants(matching: .any)["localPhotoFailure"].exists, file: file, line: line)
    }
}
