import SwiftUI

/// The global way into Assistant: a platter above the tab bar on every tab.
/// It shrinks to its icon and a short label when the tab bar minimizes.
struct AssistantChatButton: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(.tint)
                Text(placement == .inline ? "Ask" : "Ask RoamReady").foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if placement != .inline {
                    Image(systemName: "bubble.left.and.text.bubble.right").foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ask RoamReady")
        .accessibilityHint("Opens the camping assistant")
        .accessibilityIdentifier("assistantChatButton")
    }
}
