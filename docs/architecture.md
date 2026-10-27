# Application architecture

[Documentation index](README.md) · [Design](design.md) · [Build and validation](validation.md)

## Overview

RoamReady is a native SwiftUI app with a local SwiftData library and optional Apple-managed private CloudKit mirroring. Core editing works without a network or app account. Online discovery and weather are feature services; camping AI runs on device when eligible.

The app targets iOS 27.0 on iPhone and iPad, and Mac through Mac Catalyst. The local Swift package uses Swift tools/language version 6 and lower platform floors (iOS 17/macOS 14) so shared logic can be tested independently. Those package floors do not lower the app's deployment target.

## Package boundaries

[Package.swift](../Package.swift) defines four libraries and their test targets:

| Module | Dependencies | Responsibilities |
| --- | --- | --- |
| `CampCore` | Foundation | Shared rig/trip rules and form drafts, booking/site validation, checklist templates, campground lists, Assistant availability and request preparation, and campground identities. |
| `Campgrounds` | `CampCore` | Apple Maps place model, website/phone links, cleaned search text, and result merging. |
| `DocumentVault` | CryptoKit | Document types/import policy, bounded temporary files, SHA-256 integrity, and read-only legacy AES-GCM decoding. |
| `CampPersistence` | `CampCore`, `DocumentVault` | SwiftData models, `LibraryStore`, `ICloudSettings` (preference and passive activity), model-level library operations, document storage, and zip export; implementation requires SwiftData on Apple platforms. |

The native app links these local products and Apple frameworks. There are no external package dependencies.

## Source layout

| Path | Contents |
| --- | --- |
| [Camp/App/](../Camp/App/) | Entry point, root view, tabs, and `LibraryController`, which opens the container, surfaces save failures, and handles explicit erase. |
| [Camp/Features/](../Camp/Features/) | Feature views and services for Home, Trips, Checklists, CampFinder, Documents, Memories, Profile (including iCloud settings), Onboarding, Weather, and Assistant. |
| [Camp/Shared/](../Camp/Shared/) | Connectivity gate and small shared views. |
| [Sources/](../Sources/) | Swift package modules. |
| [Tests/](../Tests/) | One test target per package module. |
| [RoamReady.xcodeproj/](../RoamReady.xcodeproj/) | Native app project and shared RoamReady scheme. |
| [Config/](../Config/) | Optional signed-build capability configuration. |
| [.github/workflows/](../.github/workflows/) | `app.yml`: simulator builds and UI tests on iPhone and iPad (a device matrix); the iPhone job adds configuration checks and a Release build. `mac.yml`: package tests and Debug/Release Mac Catalyst builds on macOS. |
| [docs/](./) | Product, design, engineering, validation, and planning guides. |

The Xcode project uses filesystem-synchronized groups: new source files under `Camp/` join the app target automatically. `Info.plist` and entitlements are excluded from resource copying.

## State and data flow

1. `RoamReadyApp` creates `LibraryController` and connectivity state, then opens the library.
2. The library exposes a SwiftData model container. If opening fails, the root shows an error and retry.
3. `RootView` queries for a profile, displaying onboarding or the five tabs; on supported AI devices Home and Plan add an Assistant toolbar button.
4. Screens read models with `@Query`. Forms edit drafts such as `TripDraft`, `RigDraft`, and `ChecklistStepDraft`, then validate and apply them.
5. Model extensions enforce library rules. `LibraryController.save()` performs deliberate saves and surfaces failures; scene transitions also trigger saving.
6. If configured and enabled at launch, Apple mirrors the library to the device's private CloudKit database and manages connectivity, retries, and account transitions.

There is no raw SQL, custom CloudKit record transport, hosted user-data service, or app account/session backend. See [storage and synchronization](offline-storage.md) for model relationships, schema constraints, conflict behavior, and identity transitions.

The device-local appearance preference is stored through `AppAppearance`/`@AppStorage` and applied at the window root. System follows the OS; Light/Dark overrides also apply to navigation and sheets.

## Domain rules

A trip is one campground booking and references its rig. Editing a rig changes the details shown on all related trips; replacing it archives the old rig. New trips copy the rig's default setup/teardown steps, then own their checklist copies independently.

Rig and trip validation is shared through `RigDetails` and `TripDetails` protocols implemented by both drafts and persisted models. Portable tests exercise those rules without SwiftUI or SwiftData.

Deleting a trip cascades to its steps, photos, and note revisions. Documents are retained as unattached. A rig can be deleted only when unused by trips. See [feature behavior](features.md) and [erasing data](erase-data.md).

## Feature services and network boundaries

| Service | Integration and boundary |
| --- | --- |
| Camp Finder | MapKit campground/RV park points of interest, typed/area searches, and place lookups. Session-only results; saved lists keep Apple identifiers. No server, API key, owned dataset, or live availability. |
| Weather | WeatherKit for location temperature and campground forecasts; saved readings have timestamps and work offline. |
| Camping assistant | Bundled guidance plus Foundation Models after product/device and runtime availability checks. No remote question transfer in v1. |
| Memories | Native camera, PhotosPicker, bounded image import, and system sharing. Cloud-only Photos items may need a download. |
| Documents | System file representations, bounded staging, Quick Look, HTTPS links, verified bytes, and Apple-managed encryption. |
| Sync | SwiftData/CloudKit mirroring, enabled by configuration and a default-on launch preference. Apple owns its runtime lifecycle. |

Connectivity indicates an available path, not successful service authorization or delivery. Local edits never wait for cloud transfer. Capability provisioning, real service reachability, and device behavior are separate acceptance concerns.

## Media and exports

Rig/trip photos are downsampled from picker file representations to at most 2560 pixels and stored as JPEG data using SwiftData external storage and cloud-encrypted fields. They travel with their model through mirroring and are deleted with it. Original imported photos remain in the photo library.

Documents preserve original bytes up to 50 MiB. Content is separate from list metadata and uses SwiftData external storage plus cloud-encrypted fields. Apple handles large-asset encryption and transfer; there are no new app encryption keys. Legacy encrypted files remain readable, and reads verify size and SHA-256. Import inspection and preview verification run off the UI thread. See [document vault](document-vault.md).

Profile exports `RoamReady Export.zip`: `library.json`, `documents.json`, and verified original files under `Documents/`. Photo metadata/captions are included, not image bytes; photos are shared individually. Exported encrypted documents are readable originals. The export is an explicit user copy, not an implemented restore/import workflow.

## Validation boundaries

Portable tests cover shared policies, validation, place identities, search-result merging, and document integrity/crypto. Apple-platform tests exercise real SwiftData stores. A native simulator build checks Apple SDK compilation; physical devices are still needed for permissions, model availability, iCloud account/asset behavior, accessibility, and release acceptance. See [build and validation](validation.md).
