import Foundation
import Observation
import CloudKit
import CoreData
import CampCore
import CampPersistence

/// Observes Apple's mirroring events. No polling, upload queue, tokens, or retry scheduler.
@MainActor @Observable
final class CloudSyncController {
    private(set) var enabled = false
    private(set) var requested = false
    private(set) var busy = false
    private(set) var status = "iCloud sync is off"
    private(set) var lastCheck: Date?
    private(set) var accountNeedsReview = false
    private(set) var waitingForConnection = false
    let containerIdentifier: String?
    var configured: Bool { containerIdentifier != nil }
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var activeEvents: Set<UUID> = []
    @ObservationIgnored private var refresh: (@MainActor () async -> Void)?
    @ObservationIgnored private var accountTask: Task<Void, Never>?
    @ObservationIgnored private var configuredStore = false
    @ObservationIgnored private var disk: SQLiteStore?
    @ObservationIgnored private var suspendMirroring: (@MainActor () async -> Void)?
    @ObservationIgnored private var observationGeneration = UUID()
    private static let preference = "RoamReady.ManagedCloudSyncEnabled"

    init() {
        // A new container is required: managed mirroring cannot adopt the old custom schema.
        let id = (Bundle.main.object(forInfoDictionaryKey: "RoamReadyMirroringContainerIdentifier") as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        containerIdentifier = id.hasPrefix("iCloud.") && !id.contains("$(") ? id : nil
        requested = CloudSyncPolicy.isRequested(configured: configured,
                                                storedPreference: UserDefaults.standard.object(forKey: Self.preference) as? Bool)
        if !configured { status = "iCloud sync isn’t available in this build" }
    }
    func configure(store: SQLiteStore, suspendMirroring: @escaping @MainActor () async -> Void, refresh: @escaping @MainActor () async -> Void) async {
        guard !configuredStore else { return }; configuredStore = true
        let generation = observationGeneration
        self.refresh = refresh; self.suspendMirroring = suspendMirroring; disk = store; enabled = store.cloudEnabled
        observers.append(NotificationCenter.default.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: .main) { [weak self] notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event else { return }
            // Extract Sendable values before crossing actor isolation.
            let id = event.identifier, finished = event.endDate, success = event.succeeded
            let message = event.error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, self.observationGeneration == generation else { return }
                if finished == nil { self.activeEvents.insert(id) } else { self.activeEvents.remove(id) }
                self.busy = !self.activeEvents.isEmpty
                if let finished {
                    if success { self.lastCheck = finished }
                    self.status = success ? "iCloud activity completed. Changes sync automatically." : "Saved on this iPhone. \(message ?? "iCloud will retry when available.")"
                    await self.refresh?()
                } else { self.status = "Syncing with iCloud…" }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .NSPersistentStoreRemoteChange, object: store.coordinator, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.observationGeneration == generation else { return }
                await self.refresh?()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.observationGeneration == generation else { return }
                self.accountNeedsReview = true
                self.status = "The iCloud account changed. Sync is paused while your local library stays available."
                await self.suspendMirroring?()
            }
        })
        await checkAccount()
    }
    /// Sync is on by default. The first sync binds this library to the signed-in iCloud account,
    /// and later launches sync only for that account. Failure only pauses cloud access; it must
    /// never prevent offline trip access.
    func containerForLaunch(store: SQLiteStore, online: Bool) async -> String? {
        waitingForConnection = false; accountNeedsReview = false
        guard let containerIdentifier else { return nil }
        let pinned: String?
        do { pinned = try await store.metadata("approvedCloudUser").flatMap { String(data: $0, encoding: .utf8) } }
        catch { pinned = nil }
        // Skip the CloudKit account lookup entirely when sync is off.
        let identity: CloudSyncPolicy.Identity
        if requested && online { identity = await Self.identity(containerIdentifier) } else { identity = .unavailable }
        switch CloudSyncPolicy.launchDecision(requested: requested, pinnedUser: pinned, identity: identity) {
        case .localOnly:
            status = "iCloud sync is off"
            return nil
        case .waitForConnection:
            waitingForConnection = true
            status = "Saved on this iPhone. iCloud sync will start when you’re connected."
            return nil
        case .noAccount:
            accountNeedsReview = true
            status = "Sign in to iCloud in Settings, and allow RoamReady to use iCloud, to sync. Your trips stay on this iPhone."
            return nil
        case .accountMismatch:
            accountNeedsReview = true
            status = "This library belongs to a different iCloud account. Sign in to that account to sync; your trips stay on this iPhone."
            return nil
        case .pinAndSync(let current):
            do { try await store.setMetadata("approvedCloudUser", value: Data(current.utf8)) }
            catch {
                status = "Saved on this iPhone. iCloud sync will try again next time."
                return nil
            }
            return containerIdentifier
        case .sync:
            return containerIdentifier
        }
    }
    private static func identity(_ containerIdentifier: String) async -> CloudSyncPolicy.Identity {
        let container = CKContainer(identifier: containerIdentifier)
        do {
            let status = try await container.accountStatus()
            switch status {
            case .available: return .signedIn(try await container.userRecordID().recordName)
            case .noAccount, .restricted: return .noAccount
            default: return .unavailable
            }
        } catch { return .unavailable }
    }
    /// Stores the preference. `CampStore.setCloudSync` reopens the library so it applies immediately.
    func setRequested(_ value: Bool) {
        guard configured else { return }
        requested = value
        UserDefaults.standard.set(value, forKey: Self.preference)
        status = value ? "Turning on iCloud sync…" : "iCloud sync is off"
    }
    func tearDown() {
        observationGeneration = UUID()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll(); accountTask?.cancel(); accountTask = nil
        activeEvents.removeAll(); busy = false; enabled = false
        disk = nil; refresh = nil; suspendMirroring = nil; configuredStore = false
    }
    func setActive(_ value: Bool) {
        guard value else { return }
        accountTask?.cancel()
        accountTask = Task { [weak self] in await self?.checkAccount(); await self?.refresh?() }
    }
    private func checkAccount() async {
        guard enabled, let containerIdentifier else { return }
        let generation = observationGeneration
        do {
            let account = try await CKContainer(identifier: containerIdentifier).accountStatus()
            guard generation == observationGeneration else { return }
            accountNeedsReview = account != .available
            switch account {
            case .available: status = busy ? "Syncing with iCloud…" : "iCloud manages synchronization automatically"
            case .noAccount: status = "Sign in to iCloud in Settings to sync. Your local library remains available."
            case .restricted: status = "iCloud access is restricted. Your local library remains available."
            default: status = "iCloud is unavailable. Changes stay on this iPhone until syncing can resume."
            }
        } catch {
            guard generation == observationGeneration else { return }
            status = "Saved on this iPhone. iCloud is currently unavailable."
        }
    }
}
