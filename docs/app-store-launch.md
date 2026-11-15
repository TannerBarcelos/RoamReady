# App Store launch: v1.0

[Documentation index](README.md) · [Release guide](release-guide.md) · [Pricing](monetization.md) · [Listing copy](app-store-listing.md)

The checklist for taking RoamReady from TestFlight to the App Store for the first time. Do the parts in order; each one says where to click. Steps marked **(owner)** need your Apple account. The archive and upload steps are in the [release guide](release-guide.md#3-archive-and-upload).

Already done in the code: StoreKit 2 purchases, the paywall, read-only access, Restore, Manage subscription, a local StoreKit test file, and the `-app-store-screenshots` demo library. The version is `1.0.0`.

## 1. Agreements, tax, and banking (owner)

In-app purchases won't load, even in TestFlight, until this is active. It can take a day or two to clear.

1. [App Store Connect](https://appstoreconnect.apple.com) › **Business** (top menu).
2. Under **Agreements**, accept the **Paid Apps** agreement.
3. Add a **bank account** and complete the **U.S. tax form** (W-9 for a U.S. individual).
4. Wait until the agreement status says **Active**.

## 2. Create the in-app purchases (owner)

Go to **Apps › RoamReady: Camping Planner › Monetization**. The product IDs must match exactly; they're in [Pricing](monetization.md).

**Subscriptions** (Monetization › Subscriptions):

1. Create a subscription group named **RoamReady Pro**.
2. Add **Monthly**: product ID `com.tannerdev.roamready.pro.monthly`, duration **1 month**, price **$4.99**. Let Apple fill other storefronts from the U.S. price, then skim the list.
3. Add **Yearly**: product ID `com.tannerdev.roamready.pro.yearly`, duration **1 year**, price **$34.99** (or the price you settle on).
4. On each: **Subscription Prices › Introductory Offers › Create**, choose **all countries**, **Free**, **1 week**. Apple only gives it to people who've never had a RoamReady Pro trial.
5. On each: add an English (U.S.) **display name** and **description** (for example "Monthly" / "Everything in RoamReady, billed monthly").
6. On each: turn on **Family Sharing** (it can't be turned off later). Skip this if you don't want it, and tell Claude so the local test file matches.
7. On each: under **Review Information**, upload a screenshot of the paywall (section 4 shows how) and a short note: "Unlocks adding and editing. Without it the app is read-only."
8. Give the group itself an English display name: **RoamReady Pro**.

**Lifetime** (Monetization › In-App Purchases):

1. **Create**, type **Non-Consumable**, reference name **Lifetime**, product ID `com.tannerdev.roamready.pro.lifetime`.
2. Price **$99.99**, display name **RoamReady Lifetime**, description "Everything in RoamReady, unlocked for good.", Family Sharing as above, and the same review screenshot.

Each product should end at **Ready to Submit**. The first products are reviewed **together with the app version**, so they're attached in section 7.

## 3. Test purchases before submitting (owner)

1. **In Xcode (no account needed):** **Product › Scheme › Edit Scheme › Run › Options › StoreKit Configuration** → `Config/RoamReady.storekit`. Run on a simulator. Check that the trial, Monthly, Yearly, Lifetime, Restore, cancellation (**Debug › StoreKit › Manage Transactions** → expire or refund), and read-only all behave as in [Pricing](monetization.md).
2. **Sandbox on your iPhone:** App Store Connect › **Users and Access › Sandbox › Test Accounts** → create one. On the phone: **Settings › Developer › Sandbox Apple Account**. Run a signed build from Xcode with the StoreKit configuration set back to **None**. Real App Store Connect products load.
3. **TestFlight:** upload a build as in the [release guide](release-guide.md). Purchases are free and monthly renewals come every few minutes, so you can watch a subscription renew and then expire into read-only.

Things to check: the paywall shows prices and "1 week free", Lifetime buys and the subscription upsell disappears, Restore works on a second device, airplane mode keeps Pro, and a lapsed subscription leaves everything readable.

## 4. Screenshots

App Store Connect needs at least one screenshot per device family. Take 5–6 per family, in the same order everywhere.

| Family | Simulator | Size (portrait) |
| --- | --- | --- |
| iPhone 6.9" (required) | iPhone 18 Pro Max (or the largest iPhone you have) | 1320 × 2868 |
| iPad 13" (required for iPad) | iPad Pro 13-inch (M5) | 2064 × 2752 |
| Mac | the Mac app itself | 2880 × 1800 (16:10) |
| iPhone Duo (for the "Optimized for iPhone Duo" badge) | iPhone Duo | outer 1398 × 2034, inner 2007 × 2853 |

**Capture them from the demo library** (in memory; your real trips are never touched). Use a **signed** build so WeatherKit works; an unsigned build shows a crossed-out thermometer.

```bash
xcodebuild -project RoamReady.xcodeproj -scheme RoamReady -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath .derivedData-shots build
```

Then, for each simulator (`xcrun simctl list devices` shows the IDs; replace `<SIM>`):

```bash
xcrun simctl boot <SIM>
xcrun simctl status_bar <SIM> override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4
xcrun simctl install <SIM> .derivedData-shots/Build/Products/Debug-iphonesimulator/RoamReady.app
for p in location camera photos; do xcrun simctl privacy <SIM> grant $p com.tannerdev.roamready; done
xcrun simctl location <SIM> set 36.2509,-121.7836
xcrun simctl launch <SIM> com.tannerdev.roamready -app-store-screenshots -appAppearance light
xcrun simctl io <SIM> screenshot AppStoreScreenshots/iphone-6.9/01-home.png
```

`AppStoreScreenshots/` is git-ignored. The v1 set captured on Nov 14, 2026, in upload order:

| iPhone 6.9" | iPad 13" |
| --- | --- |
| 1. Home: the trip in progress, with weather | 1. Home beside the trip overview |
| 2. Trip overview: booking, checklists, meals | 2. Setup checklist, part done |
| 3. Trip overview, lower half: meals, grocery, Apple Weather forecast | 3. Camp Finder: list beside the map |
| 4. Setup checklist, part done | |
| 5. Grocery list by store section | |
| 6. Camp Finder near Big Sur | |

Tap **Refresh forecast** on the trip before capturing it, so the forecast shows. A real on-device Assistant answer would make a strong extra shot. Capture one on your iPhone; never use a simulator test reply.

For the paywall review screenshot (section 2), launch with the StoreKit configuration in Xcode and open **Profile › RoamReady Pro › See plans**.

Optional polish: add a one-line caption above each shot ("Every trip, ready offline") in Keynote, Figma, or a framing tool. Plain screenshots are accepted. Photos screens look best with your own real campsite photos; the demo library has none.

## 5. App information (owner)

In the app's **App Information** and the version page, paste from [listing copy](app-store-listing.md):

- **Name, subtitle, promotional text, description, keywords.** The description already includes the subscription terms Apple requires.
- **Privacy policy URL:** `https://github.com/TannerBarcelos/RoamReady/blob/main/docs/privacy-policy.md` (the repo is public).
- **Terms of use:** Apple's standard EULA is used. Leave **License Agreement** as the standard one. The link is in the paywall and at the end of the description.
- **Support URL:** `https://github.com/TannerBarcelos/RoamReady/issues`.
- **Category:** primary **Travel**, secondary **Navigation** or **Lifestyle**.
- **Copyright:** "2026 Tanner Barcelos".
- **App Privacy** (the privacy "nutrition label"): **Location › Coarse Location**, used for **App Functionality**, **not linked** to identity, **not used for tracking**. Nothing else is collected; purchases are handled by Apple and the app has no server.
- **Age rating questionnaire:** answer honestly for the shipped app. There's no user-generated content shared with others, no web browsing, and no gambling. Mention that the Assistant is Apple's on-device model giving general camping help. Expect **4+**.
- **Export compliance:** the app uses only standard encryption (HTTPS and Apple CryptoKit for stored documents). Answer **Yes** to using encryption, then that it qualifies for the exemption for standard algorithms built into Apple's operating system. To skip the question on every upload, add `ITSAppUsesNonExemptEncryption = NO` to `Camp/Info.plist` once you've confirmed that answer.

## 6. Pricing and availability (owner)

**Pricing and Availability:** the app's price is **Free** (the money is in the in-app purchases). Choose the countries; all is fine. Leave **Mac** availability on to ship the Catalyst app with the same purchases (Universal Purchase), and add Mac screenshots on the macOS version.

## 7. Submit (owner)

1. Archive and upload `1.0.0` from Xcode, as in the [release guide](release-guide.md#3-archive-and-upload). Deploy the CloudKit schema first if the models changed.
2. Test that build on TestFlight (section 3).
3. **Distribution** tab → **+ Version** → `1.0.0` (iOS). Fill in screenshots and text, then pick the build.
4. In **In-App Purchases and Subscriptions** on that version page, add all three products. If you skip this, they aren't reviewed and won't be on sale.
5. **App Review Information:** no sign-in is needed. Notes for the reviewer:
   > RoamReady works offline with no account. Onboarding is free. RoamReady Pro (Monthly or Yearly with a 1-week free trial, or Lifetime) unlocks adding and editing; without it, saved data stays readable. Plans appear after onboarding and in Profile › RoamReady Pro, which also has Restore Purchases. The Assistant appears only on devices with Apple Intelligence enabled and runs on-device.
6. **Version Release:** choose **Manually release this version** for launch day control.
7. **Add for Review › Submit.** Review is usually 1–2 days. If rejected, the message says which guideline; reply in App Store Connect or fix and resubmit.
8. After approval, click **Release**, then check the live listing, prices, the trial, and a real purchase.

Then add the upload to the [release log](release-guide.md#release-log).
