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

/// Opens the app-wide Assistant chat, in the style of `OpenURLAction`: call it like a function.
struct OpenAssistantAction {
    let handler: @MainActor () -> Void
    @MainActor func callAsFunction() { handler() }
}

extension EnvironmentValues {
    /// Nil where Assistant isn't offered.
    @Entry var openAssistant: OpenAssistantAction? = nil
}

/// In regular width (iPad, Mac, and large iPhones in landscape) the tab bar isn't at the bottom, so the
/// chat button sits in each tab's navigation bar instead of above the tab bar.
private struct AssistantToolbarButton: ViewModifier {
    @Environment(\.openAssistant) private var openAssistant
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        content.toolbar {
            if sizeClass == .regular, let openAssistant {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Ask RoamReady", systemImage: "sparkles") { openAssistant() }
                        .accessibilityIdentifier("assistantChatButton")
                }
            }
        }
    }
}

extension View {
    func assistantToolbarButton() -> some View { modifier(AssistantToolbarButton()) }
}
