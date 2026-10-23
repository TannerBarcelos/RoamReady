# Build and validation

[Documentation index](README.md) · [Architecture](architecture.md) · [Release plan](integration-plan.md)

## Requirements

Run commands from the repository root (the folder containing `Package.swift` and `RoamReady.xcodeproj`). Package tests require Swift 6 or newer. Native builds require macOS and Xcode 27 with the iOS 27 SDK.

The native app uses the local Swift package and Apple frameworks. SwiftPM declares Apple's [swift-crypto](https://github.com/apple/swift-crypto), whose `Crypto` product is linked only on Linux for CryptoKit-compatible tests. Initial package resolution may require internet access, including on macOS. There are no non-Apple runtime SDKs.

## Open the native project

Open `RoamReady.xcodeproj` in an Xcode release containing the **iOS 27 SDK**. Select the shared **RoamReady** scheme and an iOS 27 simulator, then Run. The app targets iPhone and iPad, portrait and landscape, with System/Light/Dark appearance settings. The local `CampCore` Swift package resolves from this repository; the only external package is Apple's swift-crypto, used for Linux tests.

The checked-in project is an actual Xcode project, using filesystem-synchronized source groups supported by Xcode 16 and later. New Swift files beneath `Camp/` join the target automatically. `Info.plist` and `Camp.entitlements` are explicitly excluded from resource copying.

Swift language mode is 6.0 with strict concurrency. Default MainActor inference is deliberately not enabled: isolation belongs on the app's state-owning declarations. `CampCore` is a Foundation-only package with a lower platform floor so its tests also run on Linux and macOS; the app's deployment target remains iOS 27.0.

For a physical device, change the placeholder `com.example.RoamReady` identifier to your own unique bundle identifier and select your development team under Signing & Capabilities. Simulator builds need no development team. A production App Store archive additionally needs your app icon, distribution signing, privacy disclosures, and configured services. No icon assets have been fabricated for this development scaffold.

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

Derived data is written to `.derivedData/`. The shared scheme runs the app and includes `RoamReadyUITests`; package tests, including SwiftData on macOS, run separately with `swift test`. The [Apple validation workflow](../.github/workflows/apple-validation.yml) runs these commands directly, verifies the iOS SDK version, and checks the location permission and signed-build WeatherKit/CloudKit configuration.

## Test coverage and CI

The portable Swift suites run in Swift 6 on Linux (a CI job runs them in the official `swift` container). Apple CI also compiles the SwiftData package and runs its tests on macOS against real stores: rig and trip rules, checklists and defaults, cascades, note history, the document vault, reopening from disk, and the export.

| Suite | Coverage |
| --- | --- |
| `CampCoreTests` | Rig policy/required details, trip dates/bookings, site details, checklist generation, campground identities, AI hardware eligibility, and time-zone/DST forecast dates. |
| `CampgroundsTests` | Camp Finder place models, website/phone links, cleaned search text, and unique nearest-first result merging. |
| `DocumentVaultTests` | Type detection/import rules, metadata/HTTPS validation, SHA-256, and AES-GCM sealing and integrity failures. |
| `CampPersistenceTests` (Apple platforms) | Real SwiftData stores: rigs/defaults, trip checklists, deletes/cascades, note revisions, completion/saved campgrounds, document persistence, reopening from disk, and export. |

Apple CI runs on GitHub's `xcode-27` image (macOS 27) and builds the app unsigned for the iOS Simulator with the iOS 27 SDK at the project's iOS 27 deployment target; the workflow refuses an older SDK. It also runs Assistant presentation/composer UI tests on an iOS 27 simulator using DEBUG-only simulated AI states. It does not verify Foundation Models generation or physical-device behavior. See the [latest workflow results](https://github.com/TannerBarcelos/RoamReady/actions/workflows/apple-validation.yml) for the exact commit and outcome.

## Airplane-mode acceptance pass

1. In airplane mode on a fresh install, complete rig/profile onboarding, including an emoji or photo, and add the initial trip. No account or connection is required.
2. Plan a trip, inspect both checklists, change their order, complete a step, skip a step, and add a custom step.
3. Create a second trip; confirm it has fresh progress and that editing it does not change the first trip.
4. Save a site number, rating, notes, and locally available photos. Force-quit and relaunch in airplane mode, then check everything again.
5. Change reusable checklist defaults and create another trip. Confirm the new trip uses the changed defaults and previous trips retain their snapshots.
6. Test app relaunch and save retry after simulated disk-write failures. The app must surface the failure instead of claiming changes are durable.
7. Check large text, VoiceOver, reduced motion/transparency, light/dark mode, rotation, and iPad split view. Check list controls remain usable outdoors and with long campground names.
8. Check supported and unsupported on-device AI states, and cached weather timestamps when offline. A network request must never block checklist editing.

Cloud sync is not established by local persistence tests. Validate multi-device conflicts, account changes, asset upload interruption, and background delivery using a provisioned CloudKit container. Apple manages mirroring scheduling; background push delivery still requires signed-device provisioning and acceptance.

## Appearance acceptance pass

Profile › Appearance offers **System** (the default), **Light**, and **Dark**. The selection is saved on this device, works offline, and applies at the window root so navigation, sheets, alerts, onboarding, and loading/error screens share it. Native semantic colors provide dark grouped backgrounds, elevated rows, readable primary/secondary text, and adaptive blue accents without changing the light layout. Photos and documents retain their original colors; Apple's camera and document viewers keep their system-provided presentation.

On an iOS simulator or device:

1. With no saved preference, switch the device between Light and Dark and verify all available tabs follow it, including Camp Finder's map.
2. Select **Dark** while the device is in Light. Check Home, Plan, a trip's booking/checklists/memories/weather, Camp Finder's listings and details, and Profile. Open an editor sheet, photo/document preview, and a delete confirmation; check text, fields, separators, blue actions, and destructive actions remain readable. Weather attribution must use the dark mark.
3. Select **Light** while the device is in Dark. Confirm the existing light interface returns throughout the app, including sheets and the map, and weather attribution uses the light mark.
4. Select **System** again. Change the device appearance while RoamReady is open and confirm it follows immediately; repeat with a sheet open. Explicit Light and Dark choices must stay fixed when the device setting changes.
5. Force-quit and relaunch in each mode, including in airplane mode; the selection must persist. Selecting a mode must preserve the current tab, navigation, and in-progress edits.
6. Check the picker with VoiceOver and the largest Dynamic Type sizes, and review each mode with Increase Contrast, Reduce Transparency, and Reduce Motion enabled.
7. On a disposable test library, use Erase all data. The appearance preference resets to System with the other device settings, and onboarding follows the device appearance.

These visual checks require Apple SDKs and are not covered by the portable package tests.

## Apple capability configuration

The default `Camp.entitlements` declares no capabilities; the app has no accounts. System PhotosPicker grants selected-item access without unrestricted Photo Library permission. NSCameraUsageDescription supports on-device trip photo capture. Location (when in use, approximate by default) is requested when the owner taps Home weather or Camp Finder’s Near me. Weather requests round it to about 1 km; Camp Finder uses it to search Apple Maps. Manual trip entry and text search work without location permission.

`PrivacyInfo.xcprivacy` declares app-local UserDefaults access for the iCloud sync and appearance preferences (reason CA92.1), no tracking, and coarse location (not linked, app functionality) for the Home weather reading. Camp Finder's search region goes to Apple Maps through MapKit; the device's location is not stored in the library. A chosen campground's coordinates and time zone are saved with its trip. Reassess the manifest and App Store privacy disclosures for optional CloudKit, WeatherKit, and any future backend or telemetry. There is no remote AI.

Signed builds use `Config/Cloud.entitlements` through a local xcconfig made from `Config/Cloud.xcconfig.example` (see #6). It declares CloudKit for `$(ROAMREADY_MIRRORING_CONTAINER)` and WeatherKit (`com.apple.developer.weatherkit`); CI fails if either is removed. Enable iCloud (CloudKit), Push Notifications, and WeatherKit on the App ID to match. Without WeatherKit, weather refresh fails and shows any saved forecast.

CloudKit subscription delivery also needs the appropriate Push Notifications capability and the `remote-notification` background mode if your sync design uses silent pushes; allow Xcode to generate the environment-specific push entitlement. A provisioned CloudKit capability plus SwiftData's private CloudKit configuration enables Apple-managed mirroring and conflict handling; the app does not implement its own transport. There are no app accounts; onboarding and trips must work offline. Foundation Models availability must be checked at runtime; an empty entitlements file cannot make an unsupported device eligible.

## SwiftData and automatic CloudKit mirroring

SwiftData manages the local store; no raw SQL or SQLite driver is used. Its CloudKit mirroring (`NSPersistentCloudKitContainer` underneath) manages cloud transfers and external binary data. There is no custom CloudKit transport.

See [offline-storage.md](offline-storage.md) for new-container provisioning, default-on sync and the next-launch preference, schema-change rules, asset behavior, and physical-device acceptance. Default entitlements are empty. Native mirroring requires a new CloudKit container, Push Notifications provisioning, and deployment of the generated CloudKit schema.

`ICloudSettingsTests` cover session-stable preferences, next-launch application in both directions, unconfigured builds, and passive activity/error reporting without a global delivery claim. These run on Apple CI with the persistence suite.

## Camp Finder and account changes

The portable suites cover AI hardware policy, campground identities, Camp Finder places, and the document cipher. Device acceptance must cover iCloud identity changes, iCloud preference changes and relaunches during transfers, Erase all data, offline trip camera capture, and Camp Finder (the campground-only map and tapping places, Near me with location allowed and denied, text search, Search this area, the place card, Website/Call/Directions, offline and retry, the throttling message). See the [identity/connectivity contract](account-and-offline-contract.md) for limits and the [Camp Finder source guide](campground-sourcing.md#to-check-before-release) for discovery acceptance.

## Current trip and Assistant acceptance pass

1. Add a past trip and a future trip; neither appears as Current trip on Home. Both remain in Plan.
2. Add a trip spanning today. Verify Home opens its booking, Setup, Teardown, and Photos & site notes directly. With overlapping trips, the earliest arrival is featured.
3. Check arrival midnight and midnight after departure in the campground’s time zone, including DST and a same-day stay. Leave Home open across midnight and background/reopen the app. Mark complete early, reopen, and edit dates; the card must update without deleting trip data.
4. On unsupported hardware (including base iPhone 15/15 Plus), iPad, and simulator, confirm no Assistant tab. Trip/checklist saved guidance remains available. On a supported iPhone, verify Assistant appears with AI ready, disabled, or preparing, and rechecks eligibility on return from Settings. Disabled/preparing/unavailable states must show the recovery screen and Try again with no conversation, text field, or send button. Re-enabling AI must restore the conversation.
5. With AI ready and no active trip, ask a general troubleshooting question that matches no checklist. Ask a follow-up referring to the previous answer. Verify the conversation survives tab changes; New chat clears it. Verify trip/checklist help still uses saved guidance.
6. Switch tabs or dismiss trip help during generation: the pending request cancels, its question is restored, and no late answer appears in a later request. Try a model refusal/failure and confirm honest saved-guidance fallback. Test in airplane mode after model download.
7. Check long conversations, keyboard scrolling, Dynamic Type, VoiceOver, and all available tabs on a compact iPhone. Confirm the fixed composer has only a text input and send button, without file/image upload controls. Force-quit/relaunch and confirm chat is not persisted.

The portable tests verify current-trip dates/time zones/DST/early completion, chat hardware policy, generation without a reference match, and bounded follow-up context. The `RoamReadyUITests` target checks the actual native error screens, absence of chat/composer in unavailable states, hidden tab on unsupported devices, and ready text/send composer. Its `-assistant-ui-test` state override exists only in DEBUG builds and bypasses onboarding without creating trip data. Run it with Xcode’s Test action or `xcodebuild test` using an iOS 27 simulator destination. These tests do not generate AI answers; Foundation Models still needs the physical-device checks above.

## Live on-device Foundation Models smoke test

Before release, use a physical iPhone 15 Pro or newer supported by the product policy, with iOS 27, a supported language, Apple Intelligence enabled, and the model downloaded. In Xcode, select that iPhone and set `ROAMREADY_RUN_ON_DEVICE_AI_SMOKE=1` in the shared scheme’s **Test** environment. Run `AssistantUITests/testLiveOnDeviceFoundationModelsResponseAndFollowUp`. It launches with the DEBUG-only `-assistant-device-smoke` onboarding bypass and never sets a simulated availability or response. It must receive a nonempty **generated** answer and a second generated answer to a follow-up. Repeat in airplane mode after the model is ready, then with no active trip, and check disabled/downloading states separately. A saved-guide answer does not pass this test.

Simulator CI deliberately skips this opt-in hardware test. Its deterministic send/error UI tests use separate DEBUG-only simulated generators, which are excluded from Release builds. Portable tests verify that Send reaches the generator without a trip/reference match, errors and cancellations propagate, empty answers fail, overlong questions are preserved for shortening, and context overflow retries only once. Native UI tests check successful Send and failure/retry presentation. Real generation must still be verified on the physical device; simulator or fake replies do not establish it.

The production adapter follows Apple’s [Foundation Models generation guide](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models), [language support guidance](https://developer.apple.com/documentation/foundationmodels/supporting-languages-and-locales-with-foundation-models), and [iOS 27 model error API](https://developer.apple.com/documentation/foundationmodels/languagemodelerror).
