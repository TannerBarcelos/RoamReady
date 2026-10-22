# Build and validation

## Open the native project

Open `RoamReady.xcodeproj` in an Xcode release containing the **iOS 27 SDK**. Select the shared **RoamReady** scheme and an iOS 27 simulator, then Run. The app targets iPhone and iPad, portrait and landscape, with automatic system light/dark appearance. The local `CampCore` Swift package resolves from this repository; there are no third-party package downloads.

The checked-in project is an actual Xcode project, using filesystem-synchronized source groups supported by Xcode 16 and later. New Swift files and bundled JSON beneath `Camp/` join the target automatically. `Info.plist` and `Camp.entitlements` are explicitly excluded from resource copying. `project.yml` is an optional XcodeGen regeneration specification; XcodeGen is not required to open or build the project.

Swift language mode is 6.0 with strict concurrency. Default MainActor inference is deliberately not enabled: isolation belongs on the app's state-owning declarations. `CampCore` is a Foundation-only package with a lower platform floor so its tests also run on Linux and macOS; the app's deployment target remains iOS 27.0.

For a physical device, change the placeholder `com.example.RoamReady` identifier to your own unique bundle identifier and select your development team under Signing & Capabilities. Simulator builds need no development team. A production App Store archive additionally needs your app icon, distribution signing, privacy disclosures, and configured services. No icon assets have been fabricated for this development scaffold.

## Repeatable checks

```sh
cd Camp
./scripts/check.sh
```

Requirements: Swift 6+, Bash, and Python 3. If Swift is not on PATH, use `SWIFT_BIN=/absolute/path/to/swift ./scripts/check.sh`.

The script runs the `CampCore` tests, parses the Xcode OpenStep project property list with Foundation, parses every native Swift file, validates plist and JSON syntax, validates the research rig catalog in `data/catalog/` and confirms no rig catalog is bundled in the app, and checks project and shared-scheme references. `swiftc -frontend -parse` only checks syntax; it does **not** resolve SwiftUI, UIKit, Foundation Models, WeatherKit, or other Apple SDK APIs and does not prove the native app compiles.

On a Mac with the required SDK:

```sh
./scripts/check.sh --native
```

This also lints the project with Apple's `plutil` and runs an unsigned simulator build with `xcodebuild`. Derived data is written to `.derivedData/`. The shared scheme runs the app; core unit tests are run separately with `swift test`, rather than pretending an empty scheme test action exercises them.

## Validation completed in the development environment

The portable Swift suite runs in Swift 6 on Linux. Apple CI also compiles the actual Core Data/CloudKit package and runs SQLite integration tests on macOS. The portable suite is supplemented by Apple-only managed-store tests, including model compatibility, partial-import/reopen recovery, JSON and SQLite migration, managed asset persistence, logical duplicate reconciliation, and note history.

Apple CI has completed an unsigned arm64/x86_64 simulator build with Xcode 26.6 and the available iOS 26.5 SDK, using a temporary deployment override. This verifies native API compilation, not iOS 27 acceptance or physical-device runtime behavior. The product project retains its requested iOS 27 deployment target. See the [latest workflow results](https://github.com/TannerBarcelos/RoamReady/actions/workflows/apple-validation.yml) for the exact commit and outcome.

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

The default `Camp.entitlements` declares no capabilities; the app has no accounts. System PhotosPicker grants selected-item access without unrestricted Photo Library permission. NSCameraUsageDescription supports on-device trip photo capture. User location is not requested.

`PrivacyInfo.xcprivacy` declares app-local UserDefaults access for legacy saved-campground import (reason CA92.1), no tracking, and no collected data for this local build. Reassess the manifest and App Store privacy disclosures for the public campground snapshot host, optional CloudKit, WeatherKit, and any future backend or telemetry. There is no remote AI.

Add capabilities through Xcode only when their corresponding integration is ready and your Apple Developer identifiers/profiles are configured. Optional weather/cloud examples require provisioning:

```xml
<!-- WeatherKit: enable for the registered App ID. -->
<key>com.apple.developer.weatherkit</key>
<true/>

<!-- CloudKit: replace the example container with your provisioned container. -->
<key>com.apple.developer.icloud-container-identifiers</key>
<array><string>iCloud.com.yourcompany.RoamReady</string></array>
<key>com.apple.developer.icloud-services</key>
<array><string>CloudKit</string></array>
```

CloudKit subscription delivery also needs the appropriate Push Notifications capability and the `remote-notification` background mode if your sync design uses silent pushes; allow Xcode to generate the environment-specific push entitlement. Enabling CloudKit alone does not implement syncing or conflict handling. There are no app accounts; onboarding and trips must work offline. Foundation Models availability must be checked at runtime; an empty entitlements file cannot make an unsupported device eligible.

## Core Data and automatic CloudKit mirroring

Core Data manages the local SQLite store; no raw SQL or SQLite driver is used. `NSPersistentCloudKitContainer` manages cloud transfers and external binary assets. The former custom CloudKit transport has been removed.

See [offline-storage.md](offline-storage.md) for new-container provisioning, default-on sync and the immediate toggle, migration, asset behavior, and physical-device acceptance. Default entitlements are empty. Native mirroring requires a new CloudKit container, Push Notifications provisioning, and deployment of Core Data's generated schema.

## Dataset and account checks

`check.sh` also verifies the public campground snapshot hashes/counts/shards and runs importer fixture tests. CampCore covers AI hardware policy, site unknown-length semantics, sharding, and the future provider-proxy contract. Device acceptance must cover account teardown races, unsaved edits during revocation, same-owner recovery, iCloud identity changes, offline trip camera capture, and public directory/site downloads. See account-and-offline-contract.md for limits.
