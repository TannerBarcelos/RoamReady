import SwiftUI
import CampCore

/// A source as the chat shows it: the passage the model was given, and whether the answer cited it.
struct OpenedSource: Identifiable {
    let id = UUID()
    let source: DocumentSource
    let passage: String?
    let cited: Bool
}

extension DocumentSource {
    /// "Manual · Page 2 · Scanned", for a source's row.
    var listDetail: String {
        [category, pageDescription, isScanned ? "Scanned" : nil].compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: Source dialog

/// Opened from a source in the chat: what the document said, without leaving the conversation. The full
/// document is one button away.
struct AssistantSourceSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: OpenedSource

    var body: some View {
        NavigationStack {
            AssistantSourceDetail(item: item)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

struct AssistantSourceDetail: View {
    let item: OpenedSource
    @State private var opensDocument = false

    private var detail: String {
        [item.source.listDetail, item.source.section].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "doc.text")
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 44, height: 44)
                        .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.source.title).font(.headline)
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)

                Label(item.cited ? "Cited in this answer" : "Searched, not cited",
                      systemImage: item.cited ? "checkmark.seal.fill" : "magnifyingglass")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(item.cited ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.fill.tertiary, in: Capsule())

                if let passage = item.passage, !passage.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.cited ? "What the answer used" : "What was looked at")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        HStack(alignment: .top, spacing: 12) {
                            RoundedRectangle(cornerRadius: 2).fill(.tint).frame(width: 3)
                            Text(passage).textSelection(.enabled)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("assistantSourcePassage")
                } else {
                    Text("Open the document to read this page.").foregroundStyle(.secondary)
                }

                if item.source.isLowConfidenceScan {
                    Label("This comes from a scan that may be misread. Check the original page before relying on any number or part code.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Button {
                    opensDocument = true
                } label: {
                    Label(item.source.page == nil ? "Open document" : "Open at \(item.source.pageDescription ?? "page")",
                          systemImage: "doc.richtext")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("openSourceDocument")
            }
            .padding(20)
        }
        .navigationTitle("Source")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("assistantSourceDetail")
        .sheet(isPresented: $opensDocument) { DocumentSourceView(source: item.source) }
    }
}
