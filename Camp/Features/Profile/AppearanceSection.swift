import SwiftUI

struct AppearanceSection: View {
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Section {
            if dynamicTypeSize.isAccessibilitySize {
                // Segmented controls have a fixed text size on iPad. Full rows keep every choice readable.
                ForEach(AppAppearance.allCases) { option in
                    Button { appearance = option } label: {
                        HStack {
                            Text(option.title).foregroundStyle(.primary)
                            Spacer()
                            if appearance == option {
                                Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityHidden(true)
                            }
                        }
                    }
                    .accessibilityAddTraits(appearance == option ? .isSelected : [])
                    .accessibilityIdentifier("appearanceOption-\(option.rawValue)")
                }
            } else {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("appearancePicker")
            }
        } header: {
            Text("Appearance")
        } footer: {
            Text("System follows your device’s Light or Dark appearance. Your choice applies throughout RoamReady.")
        }
    }
}
