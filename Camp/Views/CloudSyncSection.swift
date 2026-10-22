import SwiftUI

struct CloudSyncSection: View {
    @Environment(CampStore.self) private var store
    @Environment(Connectivity.self) private var connectivity
    @State private var confirming = false
    var body: some View {
        Section {
            Label(store.sync.status, systemImage: store.sync.busy ? "arrow.triangle.2.circlepath.icloud" : "icloud")
                .font(.subheadline)
            if let date = store.sync.lastCheck {
                LabeledContent("Last iCloud activity") { Text(date, style: .relative).font(.caption) }
            }
            if store.sync.configured {
                if store.sync.requiresRestart {
                    Text("Close and reopen RoamReady to apply this setting.").font(.caption).foregroundStyle(.secondary)
                }
                if store.sync.accountNeedsReview {
                    Button("Approve original iCloud account") { Task { await store.sync.enable() } }
                        .disabled(!connectivity.isOnline || store.sync.busy)
                }
                if store.sync.requested {
                    Button("Turn off iCloud sync") { Task { await store.sync.disable() } }
                        .disabled(!connectivity.isOnline)
                } else {
                    Button("Enable iCloud sync") { confirming = true }.disabled(!connectivity.isOnline || store.sync.busy)
                }
            }
            if let notice = store.libraryNotice { Text(notice).font(.caption).foregroundStyle(.secondary) }
        } header: { Text("iCloud") } footer: {
            Text(store.sync.configured
                 ? "Trips save on this iPhone first. Apple manages sync timing, retries, and attachment transfers using your iCloud account. Sync settings apply on the next launch; they don’t remove your existing iCloud copy."
                 : "Your trips and imported photos work offline. iCloud sync isn’t available in this build.")
        }
        .confirmationDialog("Enable iCloud sync on the next launch?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Enable iCloud sync") { Task { await store.sync.enable() } }
        } message: {
            Text("Trips, checklists, notes, saved campgrounds, and imported photos will sync through your private iCloud account. Apple controls when transfers run. Other devices need to download attachments before using them offline.")
        }
    }
}
