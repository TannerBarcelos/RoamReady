import SwiftUI
import CampCore

extension AssistantDocumentStatus {
    var systemImage: String {
        switch self {
        case .ready: "checkmark.circle.fill"
        case .readPartially: "checkmark.circle"
        case .queued, .extracting, .indexing: "clock"
        case .waitingForDownload: "icloud.and.arrow.down"
        case .retryableFailure: "exclamationmark.arrow.triangle.2.circlepath"
        case .noUsableText, .unsupported: "exclamationmark.triangle"
        case .englishOnly: "globe"
        }
    }

    var tint: Color {
        switch self {
        case .ready: .green
        case .retryableFailure, .noUsableText, .unsupported: .orange
        default: .secondary
        }
    }
}

/// One line under the scope: how many of the scope's documents the Assistant can use now.
struct AssistantReadinessSummary: View {
    let readiness: ScopeReadiness

    var body: some View {
        if let summary = readiness.summary {
            VStack(alignment: .leading, spacing: 4) {
                Label(summary, systemImage: readiness.isComplete ? "checkmark.circle" : "clock")
                    .font(.footnote).foregroundStyle(.secondary)
                    .lineLimit(2)
                    .accessibilityIdentifier("assistantReadiness")
                if !readiness.isComplete {
                    Text("Ask any time. Documents that aren’t ready are left out until they are.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                #if DEBUG
                if DocumentReadinessFixture.isRequested, !DocumentReadinessFixture.isReleased {
                    Button("Finish test scan") { DocumentReadinessFixture.release() }
                        .font(.caption).accessibilityIdentifier("releaseTestScan")
                }
                #endif
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.vertical, 6)
            .background(.bar)
        }
    }
}

/// Under an answer given while some documents weren't fully covered: says so, and once a document it was
/// missing is ready, offers a retry. The earlier answer stays; a retry asks the question again as a new
/// exchange, and only when the camper taps it.
struct AnswerReadinessNote: View {
    let answer: CampingAnswer
    /// The scope's readiness now, when this answer was asked in the scope on screen.
    let current: ScopeReadiness?
    let canRetry: Bool
    let retry: () -> Void

    private var note: String? {
        answer.coverage == .unfinished ? answer.readiness.cannotSupportNote : answer.readiness.incompleteNote
    }

    private var nowReady: [DocumentReadinessEntry] { current?.newlyReady(since: answer.readiness) ?? [] }

    var body: some View {
        if let note {
            VStack(alignment: .leading, spacing: 6) {
                Label(note, systemImage: "clock.badge.exclamationmark")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("assistantIncompleteNote")
                if !nowReady.isEmpty {
                    HStack(spacing: 10) {
                        Text("\(names(nowReady)) \(nowReady.count == 1 ? "is" : "are") ready now.")
                            .font(.caption)
                        Button("Retry", action: retry)
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(!canRetry)
                            .accessibilityHint("Asks this question again. Your earlier answer stays.")
                            .accessibilityIdentifier("assistantRetryWithDocuments")
                    }
                }
            }
        }
    }

    private func names(_ entries: [DocumentReadinessEntry]) -> String {
        entries.prefix(2).map { "“\($0.title)”" }.joined(separator: " and ") + (entries.count > 2 ? " and \(entries.count - 2) more" : "")
    }
}

/// A document's status in its details: what it is, why, and what to do.
struct DocumentStatusSection: View {
    let status: AssistantDocumentStatus
    let retry: () -> Void

    var body: some View {
        Section {
            Label {
                Text(status.label)
            } icon: {
                Image(systemName: status.systemImage).foregroundStyle(status.tint)
            }
            .accessibilityIdentifier("documentAssistantStatus")
            if case .indexing(let done, let total) = status, total > 0 {
                ProgressView(value: Double(done), total: Double(total))
                    .accessibilityLabel("Indexing progress")
                    .accessibilityValue("\(done) of \(total) passages")
            }
            if let guidance = status.guidance {
                Text(guidance).font(.footnote).foregroundStyle(.secondary)
            }
            if status.nextAction == .retry {
                Button("Try again", systemImage: "arrow.clockwise", action: retry)
            }
        } header: {
            Text("Assistant")
        }
    }
}
