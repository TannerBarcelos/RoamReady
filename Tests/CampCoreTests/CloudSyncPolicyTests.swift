import XCTest
@testable import CampCore

final class CloudSyncPolicyTests: XCTestCase {
    func testSyncIsOnByDefaultUnlessTurnedOffAndNeverWithoutAContainer() {
        XCTAssertTrue(CloudSyncPolicy.isRequested(configured: true, storedPreference: nil))
        XCTAssertTrue(CloudSyncPolicy.isRequested(configured: true, storedPreference: true))
        XCTAssertFalse(CloudSyncPolicy.isRequested(configured: true, storedPreference: false))
        XCTAssertFalse(CloudSyncPolicy.isRequested(configured: false, storedPreference: nil))
        XCTAssertFalse(CloudSyncPolicy.isRequested(configured: false, storedPreference: true))
    }

    func testFirstSyncPinsTheSignedInAccountWithoutAsking() {
        XCTAssertEqual(CloudSyncPolicy.launchDecision(requested: true, pinnedUser: nil, identity: .signedIn("A")), .pinAndSync("A"))
        XCTAssertEqual(CloudSyncPolicy.launchDecision(requested: true, pinnedUser: "A", identity: .signedIn("A")), .sync)
    }

    func testAnotherAccountNeverSyncsIntoAPinnedLibrary() {
        XCTAssertEqual(CloudSyncPolicy.launchDecision(requested: true, pinnedUser: "A", identity: .signedIn("B")), .accountMismatch)
    }

    func testOffNoAccountAndOfflineStayLocal() {
        for identity in [CloudSyncPolicy.Identity.signedIn("A"), .noAccount, .unavailable] {
            XCTAssertEqual(CloudSyncPolicy.launchDecision(requested: false, pinnedUser: "A", identity: identity), .localOnly)
        }
        XCTAssertEqual(CloudSyncPolicy.launchDecision(requested: true, pinnedUser: nil, identity: .noAccount), .noAccount)
        XCTAssertEqual(CloudSyncPolicy.launchDecision(requested: true, pinnedUser: "A", identity: .noAccount), .noAccount)
        XCTAssertEqual(CloudSyncPolicy.launchDecision(requested: true, pinnedUser: nil, identity: .unavailable), .waitForConnection)
        XCTAssertEqual(CloudSyncPolicy.launchDecision(requested: true, pinnedUser: "A", identity: .unavailable), .waitForConnection)
    }
}
