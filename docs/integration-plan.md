# Remaining production integrations

## Account-free, offline trips

There are no accounts; first launch and onboarding work offline, and local SwiftData saves never wait for cloud delivery. Camp Finder and fresh weather need connectivity. Camera capture, imported photos, checklist edits, site notes, ratings, and manual trip creation from known details remain local. See [account/offline contract](account-and-offline-contract.md).

There is no sign-in and no server account/session service. Profile › Erase all data deletes the CloudKit zone and everything on the device (see [erasing data](erase-data.md)). Multiple libraries per device are not planned.

## Managed iCloud

`NSPersistentCloudKitContainer` owns SQLite, private CloudKit mirroring, retries, history, and external binary transfers. There is no raw SQLite usage or custom record transport. Provision a new dedicated cloud container and deploy its generated schema. The first sync pins the device iCloud identity automatically; unavailable or mismatched identity leaves local trip access intact.

Two-device/account/attachment acceptance and actual iOS 27 runtime remain required. See [storage architecture](offline-storage.md).

## Apple Foundation Models only

v1 has no hosted AI. The only generative route is Apple's on-device Foundation Models, gated to iPhone 15 or newer product eligibility and Apple's independent runtime availability (Apple Intelligence itself requires iPhone 15 Pro or later). Remote models with a model selector are planned for v2 (#34). Saved checklist guidance remains the fallback. No provider/model choice or remote question transfer is exposed. Initial Apple model download/readiness is an online prerequisite.

## Camp Finder (Apple Maps)

Camp Finder is online-only discovery with Apple Maps (MapKit): a campground-only map, Near me, Search this area, and text search, with no server, key, or cost. Saved lists keep Apple's place identifiers only. See [Camp Finder data source](campground-sourcing.md). Outstanding: coverage and device acceptance (#10). Offline maps and region-limited offline lists are v2 (#20).

## Rig catalog

Post-v1 (#29). v1 uses owner-entered rig details (required year, make, model, and length for RVs). A lookup needs a licensed or permitted source with per-record provenance; no guessed year ranges or floorplans in onboarding.

## Native release gate

Provision real Apple identifiers and test on iPhone. Run iOS 27 build/runtime, airplane-mode return access, multi-device cloud transfers, iCloud account changes and Erase all data, camera permissions, large datasets, VoiceOver, Dynamic Type, reduced transparency/motion, WeatherKit attribution, storage exhaustion, and Foundation Models eligibility. Portable tests and iOS 27 simulator builds do not establish device or production readiness.
