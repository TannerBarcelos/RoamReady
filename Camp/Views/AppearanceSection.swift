import SwiftUI

struct AppearanceSection: View {
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system

    var body: some View {
        Section {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppAppearance.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("appearancePicker")
        } header: {
            Text("Appearance")
        } footer: {
            Text("System follows your device’s Light or Dark appearance. Your choice applies throughout RoamReady.")
        }
    }
}
