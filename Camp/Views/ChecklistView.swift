import SwiftUI
import CampCore

enum ChecklistPhase: String, CaseIterable, Identifiable {
    case setup = "Setup", teardown = "Teardown"
    var id: String { rawValue }
}

struct ChecklistView: View {
    @Environment(CampStore.self) private var store
    let tripID: UUID
    @State private var phase: ChecklistPhase
    @State private var editing = EditMode.inactive
    @State private var editedItem: ChecklistItem?
    @State private var adding = false
    @State private var templateConfirmation = false
    @State private var templateSaved = false
    @State private var templateFailure: String?
    private var rigName: String { store.trip(tripID).flatMap(store.rig(for:))?.displayName ?? "this rig" }
    @State private var showAssistant = false
    @State private var helpItem: ChecklistItem?
    @State private var helpAfterDismiss = false

    init(tripID: UUID, initialPhase: ChecklistPhase = .setup) {
        self.tripID = tripID
        _phase = State(initialValue: initialPhase)
    }
    var items: [ChecklistItem] {
        guard let trip = store.trip(tripID) else { return [] }
        return phase == .setup ? trip.setup : trip.teardown
    }
    func changeItems(_ change: (inout [ChecklistItem]) -> Void) {
        store.editTrip(tripID) { trip in
            if phase == .setup { change(&trip.setup) } else { change(&trip.teardown) }
        }
    }
    var body: some View {
        List {
            Section {
                Picker("Checklist", selection: $phase) {
                    ForEach(ChecklistPhase.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                ProgressSummary(items: items)
                SaveStatus()
            }
            Section {
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 14) {
                        Button {
                            changeItems { list in
                                if let index = list.firstIndex(where: { $0.id == item.id }) {
                                    list[index].status = item.status == .completed ? .pending : .completed
                                }
                            }
                        } label: {
                            Image(systemName: item.status == .completed ? "checkmark.circle.fill" : item.status == .skipped ? "minus.circle" : "circle")
                                .font(.title2).foregroundStyle(item.status == .completed ? Color.blue : .secondary)
                                .frame(width: 32, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(item.title), \(item.status.title). \(item.status == .completed ? "Mark pending" : "Mark complete")")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).foregroundStyle(item.status == .skipped ? .secondary : .primary)
                            Text(item.status == .skipped ? "Skipped · \(item.section)" : item.section)
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                        Button {
                            editedItem = item
                        } label: { Image(systemName: editing.isEditing ? "pencil" : "info.circle").frame(width: 36, height: 44) }
                            .buttonStyle(.borderless).accessibilityLabel("Details and edit \(item.title)")
                    }
                    .contextMenu {
                        Button("Ask about this step", systemImage: "sparkles") { helpItem = item; showAssistant = true }
                        Button(item.status == .skipped ? "Mark pending" : "Skip this step", systemImage: "arrow.uturn.right") {
                            changeItems { list in
                                if let index = list.firstIndex(where: { $0.id == item.id }) { list[index].status = item.status == .skipped ? .pending : .skipped }
                            }
                        }
                    }
                }
                .onMove { offsets, destination in changeItems { $0.move(fromOffsets: offsets, toOffset: destination) } }
                .onDelete { offsets in changeItems { $0.remove(atOffsets: offsets) } }
                Button("Add a step", systemImage: "plus") { adding = true }
            } header: { Text("Your flow") } footer: {
                Text("Tap a circle to finish a step. Use Edit to reorder or remove steps. Follow your rig’s manuals for equipment-specific procedures.")
            }
            Section {
                Button("Ask about this checklist", systemImage: "sparkles") { helpItem = nil; showAssistant = true }
                Button("Save as defaults for \(rigName)", systemImage: "square.on.square") { templateConfirmation = true }
                    .disabled(store.trip(tripID).flatMap(store.rig(for:)) == nil)
                if templateSaved { Label("Defaults updated for \(rigName)", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
                if let templateFailure { Text(templateFailure).font(.caption).foregroundStyle(.red) }
                if let url = URL(string: ChecklistFactory.sourceURL) {
                    Link("Reference: Camping World", destination: url).font(.footnote)
                }
            }
        }
        .navigationTitle(phase.rawValue)
        .toolbar { ToolbarItem(placement: .primaryAction) { EditButton() } }
        .environment(\.editMode, $editing)
        .sensoryFeedback(.success, trigger: items.filter { $0.status == .completed }.count)
        .sheet(item: $editedItem, onDismiss: {
            if helpAfterDismiss { helpAfterDismiss = false; showAssistant = true }
        }) { item in
            ChecklistItemEditor(item: item) { replacement in
                changeItems { list in if let index = list.firstIndex(where: { $0.id == replacement.id }) { list[index] = replacement } }
            } onHelp: { helpItem = item; helpAfterDismiss = true; editedItem = nil }
        }
        .sheet(isPresented: $adding) {
            ChecklistItemEditor(item: ChecklistItem(title: "")) { item in changeItems { $0.append(item) } }
        }
        .sheet(isPresented: $showAssistant) {
            if let trip = store.trip(tripID) { AssistantView(trip: trip, step: helpItem) }
        }
        .confirmationDialog("Save as defaults for \(rigName)?", isPresented: $templateConfirmation, titleVisibility: .visible) {
            Button("Save as defaults") {
                do { try store.saveAsDefaults(tripID); templateSaved = true; templateFailure = nil }
                catch { templateFailure = error.localizedDescription }
            }
        } message: { Text("Both of this trip’s checklists become the default lists for \(rigName), with every step unchecked. Only future trips with this rig use them; other trips keep their own lists.") }
    }
}

struct ChecklistItemEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var item: ChecklistItem
    let onSave: (ChecklistItem) -> Void
    var onHelp: (() -> Void)? = nil
    var body: some View {
        NavigationStack {
            Form {
                Section("Step") {
                    TextField("Title", text: $item.title, axis: .vertical)
                    TextField("Section", text: $item.section)
                    TextField("Guidance or your own notes", text: $item.detail, axis: .vertical).lineLimit(4...12)
                }
                Section("Progress") {
                    Picker("Status", selection: $item.status) {
                        ForEach(ChecklistStatus.allCases) { Text($0.title).tag($0) }
                    }
                }
                if let onHelp { Button("Ask about this step", systemImage: "sparkles") { onHelp() } }
            }
            .navigationTitle(item.title.isEmpty ? "New step" : "Step details").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(item); dismiss() }
                        .disabled(item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
