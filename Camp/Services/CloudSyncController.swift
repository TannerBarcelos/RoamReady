import Foundation
import Observation
import CloudKit
import CoreData
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
    var requiresRestart: Bool { requested != enabled && !waitingForConnection && !accountNeedsReview }
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
        requested = configured && UserDefaults.standard.bool(forKey: Self.preference)
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
    /// Verify the separately approved iCloud identity before opening a mirrored coordinator.
    /// Failure only pauses cloud access; it must never prevent offline trip access.
    func containerForLaunch(store: SQLiteStore, online: Bool) async -> String? {
        waitingForConnection = false
        guard requested, let containerIdentifier else { return nil }
        guard online else {
            waitingForConnection = true
            status = "Saved on this iPhone. iCloud will resume when connected."
            return nil
        }
        do {
            guard let bytes = try await store.metadata("approvedCloudUser"), let approved = String(data: bytes, encoding: .utf8) else {
                accountNeedsReview = true
                status = "Approve your iCloud account to enable synchronization."
                return nil
            }
            let current = try await CKContainer(identifier: containerIdentifier).userRecordID().recordName
            guard approved == current else {
                accountNeedsReview = true
                status = "This library uses a different iCloud account. Sign in to its original iCloud account to sync."
                return nil
            }
            accountNeedsReview = false
            return containerIdentifier
        } catch {
            waitingForConnection = true
            status = "Saved on this iPhone. iCloud identity will be checked when connected."
            return nil
        }
    }
    func enable() async {
        guard let containerIdentifier, let disk, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let current = try await CKContainer(identifier: containerIdentifier).userRecordID().recordName
            if let bytes = try await disk.metadata("approvedCloudUser"), String(data: bytes, encoding: .utf8) != current {
                accountNeedsReview = true
                status = "This library belongs to another iCloud account. Sync remains paused; your local trips are available."
                return
            }
            try await disk.setMetadata("approvedCloudUser", value: Data(current.utf8))
            requested = true; accountNeedsReview = false
            UserDefaults.standard.set(true, forKey: Self.preference)
            status = enabled ? "iCloud manages synchronization automatically" : "iCloud sync will turn on after restarting RoamReady."
        } catch { status = "Connect to iCloud to enable sync. Your trips remain saved locally." }
    }
    func tearDown() {
        observationGeneration = UUID()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll(); accountTask?.cancel(); accountTask = nil
        activeEvents.removeAll(); busy = false; enabled = false
        disk = nil; refresh = nil; suspendMirroring = nil; configuredStore = false
    }
    func disable() async {
        requested = false; UserDefaults.standard.set(false, forKey: Self.preference)
        status = enabled ? "iCloud sync will turn off next time you open the app after closing it. Sync remains on until then." : "iCloud sync is off"
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
