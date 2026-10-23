import SwiftUI
import CampCore

/// Profile › Rig. Editing, replacing, archiving, and default checklists all work offline.
struct RigsSection: View {
    @Environment(CampStore.self) private var store
    @State private var editor: RigEditorView.Mode?
    @State private var editingDefaults: Rig?
    @State private var resetting: Rig?
    @State private var failure: String?
    var body: some View {
        if store.state.needsRigResolution {
            Section {
                Label("You have \(store.state.activeRigs.count) active rigs", systemImage: "exclamationmark.triangle")
                Text("This can happen when two devices change rigs before syncing. Archive the one you no longer use; its trips keep showing it.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        ForEach(store.state.activeRigs) { rig in
            Section {
                HStack(spacing: 16) {
                    RigImage(rig: rig, size: 72)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(rig.displayName).font(.headline)
                        if !rig.detailSummary.isEmpty { Text(rig.detailSummary).font(.caption).foregroundStyle(.secondary) }
                        Text("Used by \(store.state.trips(usingRig: rig.id).count) trips").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 6)
                Button("Edit rig", systemImage: "pencil") { editor = .edit(rig) }
                Button("Default checklists", systemImage: "checklist") { editingDefaults = rig }
                Button("Reset default checklists", systemImage: "arrow.counterclockwise") { resetting = rig }
                NavigationLink { DocumentsView(owner: .rig(rig.id), title: "Rig documents") } label: {
                    LabeledContent { Text(String(store.documents(for: .rig(rig.id)).count)) } label: {
                        Label("Manuals & paperwork", systemImage: "folder")
                    }
                }
                Button("Replace rig", systemImage: "arrow.triangle.2.circlepath") { editor = .replace(rig) }
                if store.state.needsRigResolution {
                    Button("Archive this rig", systemImage: "archivebox") { perform { try store.archiveRig(rig.id) } }
                }
            } header: { Text("Your rig") } footer: {
                Text("Editing updates every trip that uses this rig, past trips included. Sold it or got a new one? Use Replace rig: the current rig is archived and stays on past trips.")
            }
        }
        Section {
            if store.state.canAddActiveRig {
                Button("Add a rig", systemImage: "plus") { editor = .add }
            }
            if !store.state.archivedRigs.isEmpty {
                NavigationLink { ArchivedRigsView() } label: {
                    LabeledContent { Text(String(store.state.archivedRigs.count)) } label: { Label("Archived rigs", systemImage: "archivebox") }
                }
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
        } footer: {
            Text(RigPolicy.maxActiveRigs == 1 ? "You can have one active rig at a time." : "You can have up to \(RigPolicy.maxActiveRigs) active rigs.")
        }
        .sheet(item: $editor) { mode in RigEditorView(mode: mode) }
        .sheet(item: $editingDefaults) { rig in TemplateEditorView(rig: rig, templates: store.defaults(for: rig)) }
        .confirmationDialog("Reset default checklists?", isPresented: Binding(get: { resetting != nil }, set: { if !$0 { resetting = nil } }),
                            titleVisibility: .visible, presenting: resetting) { rig in
            Button("Reset defaults for \(rig.displayName)", role: .destructive) { perform { try store.resetDefaults(for: rig.id) } }
        } message: { _ in Text("Your default lists are regenerated from the rig type. Existing trips keep their own lists.") }
    }
    private func perform(_ action: () throws -> Void) {
        do { try action(); failure = nil } catch { failure = error.localizedDescription }
    }
}

struct ArchivedRigsView: View {
    @Environment(CampStore.self) private var store
    @State private var failure: String?
    @State private var deleting: Rig?
    var body: some View {
        List {
            ForEach(store.state.archivedRigs) { rig in
                Section {
                    HStack(spacing: 16) {
                        RigImage(rig: rig, size: 56)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(rig.displayName).font(.headline)
                            let count = store.state.trips(usingRig: rig.id).count
                            Text(count == 0 ? "No trips use this rig" : "Shown on \(count) past trips").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    NavigationLink { DocumentsView(owner: .rig(rig.id), title: "Rig documents") } label: {
                        Label("Manuals & paperwork", systemImage: "folder")
                    }
                    Button("Make active again", systemImage: "arrow.uturn.backward") { perform { try store.unarchiveRig(rig.id) } }
                        .disabled(!store.state.canAddActiveRig)
                    if store.state.trips(usingRig: rig.id).isEmpty {
                        Button("Delete rig", systemImage: "trash", role: .destructive) { deleting = rig }
                    }
                }
            }
            if let failure { Text(failure).foregroundStyle(.red) }
        }
        .navigationTitle("Archived rigs")
        .confirmationDialog("Delete this rig?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { rig in
            Button("Delete \(rig.displayName)", role: .destructive) { perform { try store.deleteRig(rig.id) } }
        } message: { _ in Text("Its default checklists are deleted. Its documents move to Unattached documents.") }
    }
    private func perform(_ action: () throws -> Void) {
        do { try action(); failure = nil } catch { failure = error.localizedDescription }
    }
}

/// Add, edit, or replace a rig. Replacing archives the current rig and adds this one.
struct RigEditorView: View {
    enum Mode: Identifiable {
        case add, edit(Rig), replace(Rig)
        var id: String {
            switch self {
            case .add: "add"
            case .edit(let rig): "edit-\(rig.id)"
            case .replace(let rig): "replace-\(rig.id)"
            }
        }
    }
    @Environment(CampStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let mode: Mode
    @State private var rig = Rig()
    @State private var regenerateDefaults = false
    @State private var failure: String?
    init(mode: Mode) {
        self.mode = mode
        if case .edit(let existing) = mode { _rig = State(initialValue: existing) }
    }
    private var original: Rig? {
        switch mode {
        case .edit(let existing): existing
        case .add, .replace: nil
        }
    }
    private var checklistInputsChanged: Bool {
        guard let original else { return false }
        return original.type != rig.type || original.equipment != rig.equipment
    }
    var body: some View {
        NavigationStack {
            Form {
                if case .replace(let old) = mode {
                    Section {
                        Text("\(old.displayName) will be archived. Past trips keep showing it, and its documents stay with it. Enter your new rig below.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                RigFormSections(rig: $rig)
                if checklistInputsChanged {
                    Section {
                        Toggle("Regenerate default checklists", isOn: $regenerateDefaults)
                    } footer: { Text("Rebuild this rig’s default lists for its new type or equipment. Off keeps your custom defaults. Existing trips stay as they are.") }
                }
                if let failure { Section { Text(failure).foregroundStyle(.red) } }
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try rig.validateDetails()
                            switch mode {
                            case .add: try store.addRig(rig)
                            case .edit: try store.updateRig(rig, regenerateDefaults: checklistInputsChanged && regenerateDefaults)
                            case .replace(let old): try store.replaceRig(old.id, with: rig)
                            }
                            dismiss()
                        } catch { failure = error.localizedDescription }
                    }.disabled(!rig.hasRequiredDetails)
                }
            }
        }
    }
    private var title: String {
        switch mode {
        case .add: "Add rig"
        case .edit: "Edit rig"
        case .replace: "Replace rig"
        }
    }
}
