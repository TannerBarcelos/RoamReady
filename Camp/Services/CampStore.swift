import Foundation
import Observation
import CampCore
import UIKit

/// The UI only reads local state. Writes are serialized and retained in memory on failure.
@MainActor @Observable
final class CampStore {
    private(set) var state = AppState()
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
    @ObservationIgnored private let disk: FileAppStore
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var saveRevision = 0
    @ObservationIgnored private var pendingSave: (revision: Int, state: AppState)?
    @ObservationIgnored private var didLoad = false

    var archiveURL: URL { directory.appendingPathComponent("camp-state.json") }

    init() {
        directory = URL.applicationSupportDirectory.appendingPathComponent("Camp", isDirectory: true)
        disk = FileAppStore(directory: directory)
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
        guard !didLoad else { return }
        isLoading = true
        do {
            state = try await disk.load()
            didLoad = true
            loadFailure = nil
        } catch {
            loadFailure = "Camp couldn’t open its saved file. Nothing has been deleted or replaced. \(error.localizedDescription)"
        }
        isLoading = false
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
        pendingSave = (saveRevision, state)
        isSaving = true
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            guard let self else { return }
            await self.drainWrites()
        }
    }

    private func drainWrites() async {
        // A newer complete snapshot subsumes older unsaved keystrokes. One write is in flight.
        while let pending = pendingSave {
            pendingSave = nil
            do {
                try await disk.save(pending.state)
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
