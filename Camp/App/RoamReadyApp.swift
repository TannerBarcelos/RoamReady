import SwiftUI
import SwiftData
import CampPersistence

@main
struct RoamReadyApp: App {
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system
    @State private var library = LibraryController()
    @State private var connectivity = Connectivity()
    @State private var campFinder = CampFinder()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if let container = library.container {
                    RootView().modelContainer(container)
                } else if let failure = library.openFailure {
                    ContentUnavailableView {
                        Label("Your saved data needs attention", systemImage: "externaldrive.badge.exclamationmark")
                    } description: { Text(failure) } actions: {
                        Button("Try again") { Task { await library.open(online: connectivity.isOnline) } }
                    }
                } else {
                    ProgressView("Opening your trips…")
                }
            }
            .environment(library)
            .environment(connectivity)
            .environment(campFinder)
            .tint(.blue)
            .preferredColorScheme(appearance.colorScheme)
            // No accounts: the library belongs to this device and its iCloud account, and opens offline.
            .task { await library.open(online: connectivity.isOnline) }
            .task(id: connectivity.isOnline) {
                if connectivity.isOnline, library.sync.waitingForConnection { await library.reopen(online: true) }
            }
            .onChange(of: scenePhase) { _, phase in
                library.sync.setActive(phase == .active)
                if phase != .active { library.save() }
            }
        }
    }
}

struct RootView: View {
    @Environment(LibraryController.self) private var library
    @Query private var profiles: [CamperProfile]
    var body: some View {
        Group {
            if profiles.isEmpty { OnboardingView() } else { MainTabs() }
        }
        .alert("Couldn’t save changes", isPresented: Binding(get: { library.saveFailure != nil }, set: { _ in })) {
            Button("Retry") { library.save() }
        } message: { Text(library.saveFailure ?? "") }
    }
}

struct MainTabs: View {
    var body: some View {
        TabView {
            Tab("Home", systemImage: "house") { NavigationStack { HomeView() } }
            Tab("Plan", systemImage: "calendar") { NavigationStack { PlanView() } }
            Tab("Camp Finder", systemImage: "map") { NavigationStack { CampFinderView() } }
            Tab("Profile", systemImage: "person.crop.circle") { NavigationStack { ProfileView() } }
        }
    }
}

enum CampUIError: LocalizedError {
    case missingRig, unreadablePhoto
    var errorDescription: String? {
        switch self {
        case .missingRig: "Add a rig in Profile before adding a trip."
        case .unreadablePhoto: "This photo couldn’t be opened. If it’s stored in iCloud Photos, download it while online and try again."
        }
    }
}
