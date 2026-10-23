import Foundation
import Network
import Observation
import SwiftUI

/// Whether the device has a usable network path, from `NWPathMonitor`. Shared through the environment.
@MainActor @Observable
final class Connectivity {
    private(set) var isOnline = false
    @ObservationIgnored private let monitor = NWPathMonitor()
    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in self?.isOnline = online }
        }
        monitor.start(queue: DispatchQueue(label: "RoamReady.Connectivity"))
    }
    deinit { monitor.cancel() }
}

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
