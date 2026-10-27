import XCTest
@testable import CampCore

final class HingeCapabilityTests: XCTestCase {
    func testStartsOffWithoutAHinge() {
        var capability = HingeCapability()
        XCTAssertFalse(capability.usesDuoWorkspace)
        capability.record(hingeReported: false)
        XCTAssertFalse(capability.usesDuoWorkspace, "Devices without a hinge keep the current layout")
    }

    func testInitialHingeReportTurnsOnTheWorkspace() {
        var capability = HingeCapability()
        capability.record(hingeReported: true)
        XCTAssertTrue(capability.usesDuoWorkspace)
    }

    func testStaysOnThroughTransientHierarchyChanges() {
        var capability = HingeCapability()
        capability.record(hingeReported: true)
        capability.record(hingeReported: false)
        XCTAssertTrue(capability.usesDuoWorkspace, "A nil report while views are re-parented must not flip the layout")
        capability.record(hingeReported: true)
        XCTAssertTrue(capability.usesDuoWorkspace)
    }

    func testForcingTurnsOnTheWorkspaceWithoutHardware() {
        var capability = HingeCapability(forced: true)
        XCTAssertTrue(capability.usesDuoWorkspace)
        capability.record(hingeReported: false)
        XCTAssertTrue(capability.usesDuoWorkspace)
    }
}
