import Foundation
import SwiftUI

// Share the existing NWPathMonitor-backed status throughout the application.
typealias Connectivity = ConnectionStatus
extension ConnectionStatus { var isOnline: Bool { connected } }

/// A network path is a prerequisite, not proof that a remote service is reachable.
struct OnlineFeatureGate<Content: View>: View {
    @Environment(Connectivity.self) private var connectivity
    let feature: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        if connectivity.isOnline {
            content()
        } else {
            ContentUnavailableView {
                Label("Connection needed", systemImage: "wifi.slash")
            } description: {
                Text("\(feature) needs an internet connection. Your planned trips, checklists, photos, and notes remain available offline.")
            }
        }
    }
}
