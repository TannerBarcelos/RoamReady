# RoamReady

A native SwiftUI app for iPhone, iPad, and Mac (Catalyst) for planning camping trips. It keeps rigs, setup and teardown checklists, bookings, documents, and trip photos together. It works offline with no account. Data lives in SwiftData, mirrored to the user's private iCloud database when that's configured. There are no external package dependencies and no backend. The one deliberate third-party code is a vendored, pinned C library, `sqlite-vec` (MIT/Apache-2.0), for document search; see [Sources/CSQLiteVec/PROVENANCE.md](Sources/CSQLiteVec/PROVENANCE.md).

## Commands

Run everything from the repository root. You need Xcode 27 with the iOS 27 SDK. The working simulator is **iPhone 18 Pro (iOS 27.0)**.

```bash
# Package tests: CampCore, Campgrounds, DocumentVault, CampPersistence (SwiftData on macOS)
swift test

# Build the app for the simulator (unsigned, for local UI work)
xcodebuild -project RoamReady.xcodeproj -scheme RoamReady -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -derivedDataPath .derivedData \
  CODE_SIGNING_ALLOWED=NO build

# Install and launch the build on the booted simulator
xcrun simctl install booted .derivedData/Build/Products/Debug-iphonesimulator/RoamReady.app
xcrun simctl launch booted com.tannerdev.roamready

# UI tests (Tests/RoamReadyUITests)
xcodebuild -project RoamReady.xcodeproj -scheme RoamReady \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -derivedDataPath .derivedData test

# Lint the project and plist files
plutil -lint RoamReady.xcodeproj/project.pbxproj Camp/Info.plist Camp/Camp.entitlements Camp/PrivacyInfo.xcprivacy Config/Cloud.entitlements
```

Use the `RoamReady` scheme for the app. The other schemes (`CampCore`, `Campgrounds`, `CampPersistence`, `DocumentVault`) are the Swift packages. Simulator builds need no signing. Signed builds with real iCloud and WeatherKit use `Config/Local.xcconfig`, copied from `Config/Cloud.xcconfig.example`; it's git-ignored, so never commit it.

## Before testing in the simulator

- **A fresh install starts in onboarding.** Finish it so that a profile and a rig exist. Most screens, including the sample-trip seeder, need both.
- **To have many trips to look at,** launch with `-seed-sample-trips`. This adds seven trips to the real on-device library: five upcoming (from 4 days to about 2.5 months out) and two that ended weeks ago.
  - Seeded trips have `SAMPLE-<n>` confirmation numbers. If any trip already has one, seeding is skipped, so launching again doesn't add duplicates.
  - They sync through iCloud if the simulator is signed in. Delete them in the app when you're done.
- **The Assistant** (the sparkle button) follows Apple’s runtime eligibility, which can depend on the simulator host. Use the UI-test flags below for deterministic availability states.
- **To check Home's empty, upcoming, and current states,** look at the arrival and departure dates. Home features the trip whose dates include today, or else the next upcoming one. Completed trips appear only in Profile › Trip history.

### Debug launch arguments

These exist only in Debug builds (`#if DEBUG`).

| Argument | Effect |
| --- | --- |
| `-seed-sample-trips` | Adds sample trips to the real library ([SampleTrips.swift](Camp/App/SampleTrips.swift)) |
| `-document-search-smoke` | Runs a file-backed FTS5 + sqlite-vec lifecycle in a temp folder and logs `DOCUMENT-SEARCH-SMOKE: PASS` or `FAIL` ([DocumentSearchSmokeCheck.swift](Camp/App/DocumentSearchSmokeCheck.swift)) |
| `-navigation-ui-test` | Uses an in-memory library with fixture trips; the real library is never opened ([NavigationUITestLibrary.swift](Camp/App/NavigationUITestLibrary.swift)) |
| `-assistant-ui-test <state>` | Sets the Assistant's availability to `ready`, `disabled`, `preparing`, `unsupported`, `unavailable`, or `unsupported-language`, and skips onboarding |
| `-assistant-generation-test <reply\|failure>` | Gives the Assistant a stubbed reply or failure |
| `-assistant-device-smoke` | Skips onboarding for the Assistant smoke test on a real device |

## Where things are

| Path | What's there |
| --- | --- |
| `Camp/App/` | The app entry point (`RoamReadyApp`, `RootView`, `MainTabs`), `LibraryController` (opens and saves the SwiftData store), and the debug fixtures |
| `Camp/Features/<Feature>/` | One folder per capability: `Home`, `Trips` (new trip, trip details, plan), `Checklists`, `CampFinder` (MapKit search and saved campgrounds), `Documents`, `Memories` (photos and site notes), `Weather` (WeatherKit), `Assistant` (Foundation Models plus bundled guidance), `Profile` (rig, defaults, settings, iCloud, export, erasing data), `Onboarding` |
| `Camp/Shared/` | Shared views, appearance, connectivity, and image picking |
| `Sources/CampCore/` | Foundation-only domain rules: drafts (`TripDraft`, `RigDraft`, `ChecklistStepDraft`), validation, checklist generation, and the Assistant's availability states |
| `Sources/CampPersistence/` | The SwiftData `@Model`s (`Models.swift`), the library rules as model extensions (`Trip+Library.swift` and so on), the store and CloudKit setup, and export |
| `Sources/Campgrounds/` | Camp Finder's place model, links, and how search results are merged |
| `Sources/DocumentSearch/`, `Sources/CSQLiteVec/` | The document search index: its own disposable SQLite file with FTS5 and `sqlite-vec`, behind `DocumentSearchIndex`. `CSQLiteVec` is the vendored sqlite-vec source plus its license and provenance note; don't edit the vendored files |
| `Sources/DocumentVault/` | Document types, import rules, SHA-256, and reading older encrypted files |
| `Tests/` | One test target per package, plus `RoamReadyUITests` |
| `docs/` | Product and engineering docs. Start at [docs/README.md](docs/README.md); [architecture.md](docs/architecture.md), [features.md](docs/features.md), and [design.md](docs/design.md) matter most |

The tabs are Home, Trip (opens the new-trip sheet; it doesn't change tabs), Camp Finder, and Profile. Home features the current or next trip, followed by later trips.

## How the code works

- **Data flow:** screens read models with `@Query`. Forms edit a draft struct from `CampCore`, which is validated and then applied through a model extension in `CampPersistence`, such as `Trip.create(_:rig:in:)`. Put business rules in `CampCore` or `CampPersistence`, not in views, so `swift test` covers them.
- **The rules for a trip:** a trip is one booking that references its rig. Creating a trip copies the rig's default checklists, and after that the trip's checklists are its own. Deleting a trip also deletes its steps, photos, and note revisions; its documents are kept, unattached.
- **SwiftData models must stay CloudKit-compatible:** every attribute is optional or has a default, every relationship is optional, and there are no unique constraints. After the CloudKit schema goes to Production (#6), only add optional attributes or new models. Never rename, retype, or remove an attribute, and never change its cloud encryption.
- **Concurrency:** Swift 6 with strict concurrency. Default MainActor inference is deliberately off, so put `@MainActor` on the declarations that own state.
- **New files** under `Camp/` join the app target automatically (the project uses synchronized folders), so you don't need to edit `project.pbxproj`.
- **Test-only code** goes inside `#if DEBUG` and is turned on with a launch argument. Fixtures that must not touch the user's library use an in-memory store.
- **Style:** follow the surrounding code. Comments are sparse and explain why. User-facing text is short and plain, and the UI uses native lists, forms, and sheets (see [design.md](docs/design.md)).

## Workflow

- Branch from `main` as `feature/…`, `fix/…`, `chore/…`, `docs/…`, or `ci/…`, and merge through a PR.
- Commit subjects are short and imperative ("Add a debug-only sample-trip seeder").
- CI runs on every PR and main push. The [iOS and iPad](.github/workflows/app.yml) workflow builds the universal iOS app in Debug/Release without booting a simulator. The [Mac](.github/workflows/mac.yml) workflow runs all package tests and builds Catalyst in Debug/Release. The [UI tests](.github/workflows/ui-tests.yml) workflow is manual-only: choose iPhone or iPad when UI or release validation is needed. Do not add simulator launches back to regular CI without the owner's request.
- When behavior changes, update the matching file in `docs/` (usually `features.md`, `user-guide.md`, or `architecture.md`).
