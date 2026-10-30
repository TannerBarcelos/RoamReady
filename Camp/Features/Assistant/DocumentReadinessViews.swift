import SwiftUI
import CampCore

extension AssistantDocumentStatus {
    var systemImage: String {
        switch self {
        case .ready: "checkmark.circle.fill"
        case .readPartially, .englishPartial: "checkmark.circle"
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
