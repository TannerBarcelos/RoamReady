# App Store launch playbook

[Documentation index](README.md) · [Release guide](release-guide.md) · [Pricing](monetization.md) · [Listing copy](app-store-listing.md)

How RoamReady 1.0 actually got to the App Store (submitted Nov 16, 2026), written so the next release, or a different app, can follow it. It's split by how often you do each part:

- **[Once per Apple account](#part-1-once-per-apple-account)**: agreements, banking, tax, sandbox tester.
- **[Once per app](#part-2-once-per-app-first-release)**: in-app purchases, privacy label, age rating, compliance, screenshots, listing, the first submission.
- **[Every release](#part-3-every-release)**: version, build, TestFlight, submit.
- **[Launch day](#part-4-launch-day)**: release, offer codes, checks.
- **[Things that tripped us up](#part-5-things-that-tripped-us-up)**: read this first next time.

The app-agnostic version of this playbook, for other apps, is in [ios-release-runbooks](https://github.com/TannerBarcelos/ios-release-runbooks).

Everything below happens in [App Store Connect](https://appstoreconnect.apple.com) unless it says Xcode. Archive and upload steps are in the [release guide](release-guide.md#3-archive-and-upload).

## Part 1: Once per Apple account

Done for this account on Nov 14–16, 2026. A new app on the same account skips this part.

### 1.1 Paid Apps agreement, bank, and tax

Needed for anything that charges money, **including in-app purchases in a free app**. Until it's Active, StoreKit returns no products, even in TestFlight, and the paywall shows no prices.

1. **Business** (top menu) › **Agreements** › **Paid Apps** › **View and Agree to Terms**.
2. **Bank Accounts** › **+** › your own account.
3. **Tax Forms** › **U.S. Form W-9** (U.S. individual):
   - Name as on your tax return. Leave **Business Name** blank unless you have a registered business.
   - Type: **Individual/Sole proprietor**. Exemption: **Non-Exempt Payee**.
   - TIN: your **SSN** (or an EIN). Type it only into Apple's page, never into chat.
   - The form **can't be edited after Submit**. Check the name and number first; a mismatch can trigger 24% backup withholding.
4. Wait for all three to say **Active** (ours took about two days).

### 1.2 Sandbox test account

For testing real App Store Connect products from Xcode on a device.

1. **Users and Access** › **Sandbox** › **Test Accounts** › **+**.
2. Any name. Email: one that **isn't** an Apple Account; a plus-alias of your own works (`you+apptest@gmail.com`). A new password you don't use elsewhere. Country: **United States**.
3. On the iPhone: **Settings › Privacy & Security › Developer Mode** on (it restarts the phone), then **Settings › Developer › Sandbox Apple Account** › sign in.
4. **Clear Purchase History** on that page resets the tester so you can test the free trial again.

### 1.3 EU Digital Services Act (trader status)

Apple won't distribute in the **27 EU countries** until you declare whether you're a **trader**. Selling subscriptions or a Lifetime unlock usually makes you one, and a trader's **name, address, phone, and email are shown publicly** on the EU product page.

- For 1.0 we **left the EU out** (see [2.8](#28-pricing-and-availability)) rather than publish personal details.
- To add the EU later: get a **PO box or virtual mailbox**, a **business phone** (for example Google Voice), and a **support email**. Then **Business › Complete Compliance Requirements** › declare **trader** with those details. Apple verifies the phone and email (about a day). Then re-tick the EU countries.
- This is a legal call. A paid app declared as non-trader risks removal from EU stores.

## Part 2: Once per app (first release)

### 2.1 Decide the business model first

Write it down before building anything; it drives the code, the products, and the listing. RoamReady's is in [Pricing](monetization.md): a free download, then **RoamReady Pro** as Monthly $4.99 or Yearly $34.99 (each with a 1-week free trial), or Lifetime $99.99. Without Pro, the app is **read-only**: saved data stays visible, and adding, editing, and the Assistant open the plans.

### 2.2 Create the in-app purchases

Product IDs must match the code (`StoreProduct` in [Access.swift](../Sources/CampCore/Access.swift)) and the local test file (`Config/RoamReady.storekit`) **exactly**.

**Subscriptions** (sidebar › Monetization › **Subscriptions**):

1. **Create** a subscription group (`RoamReady Pro`). On the group: **Display Name and Description** › **Create** › English (U.S.), the display name `RoamReady Pro`, **Use App Name**. People see this name in Settings when they cancel.
2. In the group, **Create** each subscription: reference name, product ID, duration.
3. On each subscription page:
   - **Availability:** all countries. For a yearly plan, set up **1 Year Upfront** only. Skip "Monthly with a 12-Month Commitment"; that's a different checkout the app doesn't handle.
   - **Subscription Prices** › **Add Subscription Price** › United States price › Next › Confirm (Apple fills the other countries).
   - **Introductory offer:** **View all Subscription Pricing** › **Introductory Offers** › **Free**, **1 Week**, all countries, start today, no end date. Apple gives it once per person per group.
   - **Family Sharing** › **Turn On**. This can't be undone once live, and the local test file should match.
   - **Display Name and Description:** English (U.S.).
   - **Review Information:** a paywall screenshot (see [2.3](#23-test-purchases)) and a one-line note.
4. **Levels:** both plans unlock the same thing, so put them at the **same level** (group › **Edit**). Different levels make one an "upgrade" with an immediate, prorated switch.
5. Optional, on the Subscriptions page: **Billing Grace Period** › **16 days**, all renewals, Production and Sandbox. Leave **Streamlined Purchasing** on.

**One-time purchase** (sidebar › Monetization › **In-App Purchases**): **Create** › **Non-Consumable** › reference name, product ID › then Availability, **Price Schedule**, Family Sharing, localization, and Review Information, as above.

**Retention message** (optional, on a subscription page › **Retention Messaging**): shown on Apple's cancel screen. The body has a **144-character limit**. Ours: header `Your trips stay with you`, body `Everything you've saved stays readable. Come back anytime to keep planning.`, attached to both plans, no offer.

**Offer codes** (on a product › **Offer Codes**): the offer can be set up now, but **codes can only be generated after the product is approved and the app is Ready for Distribution**. Apple retired in-app purchase *promo* codes in March 2026; offer codes replace them and work for one-time purchases too. RoamReady has a `Friends & Family` offer on Lifetime (all eligibility boxes ticked), ready for launch day.

### 2.3 Test purchases

Test in this order, and switch the scheme's StoreKit setting as noted:

| Where | StoreKit Configuration (Edit Scheme › Run › Options) | What it proves |
| --- | --- | --- |
| **Simulator** | `RoamReady.storekit` | The code works with no account and no App Store Connect setup. **Debug › StoreKit › Manage Transactions** can refund or expire a purchase. |
| **iPhone from Xcode** | **None** | The real App Store Connect products load (IDs match, prices show). Uses the sandbox tester. The Paid Apps agreement must be Active. |
| **TestFlight** | (not used) | The archived build works end to end. Uses your **own** Apple Account, but is **never charged**. |

TestFlight subscriptions **renew once a day, up to six times**, then expire, and the free week is compressed to a day. To test a lapse quickly, cancel in **Settings › Apple Account › Subscriptions**; access ends at the period's end.

Take the **paywall review screenshot** in the simulator with the StoreKit file on (it shows prices): **File › Save Screen**.

Check: prices and "1 week free" show; a purchase unlocks editing; cancelling or refunding returns to read-only with all data still there; Restore works; Xcode's Transactions window shows **no ⚠️ Unfinished** transactions.

### 2.4 Screenshots

App Store Connect asks for specific sizes, and **the slots change over time**. Read the size listed under each slot. For 1.0 they were:

| Slot | Simulator | Size (portrait) | RoamReady set |
| --- | --- | --- | --- |
| **iPhone with Dynamic Island (medium display)** | iPhone 18 Pro | **1206 × 2622** (or 1179 × 2556) | 6 |
| **iPad 13" display** | iPad Pro 13-inch (M5), **iPadOS 27** runtime | 2064 × 2752 | 3 |
| **iPhone Duo**, cover screen | iPhone Duo, **folded** | 1398 × 2034 | 3 |
| **iPhone Duo**, inner screen | iPhone Duo, **fully open** (landscape) | 2853 × 2007 | 3 |

The 6.9" Pro Max size (1320 × 2868) was **rejected** for the iPhone slot, which wanted the 6.3" size. Smaller sizes can be left empty; Apple scales down.

**How we captured them.** `-app-store-screenshots` builds an in-memory demo library, so real data is never touched. Use a **signed** build so WeatherKit works:

```bash
xcodebuild -project RoamReady.xcodeproj -scheme RoamReady -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath .derivedData-shots build

SIM=<device UDID from: xcrun simctl list devices>
xcrun simctl boot $SIM
xcrun simctl status_bar $SIM override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4
xcrun simctl install $SIM .derivedData-shots/Build/Products/Debug-iphonesimulator/RoamReady.app
for p in location camera photos; do xcrun simctl privacy $SIM grant $p com.tannerdev.roamready; done
xcrun simctl location $SIM set 36.2509,-121.7836
xcrun simctl launch $SIM com.tannerdev.roamready -app-store-screenshots -appAppearance light
xcrun simctl io $SIM screenshot AppStoreScreenshots/iphone-6.3/01-home.png
```

- **Granting permissions first** skips the camera, photos, and location prompts.
- **`-appAppearance light`** forces light mode. Changing the simulator's appearance didn't stick.
- **iPhone Duo has two displays.** List them with `xcrun simctl io $SIM enumerate`, then pass `--display=<UUID>` to `screenshot`. Fold and unfold in the Simulator window; the inner display captures black while folded.
- Tap **Refresh forecast** on the trip before capturing, so the Apple Weather forecast shows.
- The order that tells the story: Home (the trip in progress) › trip overview › meals and weather › checklist › grocery list › Camp Finder. On Duo: Home beside the trip › Home beside the checklist › Camp Finder beside the map, then the same three on the cover screen.
- The files live in `AppStoreScreenshots/` (git-ignored). Upload in that order; drag to reorder.

The **Header** asset (Product Page › Header and Search Results, 3840 × 1646 or 5244 × 2950) is **optional**. Submission works without it.

### 2.5 App information (sidebar › General › App Information)

- **Name** `RoamReady: Camping Planner`, **subtitle** `Camping trips, ready offline`.
- **Category:** Travel, with Lifestyle as the secondary.
- **Content Rights:** No. Apple Maps and Weather are Apple frameworks, not third-party content.
- **License Agreement:** Apple's Standard License (the paywall's Terms link points to it).
- **Age rating:** answer honestly; RoamReady came out **4+** (with the local equivalents in Brazil, Korea, and Vietnam). Answer **Yes** to an AI assistant if asked, described as general camping help from Apple's on-device model. Campground websites open in Safari, which isn't unrestricted web access.
- Skip **App Encryption Documentation**, **App Store Server Notifications**, and **App-Specific Shared Secret**. Those are for apps with custom encryption, a server, or old receipt validation.

### 2.6 App Privacy (sidebar › Trust & Safety › App Privacy)

The label must match `Camp/PrivacyInfo.xcprivacy`.

1. **Privacy Policy URL:** `https://github.com/TannerBarcelos/RoamReady/blob/main/docs/privacy-policy.md` (the repo is public).
2. **Data Types:** "Yes, we collect data", then tick **only Location › Coarse Location**: App Functionality, **not** linked, **not** tracking. It goes to Apple Weather and Apple Maps for Home's temperature and Camp Finder's Near me.
3. Don't tick Purchases (Apple handles them), and don't tick anything kept on the device or in the user's private iCloud.
4. **Publish.** The label reads "Data Not Linked to You: Location".

### 2.7 App Compliance (sidebar › General › App Compliance)

- **China mainland** requires a **Security Assessment** and an **AI-generated content (AIGC) filing**, because RoamReady has an AI Assistant. We **excluded China** instead, which turns these rows into non-blocking "Missing Info".
- **Digital Services Act:** see [1.3](#13-eu-digital-services-act-trader-status).
- **Regulated Medical Devices:** not applicable.

### 2.8 Pricing and Availability (sidebar › Monetization)

- **Price Schedule:** **Add Pricing** › **Free**. ⚠️ A free app still needs this set; it starts empty.
- **App Availability** › **Manage:** 1.0 shipped in **136 of 175** countries, with the 27 EU countries and China mainland unticked. Products follow the app's availability.
- **iPhone and iPad Apps on Apple Silicon Macs:** **unticked**, because a separate Mac Catalyst version is planned. If ticked, Mac users get the iPad app until the Mac version is approved.

### 2.9 iPhone Duo badge and featuring

- The **"Optimized for iPhone Duo"** badge appears when the app is **built with the iOS 27.1 SDK or later** *and* has **iPhone Duo screenshots** submitted. There's no separate application. ([Apple](https://developer.apple.com/iphone-duo/prepare/))
- **Featuring nomination:** sidebar › Featuring › **Nominations** › **+** › **App Launch**, mentioning Duo support in Helpful Details. Ours: "RoamReady 1.0 launch", publish date Dec 14, 2026.

## Part 3: Every release

1. **Code:** merge to `main`. If `Models.swift` changed, deploy the CloudKit schema first ([release guide](release-guide.md#2-deploy-the-cloudkit-schema-if-the-models-changed)).
2. **Version:** raise **Marketing Version** for an App Store release (`1.0.0` › `1.0.1` or `1.1.0`).
3. **Scheme:** StoreKit Configuration › **None**.
4. **Archive:** destination **Any iOS Device (arm64)** › **Product › Archive** › **Distribute App** › App Store Connect.
5. **Encryption question** on the build: answer **"None of the algorithms mentioned above"**. RoamReady only uses encryption built into Apple's OS (HTTPS, CryptoKit). Don't pick "Standard encryption algorithms…"; that's for apps that ship their *own* crypto code. (Adding `ITSAppUsesNonExemptEncryption = NO` to `Camp/Info.plist` would skip this question.)
6. **TestFlight:** add **Owner Testing** (internal, no review) and install. External groups like **Family & Friends** need a short Beta App Review. Fill in **What to Test**.
7. **App Store:** **Distribution › + Version**, fill in **What's New**, pick the build.
8. **Submit:** see [3.1](#31-the-submission-panel).
9. Add a row to the [release log](release-guide.md#release-log).

### 3.1 The submission panel

App Store Connect collects everything into a **Draft Submission** (bottom-right button). A new subscription group or product **must** go in the same submission as an app version.

1. **Add the app version first:** version page › **Add for Review**. This anchors an iOS draft. Adding products before the version created several separate drafts.
2. Then click **Add for Review** on each new item: the subscription group, each subscription, and each one-time purchase.
3. Open the draft. It should list every item (ours: iOS App 1.0, RoamReady Pro, Monthly, Yearly, Lifetime) with **no yellow warning**.
4. **Submit for Review.** ⚠️ The button turns blue as soon as the version alone is in; don't submit until the products are in too, or the paywall ships empty.

Later releases with no new products only need the version.

**App Review notes** we used:
> RoamReady works offline with no account. Onboarding is free. RoamReady Pro (Monthly or Yearly with a 1-week free trial, or Lifetime) unlocks adding, editing, and the Assistant; without it, saved data stays readable. Plans appear after onboarding and in Profile › RoamReady Pro, which also has Restore Purchases. The Assistant appears only on devices with Apple Intelligence enabled and runs entirely on-device.

Choose **Manually release this version**. Review usually takes 1–2 days; questions or rejections appear under **App Review** in the sidebar.

## Part 4: Launch day

After the status reads **Pending Developer Release**:

1. **Release This Version.** It's live within a few hours.
2. **Friends & Family code:** Lifetime › Offer Codes › `Friends & Family` › **Create Custom Codes**, with a limited number of redemptions (friends plus a few spares) and an expiry date. Share `https://apps.apple.com/redeem?ctx=offercodes&id=6829317929&code=CODE` with `CODE` replaced. **Deactivate** stops it if it leaks.
3. **Check the live page:** price Free, Pro prices, the free trial, screenshots, and the **Optimized for iPhone Duo** badge.
4. Make one real purchase with your own account, then cancel or ask for a refund if you like.
5. Update the [release log](release-guide.md#release-log).

## Part 5: Things that tripped us up

- **No prices on the paywall:** the Paid Apps agreement isn't Active yet, or the products aren't Ready to Submit or approved.
- **"File dimensions are invalid" on screenshots:** the slot wants a different device size than you captured. Read the sizes under the slot.
- **The app icon shows as a grid placeholder** in App Store Connect and on sandbox purchase sheets until the first build is attached, or the app is live. It isn't a bug.
- **Several Draft Submissions:** items were added before the app version. Remove them, add the version first, then the items.
- **Unfinished transactions** in Xcode's Transactions window: purchases made from the paywall must be finished in code. Fixed in #166 (`StoreController.complete(_:)`).
- **An overloaded Mac** (load average in the hundreds) makes UI tests hang or fail to launch the app. Shut down unused simulators, or restart, before testing.
- **Xcode's first run on a new iOS version** spends 5–15 minutes on "Extracting OS library symbols". Keep the phone unlocked and wait.
- **China and EU warnings** appear even when you don't sell there. Exclude the countries, and the rows stop blocking.

## Still to do after 1.0

- **Mac (Catalyst) version:** capture Mac screenshots, then submit **macOS 1.0** with the same products (Universal Purchase).
- **EU:** set up trader contact details, declare trader, re-add the 27 countries.
- **China:** only if wanted. It needs a security assessment and an AIGC filing.
