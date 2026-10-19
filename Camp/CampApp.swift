import SwiftUI
import CampCore

@main
struct CampApp: App {
    @State private var store = CampStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            AppRoot()
                .environment(store)
                .tint(.blue)
                .task { await store.load() }
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { Task { await store.flushForBackground() } }
                }
        }
    }
}

struct AppRoot: View {
    @Environment(CampStore.self) private var store

    var body: some View {
        Group {
            if store.isLoading {
                ProgressView("Opening your trips…")
            } else if let failure = store.loadFailure {
                ContentUnavailableView {
                    Label("Your saved data needs attention", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text(failure)
                } actions: {
                    Button("Try again") { Task { await store.load() } }
                    if FileManager.default.fileExists(atPath: store.archiveURL.path) {
                        ShareLink("Export saved file", item: store.archiveURL)
                    }
                }
            } else if store.state.profile == nil {
                OnboardingView()
            } else {
                MainTabs()
            }
        }
        .alert("Couldn’t save changes", isPresented: Binding(
            get: { store.presentsSaveFailure },
            set: { if !$0 { store.dismissSaveFailure() } }
        )) {
            Button("Retry") { store.retrySave() }
            Button("Keep editing", role: .cancel) { }
        } message: {
            Text(store.saveFailure ?? "Your changes are still in memory. Try saving again before closing RoamReady.")
        }
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
