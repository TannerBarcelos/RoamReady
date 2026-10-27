import SwiftUI

struct ICloudSection: View {
    @Environment(LibraryController.self) private var library
    var body: some View {
        let sync = library.iCloud
        Section {
            if sync.configured {
                Toggle("Sync with iCloud", isOn: Binding(
                    get: { sync.requested },
                    set: { sync.setRequested($0) }))
            }
            Label(sync.status, systemImage: "icloud").font(.subheadline)
            if sync.hasPendingChange {
                Text(sync.requested ? "iCloud sync will turn on the next time you launch RoamReady."
                                    : "iCloud sync remains on until you close RoamReady. It will be off the next time you launch it.")
                    .font(.footnote)
            }
            if let date = sync.lastActivity {
                LabeledContent("Last successful iCloud activity") { Text(date, style: .relative).font(.caption) }
            }
        } header: { Text("iCloud") } footer: {
            if !sync.configured {
                Text("Your trips and photos work offline. iCloud sync isn’t available in this build.")
            } else if sync.enabledForSession {
                Text("Apple manages syncing your profile, rigs, trips, checklists, notes, photos, and documents with your iCloud, including reconnection and retries. Uses your iCloud storage. Everything saves on this device first and works offline. Changes to this setting take effect on the next app launch.")
            } else {
                Text("New changes save on this device without syncing to iCloud. Changes to this setting take effect on the next app launch. Turning sync off doesn’t delete anything here or any copy already in iCloud. You can delete that copy in Settings › [your name] › iCloud › Manage Account Storage.")
            }
        }
    }
}
