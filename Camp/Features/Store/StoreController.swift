import Foundation
import Observation
import StoreKit
import UIKit
import SwiftUI
import CampCore

/// Tracks what the camper has bought and decides whether edits are allowed. StoreKit keeps purchases
/// on the device, so this works offline; there is no server and no account.
@MainActor @Observable
final class StoreController {
    private(set) var status: AccessStatus = .checking
    private var updates: Task<Void, Never>?
    #if DEBUG
    private let override: AccessStatus? = StoreController.debugOverride
    #endif

    init() {
        #if DEBUG
        if let override { status = override; return }
        #endif
        // Renewals, refunds, Ask to Buy approvals, and purchases on other devices arrive here.
        updates = Task { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let transaction) = update { await transaction.finish() }
                await self?.refresh()
            }
        }
    }

    /// UI tests pin access, so they never get the one-time plans sheet at launch.
    var offersPlansAtLaunch: Bool {
        #if DEBUG
        if override != nil { return false }
        #endif
        return true
    }

    func refresh() async {
        #if DEBUG
        if let override { setStatus(override); return }
        #endif
        var entitlements: [StoreEntitlement] = []
        for await result in Transaction.currentEntitlements {
            // Unverified transactions failed Apple's signature check, so they never unlock anything.
            guard case .verified(let transaction) = result else { continue }
            entitlements.append(StoreEntitlement(productID: transaction.productID,
                                                 expirationDate: transaction.expirationDate,
                                                 isRevoked: transaction.revocationDate != nil))
        }
        setStatus(AccessStatus.resolve(entitlements))
    }

    /// `@Observable` notifies on every assignment, so an unchanged status would still redraw every screen
    /// that reads it, including ones under an open sheet. Refreshes happen on each foregrounding.
    private func setStatus(_ new: AccessStatus) {
        if status != new { status = new }
    }

    /// Runs `action` when the camper can edit; otherwise shows the paywall over whatever is on screen.
    func ifFullAccess(_ action: @escaping @MainActor () -> Void) {
        if status.canEdit { action(); return }
        Task {
            if status == .checking { await refresh() }
            if status.canEdit { action() } else { PaywallPresenter.present(store: self) }
        }
    }

    func restore() async throws {
        try await AppStore.sync()
        await refresh()
    }

    #if DEBUG
    /// `-store-ui-test full|read-only` pins access. Other UI-test and smoke launches get full access, so
    /// tests written before subscriptions keep adding and editing without a paywall.
    private static var debugOverride: AccessStatus? {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-store-ui-test"), arguments.indices.contains(index + 1) {
            return arguments[index + 1] == "read-only" ? .readOnly : .lifetime
        }
        let testFlags = ["-navigation-ui-test", "-workflow-ui-test", "-assistant-ui-test", "-layout-ui-test", "-assistant-device-smoke", "-app-store-screenshots"]
        return arguments.contains(where: testFlags.contains) ? .lifetime : nil
    }
    #endif
}

/// Presents the paywall from UIKit's topmost view controller. A SwiftUI sheet on the root can't appear over
/// an editor that's already a sheet, and that's exactly where Save gets tapped.
@MainActor
enum PaywallPresenter {
    private final class Host: UIHostingController<AnyView> {}

    static func present(store: StoreController) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard var top = scene?.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        guard !(top is Host) else { return }
        let host = Host(rootView: AnyView(EmptyView()))
        host.rootView = AnyView(PaywallView { [weak host] in host?.dismiss(animated: true) }
            .environment(store)
            .tint(.blue))
        top.present(host, animated: true)
    }
}
