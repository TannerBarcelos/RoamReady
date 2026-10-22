import Foundation

/// iCloud sync decisions, kept free of CloudKit so they can be unit-tested.
public enum CloudSyncPolicy {
    /// Sync is on unless the person turned it off. Builds without a container stay local.
    public static func isRequested(configured: Bool, storedPreference: Bool?) -> Bool {
        configured && (storedPreference ?? true)
    }

    /// What the signed-in iCloud account looks like at launch.
    public enum Identity: Equatable, Sendable {
        case signedIn(String)
        /// No account, or iCloud is restricted on this device.
        case noAccount
        /// Offline, or CloudKit could not answer.
        case unavailable
    }

    public enum LaunchDecision: Equatable, Sendable {
        case localOnly
        case waitForConnection
        case noAccount
        /// First sync for this library: bind it to the signed-in account, then sync.
        case pinAndSync(String)
        case sync
        /// The library is bound to a different iCloud account. Never merge the two.
        case accountMismatch
    }

    public static func launchDecision(requested: Bool, pinnedUser: String?, identity: Identity) -> LaunchDecision {
        guard requested else { return .localOnly }
        switch identity {
        case .unavailable: return .waitForConnection
        case .noAccount: return .noAccount
        case .signedIn(let current):
            guard let pinnedUser else { return .pinAndSync(current) }
            return pinnedUser == current ? .sync : .accountMismatch
        }
    }
}
