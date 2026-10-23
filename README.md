# RoamReady

A native SwiftUI iOS app following the approved **A · System-first** design: system lists, clear checklist progress, four native tabs, semantic colors, and automatic light/dark appearance. The app deployment target is **iOS 27.0**. Standard SwiftUI navigation and tab controls provide the system's Liquid Glass styling.

**Current milestone: account-free onboarding with owner-entered rig details, offline trip workflows, Apple-only AI eligibility, and federal campground/site discovery are implemented in source.** Portable behavior is tested on Linux; Apple CI compiles the SwiftData library, runs its tests against real stores, and builds the native app with Xcode 27 and the iOS 27 SDK at the iOS 27 deployment target. Physical-device acceptance remains outstanding. This repository is an initial development build; production services and data acquisition remain outstanding.

## Run

1. Open `RoamReady.xcodeproj` on a Mac with the iOS 27 SDK.
2. Select the shared **RoamReady** scheme and an iOS 27 simulator.
3. Build and run. On a physical device, choose your development team and replace `com.example.RoamReady` with your registered bundle identifier.

There are no third-party dependencies. The Xcode project references the local `CampCore` Swift package; its only external package is Apple's [swift-crypto](https://github.com/apple/swift-crypto), linked on Linux only so CryptoKit-based code is tested there too. See [build and validation instructions](docs/validation.md).

## Implemented in this iteration

| Area | Behavior |
| --- | --- |
| Onboarding | Rig category; for RVs, required year, make, model, and length, plus optional slide-out count (Not specified / None / 1–8), axles (towables), bunkhouse, and floorplan; equipment confirmation; rig photo or emoji; optional name and experience. No account or connection needed. |
| Home | Featured trip, checklist progress, trip memories, local save status, and quick trip creation. |
| Trips | **A trip is a booking** at one campground. Add it from a Camp Finder listing or by name (offline). Required: campground, rig (picker), dates. Optional, editable any time: site and loop; site details (parking, length limit, electric, water, sewer), entered by the owner because campground listings don't include them, with a warning when the rig is longer than the site; first site notes when adding the trip (more notes and photos later in Photos & site notes); confirmation number, provider, `https` manage-booking link, check-in/out in the campground's time zone, cost and amount paid, cancellation deadline, confirmation files. Booking card with Open booking link, View confirmation, and Directions. Cancel = delete, with an explicit confirmation of everything that is permanently deleted and what is kept. Upcoming and past lists. |
| Checklists | Each rig has default setup/teardown lists; a new trip gets fresh copies of its rig's defaults and is independent after that. Complete, uncheck, skip, add, rename, annotate, delete, and reorder steps. "Save as defaults for <rig>" (confirmed) writes a trip's lists to its rig only. |
| Documents | Rig manuals, registration, insurance, warranties, and trip reservations as PDF/image uploads or HTTPS links, from onboarding or later. Titles, categories, notes, issue/expiration dates; Quick Look preview, sharing, and confirmed deletion. Users choose each document's type; registration, insurance, and reservations are always end-to-end encrypted (others can opt in). Files up to 50 MB are stored byte-for-byte and verified by SHA-256 on every read; Profile exports a zip with all documents. Uploaded originals are preserved byte-for-byte and open offline; links stay online-only until a copy is saved. See [document vault](docs/document-vault.md). |
| Memories | Offline native camera capture and local photo import, bounded image resizing, captions, sharing, site number, site notes, and a return/avoid rating. Previous memories appear in the matching campground detail. |
| Camp Finder | Online-gated native MapKit map and federal campground/site snapshot downloads; saved campgrounds; combined equipment, hookup, amenity, length, and budget filters. Unknown data never silently satisfies a requirement. |
| Profile | Edit profile and rig offline. One active rig per owner (`RigPolicy.maxActiveRigs`); Replace rig archives the current one, which stays on past trips; archived rigs can be reactivated (within the limit) or deleted when unused. Per-rig default checklists and reset. Storage status and export. |
| Weather | The temperature where you are, at the top right of Home: asks for location only when tapped, approximate by default, and shows the last reading offline. Each trip with a campground location also shows a per-day forecast, saved for offline use with its download time. Apple Weather attribution on both. Live data requires a provisioned WeatherKit capability. |
| Camping help | Bundled checklist guidance always works offline. Apple Foundation Models explains relevant saved guidance on iPhone 15 or newer, on device only, offline and online. Apple Intelligence itself requires iPhone 15 Pro or later, so the base iPhone 15 and 15 Plus get saved guidance with an explanation. Every runtime unavailability reason is explained and falls back to saved guidance. No hosted AI or model picker in v1; remote models are planned for v2 (#34). |
| Durability | SwiftData (SQLite) store; Apple-managed private CloudKit mirroring; cascading deletes; note history; explicit zip export including documents. |

Each trip references its rig, so rig edits show on every trip that uses it; replacing a rig archives the old one so past trips keep it. Planning dates retain their original time zone; forecast matching uses the campground's time zone, including daylight-saving transitions.

## Data coverage

**Rigs are entered by their owners in v1.** The app does not ship or query a rig catalog. RV makes, models, years, and floorplans number in the tens of thousands, and no investigated free source covers them, so a partial picker would mostly send people to manual entry anyway. Owner-entered details are stored as SwiftData `Rig` models, and trips relate to their rig. Older profiles saved without a length still open; the next profile edit asks for the missing required fields. Camp Finder's "Use my rig" fills the minimum site length from the rig's length.

The online Camp Finder downloads a dated federal snapshot containing **5,260 campgrounds and 111,647 overnight sites**. Facts come from RIDB's public daily export. Site details include loops, equipment/length limits and selected factual attributes where published. This is federal coverage, not every campground or live booking availability. Development snapshot hosting uses this public repository; production CDN/refresh ownership remains to be configured. The bundled three-campground starter remains an explicitly labeled network-error fallback.

Checklist wording is original, with the [Camping World setup and teardown article](https://blog.campingworld.com/learn-to-rv/rv-setup-checklist/) as a background reference. It is not a licensed reproduction of their full article or an endorsement. Equipment-specific ordering and procedures remain subject to the rig manufacturer's manuals.

## Remaining integrations

- **iCloud/CloudKit provisioning and acceptance:** automatic private CloudKit mirroring is implemented behind configuration and is **on by default** once a container is configured. The first sync binds the library to the signed-in iCloud account without a prompt; a different account never syncs into it. A "Sync with iCloud" toggle in onboarding and Profile turns it off or on immediately (no restart); turning it off deletes nothing locally or in iCloud. The default build has no container and stays local-only. Register/provision a new dedicated Apple container, deploy its schema, and pass two-device, account-change, interrupted-transfer, and quota tests before shipping cloud sync. See [storage architecture and setup](docs/offline-storage.md).
- **No accounts in v1:** there is no sign-up or Sign in with Apple; the library belongs to the device and the person's iCloud. Profile › Erase all data deletes the iCloud copy and everything on the device. See [identity contract](docs/account-and-offline-contract.md) and [erasing data](docs/erase-data.md).
- **AI device acceptance:** Apple Foundation Models is the only generative provider. The product gate admits iPhone 15 or newer (`iPhone15,4`, `iPhone15,5`, and `iPhone16,*` and later; the iPhone 14 Pro's `iPhone15,2`/`15,3` are excluded), and Apple's runtime availability is checked separately. Apple Intelligence requires iPhone 15 Pro or later. Test the base iPhone 15 explanation, disabled/not-ready model states, supported language/region behavior, and saved-guidance fallback on devices. Remote models are planned for v2 (#34), not v1.
- **Production campground finder:** a real federal snapshot and individual-site browsing are implemented; broader private/state/local coverage, production snapshot hosting/refreshes, and any live booking availability remain outstanding. Offline maps are not implemented.
- **Rig catalog lookup (deferred, #21):** v1 uses owner entry. A future lookup needs a licensed or permitted data source. The earlier source research lives in git history (removed in this cleanup).
- **Release validation:** iOS 27 build/runtime acceptance, real-device Foundation Models behavior, WeatherKit entitlement/attribution verification, accessibility and large-text checks, photos/iCloud Photos edge cases, and full airplane-mode acceptance pass.

The default build declares no entitlements; cloud and weather are separately configured. [Validation notes](docs/validation.md#apple-capability-configuration) explain the future Apple capability setup. Enabling an entitlement alone does not implement its service.

## Checks

```sh
./scripts/check.sh
```

Runs the Swift tests, campground snapshot validator and importer tests, plist/JSON and Xcode project checks, and syntax parsing of native Swift files. Syntax parsing does **not** type-check Apple SDK APIs. Set `SWIFT_BIN=/path/to/swift` if necessary.

On a Mac with the iOS 27 SDK:

```sh
./scripts/check.sh --native
```

The portable suites (`CampCore`, `Campgrounds`, `DocumentVault`) have **52 tests** and run on Linux and macOS. They cover rig policy and required details, trip dates and booking validation, site details, checklist generation, campground unknown-value and length filtering, site shards, document type detection, validation and link rules, SHA-256 and AES-GCM sealing, default-on iCloud sync and account pinning decisions, and cross-time-zone/DST forecast dates. The SwiftData suite (`CampPersistenceTests`, 20 tests) runs on macOS against real stores: rigs and defaults, trips and their checklists, deletes and cascades, note versions, completion and campground lists, the document vault, reopening from disk, and the export.

## Source layout

Swift package modules (`Package.swift`), each with its own test target:

| Module | Depends on | Contents |
| --- | --- | --- |
| `CampCore` | Foundation | The shared rig and trip rules (`RigDetails`, `TripDetails`) and the drafts forms edit, bookings and site details, checklist templates, campground lists, AI device policy, iCloud sync policy. |
| `Campgrounds` | `CampCore` | Federal campground snapshot, campsite shards, and filters. |
| `DocumentVault` | CryptoKit (swift-crypto on Linux) | Document types and import policy, SHA-256 digests, and AES-GCM sealing. |
| `CampPersistence` | `CampCore`, `DocumentVault` | The SwiftData models, `LibraryStore` (container and CloudKit mirroring), the library rules as model extensions, the document vault, and the zip export (Apple-only). |

The app (`Camp/`) is organized by feature:

- `App/`: entry point, root view and tabs, and `LibraryController`, which owns the model container, saving, sync status, and erase. Screens read with `@Query`.
- `Features/<Feature>/`: `Home`, `Trips`, `Checklists`, `CampFinder`, `Documents`, `Memories`, `Profile`, `Onboarding`, `Weather`, `Assistant`, and `Sync`, each holding its views and its service (WeatherKit, Foundation Models, MapKit directory, camera and photos, CloudKit sync and erase).
- `Shared/`: connectivity gate and small shared views.
- `Resources/`: the bundled starter campground directory.

Other folders: `docs/` (acquisition research, build instructions, source coverage, integration plan), `scripts/` (repeatable validation and the RIDB importer), `data/` (the published campground snapshot).

The app stores its library with SwiftData: profile, rigs, trips, checklist steps, photos, note versions, saved campgrounds, and documents are models with relationships. Local saves never require a network or account. See [offline storage and sync](docs/offline-storage.md) for the models, conflicts, setup, and release gates.

Photos are resized on import (maximum 2560 pixels) and stored in their rig or trip with external storage, so they sync with it and are deleted with it. The JSON export includes metadata, not image bytes. Original photos remain in the user's photo library.
