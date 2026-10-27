import SwiftUI
import SwiftData
import CampCore
import CampPersistence

struct ProfileView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Query private var profiles: [CamperProfile]
    @Query private var trips: [Trip]
    @Query(sort: \StoredDocument.createdAt, order: .reverse) private var documents: [StoredDocument]
    @State private var editing = false
    @State private var showingSettings = false
    @State private var showingFullScreenSettings = false
    private var unattached: [StoredDocument] { documents.filter { $0.rig == nil && $0.trip == nil } }
    var body: some View {
        List {
            if let profile = profiles.first {
                Section {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(profile.name.isEmpty ? "Your camping profile" : profile.name).font(.title3.bold())
                        Text(profile.experience.title).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                    Button { editing = true } label: {
                        WrappingLabel("Edit profile", systemImage: "pencil")
                    }
                }
                .sheet(isPresented: $editing) { EditProfileView(profile: profile) }
            }
            Section("Your camping") {
                NavigationLink { TripHistoryView() } label: {
                    LabeledContent {
                        Text(String(trips.filter { $0.isCompleted() }.count))
                    } label: {
                        WrappingLabel("Trip history", systemImage: "clock.arrow.circlepath")
                    }
                }
                .accessibilityIdentifier("tripHistoryLink")
                YourCampgroundsLink()
                    .accessibilityIdentifier("savedCampgroundsLink")
            }
            RigsSection()
            if !unattached.isEmpty {
                Section {
                    NavigationLink { UnattachedDocumentsView() } label: {
                        LabeledContent { Text(String(unattached.count)) } label: { WrappingLabel("Unattached documents", systemImage: "tray") }
                    }
                } footer: { Text("Documents from deleted trips and deleted rigs stay here until you delete them.") }
            }
        }
        .navigationTitle("Profile")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("App settings", systemImage: "gearshape") {
                    // Choose once when opened so changing text size keeps the presentation stable.
                    if dynamicTypeSize.isAccessibilitySize { showingFullScreenSettings = true }
                    else { showingSettings = true }
                }
                    .accessibilityIdentifier("openAppSettings")
            }
        }
        .sheet(isPresented: $showingSettings) { AppSettingsView() }
        .fullScreenCover(isPresented: $showingFullScreenSettings) { AppSettingsView() }
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
