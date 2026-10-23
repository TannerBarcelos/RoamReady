# Identity, connectivity, and AI contract

## Product behavior

RoamReady has **no accounts** in v1: no sign-up, no Sign in with Apple, and no server holding user data. The library belongs to the device and, when sync is on, to the person's own iCloud. First launch goes straight to rig/profile onboarding, which works offline.

Trips (each one a booking: create from manual campground entry, edit any field, attach confirmation files, delete), setup/teardown checklists, progress, edits, notes, ratings, imported photos, camera capture, profile edits, rig edits/replacement/archiving, and per-rig default checklists all save through SwiftData offline and sync later. Photo capture/import remains available even if no iCloud connection is possible. Cached forecasts retain their retrieval time; fresh weather needs connectivity. Creating a trip offline means entering the campground by name; choosing it from Camp Finder requires online access.

Only Camp Finder and individual-site browsing, fresh weather, the iCloud sync preference, and erasing iCloud data require an available network path. A satisfied NWPathMonitor path is a prerequisite, not proof the service is reachable; actual authorization/download errors are surfaced. Profile and rig editing are ordinary local writes and work offline.

## Trips, rigs, and deletion (#28)

A trip is exactly one booking at one campground; there is no planning/booked status and no automatic status change, parsing, or reminder. Booking fields (site and loop, confirmation number, provider, `https`-only manage-booking link, check-in/out times in the campground's time zone, total cost and amount paid, display-only cancellation deadline) are optional and editable at any time. Trips reference a rig by `rigID`; the UI reads the rig's current details, so editing a rig updates every trip that uses it. Each owner has at most `RigPolicy.maxActiveRigs` (1) active rig, enforced in CampCore and again in the store's save; "Replace rig" archives the current rig, which stays readable on past trips. Hard delete is allowed only for a rig no trip uses. If sync merges two devices into more active rigs than allowed, both stay readable and Profile asks the owner to archive one. A trip whose rig is missing shows "Rig unavailable".

Each rig has its own default setup and teardown lists. Creating a trip copies the chosen rig's defaults; after that the trip's lists are independent. Only the confirmed "Save as defaults for <rig>" action writes a trip's lists to that trip's rig; "Reset default checklists" regenerates them from the rig type. Neither touches existing trips.

Cancelling a trip deletes it. The confirmation names the trip and dates and states that its checklists and progress, notes and all note versions, photos and captions, and site notes and rating are permanently deleted on every device signed in to the iCloud account; confirmation and paperwork files move to Unattached documents; the rig, its defaults, and original photos in the photo library are untouched.

## No accounts in v1

Sign in with Apple was removed. With no server holding user data, no Android or web app, and no sharing between people, an account added sign-up friction, a required connection on first launch, a token-revocation backend (an earlier Cloudflare Worker, since deleted), and App Store account-deletion obligations (Guideline 5.1.1(v)), and protected nothing that the device passcode and iCloud don't already. Builds before this change kept the Apple user ID, name, and email in the Keychain and a pinned-owner file; both are deleted at launch.

**Erase all data** (Profile) is the deletion path: it deletes the app's CloudKit zone (when sync is configured; needs a connection and a signed-in iCloud account), then the local stores, Media, caches, documents, and preferences, stopping and naming the step if one fails. Other devices using the same iCloud account stop syncing and keep their local copy until erased.

Revisit accounts when a feature needs a server-side identity: sharing trips between people, Android or web, or paid server features. v2's remote AI (#34) can identify a paying install by its StoreKit transaction and App Attest instead of a user account.

## iCloud identity

SwiftData's CloudKit mirroring uses the device's iCloud account. The approved container-specific record name is device-only metadata.

Sync is on by default. On the first sync the current iCloud identity is pinned without a prompt. Before opening a mirrored store, the controller verifies that the current iCloud identity matches the pinned one. If unavailable, the app opens locally and retries when connectivity returns; it never blocks the pinned user's offline trips. An identity mismatch leaves sync paused and cannot automatically rebind the library. A CKAccountChanged notification schedules mirroring teardown and local-only reopen. Existing app data is not deliberately deleted by this transition.

This is best-effort coordination around Apple's managed lifecycle, not a guarantee that a previously in-flight transfer can be undone. iCloud sign-out/switch behavior, cache retention, and account separation still require signed, two-device acceptance. Do not claim production account isolation based on source review or simulator compilation alone.

## Apple-only AI

There is no hosted model route, remote fallback, provider secret, or model picker. Camping questions remain on device. v1 is on-device only; remote models are planned for v2 (#34). The product gate allows iPhone 15 or newer: `iPhone15,4` and `iPhone15,5` (iPhone 15 and 15 Plus) and every `iPhone16,*` or later identifier. It is not a plain generation check, because `iPhone15,2` and `iPhone15,3` are the iPhone 14 Pro and Pro Max, which are excluded. The app then independently checks `SystemLanguageModel.default.availability`. Apple Intelligence requires iPhone 15 Pro or later, so the base iPhone 15 and 15 Plus pass the product gate but Apple reports `deviceNotEligible`; the app says "This iPhone doesn't support Apple Intelligence" and shows saved guidance. `appleIntelligenceNotEnabled` and `modelNotReady` each get their own explanation. iPad, simulator, unknown identifiers, and other devices retain saved guidance without generative help.

A hardware generation alone does not guarantee AI: Apple Intelligence must be enabled, the model must be downloaded/ready, and Apple's language/region/system eligibility rules must permit it. An initial model download needs connectivity; once ready the on-device model can run offline. A future identifier convention change needs policy review rather than an unsupported App Store hardware claim. App Store metadata cannot express an exact minimum iPhone marketing model; the core app can run on otherwise supported devices while its AI feature is gated at runtime.

Answers use relevant saved checklist guidance and decline unsupported specifications or repairs. Imported user notes are reference data, not privileged prompt instructions. Bundled guidance remains available when generation is unavailable, refused, or fails.

## Provisioning and acceptance

The default build declares no capabilities. Provision the new managed CloudKit container and push delivery as documented in offline-storage.md.

Required device acceptance includes an offline first launch and onboarding, Erase all data (online and offline, sync on and off), restoration to a new device through iCloud, iCloud changes during imports/exports, real camera permission/capture, and all Foundation Models availability states. No backend or provider account was created automatically during this work.
