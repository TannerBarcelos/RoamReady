import SwiftUI
import CampCore

struct ProfileView: View {
    @Environment(CampStore.self) private var store
    @State private var editing = false
    @State private var editingTemplates = false
    @State private var resetConfirmation = false
    var body: some View {
        List {
            if let profile = store.state.profile {
                Section {
                    HStack(spacing: 16) {
                        RigImage(rig: profile.rig, size: 72)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(profile.name.isEmpty ? "Your camping profile" : profile.name).font(.title3.bold())
                            Text(profile.rig.displayName).foregroundStyle(.secondary)
                            Text(profile.experience.title).font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 6)
                    Button("Edit profile & rig", systemImage: "pencil") { editing = true }
                }
            }
            Section {
                Button("Edit my default checklists", systemImage: "checklist") { editingTemplates = true }
                Button("Restore defaults for my rig", systemImage: "arrow.counterclockwise") { resetConfirmation = true }
            } header: { Text("Your camping flow") } footer: {
                Text("New trips start with these lists. Each existing trip keeps its own steps and progress.")
            }
            Section {
                SaveStatus()
                LabeledContent("Trips on this iPhone", value: String(store.state.trips.count))
                LabeledContent("Trip photos", value: String(store.state.trips.reduce(0) { $0 + $1.photos.count }))
                if FileManager.default.fileExists(atPath: store.archiveURL.path) {
                    ShareLink(item: store.archiveURL) { Label("Export trip data (JSON)", systemImage: "square.and.arrow.up") }
                        .disabled(store.isSaving || store.saveFailure != nil)
                }
                if store.saveFailure != nil { Button("Retry saving", systemImage: "arrow.clockwise") { store.retrySave() } }
            } header: { Text("On this iPhone") } footer: {
                Text("JSON exports include your profile, checklists, and notes. Share photos individually from each trip. iCloud sync and account services are not enabled in this build.")
            }
            Section("Camping help") {
                Label(CampingAssistant.availability, systemImage: "iphone").font(.subheadline)
                Text("Saved guidance is always available. On supported iPhones with Apple Intelligence ready, Camp can explain that guidance on device. Online AI is not enabled in this build.").font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Text(store.catalogNotice).font(.footnote).foregroundStyle(.secondary)
                Text(CampgroundLibrary.notice).font(.footnote).foregroundStyle(.secondary)
                if let url = URL(string: ChecklistFactory.sourceURL) { Link("Checklist reference: Camping World", destination: url) }
            } header: { Text("Sources & coverage") } footer: {
                Text("Camp · Development build 0.1 · Design A\nAppearance follows your iPhone’s system settings.")
            }
        }
        .navigationTitle("Profile")
        .sheet(isPresented: $editing) {
            if let profile = store.state.profile { EditProfileView(profile: profile) }
        }
        .sheet(isPresented: $editingTemplates) {
            if let templates = store.state.templates { TemplateEditorView(templates: templates) }
        }
        .confirmationDialog("Restore the original checklists for your current rig?", isPresented: $resetConfirmation, titleVisibility: .visible) {
            Button("Restore defaults", role: .destructive) { store.resetTemplatesForRig() }
        } message: { Text("This replaces your reusable templates. Existing trips retain their custom lists.") }
    }
}

struct EditProfileView: View {
    @Environment(CampStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var profile: CamperProfile
    @State private var rebuildTemplates = true
    var rigChanged: Bool {
        guard let previous = store.state.profile?.rig else { return true }
        return previous.type != profile.rig.type || previous.equipment != profile.rig.equipment
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("About you") {
                    TextField("First name", text: $profile.name).textContentType(.givenName)
                    Picker("Experience", selection: $profile.experience) { ForEach(Experience.allCases) { Text($0.title).tag($0) } }
                }
                RigFormSections(rig: $profile.rig)
                if rigChanged {
                    Section {
                        Toggle("Create fresh checklist defaults", isOn: $rebuildTemplates)
                    } footer: { Text("Tailor future trips to your updated rig. Turn this off to keep your custom templates. Existing trips stay as they are.") }
                }
            }
            .navigationTitle("Profile & rig").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { store.updateProfile(profile, rebuildTemplates: rigChanged && rebuildTemplates); dismiss() }
                }
            }
        }
    }
}

struct TemplateEditorView: View {
    @Environment(CampStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var templates: ChecklistTemplates
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
                } footer: { Text("These are the starting steps for future trips. Progress always starts fresh.") }
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
            .navigationTitle("My default checklists").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { store.updateTemplates(templates); dismiss() } }
            }
            .sheet(item: $editedItem) { item in
                ChecklistItemEditor(item: item) { updated in change { list in if let index = list.firstIndex(where: { $0.id == updated.id }) { list[index] = updated } } }
            }
            .sheet(isPresented: $adding) { ChecklistItemEditor(item: ChecklistItem(title: "")) { updated in change { $0.append(updated) } } }
        }
    }
}
