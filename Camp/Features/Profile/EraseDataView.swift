import SwiftUI

/// Erase all data. Explicit about what goes, confirmed twice, and honest about which step failed.
struct EraseDataView: View {
    @Environment(Connectivity.self) private var connectivity
    @Environment(CampStore.self) private var store
    @State private var understood = false
    @State private var confirming = false
    @State private var step: LibraryErase.Step?
    @State private var failure: String?
    private var blockedOffline: Bool { LibraryErase.needsConnection(store) && !connectivity.isOnline }
    var body: some View {
        Form {
            Section {
                Text("Erasing permanently deletes:").font(.headline)
                ForEach(Self.erased, id: \.self) { Label($0, systemImage: "trash").font(.subheadline) }
            } footer: {
                Text("Export your library first from Profile if you want a copy. Original photos in your photo library aren’t touched. Other iPhones and iPads using the same iCloud account stop syncing and keep what they already have until you erase them too.")
            }
            Section {
                Toggle("I understand this can’t be undone", isOn: $understood)
            }
            Section {
                if blockedOffline {
                    Label("Erasing your iCloud data needs a connection", systemImage: "wifi.slash")
                } else if let step {
                    ProgressView(step.rawValue + "…")
                } else {
                    Button("Erase all data", role: .destructive) { confirming = true }
                        .disabled(!understood)
                }
                if let failure { Text(failure).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Erase all data")
        .interactiveDismissDisabled(step != nil)
        .confirmationDialog("Erase everything RoamReady has saved?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Erase all data", role: .destructive) { Task { await erase() } }
        } message: { Text("Your iCloud copy is deleted first, then this iPhone. RoamReady starts over afterwards.") }
    }

    static let erased = [
        "Your trips, bookings, checklists, and their progress",
        "Notes and every saved note version, site notes, and ratings",
        "Trip and rig photos saved in RoamReady",
        "Your profile, rigs, their default checklists, and all documents",
        "Saved campgrounds, cached forecasts, and settings",
        "Your RoamReady data in iCloud",
    ]

    private func erase() async {
        failure = nil
        await store.flushForBackground()
        do { try await LibraryErase.run(store: store) { step = $0 } }
        catch { failure = error.localizedDescription }
        step = nil
        // After a successful erase the library reopens empty, which starts onboarding again.
        if failure == nil { await store.load(online: connectivity.isOnline) }
    }
}
