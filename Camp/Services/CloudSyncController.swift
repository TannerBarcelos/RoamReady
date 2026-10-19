import Foundation
import Observation
import Network
import CloudKit
import CampPersistence
import CampCore

@MainActor @Observable
final class CloudSyncController {
    private(set) var enabled = false
    private(set) var busy = false
    private(set) var status = "iCloud sync is off"
    private(set) var lastCheck: Date?
    private(set) var accountNeedsReview = false
    let configured: Bool
    @ObservationIgnored private let worker: CloudKitReplicator?
    @ObservationIgnored private var disk: SQLiteStore?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var scheduleToken = UUID()
    @ObservationIgnored private var resyncRequested = false
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var refresh: (@MainActor () async -> Void)?
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var retrySeconds: Double = 2
    @ObservationIgnored private var active = true
    @ObservationIgnored private var configuredStore = false
    init() {
        let id = (Bundle.main.object(forInfoDictionaryKey: "RoamReadyCloudContainerIdentifier") as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        configured = id.hasPrefix("iCloud.") && !id.contains("$(")
        worker = configured ? CloudKitReplicator(containerIdentifier: id) : nil
        if !configured { status = "iCloud sync isn’t available in this build" }
    }
    func configure(store: SQLiteStore, refresh: @escaping @MainActor () async -> Void) async {
        guard !configuredStore else { return }; configuredStore = true
        disk = store; self.refresh = refresh
        enabled = (try? await store.metadata("cloudEnabled")) != nil
        if let bytes = try? await store.metadata("cloudLastCheck") { lastCheck = try? JSONDecoder().decode(Date.self, from: bytes) }
        observer = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.accountNeedsReview = true
                self.status = "iCloud account changed. Sync is paused; your local library is available."
                self.task?.cancel()
                await self.worker?.cancel()
            }
        }
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in self?.schedule() }
        }
        monitor.start(queue: DispatchQueue(label: "RoamReady.SyncReachability"))
        if enabled { status = "Changes will sync when connected"; schedule() }
    }
    func enable() async {
        guard let worker, let disk, !busy else { return }
        busy = true
        do {
            try await worker.enable(store: disk)
            enabled = true; accountNeedsReview = false; status = "iCloud sync enabled"; retrySeconds = 2
        } catch { status = error.localizedDescription }
        busy = false; schedule()
    }
    func disable() async {
        guard let worker, let disk else { return }
        enabled = false
        task?.cancel()
        do { try await worker.disable(store: disk); status = "iCloud sync is off. Your local library is available." }
        catch { status = error.localizedDescription }
    }
    func setActive(_ value: Bool) {
        active = value
        if value { syncNow() }
        else {
            task?.cancel()
            if !busy { scheduleToken = UUID(); task = nil }
            Task { await worker?.cancel() }
        }
    }
    func schedule(after delay: Double = 2) {
        guard configured, enabled, active, !accountNeedsReview, !busy, task == nil else { return }
        let token = UUID(); scheduleToken = token
        task = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch {
                guard let self, self.scheduleToken == token else { return }
                self.task = nil
                self.schedule(after: 0)
                return
            }
            guard let self, self.scheduleToken == token else { return }
            await self.performSync()
        }
    }
    func syncNow() {
        if busy { resyncRequested = true; return }
        scheduleToken = UUID(); task?.cancel(); task = nil
        schedule(after: 0)
    }
    private func performSync() async {
        guard let worker, let disk, enabled, active, !accountNeedsReview else { task = nil; return }
        busy = true; status = "Syncing with iCloud…"
        var next: Double = 60
        do {
            let result = try await worker.sync(store: disk)
            try Task.checkCancellation()
            lastCheck = .now; retrySeconds = 2
            status = result.waitingForRelatedRecords ? "Waiting for remaining trip records; your saved library is available" : result.hasPendingUploads ? "Saved locally; more changes are waiting to sync" : "Latest iCloud check completed"
            next = result.hasPendingUploads || result.waitingForRelatedRecords ? 2 : 60
            await refresh?()
        } catch is CancellationError {
            status = accountNeedsReview ? "iCloud account changed. Sync is paused." : "Saved locally; sync will resume when the app is active"
        } catch {
            if let failure = error as? ReplicationError {
                switch failure {
                case .accountChanged: accountNeedsReview = true
                case .cloudLibraryRemoved: enabled = false
                default: break
                }
            }
            if let ck = error as? CKError, ck.code == .quotaExceeded { status = "iCloud storage is full. Your changes are saved on this iPhone." }
            else { status = "Saved on this iPhone. \(error.localizedDescription)" }
            retrySeconds = min(300, retrySeconds * 2)
            next = max(retrySeconds, (error as? CKError)?.retryAfterSeconds ?? 0)
            // Even a partially completed download may have useful records/assets.
            await refresh?()
        }
        busy = false; task = nil
        let immediate = resyncRequested; resyncRequested = false
        schedule(after: immediate ? 0 : next)
    }
}
