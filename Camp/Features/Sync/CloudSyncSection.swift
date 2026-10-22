import SwiftUI

struct CloudSyncSection: View {
    @Environment(CampStore.self) private var store
    var body: some View {
        Section {
            if store.sync.configured {
                Toggle("Sync with iCloud", isOn: Binding(
                    get: { store.sync.requested },
                    set: { value in Task { await store.setCloudSync(value) } }
                )).disabled(store.isTransitioning)
            }
            Label(store.sync.status, systemImage: store.sync.busy ? "arrow.triangle.2.circlepath.icloud" : "icloud")
                .font(.subheadline)
            if let date = store.sync.lastCheck {
                LabeledContent("Last iCloud activity") { Text(date, style: .relative).font(.caption) }
            }
            if store.sync.requested && store.sync.accountNeedsReview {
                Button("Check iCloud again", systemImage: "arrow.clockwise") { Task { await store.retryCloudSync() } }
                    .disabled(store.isTransitioning)
            }
            if let notice = store.libraryNotice { Text(notice).font(.caption).foregroundStyle(.secondary) }
        } header: { Text("iCloud") } footer: {
            if !store.sync.configured {
                Text("Your trips and photos work offline. iCloud sync isn’t available in this build.")
            } else if store.sync.requested {
                Text("Keeps a private copy of your profile, rig, trips, checklists, notes, and photos in your iCloud, so you can restore them on a new iPhone or use them on your iPad. Uses your iCloud storage. Everything still saves on this iPhone first and works offline.")
            } else {
                Text("Your data stays only on this iPhone. Turning sync off doesn’t delete anything here, and any copy already in iCloud stays there. You can delete it in Settings › [your name] › iCloud › Manage Account Storage.")
            }
        }
    }
}
