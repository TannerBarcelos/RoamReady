# Identity, connectivity, and AI contract

[Documentation index](README.md)

## Product behavior

RoamReady has **no accounts** in v1: no sign-up, no Sign in with Apple, and no server holding user data. The library belongs to the device and, when sync is on, to the person's own iCloud. First launch goes straight to rig/profile onboarding, which works offline.

Trips (each one a booking: create from manual campground entry, edit any field, attach confirmation files, delete), setup/teardown checklists, progress, edits, notes, ratings, imported photos, camera capture, profile edits, rig edits/replacement/archiving (including VIN and plate), step priorities and notes, and per-rig default checklists all save through SwiftData offline and sync later. Photo capture/import remains available even if no iCloud connection is possible. Cached forecasts retain their retrieval time; fresh weather needs connectivity. Creating a trip offline means entering the campground by name; choosing it from Camp Finder requires online access. Saved-campground marks are local and work offline; an Apple Maps campground's name and details come from Apple Maps or a trip there, so a saved identifier alone does not promise its details offline. Offline, Camp Finder shows "Camp Finder needs an internet connection" with Try again.

Only Camp Finder (search, the map, and place details from Apple Maps), fresh weather, and erasing iCloud data require an available network path. A satisfied NWPathMonitor path is a prerequisite, not proof the service is reachable; actual authorization/download errors are surfaced. Profile and rig editing and changing the iCloud launch preference are ordinary local writes and work offline.

## Trips, rigs, and deletion (#28)

A trip is exactly one booking at one campground; there is no planning/booked status and no automatic status change, parsing, or reminder. Booking fields (site and loop, confirmation number, provider, `https`-only manage-booking link, check-in/out times in the campground's time zone, total cost and amount paid, display-only cancellation deadline) are optional and editable at any time. Trips reference a rig by `rigID`; the UI reads the rig's current details, so editing a rig updates every trip that uses it. Each owner has at most `RigPolicy.maxActiveRigs` (1) active rig, enforced in CampCore and again in the store's save; "Replace rig" archives the current rig, which stays readable on past trips. Hard delete is allowed only for a rig no trip uses. If sync merges two devices into more active rigs than allowed, both stay readable and Profile asks the owner to archive one. A trip whose rig is missing shows "Rig unavailable".

Each rig has its own default setup and teardown lists. Creating a trip copies the chosen rig's defaults; after that the trip's lists are independent. Only the confirmed "Save as defaults for <rig>" action writes a trip's lists to that trip's rig; "Reset default checklists" regenerates them from the rig type. Neither touches existing trips.

Cancelling a trip deletes it. The confirmation names the trip and dates and states that its checklists and progress, notes and all note versions, photos and captions, and site notes and rating are permanently deleted on every device signed in to the iCloud account; confirmation and paperwork files move to Unattached documents; the rig, its defaults, and original photos in the photo library are untouched.

## No accounts in v1

Sign in with Apple was removed. With no server holding user data, no Android or web app, and no sharing between people, an account added sign-up friction, a required connection on first launch, a token-revocation backend (an earlier Cloudflare Worker, since deleted), and App Store account-deletion obligations (Guideline 5.1.1(v)), and protected nothing that the device passcode and iCloud don't already. Builds before this change kept the Apple user ID, name, and email in the Keychain and a pinned-owner file; both are deleted at launch.

**Erase all data** (Profile › Settings) is the deletion path: it deletes the app's CloudKit zone (when sync is configured; needs a connection and a signed-in iCloud account), then the local stores, Media, caches, documents, and preferences, stopping and naming the step if one fails. Other devices using the same iCloud account stop syncing and keep their local copy until erased.

Revisit accounts when a feature needs a server-side identity: sharing trips between people, Android or web, or paid server features. v2's remote AI (#34) can identify a paying install by its StoreKit transaction and App Attest instead of a user account.

## iCloud identity

SwiftData's CloudKit mirroring uses the device's iCloud account. Apple manages account availability and transitions, connectivity, scheduling, and retries. RoamReady does not fetch or pin a CloudKit user identifier, gate opening on account/network checks, or reopen the store after account or connectivity changes. Legacy identity pinning metadata is removed.

Sync is on by default in configured builds. The onboarding/Settings preference can be changed offline and takes effect on the next app launch; the current session keeps its launch configuration. The UI explicitly shows pending changes. Turning sync off deletes neither local data nor an existing iCloud copy.

iCloud sign-out/switch behavior, local data retention, and cross-account behavior follow Apple's managed lifecycle and still require signed, two-device acceptance. RoamReady does not provide a separate pinned-account isolation guarantee. Explicit full-library erase remains a user-requested deletion operation; it is not a sync recovery mechanism.

## Apple-only AI

Assistant (the global button and Ask for camping help on trips and checklists) runs on any iPhone, iPad, or Mac (Mac Catalyst) where Apple's Foundation Models runtime is available, and is hidden where Apple reports the device ineligible. Supported hardware keeps its button while Apple Intelligence is disabled or the model is preparing, but shows a recovery screen instead of the chat and its composer. Every answer is generated by the model: general chat does not require a trip or matching guidance, and trip/checklist help passes the trip's matching saved steps as context. There are no canned or saved-text replies. Conversation history stays in memory, in one on-device model session per chat; each request sends at most the last three turns that fit, and an overly long chat continues in a new session that keeps the newest turn.

There is no hosted model route, remote fallback, provider secret, or model picker. Camping questions remain on device. v1 is on-device only; remote models are planned for v2 (#34). There is no app-side hardware list: `SystemLanguageModel.default.availability` alone decides. Simulator follows the host Mac's Apple Intelligence setting. The model is `SystemLanguageModel.default`, Apple's on-device model in its general-purpose configuration and the only model Foundation Models runs on device. Private Cloud Compute (`PrivateCloudComputeLanguageModel`) is server-side, so it belongs with remote models in v2. `deviceNotEligible` hides Assistant. `appleIntelligenceNotEnabled` and `modelNotReady` each get their own explanation.

A hardware generation alone does not guarantee AI: Apple Intelligence must be enabled, the model must be downloaded/ready, and Apple's language/region/system eligibility rules must permit it. An initial model download needs connectivity; once ready the on-device model can run offline. A future identifier convention change needs policy review rather than an unsupported App Store hardware claim. App Store metadata cannot express an exact minimum iPhone marketing model; the core app can run on otherwise supported devices while its AI feature is gated at runtime.

Answers use relevant saved checklist guidance, including the owner's step notes, and decline unsupported specifications or repairs. Imported user notes and step notes are reference data, not privileged prompt instructions. Rig registration (VIN and plate) is never sent to the model. Bundled guidance remains available when generation is unavailable, refused, or fails.

## Provisioning and acceptance

The default build declares Mac sandbox permissions, but no CloudKit or WeatherKit capabilities. Provision the new managed CloudKit container and push delivery as documented in offline-storage.md.

Required device acceptance includes an offline first launch and onboarding, Erase all data (online and offline, sync on and off), restoration to a new device through iCloud, iCloud changes during imports/exports, real camera permission/capture, and all Foundation Models availability states. No backend or provider account was created automatically during this work.
