import SwiftUI
import SwiftData
import CampCore
import CampPersistence

struct ProfileView: View {
    @Environment(LibraryController.self) private var library
    @Environment(Connectivity.self) private var connectivity
    @Query private var profiles: [CamperProfile]
    @Query private var trips: [Trip]
    @Query private var photos: [TripPhoto]
    @Query(sort: \StoredDocument.createdAt, order: .reverse) private var documents: [StoredDocument]
    @State private var editing = false
    @State private var exportURL: URL?
    @State private var exportFailure: String?
    private var unattached: [StoredDocument] { documents.filter { $0.rig == nil && $0.trip == nil } }
    var body: some View {
        List {
            if let profile = profiles.first {
                Section {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(profile.name.isEmpty ? "Your camping profile" : profile.name).font(.title3.bold())
                        Text(profile.experience.title).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                    Button("Edit profile", systemImage: "pencil") { editing = true }
                }
                .sheet(isPresented: $editing) { EditProfileView(profile: profile) }
            }
            RigsSection()
            if !unattached.isEmpty {
                Section {
                    NavigationLink { UnattachedDocumentsView() } label: {
                        LabeledContent { Text(String(unattached.count)) } label: { Label("Unattached documents", systemImage: "tray") }
                    }
                } footer: { Text("Documents from deleted trips and deleted rigs stay here until you delete them.") }
            }
            Section {
                SaveStatus()
                LabeledContent("Trips", value: String(trips.count))
                LabeledContent("Trip photos", value: String(photos.count))
                LabeledContent("Documents", value: String(documents.count))
                Button("Prepare export", systemImage: "square.and.arrow.up") {
                    do { exportURL = try library.export(); exportFailure = nil }
                    catch { exportFailure = error.localizedDescription }
                }
                if let exportURL { ShareLink("Share export (.zip)", item: exportURL) }
                if let exportFailure { Text(exportFailure).font(.caption).foregroundStyle(.red) }
            } header: { Text("On this iPhone") } footer: {
                Text("The export includes your profile, rigs, checklists, bookings, notes, saved campgrounds, and readable copies of your documents, including end-to-end encrypted ones. Keep it somewhere private. Share trip photos individually.")
            }
            Section {
                NavigationLink { EraseDataView() } label: { Label("Erase all data", systemImage: "trash").foregroundStyle(.red) }
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
    }
}

struct EditProfileView: View {
    @Environment(LibraryController.self) private var library
    @Environment(\.dismiss) private var dismiss
    let profile: CamperProfile
    @State private var name: String
    @State private var experience: Experience
    init(profile: CamperProfile) {
        self.profile = profile
        _name = State(initialValue: profile.name); _experience = State(initialValue: profile.experience)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("About you") {
                    TextField("First name", text: $name).textContentType(.givenName)
                    Picker("Experience", selection: $experience) { ForEach(Experience.allCases) { Text($0.title).tag($0) } }
                }
            }
            .navigationTitle("Profile").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { profile.name = name; profile.experience = experience; library.save(); dismiss() }
                }
            }
        }
    }
}
