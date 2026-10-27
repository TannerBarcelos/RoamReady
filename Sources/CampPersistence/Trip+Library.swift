import Foundation
import SwiftData
import CampCore

/// Trip rules: creating a trip is entering the booking, and its checklists are its own.
public extension Trip {
    /// Creates the trip with pending copies of the rig's default lists. After this the trip's lists
    /// are independent of the rig's defaults.
    @discardableResult
    static func create(_ draft: TripDraft, rig: Rig, in context: ModelContext) throws -> Trip {
        let details = draft.cleaned
        try details.validate()
        guard !rig.isArchived else { throw CampError.rigArchived }
        let trip = Trip()
        context.insert(trip)
        trip.apply(details)
        trip.notes = details.notes
        trip.rig = rig
        let template = rig.defaultTemplate
        for phase in ChecklistPhase.allCases {
            for (position, step) in template[phase].enumerated() {
                ChecklistStep.make(step, phase: phase, position: position, pending: true, in: context).trip = trip
            }
        }
        return trip
    }

    /// Edits the booking. Checklists, progress, notes, and photos are never reset, and changing the
    /// rig doesn't replace the trip's checklists.
    func update(_ draft: TripDraft, rig: Rig?) throws {
        let details = draft.cleaned
        try details.validate()
        apply(details)
        self.rig = rig
    }

    func steps(_ phase: ChecklistPhase) -> [ChecklistStep] {
        (steps ?? []).filter { $0.phase == phase && !$0.isDeleted }.sorted { $0.position < $1.position }
    }

    func addStep(_ draft: ChecklistStepDraft, to phase: ChecklistPhase) {
        guard let modelContext else { return }
        let position = (steps(phase).last?.position ?? -1) + 1
        ChecklistStep.make(draft, phase: phase, position: position, pending: false, in: modelContext).trip = self
    }

    /// Stores the order the list now has, e.g. after a drag.
    func reorder(_ ordered: [ChecklistStep]) {
        for (position, step) in ordered.enumerated() where step.position != position { step.position = position }
    }

    func removeSteps(_ removed: [ChecklistStep]) {
        for step in removed { modelContext?.delete(step) }
    }

    /// "Save as defaults for <rig>": the trip's lists become its own rig's defaults, unchecked.
    /// Writes only to that rig.
    func saveChecklistsAsDefaults() throws {
        guard let rig else { throw CampError.rigUnavailable }
        rig.setDefaults(ChecklistTemplate(setup: steps(.setup).map(\.draft), teardown: steps(.teardown).map(\.draft)))
    }

    /// Marks the trip complete before its dates end (#31), or reopens it.
    func setCompleted(_ complete: Bool, at date: Date = .now) {
        completedAt = complete ? (completedAt ?? date) : nil
    }

    var sortedPhotos: [TripPhoto] { (photos ?? []).filter { !$0.isDeleted }.sorted { $0.createdAt < $1.createdAt } }
    var attachedDocuments: [StoredDocument] { (documents ?? []).filter { !$0.isDeleted }.sorted { $0.createdAt > $1.createdAt } }
    var revisions: [NoteRevision] { (noteRevisions ?? []).filter { !$0.isDeleted }.sorted { $0.createdAt > $1.createdAt } }

    func addPhoto(_ jpeg: Data) {
        guard let modelContext else { return }
        let photo = TripPhoto(image: jpeg)
        modelContext.insert(photo)
        photo.trip = self
    }

    /// Keeps the current notes as a version that can be restored later, unless they're already the
    /// latest version.
    func saveNoteRevision() {
        guard let modelContext, !notes.isEmpty, revisions.first?.body != notes else { return }
        let revision = NoteRevision(body: notes)
        modelContext.insert(revision)
        revision.trip = self
    }

    private func apply(_ draft: TripDraft) {
        campgroundName = draft.campgroundName; campgroundID = draft.campgroundID
        latitude = draft.latitude; longitude = draft.longitude
        arrival = draft.arrival; departure = draft.departure
        planningTimeZoneIdentifier = draft.planningTimeZoneIdentifier
        campgroundTimeZoneIdentifier = draft.campgroundTimeZoneIdentifier
        siteNumber = draft.siteNumber; loop = draft.loop; site = draft.site; confirmationNumber = draft.confirmationNumber
        bookingProvider = draft.bookingProvider; bookingURL = draft.bookingURL
        checkInMinutes = draft.checkInMinutes; checkOutMinutes = draft.checkOutMinutes
        totalCost = draft.totalCost; amountPaid = draft.amountPaid
        cancellationDeadline = draft.cancellationDeadline; completedAt = draft.completedAt
    }
}
