import SwiftUI
import SwiftData
import CampCore
import CampPersistence

struct CampingExchange: Identifiable {
    let id = UUID()
    let question: String
    let answer: CampingAnswer
    /// What this question was allowed to read. Only exchanges from the current scope reach a new prompt.
    let scope: AssistantScopeTarget
}

/// The global chat, owned above its sheet so it survives closing and reopening the Assistant.
/// Kept in memory only; conversations are never saved to the library.
@MainActor @Observable
final class AssistantConversation {
    var question = ""
    var exchanges: [CampingExchange] = []
    var generationFailure: CampingChatFailure?
}

/// Trip and checklist help: a fresh conversation each time the sheet opens. The sheet's closure reruns
/// whenever its parent redraws, so the conversation is held here in @State rather than created there.
struct TripAssistantSheet: View {
    let trip: Trip
    let step: ChecklistStep?
    @State private var chat = AssistantConversation()
    var body: some View { AssistantView(trip: trip, step: step, chat: chat) }
}

struct AssistantView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(LibraryController.self) private var library
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Rig.createdAt) private var rigs: [Rig]
    let trip: Trip?
    let step: ChecklistStep?
    let isPresentedAsSheet: Bool
    /// Borrowed from whoever owns the conversation's lifetime.
    @Bindable var chat: AssistantConversation
    @State private var pendingQuestion: String?
    @State private var searchingDocuments = false
    @State private var openedSource: DocumentSource?
    @State private var task: Task<Void, Never>?
    @State private var availability = CampingAssistant.globalAvailability

    init(trip: Trip? = nil, step: ChecklistStep? = nil, isPresentedAsSheet: Bool = true, chat: AssistantConversation) {
        _chat = Bindable(wrappedValue: chat)
        self.trip = trip
        self.step = step
        self.isPresentedAsSheet = isPresentedAsSheet
    }

    /// General chat reads the active rig; trip and checklist help read that trip and its rig.
    private var currentTarget: AssistantScopeTarget {
        if let trip { return .trip(trip) }
        return .general(rig: rigs.active.first)
    }

    private var answering: Bool { pendingQuestion != nil }
    private var showsConversation: Bool { availability.showsConversation }
    private var canSend: Bool {
        showsConversation && !answering && !chat.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if showsConversation {
                    conversation
                } else {
                    ContentUnavailableView {
                        Label(availability.title, systemImage: "sparkles")
                    } description: {
                        Text(availability.message)
                    } actions: {
                        Button("Try again") { refreshAvailability() }
                            .buttonStyle(.borderedProminent)
                    }
                    .accessibilityIdentifier("assistantUnavailable")
                }
            }
            .navigationTitle(isPresentedAsSheet ? "Camping help" : "Assistant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsConversation {
                    ToolbarItem(placement: .primaryAction) {
                        Button("New chat", systemImage: "square.and.pencil") {
                            chat.exchanges = []; chat.question = ""; chat.generationFailure = nil
                        }.disabled(answering || chat.exchanges.isEmpty)
                    }
                }
                if isPresentedAsSheet {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close Assistant", systemImage: "xmark") { dismiss() }
                            .labelStyle(.iconOnly)
                            .accessibilityIdentifier("closeAssistant")
                    }
                }
            }
            .onAppear {
                refreshAvailability()
                if let step, chat.exchanges.isEmpty, chat.question.isEmpty {
                    chat.question = "What should I know about \(step.title.lowercased())?"
                }
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                // React to a completed model download or Settings changes while the app is open.
                while !Task.isCancelled {
                    refreshAvailability()
                    do { try await Task.sleep(for: .seconds(3)) }
                    catch { return }
                }
            }
            .onDisappear { cancelRequest() }
            // A different rig or trip is a different set of paperwork: drop the running request.
            .onChange(of: currentTarget) { _, _ in cancelRequest() }
            .sheet(item: $openedSource) { DocumentSourceView(source: $0) }
        }
    }

    /// What the answer rested on: validated sources, or a plain note when it rested on none.
    @ViewBuilder private func documentNotes(for answer: CampingAnswer) -> some View {
        if !answer.sources.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Sources").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(answer.sources) { source in
                    Button { openedSource = source } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "doc.text").foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.title).font(.subheadline).foregroundStyle(.primary)
                                Text([source.category, source.pageDescription].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the document at the cited page")
                    .accessibilityIdentifier("assistantSourceRow")
                }
            }
        } else if answer.coverage == .notCovered {
            Text("Your documents don’t cover this.").font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("assistantNotCovered")
        } else if answer.coverage == .uncited {
            Text("General advice. No document was cited.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var scopeBanner: some View {
        let summary = currentTarget.summary
        return Label(summary.text, systemImage: "doc.text.magnifyingglass")
            .font(.footnote).foregroundStyle(.secondary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.vertical, 8)
            .background(.bar)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(summary.accessibilityText)
            .accessibilityIdentifier("assistantScope")
    }

    private var conversation: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if chat.exchanges.isEmpty && !answering {
                        VStack(alignment: .leading, spacing: 12) {
                            Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(.tint)
                            Text("How can I help?").font(.largeTitle.bold())
                            Text(trip == nil ? AssistantAvailability.ready.message : "Ask about your trip or checklist, then follow up for more detail.")
                                .foregroundStyle(.secondary)
                            if let trip { Text(trip.campgroundName).font(.subheadline).foregroundStyle(.secondary) }
                            if let step { Text(step.title).font(.subheadline).foregroundStyle(.secondary) }
                        }.padding(.vertical, 32)
                    }
                    ForEach(chat.exchanges) { exchange in
                        userMessage(exchange.question)
                        VStack(alignment: .leading, spacing: 10) {
                            Text(exchange.answer.text).textSelection(.enabled)
                                .accessibilityIdentifier("assistantGeneratedReply")
                            Text(exchange.answer.mode).font(.caption).foregroundStyle(.secondary)
                            if exchange.scope != currentTarget {
                                Text("Asked in \(exchange.scope.summary.text)").font(.caption).foregroundStyle(.secondary)
                            }
                            documentNotes(for: exchange.answer)
                            if let source = exchange.answer.sourceURL, let url = URL(string: source) {
                                Link("Checklist background: Camping World", destination: url).font(.caption)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Assistant response")
                    }
                    if let pendingQuestion {
                        userMessage(pendingQuestion)
                        ProgressView(searchingDocuments ? "Searching your documents…" : "Thinking…")
                            .accessibilityLabel(searchingDocuments ? "Assistant is searching your documents" : "Assistant is answering")
                    }
                    if let generationFailure = chat.generationFailure {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Couldn’t get a response", systemImage: "exclamationmark.bubble")
                                .font(.headline)
                            Text(generationFailure.localizedDescription).foregroundStyle(.secondary)
                            Button("Try again", action: ask).disabled(!canSend)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .top, spacing: 0) { scopeBanner }
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            .onChange(of: chat.exchanges.count) { _, _ in
                withAnimation(reduceMotion ? nil : .default) { scroll.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: answering) { _, _ in
                withAnimation(reduceMotion ? nil : .default) { scroll.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private func userMessage(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 36)
            Text(text)
                .textSelection(.enabled)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You: \(text)")
    }

    private var composer: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message Assistant", text: $chat.question, axis: .vertical)
                    .lineLimit(1...6)
                    .disabled(answering)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
                    .accessibilityLabel("Message Assistant")
                    .accessibilityIdentifier("assistantQuestion")
                Button(action: ask) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 34))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("Send message")
                .accessibilityIdentifier("assistantSend")
            }
            Text("On-device AI · Check advice against your manual")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }

    private func refreshAvailability() {
        availability = CampingAssistant.globalAvailability
        if !availability.showsConversation { cancelRequest() }
    }

    private func cancelRequest() {
        task?.cancel()
        task = nil
        if let pendingQuestion, chat.question.isEmpty { chat.question = pendingQuestion }
        pendingQuestion = nil
        searchingDocuments = false
    }

    private func ask() {
        refreshAvailability()
        guard canSend else { return }
        let submitted = chat.question.trimmingCharacters(in: .whitespacesAndNewlines)
        // Everything this request reads is captured now. A scope change cancels it (see onChange above).
        let target = currentTarget
        let rig = trip == nil ? rigs.active.first : trip?.rig
        let rigContext = rig.map { CampingRigContext($0) }
        let steps: [ChecklistStepDraft]
        if let trip {
            steps = (trip.steps(.setup) + trip.steps(.teardown)).map(\.draft)
        } else if let rig {
            steps = rig.defaultTemplate.setup + rig.defaultTemplate.teardown
        } else {
            steps = []
        }
        let history = AssistantConversationRules.history(
            chat.exchanges.map { ScopedChatTurn(scope: $0.scope, question: $0.question, answer: $0.answer.text) }, in: target)
        let retrievalQuestion = AssistantConversationRules.retrievalQuestion(submitted, after: history)
        pendingQuestion = submitted
        chat.generationFailure = nil
        chat.question = ""
        let index = library.documentAssistant
        let context = modelContext
        task = Task {
            do {
                var evidence: DocumentEvidence?
                if target.rigID != nil || target.isTrip {
                    searchingDocuments = true
                    evidence = await index.evidence(for: retrievalQuestion, target: target, in: context)
                    searchingDocuments = false
                    try Task.checkCancellation()
                }
                let answer = try await CampingAssistant.answer(question: submitted, steps: steps, rigType: rig?.type,
                                                       step: step?.draft, scope: trip == nil ? .general : .checklist,
                                                       history: history, rigContext: rigContext, documents: evidence)
                guard !Task.isCancelled else { return }
                refreshAvailability()
                guard !Task.isCancelled, showsConversation, currentTarget == target else { return }
                chat.exchanges.append(CampingExchange(question: submitted, answer: answer, scope: target))
            } catch {
                guard !Task.isCancelled else { return }
                refreshAvailability()
                guard !Task.isCancelled, showsConversation else { return }
                chat.generationFailure = (error as? CampingChatFailure) ?? .failed
                chat.question = submitted
            }
            pendingQuestion = nil
            searchingDocuments = false
            task = nil
        }
    }
}
