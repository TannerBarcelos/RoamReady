import Foundation
import Observation
import CloudKit
import CoreData
import CampCore

/// Decides whether the library opens with iCloud, and reports Apple's mirroring activity.
/// SwiftData mirrors through `NSPersistentCloudKitContainer`: no polling, upload queue, or retries here.
@MainActor @Observable
final class CloudSyncController {
    private(set) var requested = false
    private(set) var syncing = false
    private(set) var busy = false
    private(set) var status = "iCloud sync is off"
    private(set) var lastActivity: Date?
    private(set) var accountNeedsReview = false
    private(set) var waitingForConnection = false
    let containerIdentifier: String?
    var configured: Bool { containerIdentifier != nil }
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var activeEvents: Set<UUID> = []
    @ObservationIgnored private var onAccountChange: (@MainActor () async -> Void)?
    private static let preference = "RoamReady.CloudSyncEnabled"
    /// The iCloud user this library first synced with. A different account never syncs into it.
    private static let pinnedUser = "RoamReady.CloudSyncUser"

    init() {
        let id = (Bundle.main.object(forInfoDictionaryKey: "RoamReadyMirroringContainerIdentifier") as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        containerIdentifier = id.hasPrefix("iCloud.") && !id.contains("$(") ? id : nil
        requested = CloudSyncPolicy.isRequested(configured: configured, storedPreference: UserDefaults.standard.object(forKey: Self.preference) as? Bool)
        if !configured { status = "iCloud sync isn’t available in this build" }
    }

    /// The CloudKit container to open the library with, or nil to open it on this device only.
    /// Failure only pauses cloud access; it never prevents offline trip access.
    func containerForLaunch(online: Bool) async -> String? {
        waitingForConnection = false; accountNeedsReview = false
        guard let containerIdentifier else { return nil }
        let identity: CloudSyncPolicy.Identity = requested && online ? await Self.identity(containerIdentifier) : .unavailable
        switch CloudSyncPolicy.launchDecision(requested: requested, pinnedUser: UserDefaults.standard.string(forKey: Self.pinnedUser), identity: identity) {
        case .localOnly:
            status = "iCloud sync is off"
        case .waitForConnection:
            waitingForConnection = true
            status = "Saved on this iPhone. iCloud sync will start when you’re connected."
        case .noAccount:
            accountNeedsReview = true
            status = "Sign in to iCloud in Settings, and allow RoamReady to use iCloud, to sync. Your trips stay on this iPhone."
        case .accountMismatch:
            accountNeedsReview = true
            status = "This library belongs to a different iCloud account. Sign in to that account to sync; your trips stay on this iPhone."
        case .pinAndSync(let user):
            UserDefaults.standard.set(user, forKey: Self.pinnedUser)
            return containerIdentifier
        case .sync:
            return containerIdentifier
        }
        return nil
    }

    /// Observes mirroring events while the library is open. `onAccountChange` reopens it.
    func start(syncing: Bool, onAccountChange: @escaping @MainActor () async -> Void) {
        stop()
        self.syncing = syncing
        guard syncing else { return }
        self.onAccountChange = onAccountChange
        status = "iCloud manages synchronization automatically"
        observers.append(NotificationCenter.default.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: .main) { [weak self] notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event else { return }
            // Extract Sendable values before crossing actor isolation.
            let id = event.identifier, finished = event.endDate, succeeded = event.succeeded, message = event.error?.localizedDescription
            Task { @MainActor [weak self] in self?.record(id: id, finished: finished, succeeded: succeeded, message: message) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.accountNeedsReview = true
                self?.status = "The iCloud account changed. Sync is paused while your library stays available on this iPhone."
                await self?.onAccountChange?()
            }
        })
    }

    func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll(); activeEvents.removeAll(); busy = false; syncing = false; onAccountChange = nil
    }

    /// Stores the preference. `LibraryController.setCloudSync` reopens the library so it applies now.
    func setRequested(_ value: Bool) {
        guard configured else { return }
        requested = value
        UserDefaults.standard.set(value, forKey: Self.preference)
        status = value ? "Turning on iCloud sync…" : "iCloud sync is off"
    }

    /// Re-checks the account when the app becomes active.
    func setActive(_ active: Bool) {
        guard active, syncing, let containerIdentifier else { return }
        Task {
            let account = try? await CKContainer(identifier: containerIdentifier).accountStatus()
            accountNeedsReview = account != .available
            if account != .available { status = "iCloud is unavailable. Changes stay on this iPhone until syncing can resume." }
        }
    }

    private func record(id: UUID, finished: Date?, succeeded: Bool, message: String?) {
        guard syncing else { return }
        if finished == nil { activeEvents.insert(id) } else { activeEvents.remove(id) }
        busy = !activeEvents.isEmpty
        if let finished {
            if succeeded { lastActivity = finished }
            status = succeeded ? "Up to date with iCloud. Changes sync automatically." : "Saved on this iPhone. \(message ?? "iCloud will retry when available.")"
        } else {
            status = "Syncing with iCloud…"
        }
    }

    private static func identity(_ containerIdentifier: String) async -> CloudSyncPolicy.Identity {
        let container = CKContainer(identifier: containerIdentifier)
        do {
            switch try await container.accountStatus() {
            case .available: return .signedIn(try await container.userRecordID().recordName)
            case .noAccount, .restricted: return .noAccount
            default: return .unavailable
            }
        } catch { return .unavailable }
    }
}
