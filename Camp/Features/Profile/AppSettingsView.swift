import SwiftUI
import SwiftData
import CampCore
import CampPersistence

/// App preferences and library maintenance, separate from the owner's camping profile.
struct AppSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(LibraryController.self) private var library
    @Query private var trips: [Trip]
    @Query private var photos: [TripPhoto]
    @Query private var documents: [StoredDocument]
    @State private var exportURL: URL?
    @State private var exportFailure: String?

    var body: some View {
        NavigationStack {
            Form {
                AppearanceSection()
                ICloudSection()
                Section {
                    SaveStatus()
                    LabeledContent("Trips", value: String(trips.count))
                    LabeledContent("Trip photos", value: String(photos.count))
                    LabeledContent("Documents", value: String(documents.count))
                    Button("Prepare export", systemImage: "square.and.arrow.up") {
                        do { exportURL = try library.export(); exportFailure = nil }
                        catch { exportFailure = error.localizedDescription }
                    }
                    .accessibilityIdentifier("prepareLibraryExport")
                    if let exportURL { ShareLink("Share export (.zip)", item: exportURL) }
                    if let exportFailure { Text(exportFailure).font(.caption).foregroundStyle(.red) }
                } header: { Text("On this device") } footer: {
                    Text("The export includes your profile, rigs, checklists, bookings, notes, saved campgrounds, and readable copies of your documents, including end-to-end encrypted ones. Keep it somewhere private. Share trip photos individually.")
                }
                Section {
                    NavigationLink { EraseDataView() } label: {
                        Label("Erase all data", systemImage: "trash").foregroundStyle(.red)
                    }
                } footer: {
                    Text("RoamReady has no accounts. Your library lives on this device and, if sync is on, in your own iCloud.")
                }
                Section("Camping help") {
                    Label(CampingAssistant.availability, systemImage: "sparkles").font(.subheadline)
                    Text("Assistant answers with Apple’s on-device model on any iPhone, iPad, or Mac that supports Apple Intelligence, when it’s turned on and its model is ready. Open it with the sparkle button above the tab bar or Ask Assistant in the toolbar. Questions stay on this device.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Privacy & support") {
                    Link(destination: URL(string: "https://github.com/TannerBarcelos/RoamReady/blob/main/docs/privacy-policy.md")!) {
                        Label("Privacy policy", systemImage: "hand.raised")
                    }
                    Link(destination: URL(string: "https://github.com/TannerBarcelos/RoamReady/issues")!) {
                        Label("Get help or report a problem", systemImage: "questionmark.circle")
                    }
                }
                Section {
                    Text("Camp Finder searches campgrounds and RV parks in Apple Maps, online only. Apple Maps doesn’t list every campground, and RoamReady doesn’t book or show availability.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let url = URL(string: ChecklistFactory.sourceURL) {
                        Link("Checklist reference: Camping World", destination: url)
                    }
                } header: { Text("Sources & coverage") } footer: {
                    Text("RoamReady · Development build 0.1")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Done")
                }
            }
        }
    }
}
