import SwiftUI
import StoreKit
import CampCore

/// Apple's subscription store with the plans, the free trial, Restore, and the required terms links,
/// plus Lifetime as a one-time purchase. Prices come from the App Store in the camper's currency.
struct PaywallView: View {
    @Environment(StoreController.self) private var store
    let onClose: () -> Void

    var body: some View {
        SubscriptionStoreView(productIDs: StoreProduct.subscriptionIDs) {
            PaywallHeader()
        }
        .subscriptionStoreControlStyle(.picker)
        .subscriptionStoreButtonLabel(.multiline)
        .storeButton(.visible, for: .restorePurchases)
        .storeButton(.visible, for: .cancellation)
        .subscriptionStorePolicyDestination(url: Self.termsURL, for: .termsOfService)
        .subscriptionStorePolicyDestination(url: Self.privacyURL, for: .privacyPolicy)
        .onInAppPurchaseCompletion { _, result in
            await store.refresh()
            if case .success(.success) = result, store.status.canEdit { onClose() }
        }
        .accessibilityIdentifier("paywall")
    }

    /// Apple's standard licence agreement, which applies unless a custom one is set in App Store Connect.
    static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let privacyURL = URL(string: "https://github.com/TannerBarcelos/RoamReady/blob/main/docs/privacy-policy.md")!
}

private struct PaywallHeader: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "tent.fill")
                .font(.system(size: 44)).foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("RoamReady Pro").font(.largeTitle.bold())
            Text("Try everything free for a week.").font(.headline).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                Label("Trips, bookings, and site details", systemImage: "calendar")
                Label("Setup and teardown checklists for your rig", systemImage: "checklist")
                Label("Manuals and paperwork, offline", systemImage: "doc.text")
                Label("Photos, notes, and campground lists", systemImage: "photo.on.rectangle")
                Label("Private iCloud sync across your devices", systemImage: "icloud")
                // Only where Apple Intelligence can run, so no one is sold a feature their device lacks.
                if CampingAssistant.showsChat {
                    Label("Ask the on-device Assistant about camping and your manuals", systemImage: "sparkles")
                }
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("If you stop paying, you can still open everything you’ve saved.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            ProductView(id: StoreProduct.lifetime.rawValue) {
                Image(systemName: "infinity.circle.fill").foregroundStyle(.tint)
            }
            .productViewStyle(.compact)
            .padding(12)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("paywallLifetime")
        }
        .padding(.horizontal)
        .padding(.top, 24)
    }
}
