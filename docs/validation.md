# Build and validation

## Open the native project

Open `RoamReady.xcodeproj` in an Xcode release containing the **iOS 27 SDK**. Select the shared **RoamReady** scheme and an iOS 27 simulator, then Run. The app targets iPhone and iPad, portrait and landscape, with automatic system light/dark appearance. The local `CampCore` Swift package resolves from this repository; the only external package is Apple's swift-crypto, used for Linux tests.

The checked-in project is an actual Xcode project, using filesystem-synchronized source groups supported by Xcode 16 and later. New Swift files and bundled JSON beneath `Camp/` join the target automatically. `Info.plist` and `Camp.entitlements` are explicitly excluded from resource copying.

Swift language mode is 6.0 with strict concurrency. Default MainActor inference is deliberately not enabled: isolation belongs on the app's state-owning declarations. `CampCore` is a Foundation-only package with a lower platform floor so its tests also run on Linux and macOS; the app's deployment target remains iOS 27.0.

For a physical device, change the placeholder `com.example.RoamReady` identifier to your own unique bundle identifier and select your development team under Signing & Capabilities. Simulator builds need no development team. A production App Store archive additionally needs your app icon, distribution signing, privacy disclosures, and configured services. No icon assets have been fabricated for this development scaffold.

## Repeatable checks

```sh
cd RoamReady
./scripts/check.sh
```

Requirements: Swift 6+, Bash, and Python 3. If Swift is not on PATH, use `SWIFT_BIN=/absolute/path/to/swift ./scripts/check.sh`.

The script runs the Swift package tests, parses the Xcode OpenStep project property list with Foundation, parses every native Swift file, validates plist and JSON syntax and the signed-build entitlements, checks that Camp Finder's location prompt is declared and no campground data is bundled, and checks project and shared-scheme references. `swiftc -frontend -parse` only checks syntax; it does **not** resolve SwiftUI, UIKit, Foundation Models, WeatherKit, or other Apple SDK APIs and does not prove the native app compiles.

On a Mac with the required SDK:

```sh
./scripts/check.sh --native
```

This also lints the project with Apple's `plutil` and runs an unsigned simulator build with `xcodebuild`. Derived data is written to `.derivedData/`. The shared scheme runs the app; core unit tests are run separately with `swift test`, rather than pretending an empty scheme test action exercises them.

## Validation completed in the development environment

The portable Swift suites run in Swift 6 on Linux (a CI job runs them in the official `swift` container). Apple CI also compiles the SwiftData package and runs its tests on macOS against real stores: rig and trip rules, checklists and defaults, cascades, note history, the document vault, reopening from disk, and the export.

Apple CI runs on GitHub's `xcode-27` image (macOS 27) and builds the app unsigned for the iOS Simulator with the iOS 27 SDK at the project's iOS 27 deployment target; `check.sh --native` refuses an older SDK. This verifies compilation, not runtime behavior on physical devices. See the [latest workflow results](https://github.com/TannerBarcelos/RoamReady/actions/workflows/apple-validation.yml) for the exact commit and outcome.

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

## Apple capability configuration

The default `Camp.entitlements` declares no capabilities; the app has no accounts. System PhotosPicker grants selected-item access without unrestricted Photo Library permission. NSCameraUsageDescription supports on-device trip photo capture. Location (when in use, approximate by default) is requested when the owner taps Home weather or Camp Finder’s Near me. Weather requests round it to about 1 km; Camp Finder uses it to search Apple Maps. Manual trip entry and text search work without location permission.

`PrivacyInfo.xcprivacy` declares app-local UserDefaults access for the iCloud sync preference (reason CA92.1), no tracking, and coarse location (not linked, app functionality) for the Home weather reading. Camp Finder's search region goes to Apple Maps through MapKit; the device's location is not stored in the library. A chosen campground's coordinates and time zone are saved with its trip. Reassess the manifest and App Store privacy disclosures for optional CloudKit, WeatherKit, and any future backend or telemetry. There is no remote AI.

Signed builds use `Config/Cloud.entitlements` through a local xcconfig made from `Config/Cloud.xcconfig.example` (see #6). It declares CloudKit for `$(ROAMREADY_MIRRORING_CONTAINER)` and WeatherKit (`com.apple.developer.weatherkit`); `check.sh` fails if either is removed. Enable iCloud (CloudKit), Push Notifications, and WeatherKit on the App ID to match. Without WeatherKit, weather refresh fails and shows any saved forecast.

CloudKit subscription delivery also needs the appropriate Push Notifications capability and the `remote-notification` background mode if your sync design uses silent pushes; allow Xcode to generate the environment-specific push entitlement. Enabling CloudKit alone does not implement syncing or conflict handling. There are no app accounts; onboarding and trips must work offline. Foundation Models availability must be checked at runtime; an empty entitlements file cannot make an unsupported device eligible.

## SwiftData and automatic CloudKit mirroring

SwiftData manages the local store; no raw SQL or SQLite driver is used. Its CloudKit mirroring (`NSPersistentCloudKitContainer` underneath) manages cloud transfers and external binary data. There is no custom CloudKit transport.

See [offline-storage.md](offline-storage.md) for new-container provisioning, default-on sync and the immediate toggle, schema-change rules, asset behavior, and physical-device acceptance. Default entitlements are empty. Native mirroring requires a new CloudKit container, Push Notifications provisioning, and deployment of the generated CloudKit schema.

## Dataset and account checks

The portable suites cover AI hardware policy, campground identities, Camp Finder places, and the document cipher. Device acceptance must cover iCloud identity changes, sync toggling during transfers, Erase all data, offline trip camera capture, and Camp Finder (the campground-only map and tapping places, Near me with location allowed and denied, text search, Search this area, the place card, Website/Call/Directions, offline and retry, the throttling message). See account-and-offline-contract.md for limits.
