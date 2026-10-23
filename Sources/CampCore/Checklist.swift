import Foundation

public enum ChecklistStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case pending, completed, skipped
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public enum ChecklistPhase: String, Codable, CaseIterable, Identifiable, Sendable {
    case setup, teardown
    public var id: String { rawValue }
    public var title: String { self == .setup ? "Setup" : "Teardown" }
}

/// One step's editable content: a generated template step, a rig default, or a step being edited.
public struct ChecklistStepDraft: Equatable, Identifiable, Codable, Sendable {
    public var id = UUID()
    public var title: String
    public var detail: String
    public var section: String
    public var status: ChecklistStatus
    public init(title: String, detail: String = "", section: String = "My checklist", status: ChecklistStatus = .pending) {
        self.title = title; self.detail = detail; self.section = section; self.status = status
    }
    /// Equal content, whatever the identity: generated and copied steps get fresh identities.
    public static func == (a: Self, b: Self) -> Bool {
        a.title == b.title && a.detail == b.detail && a.section == b.section && a.status == b.status
    }
    public var isFinished: Bool { status != .pending }
    public var hasTitle: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// A setup and teardown list, as generated for a rig type or copied from a rig's defaults.
public struct ChecklistTemplate: Equatable, Codable, Sendable {
    public var setup: [ChecklistStepDraft]
    public var teardown: [ChecklistStepDraft]
    public init(setup: [ChecklistStepDraft] = [], teardown: [ChecklistStepDraft] = []) { self.setup = setup; self.teardown = teardown }
    public subscript(phase: ChecklistPhase) -> [ChecklistStepDraft] {
        get { phase == .setup ? setup : teardown }
        set { if phase == .setup { setup = newValue } else { teardown = newValue } }
    }
}
