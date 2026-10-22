import Foundation
import XCTest
@testable import CampCore

final class CampsiteSnapshotTests: XCTestCase {
    func testShardingMatchesImporterForRealFacilityIDs() {
        XCTAssertEqual(CampsiteShard.number(for: "232447"), 54)
        XCTAssertEqual(CampsiteShard.number(for: "119040"), 47)
    }
    func testUnknownLengthDoesNotInventFitAndSchemaIsChecked() throws {
        let data = Data(#"{"schemaVersion":1,"sitesByFacility":{"232447":[{"id":"100","name":"044","kind":"STANDARD NONELECTRIC","loop":"Upper Pines","vehicleAccessible":false,"attributes":{"Pets Allowed":"Yes"},"equipment":{"motorhome":35,"tent":0},"updatedAt":"2025-12-03"}]}}"#.utf8)
        let shard = try CampsiteShard.decode(data)
        let site = try XCTUnwrap(shard.sitesByFacility["232447"]?.first)
        XCTAssertEqual(site.maximumLengthFeet(for: .motorhome), 35)
        XCTAssertNil(site.maximumLengthFeet(for: .tent))
        XCTAssertNil(site.maximumLengthFeet(for: .travelTrailer))
        XCTAssertEqual(site.attributes["Pets Allowed"], "Yes")
        XCTAssertThrowsError(try CampsiteShard.decode(Data(#"{"schemaVersion":2,"sitesByFacility":{}}"#.utf8)))
    }
}
