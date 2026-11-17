# Pricing

[Documentation index](README.md) · [Release plan](integration-plan.md)

RoamReady is a **free download with RoamReady Pro**: a subscription or a one-time Lifetime purchase. This replaces the earlier $4.99 paid-upfront plan (decided Nov 14, 2026).

| Product | Product ID | Type | US price | Trial |
| --- | --- | --- | --- | --- |
| Monthly | `com.tannerdev.roamready.pro.monthly` | Auto-renewable, group "RoamReady Pro" | $4.99 / month | 1 week free |
| Yearly | `com.tannerdev.roamready.pro.yearly` | Auto-renewable, same group | $34.99 / year (confirm in App Store Connect) | 1 week free |
| Lifetime | `com.tannerdev.roamready.pro.lifetime` | Non-consumable | $99.99 once | — |

Product IDs are in `StoreProduct` ([Access.swift](../Sources/CampCore/Access.swift)) and must match App Store Connect exactly. Prices are only in App Store Connect; the app shows the App Store's localized price.

## Access rules

- **Onboarding is free.** A new camper finishes onboarding, and the plans appear once afterward. Closing them is allowed.
- **Pro (trial, subscription, or Lifetime) unlocks everything:** adding and editing trips, rigs, checklists, menus, documents, photos, notes, and campground lists, plus the Assistant (on devices with Apple Intelligence).
- **Without Pro, the app is read-only.** Everything saved stays visible and openable, offline included: trips, checklists, paperwork, photos, weather, and Camp Finder search. The Assistant button stays visible but opens the plans (decided Nov 14, 2026). Tapping something that adds or edits opens the plans instead. Deleting and **Erase all data** always work, so nobody is stuck with data they can't remove.
- **Lapsed subscriptions** fall back to read-only. Nothing is hidden or deleted.
- **Lifetime wins** over any subscription. Refunded purchases (`revocationDate`) never count.
- **Offline:** StoreKit 2 keeps verified entitlements on the device, so access works without a connection. There is no server and no account.
- **Family Sharing** is on for all three products in the local StoreKit file. Turn it on in App Store Connect too, or change both.

The rules live in `AccessStatus.resolve` (unit-tested in `AccessStatusTests`). `StoreController` reads `Transaction.currentEntitlements`, listens to `Transaction.updates`, and gates edits with `ifFullAccess { … }`. The paywall is Apple's `SubscriptionStoreView` (plans, trial, Restore, terms, privacy) plus a Lifetime `ProductView`. Profile › RoamReady Pro shows the status, **Manage subscription**, and **Restore purchases**.

## Testing purchases

- **Locally in Xcode:** in **Product › Scheme › Edit Scheme › Run › Options**, set **StoreKit Configuration** to `Config/RoamReady.storekit`. Purchases, the trial, renewals (sped up), refunds, and expiry can all be driven from **Debug › StoreKit › Manage Transactions**.
- **UI tests:** `-store-ui-test full|read-only` pins access. Other UI-test flags get full access automatically, so older tests are unaffected.
- **Sandbox and TestFlight:** after the products exist in App Store Connect, use a Sandbox Apple Account (Settings › Developer › Sandbox Apple Account on the device). TestFlight purchases are free and renew quickly.
