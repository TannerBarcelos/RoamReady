import Foundation

public enum ChecklistStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case pending, completed, skipped
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public struct ChecklistItem: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var detail: String
    public var section: String
    public var status: ChecklistStatus
    public init(id: UUID = UUID(), title: String, detail: String = "", section: String = "My checklist",
                status: ChecklistStatus = .pending) {
        self.id = id; self.title = title; self.detail = detail; self.section = section; self.status = status
    }
    public var isFinished: Bool { status != .pending }
    public func freshCopy() -> ChecklistItem {
        ChecklistItem(title: title, detail: detail, section: section)
    }
}

public struct ChecklistTemplates: Codable, Equatable, Sendable {
    public var id: UUID
    public var version: Int
    public var sourceURL: String
    public var setup: [ChecklistItem]
    public var teardown: [ChecklistItem]
    /// The rig these are the default lists for. Nil for lists `ChecklistFactory` generates before they
    /// are stored as a rig's defaults; every stored set has one (`AppState.validated`).
    public var rigID: UUID?
    public init(id: UUID = UUID(), version: Int = 1, sourceURL: String = ChecklistFactory.sourceURL,
                setup: [ChecklistItem] = [], teardown: [ChecklistItem] = [], rigID: UUID? = nil) {
        self.id = id; self.version = version; self.sourceURL = sourceURL; self.setup = setup; self.teardown = teardown
        self.rigID = rigID
    }
    /// Pending copies with fresh identities, so a copy never shares items with its source.
    public func freshCopy(rigID: UUID?) -> ChecklistTemplates {
        ChecklistTemplates(version: version, sourceURL: sourceURL, setup: setup.map { $0.freshCopy() },
                           teardown: teardown.map { $0.freshCopy() }, rigID: rigID)
    }
}

func validateChecklist(_ items: [ChecklistItem]) throws {
    guard Set(items.map(\.id)).count == items.count else { throw CampError.duplicateIdentifiers }
    guard items.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
        throw CampError.emptyChecklistTitle
    }
}
