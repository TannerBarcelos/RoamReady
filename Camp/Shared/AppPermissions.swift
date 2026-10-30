import SwiftUI
import UIKit
import CoreLocation
import AVFoundation
import Observation

/// Resolves the app's optional permissions before onboarding. Only unanswered permissions prompt.
@MainActor @Observable
final class AppPermissions: NSObject, CLLocationManagerDelegate {
    private(set) var location: CLAuthorizationStatus = .notDetermined
    private(set) var camera: AVAuthorizationStatus = .notDetermined
    private(set) var hasCheckedOnLaunch = false
    private(set) var locationServicesEnabled = true
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var requestingLocation = false
    @ObservationIgnored private var requestingCamera = false
    #if DEBUG
    @ObservationIgnored private var fixture: String?
    #endif

    override init() {
        super.init()
        manager.delegate = self
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-permissions-ui-test"), arguments.indices.contains(index + 1) {
            fixture = arguments[index + 1]
        }
        // Existing navigation/workflow tests must not depend on the simulator's privacy database.
        if !arguments.contains("-permissions-system-ui-test"),
           fixture != nil || arguments.contains("-navigation-ui-test") || arguments.contains("-workflow-ui-test")
            || CampingAssistant.isRunningAssistantUITests {
            fixture = fixture ?? "denied"
            hasCheckedOnLaunch = true
        }
        #endif
        refresh()
    }

    var locationAllowed: Bool {
        locationServicesEnabled && (location == .authorizedWhenInUse || location == .authorizedAlways)
    }

    var locationDenied: Bool { !locationServicesEnabled || location == .denied || location == .restricted }
    var cameraDenied: Bool { camera == .denied || camera == .restricted }

    func refresh() {
        #if DEBUG
        if let fixture {
            location = fixture == "allowed" ? .authorizedWhenInUse : .denied
            camera = fixture == "allowed" ? .authorized : .denied
            return
        }
        #endif
        location = manager.authorizationStatus
        camera = AVCaptureDevice.authorizationStatus(for: .video)
        locationServicesEnabled = CLLocationManager.locationServicesEnabled()
    }

    /// Foregrounding resumes the sequence after each native prompt, and picks up Settings changes.
    func checkOnLaunch() {
        refresh()
        guard !requestingLocation, !requestingCamera,
              UIApplication.shared.applicationState == .active else { return }
        if locationServicesEnabled, location == .notDetermined {
            requestingLocation = true
            manager.requestWhenInUseAuthorization()
            return
        }
        if CameraAccess.isAvailable, camera == .notDetermined {
            requestingCamera = true
            Task {
                try? await CameraAccess.request()
                requestingCamera = false
                checkOnLaunch()
            }
            return
        }
        hasCheckedOnLaunch = true
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            if status != .notDetermined { requestingLocation = false }
            checkOnLaunch()
        }
    }
}

struct OpenPermissionSettingsButton: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button("Open Settings", systemImage: "gear") {
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        }
    }
}
