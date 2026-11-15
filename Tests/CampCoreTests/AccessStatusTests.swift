import XCTest
@testable import CampCore

final class AccessStatusTests: XCTestCase {
    private let renewal = Date(timeIntervalSince1970: 2_000_000_000)

    func testNoPurchasesIsReadOnlyAndCannotEdit() {
        XCTAssertEqual(AccessStatus.resolve([]), .readOnly)
        XCTAssertFalse(AccessStatus.readOnly.canEdit)
        XCTAssertFalse(AccessStatus.checking.canEdit, "Edits wait for StoreKit rather than guessing")
    }

    func testEachSubscriptionUnlocksEditing() {
        for product in StoreProduct.subscriptions {
            let status = AccessStatus.resolve([StoreEntitlement(productID: product.rawValue, expirationDate: renewal)])
            XCTAssertEqual(status, .subscribed(product, renewsOrExpires: renewal))
            XCTAssertTrue(status.canEdit)
        }
    }

    func testLifetimeWinsOverASubscription() {
        let status = AccessStatus.resolve([
            StoreEntitlement(productID: StoreProduct.monthly.rawValue, expirationDate: renewal),
            StoreEntitlement(productID: StoreProduct.lifetime.rawValue)
        ])
        XCTAssertEqual(status, .lifetime)
    }

    func testRefundedPurchasesDoNotCount() {
        XCTAssertEqual(AccessStatus.resolve([StoreEntitlement(productID: StoreProduct.lifetime.rawValue, isRevoked: true)]), .readOnly)
        let status = AccessStatus.resolve([
            StoreEntitlement(productID: StoreProduct.lifetime.rawValue, isRevoked: true),
            StoreEntitlement(productID: StoreProduct.monthly.rawValue, expirationDate: renewal)
        ])
        XCTAssertEqual(status, .subscribed(.monthly, renewsOrExpires: renewal))
    }

    func testUnknownProductsAreIgnored() {
        XCTAssertEqual(AccessStatus.resolve([StoreEntitlement(productID: "com.example.other")]), .readOnly)
    }

    func testYearlyIsPreferredDuringAPlanChange() {
        let status = AccessStatus.resolve([
            StoreEntitlement(productID: StoreProduct.monthly.rawValue, expirationDate: renewal),
            StoreEntitlement(productID: StoreProduct.yearly.rawValue, expirationDate: renewal)
        ])
        XCTAssertEqual(status, .subscribed(.yearly, renewsOrExpires: renewal))
    }

    func testProductIDsAreDistinctAndShareThePrefix() {
        XCTAssertEqual(Set(StoreProduct.allIDs).count, StoreProduct.allCases.count)
        XCTAssertTrue(StoreProduct.allIDs.allSatisfy { $0.hasPrefix("com.tannerdev.roamready.pro.") })
        XCTAssertFalse(StoreProduct.subscriptionIDs.contains(StoreProduct.lifetime.rawValue))
    }

    func testReadOnlyExplainsThatDataStaysReadable() {
        XCTAssertTrue(AccessStatus.readOnly.message.contains("open everything"))
    }
}
