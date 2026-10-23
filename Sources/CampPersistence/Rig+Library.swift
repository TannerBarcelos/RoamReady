#if canImport(SwiftData)
import Foundation
import SwiftData
import CampCore

/// Rig rules. Every rule is enforced here, not only in the UI.
public extension Rig {
    var photoData: Data? { protectedPhoto ?? photo }
    var isArchived: Bool { archivedAt != nil }
    var activeTrips: [Trip] { (trips ?? []).filter { !$0.isDeleted } }
    var attachedDocuments: [StoredDocument] { (documents ?? []).filter { !$0.isDeleted }.sorted { $0.createdAt > $1.createdAt } }

    var draft: RigDraft {
        RigDraft(type: type, make: make, model: model, year: year, floorplan: floorplan, emoji: emoji, photo: photoData,
                 equipment: equipment, lengthFeet: lengthFeet, slideCount: slideCount, axleCount: axleCount, hasBunkhouse: hasBunkhouse)
    }

    /// Adds an active rig with default lists generated from its type.
    @discardableResult
    static func add(_ draft: RigDraft, to context: ModelContext) throws -> Rig {
        try draft.validateDetails()
        guard try context.activeRigs().count < RigPolicy.maxActiveRigs else { throw CampError.rigLimitReached }
        let rig = Rig()
        context.insert(rig)
        rig.apply(draft)
        rig.setDefaults(ChecklistFactory.template(for: draft))
        return rig
    }

    /// Edits the rig in place, so every trip that uses it shows the new details, past trips included.
    func update(_ draft: RigDraft, regenerateDefaults: Bool = false) throws {
        try draft.validateDetails()
        apply(draft)
        if regenerateDefaults { resetDefaults() }
    }

    /// "Replace rig": archive this rig and add the new one. Past trips keep showing this one.
    @discardableResult
    func replace(with draft: RigDraft) throws -> Rig {
        guard let modelContext else { preconditionFailure("Only a rig in a library can be replaced") }
        archivedAt = .now
        do { return try Rig.add(draft, to: modelContext) } catch { archivedAt = nil; throw error }
    }

    func archive() { if archivedAt == nil { archivedAt = .now } }

    func unarchive() throws {
        guard isArchived else { return }
        guard try (modelContext?.activeRigs().count ?? 0) < RigPolicy.maxActiveRigs else { throw CampError.rigLimitReached }
        archivedAt = nil
    }

    /// Only while no trip uses the rig. Its default lists go with it; its documents become unattached.
    func delete() throws {
        guard activeTrips.isEmpty else { throw CampError.rigInUse }
        modelContext?.delete(self)
    }

    /// The rig's default lists, or the lists its type generates if it has none.
    var defaultTemplate: ChecklistTemplate {
        let steps = (defaultSteps ?? []).filter { !$0.isDeleted }
        guard !steps.isEmpty else { return ChecklistFactory.template(for: self) }
        var template = ChecklistTemplate()
        for phase in ChecklistPhase.allCases {
            template[phase] = steps.filter { $0.phase == phase }.sorted { $0.position < $1.position }.map(\.draft)
        }
        return template
    }

    /// Replaces the default lists with pending copies. Existing trips are never touched.
    func setDefaults(_ template: ChecklistTemplate) {
        guard let modelContext else { return }
        for step in defaultSteps ?? [] { modelContext.delete(step) }
        for phase in ChecklistPhase.allCases {
            for (position, draft) in template[phase].enumerated() {
                let step = ChecklistStep.make(draft, phase: phase, position: position, pending: true, in: modelContext)
                step.rig = self
            }
        }
    }

    /// "Reset defaults": regenerate from the rig's type. Existing trips are never touched.
    func resetDefaults() { setDefaults(ChecklistFactory.template(for: self)) }

    private func apply(_ draft: RigDraft) {
        type = draft.type; make = draft.make; model = draft.model; year = draft.year
        floorplan = draft.floorplan; emoji = draft.emoji; protectedPhoto = draft.photo; photo = nil; equipment = draft.equipment
        lengthFeet = draft.lengthFeet; slideCount = draft.slideCount; axleCount = draft.axleCount
        hasBunkhouse = draft.hasBunkhouse
    }
}

public extension ChecklistStep {
    var draft: ChecklistStepDraft {
        ChecklistStepDraft(title: title, detail: detail, section: section, status: status)
    }

    func apply(_ draft: ChecklistStepDraft) {
        title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        detail = draft.detail; section = draft.section; status = draft.status
    }

    var isFinished: Bool { status != .pending }

    static func make(_ draft: ChecklistStepDraft, phase: ChecklistPhase, position: Int, pending: Bool,
                     in context: ModelContext) -> ChecklistStep {
        let step = ChecklistStep()
        context.insert(step)
        step.apply(draft)
        if pending { step.status = .pending }
        step.phase = phase; step.position = position
        return step
    }
}
#endif
