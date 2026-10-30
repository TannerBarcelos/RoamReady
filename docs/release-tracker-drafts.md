# Release tracker drafts (#6 and #74)

[Documentation index](README.md) · [Remaining release gates](validation.md#remaining-release-gates)

Status: **draft for owner review.** Nothing here has been applied to GitHub. Issue #110 asks for #6 and #74 to match current code and settled scope; the owner reviews and applies the bodies below (paste each into its issue). Prepared October 29, 2026 against `main` after PR #134.

What changed from the current issue bodies:

- Settled scope is stated as fact: iPhone, iPad, and Mac in v1; Apple-only on-device generation; AI hidden on unsupported devices; $4.99 one-time.
- Tabs are Home, Trip (opens the new-trip sheet), Camp Finder, Profile. There is no Plan tab and no More tab.
- The Assistant is the sparkle button above the tab bar on compact layouts and **Ask Assistant** in the toolbar on regular iPad layouts, Mac, iPhone Duo, and accessibility text sizes. The "Ask Assistant bar" (#73) is gone.
- Document encryption: all new files use Apple-managed encrypted SwiftData fields and CloudKit assets. There is no per-category encryption and no "changing a manual to insurance encrypts it" behavior.
- The Assistant now answers from eligible documents on-device (#92). Its new checks are added to B8 and the document checks to B5.
- Merged work is checked or removed. Gates that need hardware, a service, or an account stay unchecked, with no result invented.
- Still open in code, per the tracker on this date: #93 (iPad Dynamic Type), #105 (source presentation states), #108 (answer-quality and device baselines), #109 (eval guide), and the Duo items #86 and #91. They are listed as blockers, not as done.

---

## Proposed body for #6

````markdown
**The single v1 issue.** v1 ships when everything below is checked: App Store publishing (Part A) and simulator/device acceptance (Part B). Product decisions are settled (see below). Post-v1 work is in #29. Every result is recorded with build commit, hardware/OS, date, result, and linked defect in `docs/validation.md` under "Remaining release gates"; keep items unchecked until a real run is recorded there.

## What's left
| Where | Work | Who |
|---|---|---|
| #93 | Fix the iPad Dynamic Type finding in Profile's rig section | Claude |
| #105 | Assistant source presentation states (cited vs searched, changed/unavailable, page viewer on all platforms) | Claude |
| #108, #109 | Assistant answer-quality and device performance baselines; eval guide and walkthrough | Owner + Claude |
| #86, #91 | iPhone Duo: keep Home's state through folding; full Duo check | Owner + Claude |
| #110 | This reconciliation; owner approves the tracker edits | Owner |
| Part A | App ID, signing, iCloud, WeatherKit, listing, $4.99 price, TestFlight, release | Owner |
| Part B | Signed-device acceptance | Owner |

## Current state of `main`
- **Platforms:** iPhone, iPad, and Mac (Catalyst). All three ship in v1.
- **Tabs:** Home, Trip (opens the new-trip sheet and leaves the current tab selected), Camp Finder, Profile. There is no Plan tab and no More tab. Profile holds Trip history, Your campgrounds, and Settings.
- **Assistant:** on-device Apple Foundation Models only, wherever Apple's runtime reports Apple Intelligence available. Entry is a sparkle button above the tab bar on compact layouts and **Ask Assistant** in the toolbar on regular iPad layouts, Mac, iPhone Duo, and accessibility text sizes. It is hidden on devices that Apple reports ineligible; checklists work everywhere. The global chat stays in memory when the sheet closes and clears on New chat or app quit; nothing is saved to disk.
- **Documents and the Assistant:** the Assistant answers from eligible documents (Manual, Service & maintenance, Warranty, Reservation; Other only when opted in; never Registration or Insurance) in the active rig's scope, or a trip plus its rig. English only. Scans and photos are read with on-device OCR. It shows scope, coverage and readiness, loading stages, cited sources, and conflicting booking values. The search index is a per-device, disposable file: not synced, not backed up, removed by Erase all data. It uses vendored sqlite-vec (MIT/Apache-2.0).
- **Trips:** assign a document to a rig or trip from its details ("Assign to rig or trip"). Deleting a trip leaves its documents unattached and out of every Assistant scope until assigned.
- **CI:** `app.yml` (iOS and iPad build, unsigned, no simulator) and `mac.yml` (all package tests and Catalyst Debug/Release). UI tests are manual-only (`ui-tests.yml`). CI proves compilation and tests, not device behavior.
- **Dependencies:** no external packages. The one third-party code is the vendored sqlite-vec C source (see `Sources/CSQLiteVec/PROVENANCE.md`).

## v1 decisions (settled)
- **Trip = booking** at one campground. Booking details, site details, and confirmation files are entered by the user.
- **One active rig.** Replacing a rig archives the old one, which stays on past trips.
- **Checklists:** each rig has default setup and teardown lists. A new trip copies them; after that they're independent. Only "Save as defaults" changes the rig's lists.
- **Delete = cancel.** Deleting a trip removes its notes, photos, rating, and checklists on every device. Its documents move to Unattached.
- **Completion:** a trip completes the day after departure, or when the user marks it done. A completed trip adds its campground to Have been.
- **Offline-first** everywhere except Camp Finder.
- **No accounts.** iCloud sync runs through SwiftData. Erase all data deletes everything on the device and in iCloud.
- **Weather (required):** WeatherKit with an offline cache.
- **AI (required):** on-device Apple Foundation Models only; no remote AI (#34 is v2). Hidden on unsupported devices. Saved chats and compaction (#65) are deferred to post-v1.
- **Camp Finder:** Apple Maps (MapKit) only; the app never books or shows availability. No offline discovery (#20 is v2).
- **Document Q&A is English-only in v1.**
- **No backend, no API keys.**
- **Price: $4.99 USD one-time, permanently.** No subscription, free trial, in-app purchase, or unlock.

---

# Part A: Publish to the App Store

Put all settings in an untracked `Config/Local.xcconfig` copied from `Config/Cloud.xcconfig.example`, applied to both build configurations.

## A1. App ID and signing
- [ ] Register the App ID. Choose the final bundle ID; it can't change after App Store submission.
- [ ] Set `PRODUCT_BUNDLE_IDENTIFIER` and `DEVELOPMENT_TEAM`.
- [ ] A signed Debug build runs on your iPhone.

## A2. iCloud
- [ ] Create a new CloudKit container. Enable iCloud (CloudKit) and Push Notifications on the App ID.
- [ ] Set `ROAMREADY_MIRRORING_CONTAINER` and `CODE_SIGN_ENTITLEMENTS = Config/Cloud.entitlements`.
- [ ] Create one of everything in the app: rig with photo, trip, checklist step, trip photo, note, saved campground, and documents of several categories, including an Other document with **Include in Assistant** turned on. Check that the `CD_` record types appear in CloudKit Console, including `StoredDocument.includeInAssistant`.
- [ ] Deploy the schema to Production before TestFlight. As of Oct 29, 2026 the schema has **not** been deployed; `includeInAssistant` must be in the Development schema first. After the first Production deploy, model changes must be additive only (new optional attributes or models; never rename, retype, remove, or change encryption).

## A3. WeatherKit
- [ ] Enable WeatherKit on the App ID. The entitlement is already in `Config/Cloud.entitlements`.
- [ ] The temperature shows at the top right of Home, and a trip with a location shows its forecast. Apple Weather attribution looks right in light and dark mode.

## A4. Mac
- [ ] Mac signing works with the same bundle ID (`DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER = NO`) and the iCloud/WeatherKit entitlements.
- [ ] A signed Mac build launches, syncs with the iPhone, and shows weather.

## A5. Privacy
- [ ] Check the location permission text in `Info.plist`. It covers the Home temperature and Camp Finder's Near me.
- [ ] App Store privacy label: match `PrivacyInfo.xcprivacy`. Declare approximate location: not linked, no tracking, app functionality.
- [ ] Reconcile disclosures with the shipped build and `docs/privacy-policy.md`: approximate location for Apple Weather and Apple Maps, private iCloud storage, no tracking, no remote AI, and on-device document indexing (nothing leaves the device; the index is not synced).
- [ ] Decide whether to add an in-app acknowledgements screen for sqlite-vec (MIT/Apache-2.0). Today the notice lives in the README, `Sources/CSQLiteVec/PROVENANCE.md`, and the privacy policy.

## A6. App Store Connect listing
- [ ] Create the App Store Connect app with the final bundle ID. Platforms: iPhone, iPad, and Mac (with Mac screenshots).
- [ ] The app icon is checked in (`Camp/AppIcon.icon`); verify the signed Release archive includes it and it looks right on every platform.
- [ ] Screenshots, app metadata (copy is in `docs/app-store-listing.md`), age rating, privacy policy/support URLs, privacy labels, and export-compliance answers.

## A7. Pricing: $4.99 one-time
No StoreKit code is needed; the price is set in App Store Connect.
- [ ] Complete the Paid Apps Agreement, banking, and tax information.
- [ ] Pricing and Availability: US base price **$4.99 USD**; review local prices for the chosen storefronts; schedule it for launch and confirm the saved schedule.
- [ ] Listing copy: "$4.99 one-time purchase. No subscription."
- [x] Docs: `docs/monetization.md` is written for the $4.99 one-time model.

## A8. TestFlight and release
- [ ] Configure distribution signing and upload a validated archive to TestFlight after deploying the CloudKit Production schema.
- [ ] Run Part B against the TestFlight build.
- [ ] Submit for review and release. Once live, check that the listing shows $4.99 and all three platforms. (TestFlight doesn't show the live price.)

---

# Part B: Simulator and device acceptance

Use a signed build (A1-A3; the TestFlight build for the final pass) on an **iPhone 15 Pro or later**, plus a **second device** on the same iCloud account for the sync checks, plus an **iPad** and a **Mac**. CI verifies compilation and unit tests, not these interactive checks. Keep every item unchecked until tested, and record the build commit, device/OS, date, result, and any follow-up defect in `docs/validation.md`.

## B1. Onboarding
- [ ] A fresh install in airplane mode finishes onboarding and adds a trip by hand.
- [ ] Continue stays disabled until year, make, model and length are filled in.

## B2. Navigation and empty states
- [ ] The tab bar shows Home, Trip, Camp Finder, Profile, with no Plan or More tab. Trip opens the new-trip sheet and leaves the current tab selected.
- [ ] With no current or upcoming trip, Home shows the **Add a trip** and **Find a campground** rows, and each does what it says.
- [ ] With a trip that starts later, Home shows the next trip with its setup checklist progress and further trips below it. On arrival day it switches to the live trip. Completed trips appear only in Profile › Trip history.
- [ ] Your campgrounds with nothing saved explains the three lists, and **Open Camp Finder** works.
- [ ] Photos & site notes with no photos, and rig/trip documents with none, show their empty states.

## B3. Trips
- [ ] Create, edit and delete a trip. Editing never resets checklists, notes or photos.
- [ ] Site details show on the trip. A rig longer than the site limit shows a warning.
- [ ] Attach a confirmation file, then open, share and follow the booking link.
- [ ] Deleting a trip moves its documents to Unattached.
- [ ] Mark complete, then reopen. A past trip completes on its own.

## B4. Checklists and rigs
- [ ] A new trip copies the rig's default lists. Editing the trip's lists doesn't change the defaults, and editing the defaults doesn't change existing trips.
- [ ] "Save as defaults" asks first and changes only that rig.
- [ ] A second active rig is refused.
- [ ] Replacing the rig archives the old one, and past trips still show it.

## B5. Documents
- [ ] Add from Files (including an iCloud Drive file not yet downloaded), from Photos, and from a link. "Save a copy for offline use" works.
- [ ] All new files are stored in Apple-managed encrypted fields; there is no per-category encryption setting. Older app-encrypted files still open.
- [ ] A 45 MB PDF works. A file over 50 MB is refused with a clear message.
- [ ] **Assign to rig or trip** moves a document and clears the other owner; a failed save shows an error and keeps the old assignment.
- [ ] Document details show the Assistant status (Queued, Reading, Indexing, Ready, Waiting for download, and so on) for eligible documents, and **Include in Assistant** only for Other documents.

## B6. iCloud sync (two devices)
- [ ] Everything appears on both devices: profile, rigs, trips, checklists, notes, photos, documents, saved campgrounds, and the Other-document opt-in.
- [ ] Edits to different checklist steps on each device both survive.
- [ ] Device A, offline, edits a trip while device B deletes it. Reconnect A and record which one wins.
- [ ] Offline edits on both devices sync with nothing lost.
- [ ] Turning sync off and on during a large upload loses nothing.
- [ ] Switching iCloud accounts never mixes data between them.
- [ ] A document that arrives before its file shows Waiting for download, not a failure, and becomes searchable once the file arrives. Each device builds its own index.
- [ ] Erase all data clears iCloud. The other device stops syncing but keeps its own copy.

## B7. Weather (required)
- [ ] First launch: the thermometer at the top right of Home asks for location only when tapped, and the prompt defaults to approximate.
- [ ] Location allowed: Home shows the temperature in your unit. Tapping it shows today's high and low, the update time, and the Apple Weather mark and link.
- [ ] Location denied, or turned off later in Settings: the temperature disappears and Home is otherwise unchanged.
- [ ] Airplane mode: the last reading still shows. Back online, it updates once it's over 30 minutes old.
- [ ] A trip with a location shows its per-day forecast with attribution. Offline, it shows the cached forecast and when it was fetched.

## B8. Assistant (required)
- [ ] On a device with Apple Intelligence, the sparkle button (compact) or **Ask Assistant** toolbar action (regular iPad, Mac, Duo, accessibility sizes) appears on every tab and opens the chat.
- [ ] Answers in airplane mode after the model has downloaded. Makes no network requests (check in Instruments).
- [ ] Send a question, close the Assistant, reopen it: the conversation is still there. **New chat** clears it. Quitting the app clears it.
- [ ] Closing during an answer cancels it and puts the question back in the text field.
- [ ] Trip help and "Ask about this step" start a fresh chat each time and answer about that trip/step.
- [ ] With Apple Intelligence off or still downloading, the Assistant opens a recovery screen with **Try again**, and recovers after enabling it.
- [ ] On a device without Apple Intelligence, there's no Assistant entry and no "Ask about this step".
- [ ] Document Q&A with real manuals: general chat shows the rig scope; trip help shows trip and rig; an exact fault code and a paraphrase both find the right page; a cited source opens at the cited page; a replaced or deleted source says so.
- [ ] A saved check-in time that differs from the confirmation's shows both values with their sources and changes nothing.
- [ ] A scanned manual and a photographed page are searchable; low-confidence text is flagged.
- [ ] Coverage and readiness: asking while a document is still indexing says coverage is incomplete, and **Retry** appears once it is ready without replacing the earlier answer.
- [ ] A non-English document question gets the English-only explanation; `E4?` is not rejected.
- [ ] Erase all data removes the search index; it is not recreated.

## B9. Camp Finder simulator pass
- [ ] The map shows only campground/RV park icons; tapping one opens the right detail.
- [ ] Simulated location: Near me works. With permission denied, text search still works.
- [ ] Search a campground name, "Moab, UT", a ZIP, and a park; results are sensible. Search this area follows the visible map.
- [ ] Website, Call, Directions, Apple's place card, list toggles, and Add trip prefill work.
- [ ] Confirm the campground time zone, change it manually, and check check-in/out times against a reservation in another zone.
- [ ] Rename a campground after choosing a listing, including choosing a different listing while editing; the previous place's coordinates/time zone are cleared and repeat manual visits group correctly.
- [ ] At 100% network loss, Camp Finder explains the failure and Try again recovers; trips remain editable offline.

## B10. Camp Finder on hardware
- [ ] Where you camp, the map shows the real campgrounds and RV parks in the right places.
- [ ] Near me asks for location once (or reuses the Home weather permission). With location denied, text search still works.
- [ ] Website, Call, Directions and "Photos, ratings & hours" open the right things.
- [ ] Add trip gets the right name, location and time zone. Try a campground in another time zone.
- [ ] Save to the lists, then complete a trip: the campground appears in Have been and syncs to the other device.
- [ ] In airplane mode, Camp Finder shows its offline message with Try again, and the rest of the app works.

## B11. Appearance and accessibility
- [ ] System follows device Light/Dark settings; explicit Light and Dark stay fixed when device settings change.
- [ ] The choice applies to all tabs, onboarding, sheets, alerts, maps, and weather attribution, and persists after relaunch offline.
- [ ] VoiceOver, largest Dynamic Type, Increase Contrast, Reduce Transparency, and Reduce Motion remain usable in each mode, including the Assistant's stage and readiness announcements.
- [ ] iPad Profile rig section passes the focused Dynamic Type audit at the largest size with no retained findings (#93), and an iPhone pass of the same audit passes.
- [ ] Erase all data resets appearance to System on a disposable library.

## B12. iPad
- [ ] Every screen works in portrait, landscape, and Split View. Tabs show in the top tab bar.
- [ ] The Assistant opens from the toolbar's Ask Assistant action, and a cited PDF source opens at its page.

## B13. Mac
- [ ] Launch, onboarding, trips, checklists, documents, Camp Finder, weather, and the Assistant (including indexing and the PDF source viewer) all work.
- [ ] "Take a photo" is hidden on a Mac without a camera; importing from Photos and Files works.
- [ ] iCloud sync with the iPhone works both ways.

## B14. iPhone Duo
- [ ] Open (unfolded) display: Home's selected trip, Camp Finder's map with results, and the campground sheet work; folding and unfolding keeps Home's state (#86, #91).
- [ ] Assistant toolbar entry and layout on the open and cover displays.

## B15. Pricing
- [ ] The installed build has no paywall, subscription, or in-app purchase prompts.

## B16. Everywhere
- [ ] Camera and photo permissions: allowed, denied (Open Settings), and limited.
- [ ] HEIC, Live Photos and very large images import.
- [ ] VoiceOver and the largest Dynamic Type work on every screen, in light and dark mode.
- [ ] A large library (about 300 trips and 2,000 photos) still launches and scrolls smoothly.
- [ ] Low storage and interrupted transfers or indexing surface a clear failure and recover.
- [ ] Assistant device baselines and answer-quality rubric are recorded (#108).

---

## Done
#12, #26, #28, #30, #31, #32, #42, #43, #44, #45, #46, #53, #54, #55; PR #70 (empty states, Assistant sheet), PR #71 (Assistant on iPhone/iPad/Mac, Mac Catalyst), PR #73 (CI split, no external packages, $4.99 docs), PR #75 (rig registration, step priority and notes), PR #76 (v1 audit), PR #78 (sample-trip seeder), #81 (manual-only UI runs). Document Assistant: #94 to #104, #106, #107 (search foundation, rig-manual answers, scope, eligibility and Other opt-in, assignment, index lifecycle, OCR, English-only, readiness, loading stages, prompt budget, conflicts, eval harness). Duo: #82 to #85, #87 to #90 as merged. Consolidated here: #4 (tracker), #10 (acceptance), #60 (pricing). Closed as not needed: #48, #33.
````

---

## Proposed body for #74

````markdown
All product decisions for v1 are settled; this issue is closed out. Remaining v1 work is in #6.

## 1. Is the Mac app in v1?
- [x] **Yes.** iPhone, iPad, and Mac (Catalyst) ship in v1. #6 keeps A4, the Mac listing in A6, and B13. CI builds Catalyst Debug/Release (`mac.yml`).

## 2. Is #65 (production-grade AI chat) a v1 blocker?
- [x] **No. Post-v1 (#29).** The global conversation stays in memory across closing the sheet and clears on New chat or app quit; nothing is saved, so the "conversations are never persisted" rule in `docs/features.md` and `docs/account-and-offline-contract.md` stands. Bounded recent history and the one compact retry on context overflow stay in v1. Document grounding (#92) shipped separately and does not reinstate saved chats.

## 3. No AI help on devices without Apple Intelligence
- [x] **Confirmed.** Apple-only on-device generation. Where Apple reports the device ineligible, the Assistant entry and "Ask about this step" are hidden; checklists work everywhere. There is no saved-guidance fallback and no remote model (#34 is v2). #32's earlier promise of help on iPhone 15 or newer is superseded: eligibility is whatever Apple's runtime reports.

## 4. Pricing
- [x] **$4.99 one-time purchase, permanently.** No subscription, trial, in-app purchase, or unlock. See `docs/monetization.md`; App Store Connect steps are in #6 A7.

## 5. Assistant entry point on iPad and Mac
- [x] **Decided in code.** The "Ask Assistant" bar was replaced. The entry is a sparkle button above the tab bar on compact layouts and an **Ask Assistant** toolbar action on regular iPad layouts, Mac, iPhone Duo, and accessibility text sizes. Signed-device confirmation on iPad and Mac stays in #6 B8, B12, B13.

## 6. "Take a photo" on a Mac without a camera
- [x] Camera capture is hidden where no camera exists. Confirm on a Mac without a camera in #6 B13.

## 7. Document Q&A language and scope (added with #92)
- [x] **English only in v1.** Non-English documents stay viewable and shareable but are not used as evidence.
- [x] **Explicit scope.** General chat searches the active rig's eligible documents. Trip and checklist chat searches that trip's and its rig's (archived rig included). Unattached documents are excluded until assigned to a rig or trip. Registration and Insurance are never read; Other is opt-in.
- [x] **Conflicts are shown, not resolved.** Saved trip values and document values that disagree are both shown with their sources; saved data is never edited.
````
