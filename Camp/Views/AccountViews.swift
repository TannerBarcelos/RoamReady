import SwiftUI
import AuthenticationServices

struct AccountWelcomeView: View {
    @Environment(AccountSession.self) private var account
    @Environment(Connectivity.self) private var connectivity
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Image(systemName: "tent.2").font(.system(size: 44)).foregroundStyle(.blue)
                    Text(account.hasPinnedAccount ? "Welcome back" : "Your next adventure starts here").font(.largeTitle.bold())
                    Text("Create your account and set up your rig while online. Then your planned trips, checklists, photos, and notes travel with you—even without reception.")
                }
                Section {
                    if connectivity.isOnline {
                        SignInWithAppleButton(account.hasPinnedAccount ? .signIn : .signUp) { request in
                            account.prepare(request)
                        } onCompletion: { result in
                            account.complete(result, online: connectivity.isOnline)
                        }
                        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                        .frame(height: 50)
                    } else {
                        Label("Connect to finish account setup", systemImage: "wifi.slash")
                        Text("Downloading the app does not complete onboarding. Connect to Wi-Fi or cellular data before your first trip.").foregroundStyle(.secondary)
                    }
                    if let failure = account.failure ?? account.startupFailure { Text(failure).foregroundStyle(.red) }
                } footer: {
                    Text("Sign in once online. Your saved trips remain available offline while you stay signed in.")
                }
                if account.hasPinnedAccount {
                    Section { Text("Use the Apple Account originally linked to this library. Signing out does not delete trips or permit a different account to open them.").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("RoamReady")
            .confirmationDialog("Link the existing library on this device?", isPresented: Binding(
                get: { account.needsLegacyAdoption }, set: { if !$0 { account.cancelAdoption() } }
            ), titleVisibility: .visible) {
                Button("Link my existing library") { account.adoptLegacyLibrary(online: connectivity.isOnline) }
                Button("Cancel", role: .cancel) { account.cancelAdoption() }
            } message: {
                Text("This device has camping data from an earlier build without accounts. Confirm it is yours before linking it permanently to this Apple Account. Nothing will be deleted.")
            }
        }
    }
}

struct AccountSettingsView: View {
    @Environment(AccountSession.self) private var account
    @Environment(Connectivity.self) private var connectivity
    @Environment(CampStore.self) private var store
    @State private var signingOut = false
    @State private var signOutFailure: String?
    @State private var preparingSignOut = false
    var body: some View {
        OnlineFeatureGate(feature: "Account changes") {
            List {
                Section("Apple Account") {
                    Label("Signed in with Apple", systemImage: "person.crop.circle.badge.checkmark")
                    if !account.displayName.isEmpty { LabeledContent("Name", value: account.displayName) }
                    if !account.email.isEmpty { LabeledContent("Email", value: account.email) }
                    Text("Your library remains available offline while you stay signed in. Apple supplies your name and email only when you first grant access.").font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button("Sign out", role: .destructive) { signingOut = true }
                        .disabled(preparingSignOut || store.isSaving || store.saveFailure != nil)
                    if store.saveFailure != nil { Text("Save your latest changes before signing out.").foregroundStyle(.secondary) }
                    if let signOutFailure { Text(signOutFailure).foregroundStyle(.red) }
                    if let failure = account.failure { Text(failure).foregroundStyle(.red) }
                } footer: {
                    Text("Signing out locks this device’s library and keeps its data. Reopening it requires an internet connection and the same Apple Account.")
                }
                Section("Account removal") {
                    Text("Account deletion is not available in this development build. Signing out does not delete local or iCloud data.")
                    Text("You can revoke Sign in with Apple access in Settings → your Apple Account → Sign in with Apple → RoamReady. This revokes access; it does not delete your camping library.").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Account")
        .confirmationDialog("Sign out and lock your saved library?", isPresented: $signingOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) {
                Task {
                    preparingSignOut = true
                    defer { preparingSignOut = false }
                    await store.flushForBackground()
                    guard store.saveFailure == nil, !store.isSaving else {
                        signOutFailure = "Your latest changes need saving. Retry saving before signing out."
                        return
                    }
                    account.signOut(online: connectivity.isOnline)
                }
            }
        }
    }
}
