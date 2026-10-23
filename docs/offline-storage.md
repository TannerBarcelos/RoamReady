# RoamReady offline storage and synchronization

## Managed persistence

`NSPersistentCloudKitContainer` manages the local SQLite library and, in a provisioned build, automatic private CloudKit mirroring, on by default and switchable in the app. The app never executes SQL or uses SQLite APIs. Core Data owns database transactions, persistent history, remote imports, CloudKit records, asset transfers, scheduling, and retries. There is no custom CloudKit record transport, upload queue, change token, polling loop, or retry scheduler.

The `Library` model configuration contains native attributes for profiles, rigs, trips, individual checklist items, per-rig default checklists, photos, assets, saved campgrounds, note revisions, and documents with their chunked contents. The model is built in code in `Sources/CampPersistence/LibraryModel.swift` (one version, `RoamReady.Library.1`). Record layout: `profile:current`; `rig:<rig id>` per rig, archived ones included; `templates:rig:<rig id>` per rig's defaults; trips reference their rig by `rigID`. Every mirrored attribute is optional or has a default, and mirrored entities have no uniqueness constraints, as required by CloudKit. `RoamReadyManaged.sqlite` stores these entities. A separate `Device` configuration in `RoamReadyDevice.sqlite` holds the pinned iCloud identity, interrupted-write markers, and a last coherent UI projection. Device metadata never mirrors.

**Schema changes.** The app has not shipped and the CloudKit schema is still in Development, so the model may change freely; existing development stores open through Core Data's inferred lightweight migration. Once the schema is promoted to Production (#6), CloudKit accepts only additive changes: add optional attributes or entities; never rename, retype, or remove one, and never change which attributes are cloud-encrypted. A change Core Data can't infer then needs an `NSStagedMigrationManager` stage from a frozen copy of the shipped model.

A private managed-object context serializes app reads and writes, automatically merges imported changes, and uses a property merge policy. `CampStore` changes only fields that differ between its accepted baseline and the user's desired state, preserving unrelated changes. Codable domain values remain independent of Core Data; `RecordProjection` maps them to flat records and back and is tested on Linux.

The app still projects its library into memory. The projection cache is a device-only recovery view, not the authoritative database or an archive used for synchronization. It preserves the last complete view across a restart if a cloud import has delivered parents before their checklist dependencies. A trip whose rig record hasn't arrived yet is shown with "Rig unavailable" rather than hidden. Subsequent managed-store notifications refresh the view as remaining records arrive. Large-library memory and save performance require measurement before release.

## Attachments

Core Data binary attributes with **Allows External Storage** hold durable attachment contents. Core Data may store smaller bytes in SQLite and larger bytes in its private external files. This is intentionally not a strict metadata-only database. Core Data and its CloudKit mirroring own physical file placement and transfer; the app must not inspect or manipulate those private files.

Existing photo import resizes and recompresses JPEGs to at most 2560 pixels. `Media/` contains readable local copies; when one is missing it is recreated from the managed binary attribute. Imported or downloaded contents remain available offline. A new device needs an online initial download before attachments are available offline. There is no guarantee that every cloud attachment has finished downloading simply because metadata is visible. Trip camera capture uses the same local photo import path. Unreferenced photo bytes are purged on the save that releases their last reference (see README); the local copy is removed only after that commit succeeds, and a purged asset referenced again is revived from its local copy. A photo referenced only by a not-yet-synced row on another device can be purged first; that device then shows the photo as unavailable. Photo purging never touches documents. Rig and trip documents (PDFs, images, and HTTPS links) use the shared document vault, which preserves original bytes and verifies them by SHA-256 on every read. See [document-vault.md](document-vault.md). Rig-camera capture and storage eviction controls are not implemented.

Document deletion is deliberate and confirmed: content rows are deleted and an identity-only tombstone remains. Photo removal drops visible references. Durable assets and soft-deleted rows currently remain retained; automatic pruning needs a separately tested multi-device retention policy. Cache copies are not the sole durable source.

## Conflicts and logical identities

Apple manages synchronization conflicts and timing; this is eventual consistency, not an immediate-sync service. A local merge policy is not a promise of a particular winner for concurrent CloudKit edits to the same value. Independent checklist items remain separate managed objects. Saved note edits create immutable revision objects so previously saved text can be recovered, but unsaved text or every possible remote conflict loser is not guaranteed to be retained.

Because CloudKit does not support unique constraints, offline devices can independently create the same logical singleton or migrate the same library into distinct physical objects. The projection chooses a stable winner by persisted row UUID for each logical key, rather than crashing or duplicating visible trips. Duplicate singleton fields are not automatically combined; the selected profile/template is consistent once both devices receive the rows. Retained soft deletions take precedence within a logical identity; stale app edits do not explicitly clear deletion. Reordering remains numeric positions with a stable identity tie-break.

## Backup

Profile's explicit export is a zip with library JSON, document details, and verified document files; trip photo bytes are shared individually. Copying a `.sqlite` file alone is not a complete backup: WAL and Core Data external asset files belong to the store. A full backup must use supported Core Data mechanisms.

## iCloud setup

The default build declares no entitlements and an empty `ROAMREADY_MIRRORING_CONTAINER`. There are no accounts; onboarding and trips work offline. The unconfigured default makes no CloudKit requests.

1. Register the App ID, team, and a **new dedicated CloudKit container** for managed mirroring.
2. Apply `Config/Cloud.xcconfig.example`, set the actual new `ROAMREADY_MIRRORING_CONTAINER`, and use `Config/Cloud.entitlements`. Enable the iCloud/CloudKit and Push Notifications capabilities in Xcode. Let signing supply the appropriate `aps-environment`. `remote-notification` background mode is declared in Info.plist.
3. Sync is on by default. The "Sync with iCloud" toggle (onboarding and Profile) applies **immediately**: the app waits for pending local writes, closes the store, and reopens it with or without mirroring, the same path used after an iCloud account change. An in-flight CloudKit import can be interrupted; partially imported graphs are hidden by the coherent-projection logic, partially imported document files stay unavailable until every chunk arrives, and mirroring resumes on the next open. Turning sync off does not delete local data or the iCloud copy. Validate toggling during large transfers on devices before release.
4. Run a signed development build on Apple hardware. In a developer-only harness call `initializeCloudKitSchema(options: [])` on the configured container to initialize all entity/attribute types, including entities not yet created in normal app use (for example `RR_document` and `RR_documentContent`). Never initialize the schema in a production build. Inspect Core Data's generated schema in CloudKit Console and deploy it to production before TestFlight/production testing. Do not mutate generated system fields.
5. Test two devices, account transitions, offline operation, and large attachments before shipping.

Managed import/export/setup event notifications provide progress/error reporting. A completed event means that activity completed, not that every device is up to date. No force-sync button or immediate transfer guarantee is exposed. Apple controls foreground/background scheduling; silent notifications need correct provisioning and remain subject to OS constraints.

The OS iCloud account supplies private CloudKit identity; an app OAuth login is not required. On the first sync the signed-in, container-specific CloudKit user identity is pinned automatically in device-only metadata (`CloudSyncPolicy`). A preflight checks it before every mirrored open, and account-change notifications schedule teardown/local-only reopening. Unavailable identity leaves local trip access intact. These safeguards do not guarantee cancellation of an in-flight transfer; Apple's lifecycle and physical-device testing still apply. Sign-out/switch behavior, local-cache retention, and cloud deletion/reset semantics must be validated on devices before release. Do not implement an automatic cloud reset/reupload on errors. There are no app accounts. Profile › Erase all data deletes the CloudKit zone and local data; see [erasing data](erase-data.md).

## Validation and outstanding release gates

macOS integration tests exercise actual Core Data SQLite: CloudKit model rules, close/reopen/export, document original bytes, missing content, and deletion, attachment persistence without Media copies, incremental field saves, note recovery, logical duplicates, deletion, and partial-import recovery across restart. Linux tests cannot compile Core Data. Apple CI also builds the SwiftUI app; compiling against a pre-iOS-27 SDK with a temporary target override does not establish iOS 27 readiness.

Still required on provisioned devices:

- Airplane-mode first launch and relaunch, checklist edits, notes, photos, favorites, exports, interrupted local saves, low storage.
- Two-device initial download, same-value and independent edits, concurrent onboarding, template replacement, reordering, and offline deletion.
- Large/interrupted attachment and document transfers, document metadata arriving before contents, quota exhaustion, throttling, delayed push delivery, app termination, and long periods offline.
- Sign out/switch accounts during imports/exports, reopen offline, inspect local retention and verify account separation; cloud-library deletion and re-enable behavior.
- Actual iOS 27 runtime, accessibility, WeatherKit/Foundation Models behavior, and measured save/memory/storage limits with large trip histories.

Passing local tests is not certification of live CloudKit operation or production readiness.
