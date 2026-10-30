import SwiftUI
import CampCore

/// A source as the chat shows it: the passage the model was given, and whether the answer cited it.
struct OpenedSource: Identifiable {
    let id = UUID()
    let source: DocumentSource
    let passage: String?
    let cited: Bool
}

// MARK: Scope pill

/// The chat's context in one tappable pill: what it reads and how ready that is. The detail sits behind it in
/// a pane, so the transcript isn't crowded by banners.
struct AssistantScopePill: View {
    let summary: AssistantScopeSummary
    let readiness: ScopeReadiness
    let exchanges: [CampingExchange]
    @State private var showsPane = false

    private var name: String { summary.tripName ?? summary.rigName ?? "No active rig" }

    private var statusImage: String {
        if readiness.isEmpty { return "doc.text.magnifyingglass" }
        return readiness.isComplete ? "checkmark.circle.fill" : "clock"
    }

    var body: some View {
        Button { showsPane = true } label: {
            HStack(spacing: 6) {
                Image(systemName: statusImage)
                    .foregroundStyle(readiness.isEmpty || !readiness.isComplete ? Color.secondary : Color.green)
                Text(name).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 4)
        }
        // Toolbar buttons take the accent color; the pill is context, not an action, so it reads as plain text.
        .tint(.primary)
        .accessibilityLabel([summary.accessibilityText, readiness.summary].compactMap { $0 }.joined(separator: ". "))
        .accessibilityHint("Shows the documents and sources for this chat")
        .accessibilityIdentifier("assistantScope")
        .popover(isPresented: $showsPane) {
            AssistantSourcesPane(summary: summary, readiness: readiness, exchanges: exchanges)
                .frame(idealWidth: 360, idealHeight: 460)
                .presentationCompactAdaptation(.popover)
        }
    }
}

/// What the chat can read, how ready each document is, and every source its answers cited.
struct AssistantSourcesPane: View {
    let summary: AssistantScopeSummary
    let readiness: ScopeReadiness
    let exchanges: [CampingExchange]

    /// Cited sources across the chat, newest answer first, one row per document page.
    private var used: [OpenedSource] {
        var seen = Set<String>()
        var result: [OpenedSource] = []
        for exchange in exchanges.reversed() {
            for source in exchange.answer.sources where seen.insert("\(source.documentID)-\(source.page ?? 0)-\(source.checksum)").inserted {
                result.append(OpenedSource(source: source, passage: exchange.answer.passages[source.id], cited: true))
            }
        }
        return result
    }

    private var usedSavedTrip: Bool { exchanges.contains { $0.answer.usedSavedTrip } }
    private var usedChecklist: Bool { exchanges.contains { $0.answer.usedChecklist } }

    var body: some View {
        NavigationStack {
            List {
                #if DEBUG
                // First, so a UI test finds it without scrolling: a List only builds the rows on screen.
                if DocumentReadinessFixture.isRequested, !DocumentReadinessFixture.isReleased {
                    Button("Finish test scan") { DocumentReadinessFixture.release() }
                        .accessibilityIdentifier("releaseTestScan")
                }
                #endif
                Section("Used in this chat") {
                    if used.isEmpty && !usedSavedTrip && !usedChecklist {
                        Text("No sources cited yet.").foregroundStyle(.secondary)
                    }
                    if usedSavedTrip {
                        Label("Saved trip", systemImage: "calendar")
                    }
                    if usedChecklist {
                        Label("Your checklists", systemImage: "checklist")
                            .accessibilityIdentifier("assistantUsedChecklist")
                    }
                    ForEach(used) { item in
                        NavigationLink {
                            AssistantSourceDetail(item: item)
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.source.title)
                                    if let page = item.source.pageDescription {
                                        Text(page).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            } icon: {
                                Image(systemName: "doc.text").foregroundStyle(.tint)
                            }
                        }
                        .accessibilityIdentifier("assistantUsedSource")
                    }
                }
                Section("Searching") {
                    Label(summary.text, systemImage: summary.tripName == nil ? "car" : "tent")
                }
                if !readiness.isEmpty {
                    Section {
                        ForEach(readiness.entries) { entry in
                            HStack {
                                Label {
                                    Text(entry.title)
                                } icon: {
                                    Image(systemName: entry.readiness.systemImage).foregroundStyle(entry.readiness.tint)
                                }
                                Spacer(minLength: 8)
                                Text(entry.readiness.label).font(.caption).foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    } header: {
                        Text("Documents")
                    } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            if let text = readiness.summary {
                                Text(text).accessibilityIdentifier("assistantReadiness")
                            }
                            if !readiness.isComplete {
                                Text("Ask any time. Documents that aren’t ready are left out until they are.")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Sources")
            .navigationBarTitleDisplayMode(.inline)
        }
        .accessibilityIdentifier("assistantSourcesPane")
    }
}

// MARK: Searched references

extension DocumentSource {
    /// "Manual · Page 2 · Scanned", for a source's row.
    var listDetail: String {
        [category, pageDescription, isScanned ? "Scanned" : nil].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Excerpts an answer was given but didn't cite, behind one tinted line so they don't compete with its sources.
/// They are never described as used.
struct SearchedReferencesLink: View {
    let searched: [DocumentSource]
    let passages: [DocumentSource.ID: String]
    @State private var showsPane = false

    var body: some View {
        Button { showsPane = true } label: {
            HStack(spacing: 3) {
                Text("Looked at, but not cited")
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
            }
            .font(.caption)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Looked at, but not cited: \(searched.count) \(searched.count == 1 ? "reference" : "references")")
        .accessibilityHint("Shows the references searched for this answer")
        .accessibilityIdentifier("assistantSearchedReferences")
        .popover(isPresented: $showsPane) {
            NavigationStack {
                List {
                    Section {
                        ForEach(searched) { source in
                            NavigationLink {
                                AssistantSourceDetail(item: OpenedSource(source: source, passage: passages[source.id], cited: false))
                            } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(source.title)
                                        Text(source.listDetail).font(.caption).foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Searched, not cited: \(source.title), \(source.listDetail)")
                            .accessibilityAddTraits(.isButton)
                            .accessibilityIdentifier("assistantSearchedRow")
                        }
                    } footer: {
                        Text("Looked at for this answer, but not cited in it.")
                    }
                }
                .navigationTitle("References searched")
                .navigationBarTitleDisplayMode(.inline)
            }
            .frame(idealWidth: 360, idealHeight: 320)
            .presentationCompactAdaptation(.popover)
        }
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

// MARK: Progress

/// The request's stages as they happen: the current one pulses with a moving highlight, finished ones settle
/// above it as quiet checkmarks. Only stages that really happened appear.
struct AssistantStageView: View {
    let stages: [AssistantStage]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(stages.dropLast(), id: \.self) { stage in
                Label {
                    Text(stage.doneTitle)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if let current = stages.last {
                HStack(spacing: 10) {
                    Image(systemName: current.systemImage)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                        .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                        .frame(width: 24)
                    Text(current.title)
                        .font(.subheadline.weight(.medium))
                        .modifier(Shimmer(isActive: !reduceMotion))
                }
                .id(current)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(reduceMotion ? nil : .snappy, value: stages)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("assistantProgress")
    }
}

/// A highlight that sweeps across text while work is in progress. A plain label when Reduce Motion is on.
private struct Shimmer: ViewModifier {
    let isActive: Bool
    @State private var phase: CGFloat = -0.5

    func body(content: Content) -> some View {
        if isActive {
            content
                .foregroundStyle(.secondary)
                .overlay {
                    content
                        .foregroundStyle(.primary)
                        .mask {
                            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.5),
                                                   .init(color: .clear, location: 1)],
                                           startPoint: UnitPoint(x: phase - 0.5, y: 0.5), endPoint: UnitPoint(x: phase + 0.5, y: 0.5))
                        }
                        .accessibilityHidden(true)
                }
                .onAppear {
                    withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1.5 }
                }
        } else {
            content
        }
    }
}
