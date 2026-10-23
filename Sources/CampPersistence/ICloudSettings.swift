#if canImport(SwiftData)
import Foundation
import Observation
import CoreData

/// A launch preference and passive activity display. Apple owns connectivity, account changes,
/// scheduling, and retries for the lifetime of the SwiftData container.
@MainActor @Observable
public final class ICloudSettings {
    public let containerIdentifier: String?
    public let enabledForSession: Bool
    public private(set) var requested: Bool
    public private(set) var lastActivity: Date?
    public private(set) var lastError: String?
    public var configured: Bool { containerIdentifier != nil }
    public var hasPendingChange: Bool { requested != enabledForSession }
    public var containerForSession: String? { enabledForSession ? containerIdentifier : nil }
    public var status: String {
        if !configured { return "iCloud sync isn’t available in this build" }
        if !enabledForSession { return "iCloud sync is off for this session" }
        if let lastError { return "Last iCloud activity reported a problem: \(lastError)" }
        return "iCloud manages synchronization automatically"
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var observer: NSObjectProtocol?
    private static let preference = "RoamReady.CloudSyncEnabled"

    public init(containerIdentifier: String?, defaults: UserDefaults = .standard) {
        let id = (containerIdentifier ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.containerIdentifier = id.hasPrefix("iCloud.") && !id.contains("$(") ? id : nil
        self.defaults = defaults
        // Older builds pinned an account in app preferences. Identity now belongs to Apple.
        defaults.removeObject(forKey: "RoamReady.CloudSyncUser")
        let enabled = self.containerIdentifier != nil && (defaults.object(forKey: Self.preference) as? Bool ?? true)
        requested = enabled
        enabledForSession = enabled
    }

    /// Changing this preference never closes a live store. It applies on the next app launch.
    public func setRequested(_ value: Bool) {
        guard configured else { return }
        requested = value
        defaults.set(value, forKey: Self.preference)
    }

    public func startObserving() {
        stopObserving()
        guard enabledForSession else { return }
        observer = NotificationCenter.default.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification,
                                                         object: nil, queue: .main) { [weak self] notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event else { return }
            let finished = event.endDate, succeeded = event.succeeded, message = event.error?.localizedDescription
            Task { @MainActor [weak self] in self?.recordActivity(finished: finished, succeeded: succeeded, message: message) }
        }
    }

    public func stopObserving() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    /// A completed event reports one activity, never proof that every device is up to date.
    func recordActivity(finished: Date?, succeeded: Bool, message: String?) {
        guard enabledForSession, let finished else { return }
        if succeeded {
            lastActivity = finished
            lastError = nil
        } else {
            lastError = message ?? "iCloud couldn’t complete this activity. Apple manages retries."
        }
    }
}
#endif
