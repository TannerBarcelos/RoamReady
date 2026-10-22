import XCTest
@testable import CampCore

final class AssistantDevicePolicyTests: XCTestCase {
    func testIPhone16FamilyIncluding16eAndLaterMeetProductPolicy() {
        for machine in ["iPhone17,1", "iPhone17,2", "iPhone17,3", "iPhone17,4", "iPhone17,5", "iPhone18,1"] {
            XCTAssertTrue(AssistantDevicePolicy.permitsGenerativeAI(machineIdentifier: machine), machine)
        }
    }

    func testOlderIPhonesIncludingAppleIntelligenceCapable15ProAreExcluded() {
        for machine in ["iPhone16,1", "iPhone16,2", "iPhone15,4", "iPhone14,5"] {
            XCTAssertFalse(AssistantDevicePolicy.permitsGenerativeAI(machineIdentifier: machine), machine)
        }
    }

    func testOtherDevicesSimulatorsAndMalformedIdentifiersAreExcluded() {
        for machine in ["arm64", "x86_64", "iPad17,1", "", "iPhone17", "iPhone17,", "iPhone17,0", "iPhone17,1,2", "iPhonefoo,1"] {
            XCTAssertFalse(AssistantDevicePolicy.permitsGenerativeAI(machineIdentifier: machine), machine)
        }
    }
}
