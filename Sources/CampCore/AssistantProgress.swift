import Foundation

/// A step the Assistant really went through while answering one question.
public enum AssistantStage: Equatable, Sendable {
    case searchingDocuments, preparing, writing

    public var title: String {
        switch self {
        case .searchingDocuments: "Searching your documents…"
        case .preparing: "Preparing your question…"
        case .writing: "Writing an answer…"
        }
    }

    /// What VoiceOver hears when the stage begins.
    public var announcement: String {
        switch self {
        case .searchingDocuments: "Searching your documents"
        case .preparing: "Preparing your question"
        case .writing: "Writing an answer"
        }
    }
}

/// Identifies one submitted question. Work holds the id it started with; once the request is
/// canceled or replaced, that id no longer matches and the work can't change what the screen shows.
public struct AssistantRequestID: Hashable, Sendable {
    private let value = UUID()
    public init() {}
}

/// Progress of the question being answered, and the guard that keeps stale work out of the UI.
/// Only stages that were reported appear in `stages`; there is no percentage.
public struct AssistantProgress: Equatable, Sendable {
    public private(set) var id: AssistantRequestID?
    public private(set) var question = ""
    /// Stages reached so far, in order. The last one is in progress.
    public private(set) var stages: [AssistantStage] = []
    public private(set) var failure: CampingChatFailure?

    public init() {}

    public var isActive: Bool { id != nil }
    public var currentStage: AssistantStage? { stages.last }

    public func isCurrent(_ candidate: AssistantRequestID) -> Bool { id == candidate }

    /// Starts a request and supersedes any earlier one.
    public mutating func begin(question: String) -> AssistantRequestID {
        let new = AssistantRequestID()
        id = new
        self.question = question
        stages = []
        failure = nil
        return new
    }

    /// Records a stage for the request; returns the text to announce, or nil if the request is stale or already there.
    @discardableResult
    public mutating func advance(to stage: AssistantStage, for request: AssistantRequestID) -> String? {
        guard isCurrent(request), !stages.contains(stage) else { return nil }
        stages.append(stage)
        return stage.announcement
    }

    /// Ends the request successfully. False when it was superseded, so the caller must drop its result.
    @discardableResult
    public mutating func finish(_ request: AssistantRequestID) -> Bool {
        guard isCurrent(request) else { return false }
        clear()
        return true
    }

    /// Ends the request with an error; returns the text to announce, or nil if the request is stale.
    public mutating func fail(_ request: AssistantRequestID, with error: CampingChatFailure) -> String? {
        guard isCurrent(request) else { return nil }
        clear()
        failure = error
        return "Couldn’t get a response. \(error.localizedDescription)"
    }

    /// Drops the running request, if any; its work can no longer report.
    public mutating func cancel() {
        clear()
        failure = nil
    }

    private mutating func clear() {
        id = nil
        question = ""
        stages = []
    }
}
