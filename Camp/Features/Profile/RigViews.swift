import SwiftUI
import SwiftData
import CampCore
import CampPersistence

/// Profile › Rig. Editing, replacing, archiving, and default checklists all work offline.
struct RigsSection: View {
    @Environment(LibraryController.self) private var library
    @Query(sort: \Rig.createdAt) private var rigs: [Rig]
    @State private var editor: RigEditorView.Mode?
    @State private var editingDefaults: Rig?
    @State private var resetting: Rig?
    @State private var failure: String?
    var body: some View {
        if rigs.needsRigResolution {
            Section {
                Label("You have \(rigs.active.count) active rigs", systemImage: "exclamationmark.triangle")
                Text("This can happen when two devices change rigs before syncing. Archive the one you no longer use; its trips keep showing it.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        ForEach(rigs.active) { rig in
            Section {
                HStack(spacing: 16) {
                    RigImage(rig: rig, size: 72)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(rig.displayName).font(.headline)
                        if !rig.detailSummary.isEmpty { Text(rig.detailSummary).font(.caption).foregroundStyle(.secondary) }
                        // Selectable so the plate or VIN can be copied into a booking or check-in form.
                        if !rig.plateSummary.isEmpty {
                            Text("Plate \(rig.plateSummary)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if !rig.vin.isEmpty {
                            Text("VIN \(rig.vin)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Text("Used by \(rig.activeTrips.count) trips").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 6)
                Button { editor = .edit(rig) } label: {
                    Label("Edit rig", systemImage: "pencil")
                        .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                }
                Button { editingDefaults = rig } label: {
                    Label("Default checklists", systemImage: "checklist")
                        .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                }
                Button { resetting = rig } label: {
                    Label("Reset default checklists", systemImage: "arrow.counterclockwise")
                        .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                }
                NavigationLink { DocumentsView(owner: .rig(rig), title: "Rig documents") } label: {
                    LabeledContent { Text(String(rig.attachedDocuments.count)) } label: { Label("Manuals & paperwork", systemImage: "folder").lineLimit(nil).fixedSize(horizontal: false, vertical: true) }
                }
                Button { editor = .replace(rig) } label: {
                    Label("Replace rig", systemImage: "arrow.triangle.2.circlepath")
                        .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                }
                if rigs.needsRigResolution {
                    Button("Archive this rig", systemImage: "archivebox") { rig.archive(); library.save() }
                }
            } header: { Text("Your rig") } footer: {
                Text("Editing updates every trip that uses this rig, past trips included. Sold it or got a new one? Use Replace rig: the current rig is archived and stays on past trips.")
            }
        }
        Section {
            if rigs.active.count < RigPolicy.maxActiveRigs {
                Button("Add a rig", systemImage: "plus") { editor = .add }
            }
            if !rigs.archived.isEmpty {
                NavigationLink { ArchivedRigsView() } label: {
                    LabeledContent { Text(String(rigs.archived.count)) } label: { Label("Archived rigs", systemImage: "archivebox") }
                }
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
        } footer: {
            Text(RigPolicy.maxActiveRigs == 1 ? "You can have one active rig at a time." : "You can have up to \(RigPolicy.maxActiveRigs) active rigs.")
        }
        .sheet(item: $editor) { mode in RigEditorView(mode: mode) }
        .sheet(item: $editingDefaults) { rig in TemplateEditorView(rig: rig) }
        .confirmationDialog("Reset default checklists?", isPresented: Binding(get: { resetting != nil }, set: { if !$0 { resetting = nil } }),
                            titleVisibility: .visible, presenting: resetting) { rig in
            Button("Reset defaults for \(rig.displayName)", role: .destructive) { rig.resetDefaults(); library.save() }
        } message: { _ in Text("Your default lists are regenerated from the rig type. Existing trips keep their own lists.") }
    }
}

struct ArchivedRigsView: View {
    @Environment(LibraryController.self) private var library
    @Query(sort: \Rig.createdAt) private var rigs: [Rig]
    @State private var failure: String?
    @State private var deleting: Rig?
    var body: some View {
        List {
            ForEach(rigs.archived) { rig in
                Section {
                    HStack(spacing: 16) {
                        RigImage(rig: rig, size: 56)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(rig.displayName).font(.headline)
                            let count = rig.activeTrips.count
                            Text(count == 0 ? "No trips use this rig" : "Shown on \(count) past trips").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    NavigationLink { DocumentsView(owner: .rig(rig), title: "Rig documents") } label: { Label("Manuals & paperwork", systemImage: "folder").lineLimit(nil).fixedSize(horizontal: false, vertical: true) }
                    Button("Make active again", systemImage: "arrow.uturn.backward") { perform { try rig.unarchive() } }
                        .disabled(rigs.active.count >= RigPolicy.maxActiveRigs)
                    if rig.activeTrips.isEmpty {
                        Button("Delete rig", systemImage: "trash", role: .destructive) { deleting = rig }
                    }
                }
            }
            if let failure { Text(failure).foregroundStyle(.red) }
        }
        .navigationTitle("Archived rigs")
        .confirmationDialog("Delete this rig?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { rig in
            Button("Delete \(rig.displayName)", role: .destructive) { perform { try rig.delete() } }
        } message: { _ in Text("Its default checklists are deleted. Its documents move to Unattached documents.") }
    }
    private func perform(_ action: () throws -> Void) {
        do { try action(); library.save(); failure = nil } catch { failure = error.localizedDescription }
    }
}

/// Add, edit, or replace a rig. Replacing archives the current rig and adds this one.
struct RigEditorView: View {
    enum Mode: Identifiable {
        case add, edit(Rig), replace(Rig)
        var id: String {
            switch self {
            case .add: "add"
            case .edit(let rig): "edit-\(rig.persistentModelID.hashValue)"
            case .replace(let rig): "replace-\(rig.persistentModelID.hashValue)"
            }
        }
    }
    @Environment(\.modelContext) private var context
    @Environment(LibraryController.self) private var library
    @Environment(\.dismiss) private var dismiss
    let mode: Mode
    @State private var draft: RigDraft
    @State private var regenerateDefaults = false
    @State private var failure: String?
    init(mode: Mode) {
        self.mode = mode
        if case .edit(let rig) = mode { _draft = State(initialValue: rig.draft) } else { _draft = State(initialValue: RigDraft()) }
    }
    private var checklistInputsChanged: Bool {
        guard case .edit(let rig) = mode else { return false }
        return rig.type != draft.type || rig.equipment != draft.equipment
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
                RigFormSections(rig: $draft)
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
                            switch mode {
                            case .add: try Rig.add(draft, to: context)
                            case .edit(let rig): try rig.update(draft, regenerateDefaults: checklistInputsChanged && regenerateDefaults)
                            case .replace(let old): try old.replace(with: draft)
                            }
                            library.save()
                            dismiss()
                        } catch { failure = error.localizedDescription }
                    }.disabled(!draft.hasRequiredDetails)
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
