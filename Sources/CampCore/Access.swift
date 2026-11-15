import Foundation

/// RoamReady's App Store products. The IDs must match App Store Connect and `Config/RoamReady.storekit`
/// exactly; prices live there, never in code.
public enum StoreProduct: String, CaseIterable, Sendable {
    case monthly = "com.tannerdev.roamready.pro.monthly"
    case yearly = "com.tannerdev.roamready.pro.yearly"
    /// A non-consumable that never expires.
    case lifetime = "com.tannerdev.roamready.pro.lifetime"

    public static let subscriptions: [StoreProduct] = [.monthly, .yearly]
    public static var allIDs: [String] { allCases.map(\.rawValue) }
    public static var subscriptionIDs: [String] { subscriptions.map(\.rawValue) }
}

/// One verified purchase the device currently holds, reduced to what the access rules need.
public struct StoreEntitlement: Equatable, Sendable {
    public var productID: String
    public var expirationDate: Date?
    public var isRevoked: Bool

    public init(productID: String, expirationDate: Date? = nil, isRevoked: Bool = false) {
        self.productID = productID
        self.expirationDate = expirationDate
        self.isRevoked = isRevoked
    }
}

/// What the camper may do. Anyone without a purchase can still open and read everything they saved,
/// so a lapsed subscription never hides their trips, paperwork, or photos.
public enum AccessStatus: Equatable, Sendable {
    /// StoreKit hasn't answered yet. Edits wait for the answer rather than flashing the paywall.
    case checking
    case lifetime
    case subscribed(StoreProduct, renewsOrExpires: Date?)
    case readOnly

    public var canEdit: Bool {
        switch self {
        case .lifetime, .subscribed: true
        case .checking, .readOnly: false
        }
    }

    public var title: String {
        switch self {
        case .checking: "Checking purchases…"
        case .lifetime: "RoamReady Lifetime"
        case .subscribed(.yearly, _): "RoamReady Yearly"
        case .subscribed: "RoamReady Monthly"
        case .readOnly: "Read-only"
        }
    }

    public var message: String {
        switch self {
        case .checking: ""
        case .lifetime: "Thanks for supporting RoamReady. Everything is unlocked for good."
        case .subscribed: "Everything is unlocked. Manage or cancel any time in your Apple Account."
        case .readOnly: "You can open everything you’ve saved. Subscribe or buy Lifetime to add and edit trips, checklists, documents, and photos."
        }
    }

    /// StoreKit's `currentEntitlements` already drops expired subscriptions and keeps ones in a billing
    /// grace period, so this trusts its list rather than the device clock. Revoked (refunded) purchases
    /// never count, and Lifetime wins over any subscription.
    public static func resolve(_ entitlements: [StoreEntitlement]) -> AccessStatus {
        let valid = entitlements.filter { !$0.isRevoked }
        if valid.contains(where: { $0.productID == StoreProduct.lifetime.rawValue }) { return .lifetime }
        let subscriptions = valid.compactMap { entitlement -> (StoreProduct, Date?)? in
            guard let product = StoreProduct(rawValue: entitlement.productID), product != .lifetime else { return nil }
            return (product, entitlement.expirationDate)
        }
        // Prefer yearly when both appear briefly during a plan change.
        if let best = subscriptions.first(where: { $0.0 == .yearly }) ?? subscriptions.first {
            return .subscribed(best.0, renewsOrExpires: best.1)
        }
        return .readOnly
    }
}
