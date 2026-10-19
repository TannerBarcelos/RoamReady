# RoamReady

A native SwiftUI iOS app following the approved **A · System-first** design: system lists, clear checklist progress, four native tabs, semantic colors, and automatic light/dark appearance. The app deployment target is **iOS 27.0**. Standard SwiftUI navigation and tab controls provide the system's Liquid Glass styling.

**Current milestone: SQLite persistence, recoverable archive migration, and optional CloudKit synchronization are implemented in source.** Portable behavior is tested on Linux; Apple CI compiles Core Data/CloudKit, runs SQLite integration tests, and builds the native app with its installed SDK. The current runner uses iOS 26.5 with a temporary deployment override; iOS 27 and physical-device acceptance remain outstanding. This repository is an initial development build; production services and data acquisition remain outstanding.

## Run

1. Open `RoamReady.xcodeproj` on a Mac with the iOS 27 SDK.
2. Select the shared **RoamReady** scheme and an iOS 27 simulator.
3. Build and run. On a physical device, choose your development team and replace `com.example.RoamReady` with your registered bundle identifier.

There are no third-party app dependencies. The Xcode project references the local `CampCore` Swift package. XcodeGen is optional; the checked-in project opens directly. See [build and validation instructions](docs/validation.md).

## Implemented in this iteration

| Area | Behavior |
| --- | --- |
| Onboarding | Rig category; searchable sourced catalog; manual make/model/year/floorplan; equipment confirmation; local photo or emoji; optional name and experience. No account required. |
| Home | Featured trip, checklist progress, trip memories, local save status, and quick trip creation. |
| Plan | Create, edit, and delete trips; date validation; optional site number; known destination location; upcoming and past lists. |
| Checklists | Every trip receives independent setup/teardown snapshots. Complete, uncheck, skip, add, rename, annotate, delete, and reorder steps. Save a trip's lists as reusable defaults or edit defaults from Profile. |
| Memories | Local photo import, bounded image resizing, captions, sharing, site number, site notes, and a return/avoid rating. Previous memories appear in the matching campground detail. |
| Camp Finder | Native MapKit map when connected; offline search of the bundled starter directory; saved campgrounds; combined equipment, hookup, amenity, length, and budget filters. Unknown data never silently satisfies a requirement. |
| Profile | Edit profile/rig, manage templates, restore curated defaults, view storage status, and export metadata JSON. Cosmetic rig changes preserve customized defaults. |
| Weather | WeatherKit request and local forecast cache, download timestamp, partial-window handling, and provider attribution. Can appear during planning or inside a trip. Live access requires a provisioned WeatherKit capability. |
| Camping help | Bundled checklist guidance always works offline. On-device Foundation Models explains relevant saved guidance when available. Runtime availability checks and non-generative fallback are included. No model picker. |
| Durability | Core Data SQLite/WAL transactions; individual records and field changes; recoverable legacy import; Apple-managed CloudKit mirroring; retained soft deletions; note history; explicit JSON export. |

Each new trip preserves its original rig context. Planning dates retain their original time zone; forecast matching uses the campground's time zone, including daylight-saving transitions.

## Data coverage

The included rig catalog is a **verified starter**, not the finished comprehensive catalog: **82 records, three makes, model year 2025**, with primary-source provenance. Seven ambiguous records were quarantined during independent audit. Missing rigs, car campers, and tents can complete onboarding manually offline. Official brochure imagery is not included because redistribution rights have not been acquired.

The Camp Finder starter directory contains **three real US campgrounds**: Upper Pines, Watchman, and Blackwoods. Names, coordinates, and documented amenities are sourced from NPS/Recreation.gov. Rates and unverified properties remain unknown. These are campground-level facts, not guarantees about an individual site or current booking availability. All records are bundled and searchable without a connection. Map tiles and linked booking/operator pages need connectivity.

Read the [full catalog sourcing report](docs/catalog-sourcing.md) for manufacturer archives, historical gaps, J.D. Power/Black Book/RVUSA acquisition leads, image rights, offline licensing requirements, and the production ingestion process. [Campground source notes](docs/campground-sourcing.md) document the smaller Finder dataset.

Checklist wording is original, with the [Camping World setup and teardown article](https://blog.campingworld.com/learn-to-rv/rv-setup-checklist/) as a background reference. It is not a licensed reproduction of their full article or an endorsement. Equipment-specific ordering and procedures remain subject to the rig manufacturer's manuals.

## Remaining integrations

- **iCloud/CloudKit provisioning and acceptance:** automatic private CloudKit mirroring is implemented behind configuration and explicit opt-in (applied on next launch). The default build is local-only. Register/provision a new dedicated Apple container, deploy its schema, and pass two-device, account-change, interrupted-transfer, and quota tests before shipping cloud sync. See [storage architecture and setup](docs/offline-storage.md).
- **Sign in with Apple:** not implemented. Initial online sign-in, verified backend identity exchange, secure session storage, account deletion, and recovery must be added without gating local trip access. Sign in with Apple and the device's iCloud account are separate identities.
- **Online AI:** not implemented. Add one automatically selected hosted-model route through an authenticated, rate-limited backend. No provider secret may ship in the app. Measure quality, latency, and cost before selecting the provider. Disclose when a question leaves the device.
- **Production campground finder:** licensed structured coverage, updates, regional downloads, and any live booking availability are outstanding. Offline map regions require their own supported implementation and rights.
- **Comprehensive rigs and official images:** acquisition/licensing, normalized year/model/floorplan coverage, independent review, and update ownership are required. The sourcing report prepares this work; no vendor has been contacted or contracted.
- **Release validation:** iOS 27 build/runtime acceptance, real-device Foundation Models behavior, WeatherKit entitlement/attribution verification, accessibility and large-text checks, photos/iCloud Photos edge cases, and full airplane-mode acceptance pass.

The default entitlements request no unconfigured account, cloud, or weather services. [Validation notes](docs/validation.md#apple-capability-configuration) explain the future Apple capability setup. Enabling an entitlement alone does not implement its service.

## Checks

```sh
./scripts/check.sh
```

Runs the Swift core tests, catalog/provenance validator, plist/JSON and Xcode project checks, and syntax parsing of native Swift files. Syntax parsing does **not** type-check Apple SDK APIs. Set `SWIFT_BIN=/path/to/swift` if necessary.

On a Mac with the iOS 27 SDK:

```sh
./scripts/check.sh --native
```

The portable core suite currently has **22 tests**; Apple-only SQLite persistence tests additionally run on macOS. The core tests cover save/reopen, trip snapshot isolation, rig filtering, invalid dates/coordinates, archive corruption/future versions/migration, photo path safety, campground unknown-value and length filtering, rig snapshots, and cross-time-zone/DST forecast dates.

## Source layout

- `Camp/`: native SwiftUI screens, photo storage, WeatherKit and Foundation Models adapters, and bundled data.
- `Sources/CampCore/`: portable Foundation-only domain, original checklist templates, filters, date rules, and atomic archive store.
- `Sources/CampPersistence/`: native SQLite transactions, legacy migration, media assets, durable sync queue, and private CloudKit transport.
- `Tests/CampCoreTests/` and `Tests/CampPersistenceTests/`: domain/merge tests and Apple-only persistence integration tests.
- `docs/`: acquisition research, build instructions, source coverage, and integration plan.
- `scripts/`: repeatable validation.

The app now uses Core Data with SQLite. The original `camp-state.json` is an import/recovery format, not the live store. A one-time, verified transaction imports it and leaves the source file intact. SQLite holds individual trips, checklist steps, photos, rigs, favorites, note versions, and sync metadata. Local saves never require a network or account. See [offline storage and sync](docs/offline-storage.md) for conflict rules, setup, limitations, and release gates.

Photos are resized on import (maximum 2560 pixels), stored as local JPEGs, and displayed using bounded thumbnails. Photo bytes also enter an externally stored database asset in the same transaction as the trip reference, allowing optional CKAsset transfer and local cache repair. JSON export includes metadata and photo references, not image bytes. Removing photos/trips records permanent tombstones; automatic purging of unreferenced photo bytes is intentionally deferred until a tested retention policy exists. Original photos remain in the user's photo library.
