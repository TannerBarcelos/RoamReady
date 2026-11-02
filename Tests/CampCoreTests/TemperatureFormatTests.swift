import XCTest
@testable import CampCore

final class TemperatureFormatTests: XCTestCase {
    private let us = Locale(identifier: "en_US")
    private let uk = Locale(identifier: "en_GB")

    func testRoundsAfterConvertingToFahrenheit() {
        XCTAssertEqual(TemperatureFormat.string(celsius: (64.601352 - 32) * 5 / 9, locale: us), "65°")
        XCTAssertEqual(TemperatureFormat.string(celsius: (49.745479 - 32) * 5 / 9, locale: us), "50°")
    }

    func testCelsiusRoundsToWholeNumber() {
        XCTAssertEqual(TemperatureFormat.string(celsius: 18.4, locale: uk), "18°")
        XCTAssertEqual(TemperatureFormat.string(celsius: 18.6, locale: uk), "19°")
    }

    func testIncludesUnitWhenAsked() {
        XCTAssertEqual(TemperatureFormat.string(celsius: 22, includeUnit: true, locale: uk), "22°C")
        XCTAssertEqual(TemperatureFormat.string(celsius: 22, includeUnit: true, locale: us), "72°F")
    }
}
