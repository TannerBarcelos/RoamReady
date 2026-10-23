import SwiftUI
import CampCore

struct ProfileView: View {
    @Environment(CampStore.self) private var store
    @Environment(Connectivity.self) private var connectivity
    @State private var editing = false
    @State private var exportURL: URL?
    @State private var exportFailure: String?
    @State private var preparingExport = false
    var body: some View {
        List {
            if let profile = store.state.profile {
                Section {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(profile.name.isEmpty ? "Your camping profile" : profile.name).font(.title3.bold())
                        Text(profile.experience.title).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                    Button("Edit profile", systemImage: "pencil") { editing = true }
                }
            }
            RigsSection()
            if !store.unattachedDocuments.isEmpty {
                Section {
                    NavigationLink { UnattachedDocumentsView() } label: {
                        LabeledContent { Text(String(store.unattachedDocuments.count)) } label: { Label("Unattached documents", systemImage: "tray") }
                    }
                } footer: { Text("Documents from deleted trips and deleted rigs stay here until you delete them.") }
            }
            Section {
                SaveStatus()
                LabeledContent("Trips on this iPhone", value: String(store.state.trips.count))
                LabeledContent("Trip photos", value: String(store.state.trips.reduce(0) { $0 + $1.photos.count }))
                LabeledContent("Documents", value: String(store.documents.count))
                Button(preparingExport ? "Preparing export…" : "Prepare export", systemImage: "square.and.arrow.up") {
                    Task {
                        preparingExport = true; exportFailure = nil
                        defer { preparingExport = false }
                        do { exportURL = try await store.exportLibrary() }
                        catch { exportFailure = error.localizedDescription }
                    }
                }.disabled(preparingExport || store.isSaving || store.saveFailure != nil)
                if let exportURL { ShareLink("Share export (.zip)", item: exportURL) }
                if let exportFailure { Text(exportFailure).font(.caption).foregroundStyle(.red) }
                if store.saveFailure != nil { Button("Retry saving", systemImage: "arrow.clockwise") { store.retrySave() } }
            } header: { Text("On this iPhone") } footer: {
                Text("The export includes your profile, rigs, checklists, bookings, notes, saved campgrounds, and readable copies of your documents, including end-to-end encrypted ones. Keep it somewhere private. Share trip photos individually.")
            }
            Section {
                NavigationLink { EraseDataView() } label: {
                    Label("Erase all data", systemImage: "trash").foregroundStyle(.red)
                }
            } footer: { Text("RoamReady has no accounts. Your library lives on this iPhone and, if sync is on, in your own iCloud.") }
            CloudSyncSection().disabled(!connectivity.isOnline)
            Section("Camping help") {
                Label(CampingAssistant.availability, systemImage: "iphone").font(.subheadline)
                Text("Saved guidance is always available. AI explanations use Apple’s on-device model on iPhones that support Apple Intelligence (iPhone 15 Pro or later) when it’s turned on and its model is ready. Questions stay on this device.").font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Text("Camp Finder downloads a dated federal campground and campsite snapshot from RIDB. It does not show live booking availability.").font(.footnote).foregroundStyle(.secondary)
                if let url = URL(string: ChecklistFactory.sourceURL) { Link("Checklist reference: Camping World", destination: url) }
            } header: { Text("Sources & coverage") } footer: {
                Text("RoamReady · Development build 0.1 · Design A\nAppearance follows your iPhone’s system settings.")
            }
        }
        .navigationTitle("Profile")
        .sheet(isPresented: $editing) {
            if let profile = store.state.profile { EditProfileView(profile: profile) }
        }
    }
}

struct EditProfileView: View {
    @Environment(CampStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var profile: CamperProfile
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("About you") {
                    TextField("First name", text: $profile.name).textContentType(.givenName)
                    Picker("Experience", selection: $profile.experience) { ForEach(Experience.allCases) { Text($0.title).tag($0) } }
                }
                if let failure { Text(failure).foregroundStyle(.red) }
            }
            .navigationTitle("Profile").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do { try store.updateProfile(profile); dismiss() } catch { failure = error.localizedDescription }
                    }
                }
            }
        }
    }
}
