# RoamReady offline storage and synchronization

[Documentation index](README.md)

## SwiftData library

The library is a SwiftData store (`Library/RoamReady.store` in Application Support). SwiftData owns the SQLite file, external binary files, persistent history, and, in a provisioned build, private CloudKit mirroring through Apple's `NSPersistentCloudKitContainer`. The app never executes SQL, and there is no custom record transport, upload queue, change token, polling loop, or retry scheduler.

The models live in `Sources/CampPersistence/Models.swift`:

| Model | Holds | Relationships |
| --- | --- | --- |
| `CamperProfile` | name, experience | — |
| `Rig` | owner-entered details, equipment, photo (external storage), archive date | default `ChecklistStep`s (cascade), trips, documents |
| `Trip` | campground, dates, time zones, site details, booking, completion, notes, rating | rig, `ChecklistStep`s, `TripPhoto`s, `NoteRevision`s (all cascade), documents |
| `ChecklistStep` | title, detail, section, status, phase, position | its trip, or its rig for default lists |
| `TripPhoto` | resized JPEG (external storage), caption | trip |
| `NoteRevision` | a saved version of a trip's notes | trip |
| `SavedCampground` | Camp Finder lists (want to go, favorite, have been); Apple Maps places keep only their identifier | — |
| `StoredDocument` | document details; text fields cloud-encrypted | rig or trip (neither = unattached), `DocumentContent` (cascade) |
| `DocumentContent` | the file bytes (external storage) and its file key (cloud-encrypted) | document |

Every attribute is optional or has a default, every relationship is optional, and there are no unique constraints, as CloudKit mirroring requires. Deleting a trip cascades to its steps, photos, and note versions; its documents are kept and become unattached. A rig can be deleted only while no trip uses it.

The rules live next to the models (`Rig+Library.swift`, `Trip+Library.swift`, `SavedCampground+Library.swift`, `StoredDocument+Library.swift`): the one-active-rig limit, copying a rig's defaults into a new trip, "Save as defaults", completion, note versions, campground lists, and the document vault. Date, booking, site, and rig-detail rules are portable (`CampCore`'s `TripDetails` and `RigDetails` protocols, shared by the models and the forms' drafts) and are tested on Linux.

Screens read with `@Query` and edit models directly; SwiftData saves automatically, and `LibraryController.save()` saves after each deliberate action so a failure is shown. Forms edit a draft (`TripDraft`, `RigDraft`, `ChecklistStepDraft`) so Cancel discards changes.

**Schema changes.** The app has not shipped and the CloudKit schema is still in Development, so the models may change freely; delete and reinstall the app if a development store won't open. Once the schema is promoted to Production (#6), CloudKit accepts only additive changes: add optional attributes or models; never rename, retype, or remove one, and never change which attributes are cloud-encrypted. A change SwiftData can't infer then needs a `VersionedSchema` and `SchemaMigrationPlan`.

## Photos and documents

Rig and trip photos are resized on import (at most 2560 pixels) and stored in the model as JPEG data with external storage, so they sync with their rig or trip and are deleted with it. There is no separate media folder or purge step. Original photos stay in the user's photo library.

Documents are at most 50 MB, stored byte-for-byte, and verified by SHA-256 on every read. See [document vault](document-vault.md).

A new device needs an online initial download before photos and files are available offline. Metadata can arrive before a file; the document then shows "Waiting to download from iCloud".

## Conflicts

Apple manages synchronization conflicts and timing; this is eventual consistency. Independent checklist steps are separate objects, so edits to different steps both survive. Two devices that each add a rig offline can end up with two active rigs; both stay readable and Profile asks the owner to archive one. Two devices that save the same campground can produce two list entries; the first one decides. Notes keep a version each time the Photos & site notes screen is left, so earlier text can be restored.

## Backup

Profile › Prepare export writes a zip with `library.json`, `documents.json`, and each document's verified original file; trip photos are shared individually. Copying the store file alone is not a complete backup: its WAL and external files belong to it.

## iCloud setup

The default build declares no entitlements and an empty `ROAMREADY_MIRRORING_CONTAINER`. There are no accounts; onboarding and trips work offline. The unconfigured default makes no CloudKit requests.

1. Register the App ID, team, and a **new dedicated CloudKit container** for mirroring.
2. Apply `Config/Cloud.xcconfig.example`, set the actual `ROAMREADY_MIRRORING_CONTAINER`, and use `Config/Cloud.entitlements` (CloudKit and WeatherKit). Enable iCloud (CloudKit), Push Notifications, and WeatherKit on the App ID. Let signing supply the appropriate `aps-environment`. `remote-notification` background mode is declared in Info.plist.
3. Sync is on by default. The "Sync with iCloud" toggle (onboarding and Profile) applies **immediately**: the app saves, closes the container, and reopens it with or without mirroring, the same path used after an iCloud account change. Turning sync off does not delete local data or the iCloud copy. Validate toggling during large transfers on devices before release.
4. Run a signed development build on Apple hardware so SwiftData creates the CloudKit schema in the Development environment, exercising every model (including documents). Inspect it in CloudKit Console and deploy it to Production before TestFlight. Do not mutate generated system fields.
5. Test two devices, account transitions, offline operation, and large attachments before shipping.

Mirroring events (`NSPersistentCloudKitContainer.eventChangedNotification`) drive the sync status in Profile and on each document. A completed event means that activity completed, not that every device is up to date. No force-sync button is exposed.

The OS iCloud account supplies private CloudKit identity. On the first sync the signed-in, container-specific CloudKit user is pinned automatically (`CloudSyncPolicy`); a different account never syncs into the library, and an account change reopens it on this device only. Profile › Erase all data deletes the CloudKit zone and everything local; see [erasing data](erase-data.md).

## Validation and outstanding release gates

macOS CI runs the SwiftData tests against real stores: rig, trip, checklist, list, and document rules; cascades and unattached documents; encryption and tamper detection; reopening from disk; and the export. Apple CI also builds the SwiftUI app with the iOS 27 SDK; a simulator build does not establish runtime behavior on devices.

Still required on provisioned devices:

- Airplane-mode first launch and relaunch, checklist edits, notes, photos, saved campgrounds, exports, low storage.
- Two-device initial download, independent edits, concurrent onboarding, default-list replacement, reordering, and offline deletion.
- Large and interrupted document transfers, metadata arriving before files, quota exhaustion, throttling, app termination, and long periods offline.
- Sign out or switch iCloud accounts during transfers, reopen offline, verify account separation, and Erase all data.
- Actual iOS 27 runtime, accessibility, WeatherKit and Foundation Models behavior, and measured memory and save times with large trip histories.

Passing local tests is not certification of live CloudKit operation or production readiness.
