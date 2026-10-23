import SwiftUI

struct CloudSyncSection: View {
    @Environment(LibraryController.self) private var library
    @Environment(Connectivity.self) private var connectivity
    var body: some View {
        let sync = library.sync
        Section {
            if sync.configured {
                Toggle("Sync with iCloud", isOn: Binding(
                    get: { sync.requested },
                    set: { value in Task { await library.setCloudSync(value, online: connectivity.isOnline) } }))
            }
            Label(sync.status, systemImage: sync.busy ? "arrow.triangle.2.circlepath.icloud" : "icloud").font(.subheadline)
            if let date = sync.lastActivity {
                LabeledContent("Last iCloud activity") { Text(date, style: .relative).font(.caption) }
            }
            if sync.requested && sync.accountNeedsReview {
                Button("Check iCloud again", systemImage: "arrow.clockwise") { Task { await library.reopen(online: connectivity.isOnline) } }
            }
        } header: { Text("iCloud") } footer: {
            if !sync.configured {
                Text("Your trips and photos work offline. iCloud sync isn’t available in this build.")
            } else if sync.requested {
                Text("Keeps a private copy of your profile, rig, trips, checklists, notes, photos, and documents in your iCloud, so you can restore them on a new iPhone or use them on your iPad. Uses your iCloud storage. Everything still saves on this iPhone first and works offline.")
            } else {
                Text("Your data stays only on this iPhone. Turning sync off doesn’t delete anything here, and any copy already in iCloud stays there. You can delete it in Settings › [your name] › iCloud › Manage Account Storage.")
            }
        }
    }
}
