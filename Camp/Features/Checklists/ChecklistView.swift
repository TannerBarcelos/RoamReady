import SwiftUI
import SwiftData
import CampCore
import CampPersistence

/// A trip's checklist. Steps are edited in place; the rig's defaults never change unless the owner
/// saves this trip's lists as defaults.
struct ChecklistView: View {
    @Environment(LibraryController.self) private var library
    let trip: Trip
    @State private var phase: ChecklistPhase
    @State private var editing = EditMode.inactive
    @State private var editedStep: ChecklistStep?
    @State private var adding = false
    @State private var confirmingDefaults = false
    @State private var defaultsSaved = false
    @State private var failure: String?
    @State private var showAssistant = false
    @State private var helpStep: ChecklistStep?
    @State private var helpAfterDismiss = false

    init(trip: Trip, initialPhase: ChecklistPhase = .setup) {
        self.trip = trip
        _phase = State(initialValue: initialPhase)
    }
    private var steps: [ChecklistStep] { trip.steps(phase) }
    private var rigName: String { trip.rig?.displayName ?? "this rig" }

    var body: some View {
        List {
            Section {
                Picker("Checklist", selection: $phase) {
                    ForEach(ChecklistPhase.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                ProgressSummary(steps: steps)
                SaveStatus()
            }
            Section {
                ForEach(steps) { step in
                    HStack(alignment: .top, spacing: 14) {
                        Button {
                            step.status = step.status == .completed ? .pending : .completed
                            library.save()
                        } label: {
                            Image(systemName: step.status == .completed ? "checkmark.circle.fill" : step.status == .skipped ? "minus.circle" : "circle")
                                .font(.title2).foregroundStyle(step.status == .completed ? Color.blue : .secondary)
                                .frame(width: 32, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(step.title), \(step.status.title). \(step.status == .completed ? "Mark pending" : "Mark complete")")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(step.title).foregroundStyle(step.status == .skipped ? .secondary : .primary)
                            Text(step.status == .skipped ? "Skipped · \(step.section)" : step.section)
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                        Button { editedStep = step } label: { Image(systemName: editing.isEditing ? "pencil" : "info.circle").frame(width: 36, height: 44) }
                            .buttonStyle(.borderless).accessibilityLabel("Details and edit \(step.title)")
                    }
                    .contextMenu {
                        Button("Ask about this step", systemImage: "sparkles") { helpStep = step; showAssistant = true }
                        Button(step.status == .skipped ? "Mark pending" : "Skip this step", systemImage: "arrow.uturn.right") {
                            step.status = step.status == .skipped ? .pending : .skipped
                            library.save()
                        }
                    }
                }
                .onMove { offsets, destination in
                    var ordered = steps; ordered.move(fromOffsets: offsets, toOffset: destination)
                    trip.reorder(ordered); library.save()
                }
                .onDelete { offsets in trip.removeSteps(offsets.map { steps[$0] }); library.save() }
                Button("Add a step", systemImage: "plus") { adding = true }
            } header: { Text("Your flow") } footer: {
                Text("Tap a circle to finish a step. Use Edit to reorder or remove steps. Follow your rig’s manuals for equipment-specific procedures.")
            }
            Section {
                Button("Ask about this checklist", systemImage: "sparkles") { helpStep = nil; showAssistant = true }
                Button("Save as defaults for \(rigName)", systemImage: "square.on.square") { confirmingDefaults = true }
                    .disabled(trip.rig == nil)
                if defaultsSaved { Label("Defaults updated for \(rigName)", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
                if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
                if let url = URL(string: ChecklistFactory.sourceURL) {
                    Link("Reference: Camping World", destination: url).font(.footnote)
                }
            }
        }
        .navigationTitle(phase.title)
        .toolbar { ToolbarItem(placement: .primaryAction) { EditButton() } }
        .environment(\.editMode, $editing)
        .sensoryFeedback(.success, trigger: steps.filter { $0.status == .completed }.count)
        .sheet(item: $editedStep, onDismiss: {
            if helpAfterDismiss { helpAfterDismiss = false; showAssistant = true }
        }) { step in
            ChecklistStepEditor(step: step.draft, onSave: { edited in step.apply(edited); library.save() },
                                onHelp: { helpStep = step; helpAfterDismiss = true; editedStep = nil })
        }
        .sheet(isPresented: $adding) {
            ChecklistStepEditor(step: ChecklistStepDraft(title: "")) { step in trip.addStep(step, to: phase); library.save() }
        }
        .sheet(isPresented: $showAssistant) { AssistantView(trip: trip, step: helpStep) }
        .confirmationDialog("Save as defaults for \(rigName)?", isPresented: $confirmingDefaults, titleVisibility: .visible) {
            Button("Save as defaults") {
                do { try trip.saveChecklistsAsDefaults(); library.save(); defaultsSaved = true; failure = nil }
                catch { failure = error.localizedDescription }
            }
        } message: { Text("Both of this trip’s checklists become the default lists for \(rigName), with every step unchecked. Only future trips with this rig use them; other trips keep their own lists.") }
    }
}

/// Edits a copy of a step, so Cancel discards the changes.
struct ChecklistStepEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var step: ChecklistStepDraft
    let onSave: (ChecklistStepDraft) -> Void
    var onHelp: (() -> Void)? = nil
    var body: some View {
        NavigationStack {
            Form {
                Section("Step") {
                    TextField("Title", text: $step.title, axis: .vertical)
                    TextField("Section", text: $step.section)
                    TextField("Guidance or your own notes", text: $step.detail, axis: .vertical).lineLimit(4...12)
                }
                Section("Progress") {
                    Picker("Status", selection: $step.status) {
                        ForEach(ChecklistStatus.allCases) { Text($0.title).tag($0) }
                    }
                }
                if let onHelp { Button("Ask about this step", systemImage: "sparkles") { onHelp() } }
            }
            .navigationTitle(step.title.isEmpty ? "New step" : "Step details").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(step); dismiss() }.disabled(!step.hasTitle)
                }
            }
        }
    }
}
