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
                Text("iCloud sync isn’t available in this build.")
            } else if sync.enabledForSession {
                Text("Keep your library across your devices with iCloud. Changes to this setting take effect the next time you open RoamReady.")
            } else {
                Text("Turn on iCloud to keep your library across your devices. Changes take effect the next time you open RoamReady. Turning sync off keeps your existing data.")
            }
        }
    }
}
