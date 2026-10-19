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
    let containerIdentifier: String?
    var configured: Bool { containerIdentifier != nil }
    var requiresRestart: Bool { requested != enabled }
    var launchContainerIdentifier: String? { requested ? containerIdentifier : nil }
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var activeEvents: Set<UUID> = []
    @ObservationIgnored private var refresh: (@MainActor () async -> Void)?
    @ObservationIgnored private var accountTask: Task<Void, Never>?
    @ObservationIgnored private var configuredStore = false
    private static let preference = "RoamReady.ManagedCloudSyncEnabled"

    init() {
        // A new container is required: managed mirroring cannot adopt the old custom schema.
        let id = (Bundle.main.object(forInfoDictionaryKey: "RoamReadyMirroringContainerIdentifier") as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        containerIdentifier = id.hasPrefix("iCloud.") && !id.contains("$(") ? id : nil
        requested = configured && UserDefaults.standard.bool(forKey: Self.preference)
        if !configured { status = "iCloud sync isn’t available in this build" }
    }
    func configure(store: SQLiteStore, refresh: @escaping @MainActor () async -> Void) async {
        guard !configuredStore else { return }; configuredStore = true
        self.refresh = refresh; enabled = store.cloudEnabled
        observers.append(NotificationCenter.default.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: .main) { [weak self] notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event else { return }
            // Extract Sendable values before crossing actor isolation.
            let id = event.identifier, finished = event.endDate, success = event.succeeded
            let message = event.error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self else { return }
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
            Task { @MainActor [weak self] in await self?.refresh?() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.checkAccount()
                await self?.refresh?()
            }
        })
        await checkAccount()
    }
    func enable() async {
        guard configured else { return }
        requested = true; UserDefaults.standard.set(true, forKey: Self.preference)
        status = enabled ? "iCloud manages synchronization automatically" : "iCloud sync will turn on next time you open the app after closing it."
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
        do {
            let account = try await CKContainer(identifier: containerIdentifier).accountStatus()
            accountNeedsReview = account != .available
            switch account {
            case .available: status = busy ? "Syncing with iCloud…" : "iCloud manages synchronization automatically"
            case .noAccount: status = "Sign in to iCloud in Settings to sync. Your local library remains available."
            case .restricted: status = "iCloud access is restricted. Your local library remains available."
            default: status = "iCloud is unavailable. Changes stay on this iPhone until syncing can resume."
            }
        } catch { status = "Saved on this iPhone. iCloud is currently unavailable." }
    }
}
