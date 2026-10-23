import SwiftUI
import CampCore
import CampPersistence

/// A rig's default lists, edited as a copy so Cancel discards the changes. Existing trips never change.
struct TemplateEditorView: View {
    @Environment(LibraryController.self) private var library
    @Environment(\.dismiss) private var dismiss
    let rig: Rig
    @State private var template: ChecklistTemplate
    @State private var phase = ChecklistPhase.setup
    @State private var editedStep: ChecklistStepDraft?
    @State private var adding = false
    init(rig: Rig) {
        self.rig = rig
        _template = State(initialValue: rig.defaultTemplate)
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Checklist", selection: $phase) {
                        ForEach(ChecklistPhase.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                } footer: { Text("New trips with \(rig.displayName) start with these steps. Editing them never changes existing trips.") }
                Section {
                    ForEach(template[phase]) { step in
                        Button { editedStep = step } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(step.title).foregroundStyle(.primary)
                                Text(step.section).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { template[phase].remove(atOffsets: $0) }
                    .onMove { template[phase].move(fromOffsets: $0, toOffset: $1) }
                    Button("Add a step", systemImage: "plus") { adding = true }
                }
            }
            .navigationTitle("Default checklists").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { rig.setDefaults(template); library.save(); dismiss() }
                }
            }
            .sheet(item: $editedStep) { step in
                ChecklistStepEditor(step: step) { edited in
                    if let index = template[phase].firstIndex(where: { $0.id == step.id }) { template[phase][index] = edited }
                }
            }
            .sheet(isPresented: $adding) { ChecklistStepEditor(step: ChecklistStepDraft(title: "")) { template[phase].append($0) } }
        }
    }
}
