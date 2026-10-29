import CampCore

public extension AssistantDocumentStatus {
    /// How the index's state reads to the camper.
    init(_ state: DocumentIndexState) {
        switch state {
        case .queued: self = .queued
        case .extracting: self = .extracting
        case .indexing(let done, let total): self = .indexing(done: done, of: total)
        case .ready: self = .ready
        case .readPartially: self = .readPartially
        case .waitingForDownload: self = .waitingForDownload
        case .noUsableText(let reason): self = .noUsableText(NoTextCause(reason))
        case .englishOnly: self = .englishOnly
        case .unsupported: self = .unsupported
        case .retryableFailure: self = .retryableFailure
        }
    }
}

public extension AssistantDocumentStatus.NoTextCause {
    init(_ reason: NoUsableTextReason) {
        switch reason {
        case .empty: self = .empty
        case .encrypted: self = .encrypted
        case .unreadable: self = .unreadable
        case .tooLarge: self = .tooLarge
        case .noText: self = .noText
        }
    }
}
