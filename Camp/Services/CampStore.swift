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
    let sync = CloudSyncController()
    private(set) var isLoading = true
    private(set) var loadFailure: String?
    private(set) var saveFailure: String?
    private(set) var presentsSaveFailure = false
    private(set) var isSaving = false
    private(set) var lastSavedAt: Date?
    let directory: URL
    let media: MediaStore
    let catalog: [RigCatalogRecord]
    let catalogNotice: String
    @ObservationIgnored private var disk: SQLiteStore?
    @ObservationIgnored private var baseline = LibrarySnapshot()
    @ObservationIgnored private var loadInProgress = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var saveRevision = 0
    @ObservationIgnored private var pendingSave: (revision: Int, library: LibrarySnapshot)?
    @ObservationIgnored private var didLoad = false

    var archiveURL: URL { directory.appendingPathComponent("camp-state.json") }

    init() {
        directory = URL.applicationSupportDirectory.appendingPathComponent("Camp", isDirectory: true)
        media = MediaStore(directory: directory.appendingPathComponent("Media", isDirectory: true))
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

    func load() async {
        guard !didLoad, !loadInProgress else { return }
        loadInProgress = true; isLoading = true
        defer { loadInProgress = false; isLoading = false }
        do {
            let database: SQLiteStore
            if let disk { database = disk } else {
                database = try await SQLiteStore.open(directory: directory)
                disk = database
            }
            await sync.configure(store: database) { [weak self] in
                guard let self else { return }
                if self.didLoad { await self.refreshFromDisk() } else { await self.load() }
            }
            let legacySaved = Set((UserDefaults.standard.string(forKey: "savedCampgroundIDs") ?? "").split(separator: ",").map(String.init))
            let restored = try await database.migrateLegacy(archiveURL: archiveURL, favorites: legacySaved)
            baseline = restored; state = restored.state; savedCampgroundIDs = restored.favorites
            didLoad = true; loadFailure = nil; lastSavedAt = .now
        } catch {
            loadFailure = "RoamReady couldn’t open its local library. Your database, legacy archive, and photos have been preserved. \(error.localizedDescription)"
        }
    }

    func toggleSavedCampground(_ id: String) {
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
        guard didLoad, saveTask == nil, let disk else { return }
        let revision = saveRevision
        do {
            let fresh = try await disk.snapshot()
            guard revision == saveRevision, saveTask == nil else { return }
            baseline = fresh; state = fresh.state; savedCampgroundIDs = fresh.favorites
            libraryNotice = nil; mediaRevision += 1
        } catch { libraryNotice = "Waiting for related records. Your current library is preserved. \(error.localizedDescription)" }
    }

    func finishOnboarding(_ profile: CamperProfile) {
        state.profile = profile
        state.templates = ChecklistFactory.templates(for: profile.rig)
        persist()
    }

    func updateProfile(_ profile: CamperProfile, rebuildTemplates: Bool = false) {
        state.profile = profile
        if rebuildTemplates { state.templates = ChecklistFactory.templates(for: profile.rig) }
        persist()
    }

    func updateTemplates(_ templates: ChecklistTemplates) {
        var fresh = templates
        fresh.id = UUID()
        fresh.setup = templates.setup.map { $0.freshCopy() }
        fresh.teardown = templates.teardown.map { $0.freshCopy() }
        state.templates = fresh
        persist()
    }

    func resetTemplatesForRig() {
        guard let rig = state.profile?.rig else { return }
        state.templates = ChecklistFactory.templates(for: rig)
        persist()
    }

    @discardableResult
    func createTrip(name: String, arrival: Date, departure: Date, site: String,
                    campground: Campground?) throws -> UUID {
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
        guard let index = state.trips.firstIndex(where: { $0.id == id }) else { return }
        change(&state.trips[index])
        persist()
    }

    func deleteTrip(_ id: UUID) {
        state.trips.removeAll { $0.id == id }
        // Retain media until a later successful garbage-collection pass, never delete before commit.
        persist()
    }

    func saveAsTemplate(_ id: UUID) {
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
        guard didLoad else { return }
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
        if saveFailure == nil { await refreshFromDisk(); sync.schedule() }
    }

    func flushForBackground() async {
        guard saveTask != nil else { return }
        let token = UIApplication.shared.beginBackgroundTask(withName: "Save camping changes")
        defer { if token != .invalid { UIApplication.shared.endBackgroundTask(token) } }
        await saveTask?.value
    }
}

enum CampUIError: LocalizedError {
    case missingRig, unreadablePhoto
    var errorDescription: String? {
        switch self {
        case .missingRig: "Add your rig before planning a trip."
        case .unreadablePhoto: "This photo couldn’t be opened. If it’s stored in iCloud Photos, download it while online and try again."
        }
    }
}
