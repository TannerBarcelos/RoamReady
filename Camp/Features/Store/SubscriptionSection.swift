import SwiftUI
import StoreKit
import CampCore
import UIKit

/// Profile's purchase status, with the ways to subscribe, manage, or restore.
struct SubscriptionSection: View {
    @Environment(StoreController.self) private var store
    @State private var restoring = false
    @State private var restoreMessage: String?

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(store.status.title).font(.headline)
                if case .subscribed(_, let date?) = store.status {
                    Text("Renews or ends \(date.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !store.status.message.isEmpty {
                    Text(store.status.message).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("subscriptionStatus")
            switch store.status {
            case .readOnly:
                Button("See plans", systemImage: "sparkles") { PaywallPresenter.present(store: store) }
            case .subscribed:
                Button("Manage subscription", systemImage: "creditcard") {
                    // Apple's manage sheet, presented by StoreKit itself so it never competes with the
                    // rig and checklist sheets presented from this list.
                    guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else { return }
                    Task { try? await AppStore.showManageSubscriptions(in: scene); await store.refresh() }
                }
            case .lifetime, .checking:
                EmptyView()
            }
            if store.status != .lifetime {
                Button("Restore purchases", systemImage: "arrow.clockwise") {
                    restoring = true
                    Task {
                        defer { restoring = false }
                        do {
                            try await store.restore()
                            restoreMessage = store.status.canEdit ? "Purchases restored." : "No purchases found for this Apple Account."
                        } catch { restoreMessage = error.localizedDescription }
                    }
                }
                .disabled(restoring)
                if let restoreMessage { Text(restoreMessage).font(.caption).foregroundStyle(.secondary) }
            }
        } header: { Text("RoamReady Pro") }
        .task { await store.refresh() }
    }
}

/// A row explaining read-only access, with a way to the plans.
struct ReadOnlyNotice: View {
    @Environment(StoreController.self) private var store
    var body: some View {
        Button { PaywallPresenter.present(store: store) } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Read-only").font(.headline).foregroundStyle(.primary)
                    Text("Subscribe or buy Lifetime to add and edit.").font(.caption).foregroundStyle(.secondary)
                }
            } icon: { Image(systemName: "lock.fill").foregroundStyle(.orange) }
        }
        .accessibilityIdentifier("readOnlyNotice")
    }
}
