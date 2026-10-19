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

The script runs the `CampCore` tests, parses the Xcode OpenStep project property list with Foundation, parses every native Swift file, validates plist and JSON syntax, checks rig catalog IDs/types/provenance fields, and checks project and shared-scheme references. `swiftc -frontend -parse` only checks syntax; it does **not** resolve SwiftUI, UIKit, Foundation Models, WeatherKit, or other Apple SDK APIs and does not prove the native app compiles.

On a Mac with the required SDK:

```sh
./scripts/check.sh --native
```

This also lints the project with Apple's `plutil` and runs an unsigned simulator build with `xcodebuild`. Derived data is written to `.derivedData/`. The shared scheme runs the app; core unit tests are run separately with `swift test`, rather than pretending an empty scheme test action exercises them.

## Validation completed in the development environment

The Foundation-only package compiled under Swift 6.0.3 on Linux, and all 17 XCTest cases passed. They verify persistence across a fresh store instance, profile/trip/photo metadata retention, independent checklist snapshots, completed/skipped state, rig filtering, invalid dates and coordinates, migration of the version-zero archive, rejection of future schemas, preservation of corrupt archives, failed-save preservation, invalid media references, filesystem error propagation, catalog decoding, unknown campground attributes, separate trailer/motorhome length limits, rig context snapshots, and destination forecast dates across time zones and daylight-saving transitions.

Native simulator/device compilation and runtime behavior have **not** been validated in this Linux environment. An iOS 27 SDK was not available here. The project intentionally retains the requested iOS 27 deployment target rather than presenting a lower-target build as an iOS 27 result.

## Airplane-mode acceptance pass

1. Complete onboarding without an account, including an emoji or a photo already stored on the device.
2. Plan a trip, inspect both checklists, change their order, complete a step, skip a step, and add a custom step.
3. Create a second trip; confirm it has fresh progress and that editing it does not change the first trip.
4. Save a site number, rating, notes, and locally available photos. Force-quit and relaunch in airplane mode, then check everything again.
5. Change reusable checklist defaults and create another trip. Confirm the new trip uses the changed defaults and previous trips retain their snapshots.
6. Test app relaunch and save retry after simulated disk-write failures. The app must surface the failure instead of claiming changes are durable.
7. Check large text, VoiceOver, reduced motion/transparency, light/dark mode, rotation, and iPad split view. Check list controls remain usable outdoors and with long campground names.
8. Check supported and unsupported on-device AI states, and cached weather timestamps when offline. A network request must never block checklist editing.

Cloud sync is not established by local persistence tests. Validate multi-device conflicts, account changes, asset upload interruption, and background delivery only after the sync integration is implemented and configured.

## Apple capability configuration

The default `Camp.entitlements` is an empty dictionary, and no permissions are requested unnecessarily. System `PhotosPicker` grants access to selected items without requesting unrestricted Photo Library access. There is no camera or user-location permission because this scaffold does not use either.

`PrivacyInfo.xcprivacy` declares app-local UserDefaults access for saved campground IDs (reason CA92.1), no tracking, and no collected data for this local build. Reassess the manifest and App Store privacy disclosures when backend identity, online AI, telemetry, or other collection is introduced.

Add capabilities through Xcode only when their corresponding integration is ready and your Apple Developer identifiers/profiles are configured. Entitlement examples below describe the eventual additions; they are **not** enabled in the development target:

```xml
<!-- WeatherKit: enable for the registered App ID. -->
<key>com.apple.developer.weatherkit</key>
<true/>

<!-- Sign in with Apple: enable after implementing identity/session handling. -->
<key>com.apple.developer.applesignin</key>
<array><string>Default</string></array>

<!-- CloudKit: replace the example container with your provisioned container. -->
<key>com.apple.developer.icloud-container-identifiers</key>
<array><string>iCloud.com.yourcompany.Camp</string></array>
<key>com.apple.developer.icloud-services</key>
<array><string>CloudKit</string></array>
```

CloudKit subscription delivery also needs the appropriate Push Notifications capability and the `remote-notification` background mode if your sync design uses silent pushes; allow Xcode to generate the environment-specific push entitlement. Enabling CloudKit alone does not implement syncing or conflict handling. Sign in with Apple and iCloud are separate identities and must not gate access to local trips. Foundation Models availability must be checked at runtime; an empty entitlements file cannot make an unsupported device eligible.
