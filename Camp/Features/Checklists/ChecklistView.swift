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
    @State private var helpStep: CampingStepContext?
    @State private var helpAfterDismiss = false

    private let initialPhase: ChecklistPhase
    /// Lets Home keep the shown phase above the view, so it survives a fold.
    private let onPhaseChange: ((ChecklistPhase) -> Void)?

    init(trip: Trip, initialPhase: ChecklistPhase = .setup, onPhaseChange: ((ChecklistPhase) -> Void)? = nil) {
        self.trip = trip
        self.initialPhase = initialPhase
        self.onPhaseChange = onPhaseChange
        _phase = State(initialValue: initialPhase)
    }
    private var steps: [ChecklistStep] { trip.steps(phase) }
    private var rigName: String { trip.rig?.displayName ?? "this rig" }
    /// AI help only appears on hardware that can run Apple Intelligence.
    private var offersHelp: Bool { CampingAssistant.showsChat }

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
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(step.title), \(step.status.title). \(step.status == .completed ? "Mark pending" : "Mark complete")")
                        ChecklistStepSummary(step: step.draft, caption: step.status == .skipped ? "Skipped · \(step.section)" : step.section)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                        Button { editedStep = step } label: { Image(systemName: editing.isEditing ? "pencil" : "info.circle").frame(width: 44, height: 44) }
                            .buttonStyle(.borderless).accessibilityLabel("Details and edit \(step.title)")
                    }
                    .contextMenu {
                        if offersHelp {
                            Button("Ask about this step", systemImage: "sparkles") { helpStep = CampingStepContext(step.draft, phase: step.phase, position: step.position); showAssistant = true }
                        }
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
                if offersHelp {
                    Button("Ask about this checklist", systemImage: "sparkles") { helpStep = nil; showAssistant = true }
                }
                Button("Save as defaults for \(rigName)", systemImage: "square.on.square") { confirmingDefaults = true }
                    .disabled(trip.rig == nil)
                if defaultsSaved { Label("Defaults updated for \(rigName)", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
                if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
            }
        }
        .navigationTitle(phase.title)
        .onChange(of: initialPhase) { _, newPhase in phase = newPhase }
        .onChange(of: phase) { _, newPhase in onPhaseChange?(newPhase) }
        .toolbar { ToolbarItem(placement: .primaryAction) { EditButton() } }
        .environment(\.editMode, $editing)
        .sensoryFeedback(.success, trigger: steps.filter { $0.status == .completed }.count)
        .sheet(item: $editedStep, onDismiss: {
            if helpAfterDismiss { helpAfterDismiss = false; showAssistant = true }
        }) { step in
            ChecklistStepEditor(step: step.draft, onSave: { edited in step.apply(edited); library.save() },
                                onHelp: offersHelp ? { draft in
                                    helpStep = CampingStepContext(draft, phase: step.phase, position: step.position)
                                    helpAfterDismiss = true; editedStep = nil
                                } : nil)
        }
        .sheet(isPresented: $adding) {
            ChecklistStepEditor(step: ChecklistStepDraft(title: "")) { step in trip.addStep(step, to: phase); library.save() }
        }
        .sheet(isPresented: $showAssistant) { TripAssistantSheet(trip: trip, step: helpStep) }
        .confirmationDialog("Save as defaults for \(rigName)?", isPresented: $confirmingDefaults, titleVisibility: .visible) {
            Button("Save as defaults") {
                do { try trip.saveChecklistsAsDefaults(); library.save(); defaultsSaved = true; failure = nil }
                catch { failure = error.localizedDescription }
            }
        } message: { Text("Both of this trip’s checklists become the default lists for \(rigName), with every step unchecked. Only future trips with this rig use them; other trips keep their own lists.") }
    }
}

/// A step laid out like a reminder: priority marks before the title, the owner's notes under it, then a caption.
struct ChecklistStepSummary: View {
    let step: ChecklistStepDraft
    let caption: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if !step.priority.marks.isEmpty {
                    Text(step.priority.marks).fontWeight(.bold).foregroundStyle(.blue)
                        .accessibilityLabel("\(step.priority.title) priority")
                }
                Text(step.title).foregroundStyle(step.status == .skipped ? .secondary : .primary)
            }
            if let notes = step.visibleNotes {
                Text(notes).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("checklistStep-\(step.title)")
    }
}

/// Edits a copy of a step, so Cancel discards the changes.
struct ChecklistStepEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var step: ChecklistStepDraft
    let onSave: (ChecklistStepDraft) -> Void
    var onHelp: ((ChecklistStepDraft) -> Void)? = nil
    var body: some View {
        NavigationStack {
            Form {
                Section("Step") {
                    TextField("Title", text: $step.title, axis: .vertical)
                        .accessibilityIdentifier("checklistStepTitle")
                    TextField("Notes", text: $step.notes, axis: .vertical).lineLimit(2...8)
                        .accessibilityIdentifier("checklistStepNotes")
                }
                Section {
                    Picker("Priority", selection: $step.priority) {
                        ForEach(ChecklistPriority.allCases) { priority in
                            Text(priority.marks.isEmpty ? priority.title : "\(priority.title) \(priority.marks)").tag(priority)
                        }
                    }
                    TextField("Section", text: $step.section)
                    Picker("Status", selection: $step.status) {
                        ForEach(ChecklistStatus.allCases) { Text($0.title).tag($0) }
                    }
                }
                Section {
                    TextField("Guidance", text: $step.detail, axis: .vertical).lineLimit(4...12)
                        .accessibilityIdentifier("checklistStepGuidance")
                } header: { Text("Guidance") } footer: {
                    Text("General guidance for this step. Follow your rig’s manuals for equipment-specific procedures.")
                }
                if let onHelp { Button("Ask about this step", systemImage: "sparkles") { onHelp(step) } }
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
