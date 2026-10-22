import SwiftUI
import CampCore

struct AssistantView: View {
    @Environment(CampStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let trip: Trip
    let step: ChecklistItem?
    @State private var question = ""
    @State private var response: CampingAnswer?
    @State private var answering = false
    @State private var task: Task<Void, Never>?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(CampingAssistant.availability, systemImage: "iphone")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let step { LabeledContent("Current step", value: step.title) }
                    TextField("What do you need help with?", text: $question, axis: .vertical).lineLimit(3...8)
                    Button {
                        answering = true
                        task = Task {
                            let answer = await CampingAssistant.answer(question: question, trip: trip, rig: store.rig(for: trip), step: step)
                            if !Task.isCancelled { response = answer; answering = false }
                        }
                    } label: {
                        if answering { ProgressView("Looking at your saved guidance…") }
                        else { Label("Ask", systemImage: "sparkles") }
                    }.disabled(answering || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } footer: { Text("AI uses Apple’s on-device model only and requires iPhone 16 or newer with Apple Intelligence enabled and its model downloaded. Questions aren’t sent to an online AI service. Saved guidance works without AI.") }
                if let response {
                    Section {
                        Text(response.text).textSelection(.enabled)
                        Text(response.mode).font(.caption).foregroundStyle(.secondary)
                        if let url = URL(string: response.sourceURL) { Link("Checklist background: Camping World", destination: url).font(.caption) }
                    } header: { Text("Camping help") } footer: { Text("Your saved checklist may include personal edits. This answer does not replace your rig’s manual or professional assistance.") }
                }
            }
            .navigationTitle("Camping help").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { if let step { question = "What should I know about \(step.title.lowercased())?" } }
            .onDisappear { task?.cancel() }
        }
    }
}
