import SwiftUI
import CampCore

struct TemplateEditorView: View {
    @Environment(CampStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let rig: Rig
    @State var templates: ChecklistTemplates
    @State private var failure: String?
    @State private var phase = ChecklistPhase.setup
    @State private var editedItem: ChecklistItem?
    @State private var adding = false
    var items: [ChecklistItem] { phase == .setup ? templates.setup : templates.teardown }
    func change(_ mutation: (inout [ChecklistItem]) -> Void) {
        if phase == .setup { mutation(&templates.setup) } else { mutation(&templates.teardown) }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Checklist", selection: $phase) {
                        ForEach(ChecklistPhase.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                } footer: { Text("New trips with \(rig.displayName) start with these steps. Editing them never changes existing trips.") }
                if let failure { Text(failure).foregroundStyle(.red) }
                Section {
                    ForEach(items) { item in
                        Button { editedItem = item } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title).foregroundStyle(.primary)
                                Text(item.section).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in change { $0.remove(atOffsets: offsets) } }
                    .onMove { offsets, destination in change { $0.move(fromOffsets: offsets, toOffset: destination) } }
                    Button("Add a step", systemImage: "plus") { adding = true }
                }
            }
            .navigationTitle("Default checklists").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do { try store.updateDefaults(templates, for: rig.id); dismiss() } catch { failure = error.localizedDescription }
                    }
                }
            }
            .sheet(item: $editedItem) { item in
                ChecklistItemEditor(item: item) { updated in change { list in if let index = list.firstIndex(where: { $0.id == updated.id }) { list[index] = updated } } }
            }
            .sheet(isPresented: $adding) { ChecklistItemEditor(item: ChecklistItem(title: "")) { updated in change { $0.append(updated) } } }
        }
    }
}
