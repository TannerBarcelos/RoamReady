import SwiftUI
import SwiftData
import CampCore
import CampPersistence

struct CampingExchange: Identifiable {
    let id = UUID()
    let question: String
    let answer: CampingAnswer
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
    @Query(sort: \Rig.createdAt) private var rigs: [Rig]
    let trip: Trip?
    let step: ChecklistStep?
    let isPresentedAsSheet: Bool
    /// Borrowed from whoever owns the conversation's lifetime.
    @Bindable var chat: AssistantConversation
    @State private var pendingQuestion: String?
    @State private var task: Task<Void, Never>?
    @State private var availability = CampingAssistant.globalAvailability

    init(trip: Trip? = nil, step: ChecklistStep? = nil, isPresentedAsSheet: Bool = true, chat: AssistantConversation) {
        _chat = Bindable(wrappedValue: chat)
        self.trip = trip
        self.step = step
        self.isPresentedAsSheet = isPresentedAsSheet
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
        }
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
                        ProgressView("Thinking…").accessibilityLabel("Assistant is answering")
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
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            .onChange(of: chat.exchanges.count) { _, _ in
                withAnimation { scroll.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: answering) { _, _ in
                withAnimation { scroll.scrollTo("bottom", anchor: .bottom) }
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
    }

    private func ask() {
        refreshAvailability()
        guard canSend else { return }
        let submitted = chat.question.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let history = chat.exchanges.map { CampingChatTurn(question: $0.question, answer: $0.answer.text) }
        pendingQuestion = submitted
        chat.generationFailure = nil
        chat.question = ""
        task = Task {
            do {
                let answer = try await CampingAssistant.answer(question: submitted, steps: steps, rigType: rig?.type,
                                                       step: step?.draft, scope: trip == nil ? .general : .checklist,
                                                       history: history, rigContext: rigContext)
                guard !Task.isCancelled else { return }
                refreshAvailability()
                guard !Task.isCancelled, showsConversation else { return }
                chat.exchanges.append(CampingExchange(question: submitted, answer: answer))
            } catch {
                guard !Task.isCancelled else { return }
                refreshAvailability()
                guard !Task.isCancelled, showsConversation else { return }
                chat.generationFailure = (error as? CampingChatFailure) ?? .failed
                chat.question = submitted
            }
            pendingQuestion = nil
            task = nil
        }
    }
}
