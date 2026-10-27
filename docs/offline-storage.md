# RoamReady offline storage and synchronization

[Documentation index](README.md)

## SwiftData library

The library is a SwiftData store (`Library/RoamReady.store` in Application Support). SwiftData owns the SQLite file, external binary files, persistent history, and, in a provisioned build, private CloudKit mirroring through Apple's `NSPersistentCloudKitContainer`. The app never executes SQL, and there is no custom record transport, upload queue, change token, polling loop, or retry scheduler.

The models live in `Sources/CampPersistence/Models.swift`:

| Model | Holds | Relationships |
| --- | --- | --- |
| `CamperProfile` | name, experience | — |
| `Rig` | owner-entered details, equipment, registration (VIN, plate, region; cloud-encrypted), photo (external storage), archive date | default `ChecklistStep`s (cascade), trips, documents |
| `Trip` | campground, dates, time zones, site details, booking, completion, notes, rating | rig, `ChecklistStep`s, `TripPhoto`s, `NoteRevision`s (all cascade), documents |
| `ChecklistStep` | title, detail (guidance), notes, priority, section, status, phase, position | its trip, or its rig for default lists |
| `TripPhoto` | resized JPEG (external storage), caption | trip |
| `NoteRevision` | a saved version of a trip's notes | trip |
| `SavedCampground` | Camp Finder lists (want to go, favorite, have been); Apple Maps places keep only their identifier | — |
| `StoredDocument` | document details; text fields cloud-encrypted | rig or trip (neither = unattached), `DocumentContent` (cascade) |
| `DocumentContent` | the original file bytes (external storage and cloud encryption); legacy bytes/keys remain readable | document |

Every attribute is optional or has a default, every relationship is optional, and there are no unique constraints, as CloudKit mirroring requires. Deleting a trip cascades to its steps, photos, and note versions; its documents are kept and become unattached. A rig can be deleted only while no trip uses it.

The rules live next to the models (`Rig+Library.swift`, `Trip+Library.swift`, `SavedCampground+Library.swift`, `StoredDocument+Library.swift`): the one-active-rig limit, copying a rig's defaults into a new trip, "Save as defaults", completion, note versions, campground lists, and the document vault. Date, booking, site, and rig-detail rules live in `CampCore` (its `TripDetails` and `RigDetails` protocols, shared by the models and the forms' drafts) and are tested without SwiftData.

Screens read with `@Query` and edit models directly; SwiftData saves automatically, and `LibraryController.save()` saves after each deliberate action so a failure is shown. Forms edit a draft (`TripDraft`, `RigDraft`, `ChecklistStepDraft`) so Cancel discards changes.

**Schema changes.** The app has not shipped and the CloudKit schema is still in Development, so the models may change freely; delete and reinstall the app if a development store won't open. Once the schema is promoted to Production (#6), CloudKit accepts only additive changes: add optional attributes or models; never rename, retype, or remove one, and never change which attributes are cloud-encrypted. A change SwiftData can't infer then needs a `VersionedSchema` and `SchemaMigrationPlan`.

## Photos and documents

Rig and trip photos use file-based picker imports, are downsampled from disk (at most 2560 pixels), and are stored in new model fields as JPEG data with external storage and cloud encryption, so they sync with their rig or trip and are deleted with it. There is no separate media folder or purge step. Original photos stay in the user's photo library.

Documents are at most 50 MiB (an app limit), stored byte-for-byte in new external/cloud-encrypted attributes, and verified by SHA-256 on every read. Apple encrypts and transfers large assets; app-level sealing is retained only for reading legacy files. Existing CloudKit fields are preserved rather than changing their encryption settings. See [document vault](document-vault.md).

A new device needs an online initial download before photos and files are available offline. Metadata can arrive before a file; the document then shows "Waiting to download from iCloud".

## Conflicts

Apple manages synchronization conflicts and timing; this is eventual consistency. Independent checklist steps are separate objects, so edits to different steps both survive. Two devices that each add a rig offline can end up with two active rigs; both stay readable and Profile asks the owner to archive one. Two devices that save the same campground can produce two list entries; the first one decides. Notes keep a version each time the Photos & site notes screen is left, so earlier text can be restored.

## Backup

Profile › Prepare export writes a zip with `library.json`, `documents.json`, and each document's verified original file; trip photos are shared individually. Copying the store file alone is not a complete backup: its WAL and external files belong to it.

## iCloud setup

The default build declares no entitlements and an empty `ROAMREADY_MIRRORING_CONTAINER`. There are no accounts; onboarding and trips work offline. The unconfigured default makes no CloudKit requests.

1. Register the App ID, team, and a **new dedicated CloudKit container** for mirroring.
2. Apply `Config/Cloud.xcconfig.example`, set the actual `ROAMREADY_MIRRORING_CONTAINER`, and use `Config/Cloud.entitlements` (CloudKit and WeatherKit). Enable iCloud (CloudKit), Push Notifications, and WeatherKit on the App ID. Let signing supply the appropriate `aps-environment`. `remote-notification` background mode is declared in Info.plist.
3. Sync is on by default. The "Sync with iCloud" preference (onboarding and Profile) works offline and applies **on the next app launch**. The current session keeps its launch configuration, and the UI shows pending changes. Turning sync off does not delete local data or the iCloud copy. Validate preference changes and relaunches during large transfers on devices before release.
4. Run a signed development build on Apple hardware so SwiftData creates the CloudKit schema in the Development environment, exercising every model (including documents). Inspect it in CloudKit Console and deploy it to Production before TestFlight. Do not mutate generated system fields.
5. Test two devices, account transitions, offline operation, and large attachments before shipping.

`ICloudSettings` passively observes mirroring events (`NSPersistentCloudKitContainer.eventChangedNotification`) to show the last successful activity and the last completed activity's error. A completed event means that activity completed, not that every device is up to date. The status never claims global delivery. No force-sync or account-retry button is exposed.

The OS iCloud account supplies private CloudKit identity. SwiftData opens with the launch preference without an account or network preflight, and Apple handles account changes, connectivity, and retries while that same container stays open. There is no app-level identity pin, account notification handler, network-driven reopen, or account polling. Local data retention and cross-account behavior follow Apple's managed lifecycle and require device acceptance. Profile › Erase all data remains an explicit operation that deletes the CloudKit zone and everything local; see [erasing data](erase-data.md).

## Validation and outstanding release gates

macOS CI runs the SwiftData tests against real stores: rig, trip, checklist, list, and document rules; cascades and unattached documents; encryption and tamper detection; reopening from disk; and the export. CI also builds the SwiftUI app with the iOS 27 SDK; a simulator build does not establish runtime behavior on devices.

Still required on provisioned devices:

- Airplane-mode first launch and relaunch with mirroring configured, checklist edits, notes, photos, saved campgrounds, exports, low storage. Verify iCloud resumes without a database reopen after reconnection.
- Change the iCloud preference offline in both directions, verify the current session stays unchanged, and relaunch to apply it; repeat during attachment transfers.
- Two-device initial download, independent edits, concurrent onboarding, default-list replacement, reordering, and offline deletion.
- Large and interrupted document transfers, metadata arriving before files, quota exhaustion, throttling, app termination, and long periods offline.
- Sign out or switch iCloud accounts during transfers; verify Apple's local retention and cross-account behavior, offline relaunch, sign-in/reconnection without reopening the store, and Erase all data.
- Actual iOS 27 runtime, accessibility, WeatherKit and Foundation Models behavior, and measured memory and save times with large trip histories.

Passing local tests is not certification of live CloudKit operation or production readiness.
