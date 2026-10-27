import SwiftUI
import UIKit
import os
import CampCore

extension EnvironmentValues {
    /// True in a scene whose device reported a hinge (iPhone Duo), or with `-duo-ui-test` in Debug.
    /// Screens read this to choose their Duo layout; everywhere else keeps the current presentation.
    @Entry var usesDuoWorkspace = false
}

extension View {
    /// Observes the scene's hinge and publishes `usesDuoWorkspace` to the content below it.
    /// Apply it once, at the root of each window's content, so every scene owns its own state.
    func observesDuoWorkspace() -> some View { modifier(DuoWorkspaceObserver()) }
}

enum DuoWorkspace {
    static let logger = Logger(subsystem: "com.tannerdev.roamready", category: "DuoWorkspace")

    #if DEBUG
    static let uiTestArgument = "-duo-ui-test"
    static var isForcedForUITests: Bool { ProcessInfo.processInfo.arguments.contains(uiTestArgument) }
    /// UI tests read a marker element; normal Debug runs don't add it to VoiceOver.
    static var exposesUITestMarker: Bool { ProcessInfo.processInfo.arguments.contains { $0.hasSuffix("-ui-test") } }
    #else
    static let isForcedForUITests = false
    #endif
}

private struct DuoWorkspaceObserver: ViewModifier {
    @State private var capability = HingeCapability(forced: DuoWorkspace.isForcedForUITests)

    func body(content: Content) -> some View {
        content
            .background {
                HingeObserver { hingeReported in
                    let wasOn = capability.usesDuoWorkspace
                    capability.record(hingeReported: hingeReported)
                    if capability.usesDuoWorkspace != wasOn {
                        DuoWorkspace.logger.info("Hinge reported; using the Duo workspace")
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .environment(\.usesDuoWorkspace, capability.usesDuoWorkspace)
            #if DEBUG
            .overlay(alignment: .topLeading) {
                if capability.usesDuoWorkspace && DuoWorkspace.exposesUITestMarker {
                    Color.clear.frame(width: 1, height: 1)
                        .accessibilityElement()
                        .accessibilityLabel("Duo workspace")
                        .accessibilityIdentifier("duoWorkspace")
                        .allowsHitTesting(false)
                }
            }
            #endif
    }
}

/// Hosts a `UIHingeInteraction` in the scene's view hierarchy. The interaction reports the
/// initial hinge state once the view joins a window, then each change.
private struct HingeObserver: UIViewRepresentable {
    let onUpdate: @MainActor (_ hingeReported: Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        context.coordinator.onUpdate = onUpdate
        // Mac Catalyst has no hinge API, and iOS 27.0 keeps the current presentation.
        #if !targetEnvironment(macCatalyst)
        if #available(iOS 27.1, *) {
            let coordinator = context.coordinator
            view.addInteraction(UIHingeInteraction { _, update in
                if let hinge = update.hinge {
                    DuoWorkspace.logger.debug("Hinge update: status \(hinge.status.rawValue), angle \(hinge.angle)")
                } else {
                    DuoWorkspace.logger.debug("Hinge update: no hinge in this hierarchy")
                }
                coordinator.onUpdate(update.hinge != nil)
            })
        }
        #endif
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.onUpdate = onUpdate
    }

    @MainActor
    final class Coordinator {
        var onUpdate: @MainActor (Bool) -> Void = { _ in }
    }
}
