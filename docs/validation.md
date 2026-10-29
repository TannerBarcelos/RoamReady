# Build and validation

[Documentation index](README.md) · [Architecture](architecture.md) · [Release plan](integration-plan.md)

## Requirements

Run commands from the repository root (the folder containing `Package.swift` and `RoamReady.xcodeproj`). Package tests require Swift 6 or newer. Native builds require macOS and Xcode 27 with the iOS 27 SDK.

The native app uses the local Swift package and Apple frameworks only. There are no external package dependencies. The one deliberate third-party code is the vendored C source of sqlite-vec v0.1.9 (`Sources/CSQLiteVec`, MIT/Apache-2.0, with a provenance note); see [architecture](architecture.md).

## Open the native project

Open `RoamReady.xcodeproj` in an Xcode release containing the **iOS 27 SDK**. Select the shared **RoamReady** scheme and an iOS 27 simulator, then Run. The app targets iPhone, iPad, and Mac (Mac Catalyst; choose **My Mac (Mac Catalyst)** to run it), portrait and landscape, with System/Light/Dark appearance settings. The local `CampCore` Swift package resolves from this repository with no external package dependencies.

The checked-in project is an actual Xcode project, using filesystem-synchronized source groups supported by Xcode 16 and later. New Swift files beneath `Camp/` join the target automatically. `Info.plist` and `Camp.entitlements` are explicitly excluded from resource copying.

Swift language mode is 6.0 with strict concurrency. Default MainActor inference is deliberately not enabled: isolation belongs on the app's state-owning declarations. `CampCore` is a Foundation-only package with a lower platform floor so its tests run natively on macOS; the app's deployment target remains iOS 27.0.

The checked-in defaults use the owner’s `com.tannerdev.roamready` bundle identifier and development team. For another team, override both in `Config/Local.xcconfig`. Simulator builds need no development team. Both Debug and Release use `Config/App.xcconfig`, which optionally includes the ignored `Config/Local.xcconfig`. Copy `Config/Cloud.xcconfig.example` there and fill in your real bundle ID, team and container; no project-file edit or manual base-configuration selection is needed. CI checks that local overrides reach both configurations. A production App Store archive additionally needs distribution signing, privacy disclosures, and configured services. The checked-in `Camp/AppIcon.icon` must be verified in the signed Release archive.

## Repeatable checks

Run the package tests from the repository root with Swift 6 or newer:

```sh
swift test
```

On a Mac with the iOS 27 SDK, lint the project configuration and build for Simulator:

```sh
plutil -lint RoamReady.xcodeproj/project.pbxproj Camp/Info.plist Camp/Camp.entitlements Camp/PrivacyInfo.xcprivacy Config/Cloud.entitlements
xcodebuild -project RoamReady.xcodeproj -scheme RoamReady -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath .derivedData \
  CODE_SIGNING_ALLOWED=NO build
```

Derived data is written to `.derivedData/`. The shared scheme runs the app and includes `RoamReadyUITests`; package tests, including SwiftData on macOS, run separately with `swift test`. Regular CI builds the iOS app unsigned with `-destination 'generic/platform=iOS'`, which compiles for iPhone and iPad without booting a simulator. It also verifies the SDK version, location permission, and WeatherKit/CloudKit configuration.

## Test coverage and CI

The Mac workflow runs every package suite with `swift test` on macOS, including the SwiftData tests against real stores: rig and trip rules, checklists and defaults, cascades, note history, the document vault, reopening from disk, migrating an older store, and the export.

| Suite | Coverage |
| --- | --- |
| `CampCoreTests` | Rig policy/required details, VIN and plate normalization/validation, step priority/notes, trip dates/bookings, site details, checklist generation, campground identities, Assistant availability states and requests, and time-zone/DST forecast dates. |
| `CampgroundsTests` | Camp Finder place models, website/phone links, cleaned search text, and unique nearest-first result merging. |
| `DocumentVaultTests` | Type detection/import rules, metadata/HTTPS validation, SHA-256, streaming file inspection/staging/cleanup, and legacy AES-GCM decoding and integrity failures. |
| `DocumentSearchTests` | File-backed FTS5 and sqlite-vec lifecycle (publish, lexical and KNN search, reopen, delete), lexical fallback when embeddings are unavailable, revision and dimension changes making old vectors ineligible, scope allow-list applied before ranking, atomic republish and stale-row exclusion, hostile FTS input and document IDs, and schema-version refusal. |
| `CampPersistenceTests` | Real SwiftData stores: rigs/defaults, encrypted registration, step priority/notes through defaults and new trips, trip checklists, deletes/cascades, note revisions, completion/saved campgrounds, document persistence, reopening from disk, and export. |

On every PR and main push, the [iOS and iPad](../.github/workflows/app.yml) workflow builds the single universal app in Debug and Release, and the [Mac](../.github/workflows/mac.yml) workflow runs all package tests and builds Catalyst in both configurations. These jobs use GitHub's `xcode-27` image and never boot a simulator. Package tests retain real-store migration, cascade, export, and persistence coverage.

Simulator tests are deferred to the manual [UI tests](../.github/workflows/ui-tests.yml) workflow. In GitHub Actions, select **UI tests (manual)**, choose the branch and iPhone or iPad, and click **Run workflow**. The full native suite and its unfiltered accessibility audits remain available; no UI tests run automatically on PRs or main pushes. They cover navigation, onboarding/disk persistence, appearance, and simulated Assistant states, but do not establish real Foundation Models generation or physical-device behavior. The unresolved iPad Dynamic Type finding recorded in [the v1 audit](v1-audit.md) remains a release-validation item; green build/package CI does not certify that audit.

## Airplane-mode acceptance pass

1. In airplane mode on a fresh install, complete rig/profile onboarding, including an emoji or photo and a VIN and plate, and add the initial trip. No account or connection is required. Check that an invalid VIN blocks Continue with its own message.
2. Plan a trip, inspect both checklists, change their order, complete a step, skip a step, and add a custom step. Give one step a High priority and notes; confirm `!!!` and the notes show in the list.
3. Create a second trip; confirm it has fresh progress and that editing it does not change the first trip.
4. Save a site number, rating, notes, and locally available photos. Force-quit and relaunch in airplane mode, then check everything again.
5. Change reusable checklist defaults and create another trip. Confirm the new trip uses the changed defaults, including their priorities and notes, and previous trips retain their snapshots.
6. Test app relaunch and save retry after simulated disk-write failures. The app must surface the failure instead of claiming changes are durable.
7. Check large text, VoiceOver, reduced motion/transparency, light/dark mode, rotation, and iPad split view. Check list controls remain usable outdoors and with long campground names.
8. Check supported and unsupported on-device AI states, and cached weather timestamps when offline. A network request must never block checklist editing.

Cloud sync is not established by local persistence tests. Validate multi-device conflicts, account changes, asset upload interruption, and background delivery using a provisioned CloudKit container. Apple manages mirroring scheduling; background push delivery still requires signed-device provisioning and acceptance.

## Appearance acceptance pass

Profile › Settings › Appearance offers **System** (the default), **Light**, and **Dark**. The selection is saved on this device, works offline, and applies at the window root so navigation, sheets, alerts, onboarding, and loading/error screens share it. Native semantic colors provide dark grouped backgrounds, elevated rows, readable primary/secondary text, and adaptive blue accents without changing the light layout. Photos and documents retain their original colors; Apple's camera and document viewers keep their system-provided presentation.

On an iOS simulator or device:

1. With no saved preference, switch the device between Light and Dark and verify all available tabs follow it, including Camp Finder's map.
2. Select **Dark** while the device is in Light. Check Home, Profile’s trip history, a trip's booking/checklists/memories/weather, Camp Finder's listings and details, and Profile. Open an editor sheet, photo/document preview, and a delete confirmation; check text, fields, separators, blue actions, and destructive actions remain readable. Weather attribution must use the dark mark.
3. Select **Light** while the device is in Dark. Confirm the existing light interface returns throughout the app, including sheets and the map, and weather attribution uses the light mark.
4. Select **System** again. Change the device appearance while RoamReady is open and confirm it follows immediately; repeat with a sheet open. Explicit Light and Dark choices must stay fixed when the device setting changes.
5. Force-quit and relaunch in each mode, including in airplane mode; the selection must persist. Selecting a mode must preserve the current tab, navigation, and in-progress edits.
6. Check the picker with VoiceOver and the largest Dynamic Type sizes, and review each mode with Increase Contrast, Reduce Transparency, and Reduce Motion enabled.
7. On a disposable test library, use Erase all data. The appearance preference resets to System with the other device settings, and onboarding follows the device appearance.

These visual checks are not covered by the package tests.

## Regular-iPhone layout baselines (Duo)

The iPhone Duo work (#82–#91) changes layouts only on Duo. Regular iPhones must keep their current layouts, navigation, tab behavior, and Assistant placement. The screenshots in [validation/duo-baselines](validation/duo-baselines/) record the regular-iPhone layouts from `main` at 7c99419, before any Duo change. Compare each Duo slice against them.

| | Small iPhone | Large iPhone |
| --- | --- | --- |
| Simulator | iPhone 17e | iPhone Air (the largest iPhone simulator installed; there is no Pro Max) |
| OS | iOS 27.0 (24A434) | iOS 27.0 (24A434) |
| File prefix | `small-` | `large-` |

- **Text sizes:** `default` is the system default (`content_size large`); `ax3` is Accessibility Extra Large (`content_size accessibility-extra-large`).
- **Orientations:** `portrait` and `landscape` (landscape left).
- **Appearance:** Light. Captured on Oct 27–28, 2026, so dates in the fixture trips show those days.
- **Files:** `<device>-<text size>-<orientation>-<screen>.png`, scaled so the longest side is 900 px. There are 48: the small iPhone at the default text size is missing. Its captures came out at the accessibility size because the text-size change didn't take effect, so they were left out. Recapture that set with the steps below.

| Screen | How it's reached | Launch arguments |
| --- | --- | --- |
| `onboarding` | A fresh install, no flags (opens the real, empty library) | none |
| `home` | Launch | `-assistant-ui-test ready -navigation-ui-test` |
| `trip-detail` | Home › Current Pines | same |
| `checklist` | Trip details › Setup | same |
| `camp-finder` | The Camp Finder tab, after 4 seconds for map tiles | same |
| `profile` | The Profile tab | same |
| `assistant-entry` | Home, showing the sparkle button or the toolbar's Ask Assistant | same |
| `assistant-sheet` | The Assistant sheet, opened from Home | same |

`-navigation-ui-test` uses the in-memory fixture library ([NavigationUITestLibrary.swift](../Camp/App/NavigationUITestLibrary.swift)), so the trips are Current Pines, Overlapping Creek, Upcoming Lake, and Past Meadows. Their dates are relative to today, so later captures match except for the dates, the clock, and Camp Finder's map tiles.

What the baselines show today:

- On the large iPhone at the default size in portrait, the Assistant is the round sparkle button above the tab bar.
- On the large iPhone in landscape, the width class is regular, so the Assistant is **Ask Assistant** in the toolbar even at the default size.
- At the accessibility size, the Assistant is in the toolbar on both iPhones and in both orientations.
- The tab bar always shows Home, Trip, Camp Finder, and Profile.

### Recapture the baselines

`LayoutBaselineUITests` ([LayoutBaselineUITests.swift](../Tests/RoamReadyUITests/LayoutBaselineUITests.swift)) takes the screenshots. It skips itself unless `ROAMREADY_BASELINE_DIR` is set, so the regular UI test run is unaffected. Use your own simulator clones so other simulator work isn't disturbed:

```sh
SMALL=$(xcrun simctl clone "iPhone 17e" baseline-small)   # pick the iOS 27.0 device if there are several
LARGE=$(xcrun simctl clone "iPhone Air" baseline-large)
xcrun simctl boot "$SMALL"; xcrun simctl boot "$LARGE"

xcodebuild -project RoamReady.xcodeproj -scheme RoamReady -configuration Debug \
  -destination "id=$SMALL" -derivedDataPath .derivedData CODE_SIGNING_ALLOWED=NO build-for-testing

OUT=/tmp/duo-baselines
for device in small large; do
  udid=$SMALL; [[ $device == large ]] && udid=$LARGE
  for size in large accessibility-extra-large; do
    label=default; [[ $size != large ]] && label=ax3
    xcrun simctl uninstall "$udid" com.tannerdev.roamready   # fresh install, so onboarding shows
    xcrun simctl ui "$udid" content_size "$size"
    xcrun simctl ui "$udid" content_size                      # confirm it took effect
    TEST_RUNNER_ROAMREADY_BASELINE_DIR=$OUT TEST_RUNNER_ROAMREADY_BASELINE_PREFIX=$device-$label \
      xcodebuild -project RoamReady.xcodeproj -scheme RoamReady -destination "id=$udid" \
      -derivedDataPath .derivedData CODE_SIGNING_ALLOWED=NO test-without-building \
      -only-testing:RoamReadyUITests/LayoutBaselineUITests
  done
  xcrun simctl ui "$udid" content_size large
done

xcrun simctl delete "$SMALL" "$LARGE"
```

Each run takes several minutes per device and text size. The simulator must stay booted for the whole run: if `simctl ui` reports the device is shut down, the text size was not applied and that run must be repeated. XCTest stores landscape screenshots in portrait pixels with an orientation tag. Before committing, scale them with ImageIO using `kCGImageSourceCreateThumbnailWithTransform` (and `kCGImageSourceThumbnailMaxPixelSize` 900), which stores them upright; plain `sips -Z` keeps the tag.

To check a Duo slice, run the same capture on its branch and compare the images file by file. Regular iPhones should differ only in dates, the clock, and map tiles.

## Apple capability configuration

The default `Camp.entitlements` includes Mac sandbox permissions but no CloudKit or WeatherKit capabilities; the app has no accounts. System PhotosPicker grants selected-item access without unrestricted Photo Library permission. NSCameraUsageDescription supports on-device trip photo capture. Location (when in use, approximate by default) is requested when the owner taps Home weather or Camp Finder’s Near me. Weather requests round it to about 1 km; Camp Finder uses it to search Apple Maps. Manual trip entry and text search work without location permission.

`PrivacyInfo.xcprivacy` declares app-local UserDefaults access for the iCloud sync and appearance preferences (reason CA92.1), no tracking, and coarse location (not linked, app functionality) for the Home weather reading. Camp Finder's search region goes to Apple Maps through MapKit; the device's location is not stored in the library. A chosen campground's coordinates and time zone are saved with its trip. Reassess the manifest and App Store privacy disclosures for optional CloudKit, WeatherKit, and any future backend or telemetry. There is no remote AI.

Signed builds use `Config/Cloud.entitlements` through a local xcconfig made from `Config/Cloud.xcconfig.example` (see #6). It declares CloudKit for `$(ROAMREADY_MIRRORING_CONTAINER)` and WeatherKit (`com.apple.developer.weatherkit`); CI fails if either is removed. Enable iCloud (CloudKit), Push Notifications, and WeatherKit on the App ID to match. Without WeatherKit, weather refresh fails and shows any saved forecast.

CloudKit subscription delivery also needs the appropriate Push Notifications capability and the `remote-notification` background mode if your sync design uses silent pushes; allow Xcode to generate the environment-specific push entitlement. A provisioned CloudKit capability plus SwiftData's private CloudKit configuration enables Apple-managed mirroring and conflict handling; the app does not implement its own transport. There are no app accounts; onboarding and trips must work offline. Foundation Models availability must be checked at runtime; an empty entitlements file cannot make an unsupported device eligible.

## SwiftData and automatic CloudKit mirroring

SwiftData manages the local store; no raw SQL or SQLite driver is used. Its CloudKit mirroring (`NSPersistentCloudKitContainer` underneath) manages cloud transfers and external binary data. There is no custom CloudKit transport.

See [offline-storage.md](offline-storage.md) for new-container provisioning, default-on sync and the next-launch preference, schema-change rules, asset behavior, and physical-device acceptance. Default entitlements contain only Mac sandbox permissions. Native mirroring requires a new CloudKit container, Push Notifications provisioning, and deployment of the generated CloudKit schema. Before the first Production deployment, confirm the Development schema includes `StoredDocument.includeInAssistant`; after it, only additive changes are allowed.

`ICloudSettingsTests` cover session-stable preferences, next-launch application in both directions, unconfigured builds, and passive activity/error reporting without a global delivery claim. These run in CI with the persistence suite.

## Camp Finder and account changes

The package tests cover Assistant availability and requests, campground identities, Camp Finder places, file staging/streaming inspection, and legacy document decoding. Device acceptance must cover iCloud identity changes, iCloud preference changes and relaunches during transfers, Erase all data, offline trip camera capture, and Camp Finder (the campground-only map and tapping places, Near me with location allowed and denied, text search, Search this area, the place card, Website/Call/Directions, offline and retry, the throttling message). See the [identity/connectivity contract](account-and-offline-contract.md) for limits and the [Camp Finder source guide](campground-sourcing.md#to-check-before-release) for discovery acceptance.

## Current trip and Assistant acceptance pass

The navigation UI tests use a DEBUG-only in-memory library with overlapping current trips, an upcoming trip, and a completed trip. They verify all unfinished trips remain reachable on Home, Profile owns trip history and saved campgrounds, Settings contains appearance and export, and the Trip tab returns to the previous tab after dismissal. The fixture never opens the owner’s on-disk library.

1. Add a past trip and a future trip; neither appears as Current trip on Home. The future trip remains on Home; the past trip is in Profile › Trip history.
2. Add a trip spanning today. Verify Home opens its booking, Setup, Teardown, and Photos & site notes directly. With overlapping trips, the earliest arrival is featured.
3. Check arrival midnight and midnight after departure in the campground’s time zone, including DST and a same-day stay. Leave Home open across midnight and background/reopen the app. Mark complete early, reopen, and edit dates; the card must update without deleting trip data.
4. On hardware without Apple Intelligence, confirm no Assistant sparkle button above the tab bar and no Ask for camping help. On a supported iPhone, iPad, and Mac, verify the Assistant sparkle button or toolbar action appears on every tab, the tab bar shows four tabs with no Plan or More, and Assistant opens with AI ready, disabled, or preparing, and rechecks eligibility on return from Settings. Disabled/preparing/unavailable states must show the recovery screen and Try again with no conversation, text field, or send button. Re-enabling AI must restore the conversation.
5. With AI ready and no active trip, ask a general troubleshooting question that matches no checklist. Ask a follow-up referring to the previous answer. Verify the conversation survives closing and reopening the Assistant; New chat clears it. Ask trip/checklist help a question its checklist doesn’t cover and verify a generated answer, not saved text.
6. Close the Assistant or dismiss trip help during generation: the pending request cancels, its question is restored, and no late answer appears in a later request. Try a model refusal/failure and confirm a retryable error, with no saved-text substitute. Test in airplane mode after model download.
7. Check long conversations, keyboard scrolling, Dynamic Type, VoiceOver, and all available tabs on a compact iPhone. Confirm the fixed composer has only a text input and send button, without file/image upload controls. Force-quit/relaunch and confirm chat is not persisted.

The package tests verify current-trip dates/time zones/DST/early completion, generation without a reference match, and bounded follow-up context. The `RoamReadyUITests` target checks the actual native error screens, absence of chat/composer in unavailable states, hidden Assistant sparkle button on unsupported devices, and ready text/send composer. Its `-assistant-ui-test` state override exists only in DEBUG builds and bypasses onboarding without creating trip data. Run it with Xcode’s Test action or `xcodebuild test` using an iOS 27 simulator destination. These tests do not generate AI answers; Foundation Models still needs the physical-device checks above.

## Live on-device Foundation Models smoke test

Before release, use a physical iPhone, iPad, or Mac that supports Apple Intelligence, with iOS 27, a supported language, Apple Intelligence enabled, and the model downloaded. In Xcode, select that iPhone and set `ROAMREADY_RUN_ON_DEVICE_AI_SMOKE=1` in the shared scheme’s **Test** environment. Run `AssistantUITests/testLiveOnDeviceFoundationModelsResponseAndFollowUp`. It launches with the DEBUG-only `-assistant-device-smoke` onboarding bypass and never sets a simulated availability or response. It must receive a nonempty **generated** answer and a second generated answer to a follow-up. Repeat in airplane mode after the model is ready, then with no active trip, and check disabled/downloading states separately. A saved-guide answer does not pass this test.

Simulator CI deliberately skips this opt-in hardware test. Its deterministic send/error UI tests use separate DEBUG-only simulated generators, which are excluded from Release builds. Package tests verify that Send reaches the generator without a trip/reference match, errors and cancellations propagate, empty answers fail, overlong questions are preserved for shortening, and context overflow retries only once. Native UI tests check successful Send and failure/retry presentation. Real generation must still be verified on the physical device; simulator or fake replies do not establish it.

The production adapter follows Apple’s [Foundation Models generation guide](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models), [language support guidance](https://developer.apple.com/documentation/foundationmodels/supporting-languages-and-locales-with-foundation-models), and [iOS 27 model error API](https://developer.apple.com/documentation/foundationmodels/languagemodelerror).
