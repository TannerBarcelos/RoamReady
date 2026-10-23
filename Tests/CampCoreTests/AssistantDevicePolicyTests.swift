import XCTest
@testable import CampCore

final class AssistantDevicePolicyTests: XCTestCase {
    func testGlobalChatIsHiddenOnNonAIHardware() {
        for machine in ["iPhone15,4", "iPhone15,5", "iPhone15,2", "iPhone14,7", "iPad17,1", "simulator", "", "iPhone17,0"] {
            XCTAssertFalse(AssistantDevicePolicy.supportsGlobalChat(machineIdentifier: machine), machine)
        }
        for machine in ["iPhone16,1", "iPhone16,2", "iPhone17,1", "iPhone18,1"] {
            XCTAssertTrue(AssistantDevicePolicy.supportsGlobalChat(machineIdentifier: machine), machine)
        }
    }
    func testIPhone15And15PlusPassTheProductGate() {
        // Apple's runtime check still reports deviceNotEligible on these; the app explains that.
        for machine in ["iPhone15,4", "iPhone15,5"] {
            XCTAssertTrue(AssistantDevicePolicy.permitsGenerativeAI(machineIdentifier: machine), machine)
        }
    }

    func testIPhone15ProAnd16FamilyAndLaterMeetProductPolicy() {
        for machine in ["iPhone16,1", "iPhone16,2", "iPhone17,1", "iPhone17,2", "iPhone17,3", "iPhone17,4",
                        "iPhone17,5", "iPhone18,1", "iPhone19,3"] {
            XCTAssertTrue(AssistantDevicePolicy.permitsGenerativeAI(machineIdentifier: machine), machine)
        }
    }

    func testIPhone14ProAndOlderAreExcluded() {
        // iPhone15,2 / 15,3 are the iPhone 14 Pro / Pro Max despite the "15" prefix.
        for machine in ["iPhone15,2", "iPhone15,3", "iPhone15,1", "iPhone15,6", "iPhone14,7", "iPhone14,5", "iPhone12,1"] {
            XCTAssertFalse(AssistantDevicePolicy.permitsGenerativeAI(machineIdentifier: machine), machine)
        }
    }

    func testOtherDevicesSimulatorsAndMalformedIdentifiersAreExcluded() {
        for machine in ["arm64", "x86_64", "iPad17,1", "iPad16,3", "", "iPhone17", "iPhone17,", "iPhone17,0",
                        "iPhone15,0", "iPhone17,1,2", "iPhonefoo,1", "iPhone,4"] {
            XCTAssertFalse(AssistantDevicePolicy.permitsGenerativeAI(machineIdentifier: machine), machine)
        }
    }
}
