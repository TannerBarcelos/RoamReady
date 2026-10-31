import SwiftUI
import SwiftData
import CampCore
import CampPersistence

struct CampingExchange: Identifiable {
    let id = UUID()
    let question: String
    let answer: CampingAnswer
    /// What this question was allowed to read. A different scope starts a new model session.
    let scope: AssistantScopeTarget
}

/// The global chat, owned above its sheet so it survives closing and reopening the Assistant.
/// Kept in memory only; conversations are never saved to the library.
@MainActor @Observable
final class AssistantConversation {
    /// The model session behind these exchanges. Its transcript, not the exchanges, is what the model sees.
    @ObservationIgnored let session = CampingAssistant.makeChat()
    var question = ""
    var exchanges: [CampingExchange] = []
    var generationFailure: CampingChatFailure?
    /// The question Retry resubmits, kept apart from the message field the person may have edited since.
    var failedQuestion: String?
}

/// Trip and checklist help: a fresh conversation each time the sheet opens. The sheet's closure reruns
/// whenever its parent redraws, so the conversation is held here in @State rather than created there.
struct TripAssistantSheet: View {
    let trip: Trip
    let step: CampingStepContext?
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
    @Query(sort: \Trip.arrival) private var trips: [Trip]
    let trip: Trip?
    let step: CampingStepContext?
    let isPresentedAsSheet: Bool
    /// Borrowed from whoever owns the conversation's lifetime.
    @Bindable var chat: AssistantConversation
    @State private var progress = AssistantProgress()
    @State private var openedSource: OpenedSource?
    @State private var task: Task<Void, Never>?
    @State private var availability = CampingAssistant.globalAvailability

    init(trip: Trip? = nil, step: CampingStepContext? = nil, isPresentedAsSheet: Bool = true, chat: AssistantConversation) {
        _chat = Bindable(wrappedValue: chat)
        self.trip = trip
        self.step = step
        self.isPresentedAsSheet = isPresentedAsSheet
    }

    /// Global chat follows Home's current-or-next trip. Explicit trip help keeps its selected trip.
    private var contextTrip: Trip? { trip ?? trips.featuredTrip() }

    /// Saved facts and document scope always refer to the same trip and rig.
    private var currentTarget: AssistantScopeTarget {
        if let trip = contextTrip { return .trip(trip) }
        return .general(rig: rigs.active.first)
    }

    private var pendingQuestion: String? { progress.isActive ? progress.question : nil }
    private var answering: Bool { progress.isActive }
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
                    ToolbarItem(placement: .principal) {
                        Text(currentTarget.summary.text)
                            .font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("assistantScope")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("New chat", systemImage: "square.and.pencil") {
                            chat.exchanges = []; chat.question = ""; chat.generationFailure = nil; chat.failedQuestion = nil
                            chat.session.reset()
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
                // Load the model while the camper types, so the first answer starts sooner (TN3193).
                if showsConversation { chat.session.prewarm() }
                if let step, chat.exchanges.isEmpty, chat.question.isEmpty {
                    chat.question = "What should I know about \(step.draft.title.lowercased())?"
                }
                #if DEBUG
                if DocumentAssistantFixture.showsSourceStates, chat.exchanges.isEmpty {
                    chat.exchanges = DocumentAssistantFixture.sourceStateExchanges(scope: currentTarget, in: modelContext)
                }
                #endif
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
            .sheet(item: $openedSource) { AssistantSourceSheet(item: $0) }
        }
    }

    /// Only sources used by this answer.
    @ViewBuilder private func documentNotes(for answer: CampingAnswer) -> some View {
        let cited = answer.sources
        if !cited.isEmpty || answer.usedSavedTrip {
            VStack(alignment: .leading, spacing: 6) {
                Text("Sources").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                if answer.usedSavedTrip { savedTripRow }
                ForEach(cited) { sourceRow($0, in: answer) }
                if cited.contains(where: \.isLowConfidenceScan) {
                    Label("Part of this comes from a scan that may be misread. Check the original page before relying on any number or part code.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("assistantScanCaution")
                }
            }
        }
    }

    /// A cited source opens the source dialog.
    private func sourceRow(_ source: DocumentSource, in answer: CampingAnswer) -> some View {
        let detail = source.listDetail
        return Button {
            openedSource = OpenedSource(source: source, passage: answer.passages[source.id], cited: true)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.text").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.title).font(.subheadline)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Source: \(source.title), \(detail)")
        .accessibilityHint("Shows the passage this answer cited")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("assistantSourceRow")
    }

    /// The trip's own saved details, named as a source so they are told apart from documents. Not tappable:
    /// the Assistant never edits them, and the camper changes them in the trip.
    private var savedTripRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Saved trip").font(.subheadline)
                Text("Details you entered · Not changed").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("assistantSavedTripSource")
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
                            if let step { Text(step.draft.title).font(.subheadline).foregroundStyle(.secondary) }
                        }.padding(.vertical, 32)
                    }
                    ForEach(chat.exchanges) { exchange in
                        userMessage(exchange.question)
                        VStack(alignment: .leading, spacing: 10) {
                            Text(exchange.answer.text).textSelection(.enabled)
                                .accessibilityIdentifier("assistantGeneratedReply")
                            if exchange.scope != currentTarget {
                                Text("Asked in \(exchange.scope.summary.text)").font(.caption).foregroundStyle(.secondary)
                            }
                            documentNotes(for: exchange.answer)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Assistant response")
                    }
                    if let pendingQuestion {
                        userMessage(pendingQuestion)
                        responseProgress
                    }
                    if let generationFailure = chat.generationFailure {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Couldn’t get a response", systemImage: "exclamationmark.bubble")
                                .font(.headline)
                            Text(generationFailure.localizedDescription).foregroundStyle(.secondary)
                            Button("Retry", action: retry)
                                .disabled(answering || chat.failedQuestion == nil)
                                .accessibilityIdentifier("assistantRetry")
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            .onChange(of: chat.exchanges.count) { _, _ in
                withAnimation(reduceMotion ? nil : .default) { scroll.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: answering) { _, _ in
                withAnimation(reduceMotion ? nil : .default) { scroll.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var responseProgress: some View {
        ProgressView()
            .accessibilityLabel("Response in progress")
            .accessibilityIdentifier("assistantProgress")
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
        // Forgetting the request id is what stops its late results; see `progress.isCurrent`.
        progress.cancel()
    }

    private func announce(_ text: String?) {
        guard let text else { return }
        AccessibilityNotification.Announcement(text).post()
    }

    private func ask() {
        refreshAvailability()
        guard canSend else { return }
        submit(chat.question.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func retry() {
        refreshAvailability()
        guard showsConversation, !answering, let question = chat.failedQuestion else { return }
        submit(question)
    }

    private func submit(_ submitted: String, retrying retried: CampingExchange? = nil) {
        // Everything this request reads is captured now. A scope change cancels it (see onChange above).
        let target = currentTarget
        let selectedTrip = contextTrip
        let rig = selectedTrip == nil ? rigs.active.first : selectedTrip?.rig
        let rigContext = rig.map { CampingRigContext($0) }
        let tripFacts = selectedTrip.map { TripBookingFacts($0) }
        let tools = selectedTrip.map { $0.assistantTools() }
        let steps: [ChecklistStepDraft]
        if let trip = selectedTrip {
            steps = (trip.steps(.setup) + trip.steps(.teardown)).map(\.draft)
        } else if let rig {
            steps = rig.defaultTemplate.setup + rig.defaultTemplate.teardown
        } else {
            steps = []
        }
        let session = chat.session
        // An exchange that was never a model turn has no turns before it in the session.
        let before = retried.map { $0.answer.turnID ?? "" }
        let retrievalQuestion = AssistantConversationRules.retrievalQuestion(
            submitted, after: session.previousQuestion(in: target, before: before), stepTitle: step?.draft.title)
        let request = progress.begin(question: submitted)
        chat.generationFailure = nil
        chat.failedQuestion = nil
        // A retry leaves anything newly typed in the field alone.
        if retried == nil, chat.question.trimmingCharacters(in: .whitespacesAndNewlines) == submitted { chat.question = "" }
        let index = library.documentAssistant
        let context = modelContext
        task = Task {
            do {
                var evidence: DocumentEvidence?
                if step != nil || !TripOverviewQuestion.matches(submitted), target.rigID != nil || target.isTrip {
                    // Document questions are English only: explain instead of searching or translating.
                    if index.needsEnglish(submitted, target: target, in: context) {
                        guard !Task.isCancelled, progress.isCurrent(request), currentTarget == target else { return }
                        chat.exchanges.append(CampingExchange(question: submitted, answer: .englishOnlyNotice, scope: target))
                        progress.finish(request)
                        task = nil
                        return
                    }
                    _ = progress.advance(to: .searchingDocuments, for: request)
                    evidence = await index.evidence(for: retrievalQuestion, target: target, in: context)
                    try Task.checkCancellation()
                }
                let answer = try await CampingAssistant.answer(question: submitted, steps: steps, rigType: rig?.type,
                                                       step: step?.draft, scope: trip == nil ? .general : .checklist,
                                                       chat: session, chatScope: target, before: before,
                                                       rigContext: rigContext, documents: evidence,
                                                       tripFacts: tripFacts, tools: tools, stepContext: step,
                                                       onStage: { stage in
                    guard progress.isCurrent(request) else { return }
                    _ = progress.advance(to: stage, for: request)
                })
                refreshAvailability()
                // Canceled or superseded work ends here without touching the conversation, and an answer
                // nobody sees leaves the session too.
                guard !Task.isCancelled, progress.isCurrent(request), showsConversation, currentTarget == target else {
                    if let turnID = answer.turnID { session.forget(turnID) }
                    if !Task.isCancelled, progress.isCurrent(request) { cancelRequest() }
                    return
                }
                chat.exchanges.append(CampingExchange(question: submitted, answer: answer, scope: target))
                progress.finish(request)
            } catch {
                guard !Task.isCancelled, progress.isCurrent(request) else { return }
                refreshAvailability()
                guard !Task.isCancelled, progress.isCurrent(request), showsConversation else { return }
                let failure = (error as? CampingChatFailure) ?? .failed
                announce(progress.fail(request, with: failure))
                chat.generationFailure = failure
                chat.failedQuestion = submitted
                if retried == nil { chat.question = submitted }
            }
            task = nil
        }
    }
}
