import Foundation
import Observation
import CampCore
import CampPersistence
import UIKit

/// The UI only reads local state. Writes are serialized and retained in memory on failure.
@MainActor @Observable
final class CampStore {
    private(set) var state = AppState()
    private(set) var savedCampgroundIDs: Set<String> = []
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
    let catalog: [RigCatalogRecord]
    let catalogNotice: String
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
        if let url = Bundle.main.url(forResource: "rig-catalog", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? RigCatalog.decode(data) {
            catalog = decoded.records
            catalogNotice = decoded.coverageNote
        } else {
            catalog = []
            catalogNotice = "The catalog is unavailable. You can still enter your rig manually."
        }
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
            baseline = restored; state = restored.state; savedCampgroundIDs = restored.favorites
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
            state = AppState(); savedCampgroundIDs = []; mediaRevision += 1
            documents = []; documentFiles.removeAll()
            loadFailure = nil; presentsSaveFailure = false; isLoading = false
            isTransitioning = false
        }
    }
    private func preserveFailedChanges() {
        if saveFailure != nil, didLoad {
            suspendedUnsaved = (baseline, LibrarySnapshot(state: state, favorites: savedCampgroundIDs))
        }
    }
    private func suspendCloudMirroring() async {
        cloudSuppressed = true
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

    func toggleSavedCampground(_ id: String) {
        guard !isTransitioning, wantsLibraryAccess else { return }
        if savedCampgroundIDs.contains(id) { savedCampgroundIDs.remove(id) }
        else { savedCampgroundIDs.insert(id) }
        persist()
    }
    func exportLibrary() async throws -> URL {
        await saveTask?.value
        guard let disk, saveFailure == nil else { throw CocoaError(.fileWriteUnknown) }
        let url = directory.appendingPathComponent("Exports/RoamReady.json")
        try await disk.export(to: url)
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
            baseline = fresh; state = fresh.state; savedCampgroundIDs = fresh.favorites
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
            document.owner.kind == .trip ? trip(document.owner.id) == nil : document.owner.id != state.profile?.rig.id
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

    private func reloadDocuments() async {
        guard let disk else { return }
        let generation = libraryGeneration
        guard let latest = try? await disk.documents(ownedBy: nil), generation == libraryGeneration, wantsLibraryAccess else { return }
        documents = latest
    }

    func finishOnboarding(_ profile: CamperProfile) {
        guard !isTransitioning, wantsLibraryAccess else { return }
        state.profile = profile
        state.templates = ChecklistFactory.templates(for: profile.rig)
        persist()
    }

    func updateProfile(_ profile: CamperProfile, rebuildTemplates: Bool = false) {
        guard !isTransitioning, wantsLibraryAccess else { return }
        state.profile = profile
        if rebuildTemplates { state.templates = ChecklistFactory.templates(for: profile.rig) }
        persist()
    }

    func updateTemplates(_ templates: ChecklistTemplates) {
        guard !isTransitioning, wantsLibraryAccess else { return }
        var fresh = templates
        fresh.id = UUID()
        fresh.setup = templates.setup.map { $0.freshCopy() }
        fresh.teardown = templates.teardown.map { $0.freshCopy() }
        state.templates = fresh
        persist()
    }

    func resetTemplatesForRig() {
        guard !isTransitioning, wantsLibraryAccess else { return }
        guard let rig = state.profile?.rig else { return }
        state.templates = ChecklistFactory.templates(for: rig)
        persist()
    }

    @discardableResult
    func createTrip(name: String, arrival: Date, departure: Date, site: String,
                    campground: Campground?) throws -> UUID {
        guard !isTransitioning, wantsLibraryAccess else { throw CampUIError.libraryBusy }
        guard let rig = state.profile?.rig else { throw CampUIError.missingRig }
        var trip = try Trip.create(campgroundName: name, arrival: arrival, departure: departure,
                                   rig: rig, templates: state.templates,
                                   latitude: campground?.latitude, longitude: campground?.longitude)
        trip.siteNumber = site
        trip.campgroundID = campground?.id
        trip.campgroundTimeZoneIdentifier = campground?.timeZoneIdentifier
        state.trips.append(trip)
        persist()
        return trip.id
    }

    func trip(_ id: UUID) -> Trip? { state.trips.first { $0.id == id } }

    func editTrip(_ id: UUID, _ change: (inout Trip) -> Void) {
        guard !isTransitioning, wantsLibraryAccess else { return }
        guard let index = state.trips.firstIndex(where: { $0.id == id }) else { return }
        change(&state.trips[index])
        persist()
    }

    func deleteTrip(_ id: UUID) {
        guard !isTransitioning, wantsLibraryAccess else { return }
        state.trips.removeAll { $0.id == id }
        // Retain media until a later successful garbage-collection pass, never delete before commit.
        persist()
    }

    func saveAsTemplate(_ id: UUID) {
        guard !isTransitioning, wantsLibraryAccess else { return }
        guard let trip = trip(id), var templates = state.templates else { return }
        templates.id = UUID()
        templates.setup = trip.setup.map { item in
            var copy = item; copy.id = UUID(); copy.status = .pending; return copy
        }
        templates.teardown = trip.teardown.map { item in
            var copy = item; copy.id = UUID(); copy.status = .pending; return copy
        }
        state.templates = templates
        persist()
    }

    func dismissSaveFailure() { presentsSaveFailure = false }
    func retrySave() { persist() }

    private func persist() {
        guard didLoad, !isTransitioning, wantsLibraryAccess else { return }
        saveRevision += 1
        pendingSave = (saveRevision, LibrarySnapshot(state: state, favorites: savedCampgroundIDs))
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
        case .missingRig: "Add your rig before planning a trip."
        case .unreadablePhoto: "This photo couldn’t be opened. If it’s stored in iCloud Photos, download it while online and try again."
        }
    }
}
