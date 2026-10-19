import SwiftUI

struct CloudSyncSection: View {
    @Environment(CampStore.self) private var store
    @State private var confirming = false
    var body: some View {
        Section {
            Label(store.sync.status, systemImage: store.sync.busy ? "arrow.triangle.2.circlepath.icloud" : "icloud")
                .font(.subheadline)
            if let date = store.sync.lastCheck {
                LabeledContent("Last iCloud check") { Text(date, style: .relative).font(.caption) }
            }
            if store.sync.configured {
                if store.sync.enabled {
                    Button("Check iCloud now") { store.sync.syncNow() }
                        .disabled(store.sync.busy || store.sync.accountNeedsReview)
                    if store.sync.accountNeedsReview {
                        Button("Check my iCloud account") { Task { await store.sync.enable() } }.disabled(store.sync.busy)
                    }
                    Button("Turn off iCloud sync") { Task { await store.sync.disable() } }
                } else {
                    Button("Enable iCloud sync") { confirming = true }.disabled(store.sync.busy)
                }
            }
            if let notice = store.libraryNotice { Text(notice).font(.caption).foregroundStyle(.secondary) }
        } header: { Text("iCloud") } footer: {
            Text(store.sync.configured
                 ? "Your trips save on this iPhone first. Sync uses your iCloud account when connected; an app account isn’t required. Turning sync off keeps your local library and existing iCloud copy."
                 : "Your trips and imported photos work offline. iCloud sync isn’t available in this build.")
        }
        .confirmationDialog("Sync this library with your current iCloud account?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Enable iCloud sync") { Task { await store.sync.enable() } }
        } message: {
            Text("Trips, checklists, notes, saved campgrounds, and imported photos will be stored in your private iCloud library and downloaded on your other devices. Existing iCloud trips will be added here.")
        }
    }
}
