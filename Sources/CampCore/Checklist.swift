import Foundation

public enum ChecklistStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case pending, completed, skipped
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

/// A step's priority, as in Reminders: none, or low to high, shown as one to three exclamation marks.
public enum ChecklistPriority: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, low, medium, high
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    /// "!", "!!", or "!!!" before the title; empty for no priority.
    public var marks: String {
        switch self {
        case .none: ""
        case .low: "!"
        case .medium: "!!"
        case .high: "!!!"
        }
    }
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
    /// The owner's own notes, kept apart from `detail` so generated guidance and personal notes don't mix.
    public var notes: String
    public var priority: ChecklistPriority
    public init(title: String, detail: String = "", section: String = "My checklist", status: ChecklistStatus = .pending,
                notes: String = "", priority: ChecklistPriority = .none) {
        self.title = title; self.detail = detail; self.section = section; self.status = status
        self.notes = notes; self.priority = priority
    }
    /// Equal content, whatever the identity: generated and copied steps get fresh identities.
    public static func == (a: Self, b: Self) -> Bool {
        a.title == b.title && a.detail == b.detail && a.section == b.section && a.status == b.status
            && a.notes == b.notes && a.priority == b.priority
    }
    public var isFinished: Bool { status != .pending }
    public var hasTitle: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// The notes without surrounding blank lines, or nil when there are none to show.
    public var visibleNotes: String? {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
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
