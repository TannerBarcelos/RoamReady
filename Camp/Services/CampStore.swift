import Foundation
import Observation
import CampCore
import CampPersistence
import UIKit

/// The UI only reads local state. Writes are serialized and retained in memory on failure.
@MainActor @Observable
final class CampStore {
    private(set) var state = AppState()
    /// Saved campgrounds and their lists (#30), by campground ID.
    private(set) var savedCampgrounds: [String: SavedCampground] = [:]
    private(set) var libraryNotice: String?
    private(set) var mediaRevision = 0
    /// Metadata for every active document. Bytes stay in the store until a document is opened.
    private(set) var documents: [ManagedDocument] = []
    let sync = CloudSyncController()
    private(set) var isLoading = true
    private(set) var loadFailure: String?
    private(set) var saveFailure: String?
    private(set) var presentsSaveFailure = false
    private(set) var isSaving = false
    private(set) var lastSavedAt: Date?
    let directory: URL
    let media: MediaStore
    let documentFiles: DocumentFileCache
    @ObservationIgnored private var disk: SQLiteStore?
    @ObservationIgnored private var baseline = LibrarySnapshot()
    @ObservationIgnored private var loadInProgress = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var saveRevision = 0
    @ObservationIgnored private var pendingSave: (revision: Int, library: LibrarySnapshot)?
    @ObservationIgnored private var didLoad = false
    @ObservationIgnored private var libraryGeneration = 0
    @ObservationIgnored private var cloudSuppressed = false
    private(set) var isTransitioning = false
    @ObservationIgnored private var lifecycleTask: Task<Void, Never>?
    @ObservationIgnored private var lifecycleID = UUID()
    @ObservationIgnored private var wantsLibraryAccess = false
    @ObservationIgnored private var suspendedUnsaved: (baseline: LibrarySnapshot, desired: LibrarySnapshot)?

    var archiveURL: URL { directory.appendingPathComponent("camp-state.json") }

    init() {
        directory = URL.applicationSupportDirectory.appendingPathComponent("Camp", isDirectory: true)
        media = MediaStore(directory: directory.appendingPathComponent("Media", isDirectory: true))
        documentFiles = DocumentFileCache(directory: URL.cachesDirectory.appendingPathComponent("RoamReadyDocuments", isDirectory: true))
    }

    private func serializeLifecycle(_ operation: @escaping @MainActor () async -> Void) async {
        let previous = lifecycleTask, id = UUID()
        lifecycleID = id
        let task = Task { await previous?.value; await operation() }
        lifecycleTask = task
        await task.value
        if lifecycleID == id { lifecycleTask = nil }
    }
    func load(online: Bool = true) async {
        wantsLibraryAccess = true
        await serializeLifecycle { [self] in
            guard wantsLibraryAccess else { return }
            await performLoad(online: online)
        }
    }
    private func performLoad(online: Bool = true) async {
        guard !didLoad, !loadInProgress, wantsLibraryAccess else { return }
        loadInProgress = true; isLoading = true; isTransitioning = true
        let generation = libraryGeneration
        defer { loadInProgress = false; isLoading = false; isTransitioning = false }
        do {
            var database: SQLiteStore
            if let disk { database = disk } else {
                let local = try await SQLiteStore.open(directory: directory)
                guard generation == libraryGeneration else { try? await local.close(); return }
                let identifier = cloudSuppressed ? nil : await sync.containerForLaunch(store: local, online: online)
                guard generation == libraryGeneration else { try? await local.close(); return }
                if let identifier {
                    try await local.close()
                    database = try await SQLiteStore.open(directory: directory, cloudContainerIdentifier: identifier)
                } else { database = local }
                guard generation == libraryGeneration else { try? await database.close(); return }
                disk = database
            }
            await sync.configure(store: database, suspendMirroring: { [weak self] in
                await self?.suspendCloudMirroring()
            }) { [weak self] in
                guard let self else { return }
                if self.didLoad { await self.refreshFromDisk() } else { await self.load() }
            }
            let legacySaved = Set((UserDefaults.standard.string(forKey: "savedCampgroundIDs") ?? "").split(separator: ",").map(String.init))
            var restored = try await database.migrateLegacy(archiveURL: archiveURL, favorites: legacySaved)
            if let recovery = suspendedUnsaved {
                try await database.save(from: recovery.baseline, to: recovery.desired)
                restored = try await database.snapshot()
            }
            let notice = try await database.metadata("migrationNotice").flatMap { String(data: $0, encoding: .utf8) }
            // A document listing problem must not block access to trips.
            let loadedDocuments = (try? await database.documents(ownedBy: nil)) ?? []
            guard generation == libraryGeneration else { return }
            documents = loadedDocuments
            suspendedUnsaved = nil; saveFailure = nil; presentsSaveFailure = false
            baseline = restored; state = restored.state; savedCampgrounds = restored.saved
            libraryNotice = notice
            didLoad = true; loadFailure = nil; lastSavedAt = .now
        } catch {
            guard generation == libraryGeneration else { return }
            loadFailure = "RoamReady couldn’t open its local library. Your database, legacy archive, and photos have been preserved. \(error.localizedDescription)"
        }
    }

    /// Account UI locks immediately. Preserve failed writes for the same pinned owner.
    func suspendLibrary() async {
        wantsLibraryAccess = false; libraryGeneration += 1
        isTransitioning = true
        await serializeLifecycle { [self] in
            await saveTask?.value
            preserveFailedChanges()
            sync.tearDown()
            if let disk { try? await disk.close() }
            disk = nil; didLoad = false; baseline = LibrarySnapshot()
            state = AppState(); savedCampgrounds = [:]; mediaRevision += 1
            documents = []; documentFiles.removeAll()
            loadFailure = nil; presentsSaveFailure = false; isLoading = false
            isTransitioning = false
        }
    }
    /// Erase all data: close the library and delete everything RoamReady keeps on this device:
    /// the Core Data stores and backups, Media, the forecast cache, document caches and imports,
    /// and stored preferences. The caller has already deleted the iCloud data.
    func eraseLibrary() async throws {
        await suspendLibrary()
        let fileManager = FileManager.default
        for location in [directory, documentFiles.directory, DocumentImport.directory] where fileManager.fileExists(atPath: location.path) {
            try fileManager.removeItem(at: location)
        }
        if let domain = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: domain) }
        suspendedUnsaved = nil; saveFailure = nil; libraryNotice = nil
    }

    private func preserveFailedChanges() {
        if saveFailure != nil, didLoad {
            suspendedUnsaved = (baseline, library)
        }
    }
    /// After an iCloud account change, reopen local-only until the person retries or relaunches.
    private func suspendCloudMirroring() async {
        cloudSuppressed = true
        await reopenLibrary()
    }
    /// Applies the iCloud setting now. Reopening never deletes local data or the iCloud copy.
    func setCloudSync(_ enabled: Bool) async {
        sync.setRequested(enabled)
        cloudSuppressed = false
        await reopenLibrary()
    }
    /// Re-checks the iCloud account, e.g. after signing in to iCloud in Settings.
    func retryCloudSync() async {
        cloudSuppressed = false
        await reopenLibrary()
    }
    private func reopenLibrary() async {
        await serializeLifecycle { [self] in
            guard wantsLibraryAccess else { return }
            isTransitioning = true; isLoading = true
            await saveTask?.value
            preserveFailedChanges()
            sync.tearDown()
            if let disk { try? await disk.close() }
            disk = nil; didLoad = false
            await performLoad()
            isTransitioning = false; isLoading = false
        }
    }
    func resumeMirroringIfNeeded() async {
        await serializeLifecycle { [self] in
            guard wantsLibraryAccess, didLoad, sync.waitingForConnection, !sync.enabled else { return }
            isTransitioning = true; isLoading = true
            defer { isTransitioning = false; isLoading = false }
            await saveTask?.value
            guard saveFailure == nil else { return }
            sync.tearDown()
            if let disk { try? await disk.close() }
            disk = nil; didLoad = false; cloudSuppressed = false
            await performLoad()
        }
    }

    var library: LibrarySnapshot { LibrarySnapshot(state: state, saved: savedCampgrounds) }

    /// "Been here" also follows completed trips unless the owner chose otherwise.
    func isCampground(_ id: String, on list: CampgroundList) -> Bool { library.isCampground(id, on: list) }

    func setCampground(_ id: String, name: String, region: String, on list: CampgroundList, _ included: Bool) {
        guard !isTransitioning, wantsLibraryAccess else { return }
        var next = library
        next.setCampground(id, name: name, region: region, on: list, included)
        savedCampgrounds = next.saved
        persist()
    }
    func exportLibrary() async throws -> URL {
        await saveTask?.value
        guard let disk, saveFailure == nil else { throw CocoaError(.fileWriteUnknown) }
        // Includes readable copies of every document, so it is protected like the store and
        // replaced on each export rather than accumulating.
        let url = directory.appendingPathComponent("Exports/RoamReady Export.zip")
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("Exports/RoamReady.json"))
        try await disk.exportArchive(to: url)
        documentFiles.protect(url)
        return url
    }
    func revisions(for tripID: UUID) async throws -> [NoteRevision] {
        guard let disk else { return [] }
        return try await disk.noteRevisions(tripID: tripID)
    }
    func photoURL(filename: String) async throws -> URL {
        guard let url = media.url(for: filename) else { throw CampUIError.unreadablePhoto }
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let disk, let bytes = try await disk.asset(filename: filename) else { throw ReplicationError.missingAsset }
        try await media.restore(bytes, filename: filename)
        return url
    }
    private func refreshFromDisk() async {
        guard didLoad, !isTransitioning, wantsLibraryAccess, saveTask == nil, let disk else { return }
        let revision = saveRevision, generation = libraryGeneration
        do {
            let fresh = try await disk.snapshot()
            let notice = try await disk.metadata("migrationNotice").flatMap { String(data: $0, encoding: .utf8) }
            if let latest = try? await disk.documents(ownedBy: nil), generation == libraryGeneration { documents = latest }
            guard revision == saveRevision, generation == libraryGeneration, wantsLibraryAccess, !isTransitioning, saveTask == nil else { return }
            baseline = fresh; state = fresh.state; savedCampgrounds = fresh.saved
            libraryNotice = notice; mediaRevision += 1
        } catch {
            guard generation == libraryGeneration, wantsLibraryAccess else { return }
            libraryNotice = "Waiting for related records. Your current library is preserved. \(error.localizedDescription)"
        }
    }

    // MARK: Documents

    func documents(for owner: DocumentOwner) -> [ManagedDocument] { documents.filter { $0.owner == owner } }
    func document(_ id: UUID) -> ManagedDocument? { documents.first { $0.id == id } }

    /// Documents whose trip was deleted or whose rig was replaced. They stay until deleted deliberately.
    var unattachedDocuments: [ManagedDocument] {
        documents.filter { document in
            document.owner.kind == .trip ? trip(document.owner.id) == nil : state.rig(document.owner.id) == nil
        }
    }

    private func documentRepository() throws -> SQLiteStore {
        guard didLoad, !isTransitioning, wantsLibraryAccess, let disk else { throw CampUIError.libraryBusy }
        return disk
    }

    @discardableResult
    func addDocument(_ draft: DocumentDraft) async throws -> ManagedDocument {
        let added = try await documentRepository().addDocument(draft)
        await reloadDocuments()
        return added
    }

    func updateDocument(_ id: UUID, metadata: DocumentMetadata) async throws {
        try await documentRepository().updateDocument(id: id, metadata: metadata)
        await reloadDocuments()
    }

    /// Explicit user action: download a link's contents so it opens offline.
    func saveLinkedContentsOffline(_ id: UUID) async throws {
        guard let link = document(id)?.link else { throw DocumentError.notALink }
        let repository = try documentRepository()
        // Leaving the app mid-download should not lose a copy the user asked for. If iOS ends the
        // extra time, the download is cancelled and nothing partial is saved.
        let work = Task { () throws -> Void in
            let download = try await DocumentImport.download(link)
            defer { DocumentImport.discard(download.url) }
            try Task.checkCancellation()
            try await repository.attachContent(toDocument: id, source: .file(download.url), filename: download.filename)
        }
        let activity = BackgroundActivity(name: "Save document for offline use") { work.cancel() }
        defer { activity.end() }
        try await work.value
        await reloadDocuments()
    }

    func deleteDocument(_ id: UUID) async throws {
        try await documentRepository().deleteDocument(id: id)
        await reloadDocuments()
    }

    /// A readable file containing the verified original bytes, rebuilt from the store if needed.
    func documentFileURL(_ id: UUID) async throws -> URL {
        guard let file = document(id)?.file else { throw DocumentError.linkOnly }
        if let cached = documentFiles.cachedURL(for: file) { return cached }
        // Decrypted and verified chunk by chunk straight into the cache file.
        let destination = documentFiles.url(for: file)
        try await documentRepository().exportContents(ofDocument: id, to: destination)
        documentFiles.protect(destination)
        return destination
    }

    /// From this device's mirroring records; refreshed by sync events through `mediaRevision`.
    func cloudStatus(ofDocument id: UUID) async -> DocumentCloudStatus? {
        guard let disk = try? documentRepository() else { return nil }
        return try? await disk.cloudStatus(ofDocument: id)
    }

    private func reloadDocuments() async {
        guard let disk else { return }
        let generation = libraryGeneration
        guard let latest = try? await disk.documents(ownedBy: nil), generation == libraryGeneration, wantsLibraryAccess else { return }
        documents = latest
    }

    // MARK: Profile, rigs, and default checklists. All of these work offline.

    /// The rig new trips use in v1, where each owner has one active rig.
    var activeRig: Rig? { state.activeRigs.first }
    func rig(for trip: Trip) -> Rig? { state.rig(for: trip) }

    /// Applies a change through CampCore's rules, then saves. Nothing changes if a rule refuses it.
    private func mutate(_ change: (inout AppState) throws -> Void) throws {
        guard !isTransitioning, wantsLibraryAccess else { throw CampUIError.libraryBusy }
        var next = state
        try change(&next)
        _ = try next.validated()
        state = next
        persist()
    }

    /// Onboarding creates the profile, the first rig, and that rig's default checklists.
    func finishOnboarding(_ profile: CamperProfile, rig: Rig) throws {
        try mutate { state in
            state.profile = profile
            if state.rig(rig.id) == nil { try state.addRig(rig) }
        }
    }

    func updateProfile(_ profile: CamperProfile) throws {
        try mutate { $0.profile = profile }
    }

    /// Editing a rig changes what every trip using it shows. Defaults are regenerated only on request.
    func updateRig(_ rig: Rig, regenerateDefaults: Bool = false) throws {
        try mutate { state in
            try state.updateRig(rig)
            if regenerateDefaults { try state.resetDefaults(for: rig.id) }
        }
    }

    /// Archive the current rig and add its replacement. Past trips keep showing the old one.
    func replaceRig(_ id: UUID, with replacement: Rig) throws {
        try mutate { try $0.replaceRig(id, with: replacement) }
    }
    func addRig(_ rig: Rig) throws { try mutate { try $0.addRig(rig) } }
    func archiveRig(_ id: UUID) throws { try mutate { try $0.archiveRig(id) } }
    func unarchiveRig(_ id: UUID) throws { try mutate { try $0.unarchiveRig(id) } }
    func deleteRig(_ id: UUID) throws { try mutate { try $0.deleteRig(id) } }

    /// Replaces the rig's defaults. Existing trips are never touched.
    func updateDefaults(_ templates: ChecklistTemplates, for rigID: UUID) throws {
        try mutate { state in
            guard state.rig(rigID) != nil else { throw CampError.rigNotFound }
            state.setDefaults(templates, for: rigID)
        }
    }

    func resetDefaults(for rigID: UUID) throws {
        try mutate { try $0.resetDefaults(for: rigID) }
    }

    /// The rig's defaults, or the lists its type generates if it has none yet.
    func defaults(for rig: Rig) -> ChecklistTemplates {
        state.defaults(for: rig.id) ?? ChecklistFactory.templates(for: rig)
    }

    // MARK: Trips

    /// Creating a trip is entering the booking. `draft` carries the campground and booking fields;
    /// the trip's checklists are fresh copies of the chosen rig's defaults.
    @discardableResult
    func createTrip(from draft: Trip, rigID: UUID) throws -> UUID {
        var created: Trip?
        try mutate { state in
            created = try state.createTrip(campgroundName: draft.campgroundName, arrival: draft.arrival, departure: draft.departure,
                                           rigID: rigID, latitude: draft.latitude, longitude: draft.longitude,
                                           campgroundID: draft.campgroundID,
                                           campgroundTimeZoneIdentifier: draft.campgroundTimeZoneIdentifier) { trip in
                trip.copyBookingDetails(from: draft)
            }
        }
        return created!.id
    }

    func trip(_ id: UUID) -> Trip? { state.trips.first { $0.id == id } }

    func editTrip(_ id: UUID, _ change: (inout Trip) -> Void) {
        guard !isTransitioning, wantsLibraryAccess else { return }
        guard let index = state.trips.firstIndex(where: { $0.id == id }) else { return }
        change(&state.trips[index])
        persist()
    }

    /// Cancelling a trip deletes it with its checklists, notes and note history, photos, and rating,
    /// on every device after sync. Its documents move to Unattached documents.
    func deleteTrip(_ id: UUID) {
        guard !isTransitioning, wantsLibraryAccess else { return }
        state.trips.removeAll { $0.id == id }
        // Photo bytes no longer referenced are purged in the same commit that removes the trip.
        persist()
    }

    /// Marks a trip complete before its dates end (#31). Trips also complete on their own once the
    /// day after departure begins; that needs no write.
    func markTripComplete(_ id: UUID, _ complete: Bool = true) {
        editTrip(id) { $0.completedAt = complete ? ($0.completedAt ?? .now) : nil }
    }

    /// "Save as defaults for <rig>": writes only to the trip's own rig.
    func saveAsDefaults(_ tripID: UUID) throws {
        try mutate { try $0.saveTripChecklistsAsDefaults(tripID) }
    }

    func dismissSaveFailure() { presentsSaveFailure = false }
    func retrySave() { persist() }

    private func persist() {
        guard didLoad, !isTransitioning, wantsLibraryAccess else { return }
        saveRevision += 1
        pendingSave = (saveRevision, library)
        isSaving = true
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            guard let self else { return }
            await self.drainWrites()
        }
    }

    private func drainWrites() async {
        // A newer complete snapshot subsumes older unsaved keystrokes. One write is in flight.
        guard let disk else { return }
        while let pending = pendingSave {
            pendingSave = nil
            do {
                try await disk.save(from: baseline, to: pending.library)
                baseline = pending.library
                if pending.revision == saveRevision {
                    lastSavedAt = .now
                    saveFailure = nil
                    presentsSaveFailure = false
                }
            } catch {
                if pending.revision == saveRevision {
                    saveFailure = "Your latest changes have not been saved to this iPhone. \(error.localizedDescription)"
                    presentsSaveFailure = true
                }
            }
        }
        isSaving = false
        saveTask = nil
        if saveFailure == nil { await refreshFromDisk() }
    }

    func flushForBackground() async {
        guard saveTask != nil else { return }
        let token = UIApplication.shared.beginBackgroundTask(withName: "Save camping changes")
        defer { if token != .invalid { UIApplication.shared.endBackgroundTask(token) } }
        await saveTask?.value
    }
}

/// Extra execution time while a user-requested operation finishes after the app leaves the
/// foreground. The expiration handler ends the activity synchronously, as UIKit requires.
@MainActor
final class BackgroundActivity {
    private var identifier = UIBackgroundTaskIdentifier.invalid
    init(name: String, onExpiration: @escaping @MainActor @Sendable () -> Void) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated {
                onExpiration()
                self?.end()
            }
        }
    }
    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

enum CampUIError: LocalizedError {
    case missingRig, unreadablePhoto, libraryBusy
    var errorDescription: String? {
        switch self {
        case .libraryBusy: "Your library is reopening. Please try again in a moment."
        case .missingRig: "Add a rig in Profile before adding a trip."
        case .unreadablePhoto: "This photo couldn’t be opened. If it’s stored in iCloud Photos, download it while online and try again."
        }
    }
}
