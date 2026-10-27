import SwiftUI

struct AppearanceSection: View {
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system

    var body: some View {
        Section {
            // Keep the same scalable controls at every text size, including during system changes.
            ForEach(AppAppearance.allCases) { option in
                Button { appearance = option } label: {
                    HStack {
                        Text(option.title)
                            .font(.body).foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if appearance == option {
                            Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityHidden(true)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(appearance == option ? .isSelected : [])
                .accessibilityIdentifier("appearanceOption-\(option.rawValue)")
            }
        } header: {
            Text("Appearance")
        } footer: {
            Text("System follows your device’s Light or Dark appearance. Your choice applies throughout RoamReady.")
        }
    }
}
