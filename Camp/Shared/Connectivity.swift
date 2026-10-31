import Foundation
import Network
import Observation
import SwiftUI

/// Whether the device has a usable network path, from `NWPathMonitor`. Shared through the environment.
@MainActor @Observable
final class Connectivity {
    private(set) var isOnline = false
    @ObservationIgnored private let monitor = NWPathMonitor()
    #if DEBUG
    @ObservationIgnored private var usesFixture = false
    #endif
    init() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-connectivity-ui-test"), arguments.indices.contains(index + 1) {
            usesFixture = true
            isOnline = arguments[index + 1] == "online"
            return
        }
        #endif
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in self?.isOnline = online }
        }
        monitor.start(queue: DispatchQueue(label: "RoamReady.Connectivity"))
    }
    deinit { monitor.cancel() }
    /// Reads the current path again, for a Try again button.
    func recheck() {
        #if DEBUG
        if usesFixture { return }
        #endif
        isOnline = monitor.currentPath.status == .satisfied
    }
}

/// A network path is a prerequisite, not proof that a remote service is reachable.
struct OnlineFeatureGate<Content: View>: View {
    @Environment(Connectivity.self) private var connectivity
    let feature: String
    /// Runs when the person taps Try again; the gate itself reopens as soon as a path returns.
    var retry: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content
    var body: some View {
        if connectivity.isOnline {
            content()
        } else {
            ContentUnavailableView {
                Label("Connection needed", systemImage: "wifi.slash")
            } description: {
                Text("\(feature) needs an internet connection. Your planned trips, checklists, photos, notes, and saved campgrounds remain available offline.")
            } actions: {
                Button("Try again") { connectivity.recheck(); retry?() }
            }
        }
    }
}
