# RoamReady offline storage and synchronization

## Managed persistence

`NSPersistentCloudKitContainer` manages the local SQLite library and, in a provisioned build after opt-in, automatic private CloudKit mirroring. The app never executes SQL or uses SQLite APIs. Core Data owns database transactions, persistent history, remote imports, CloudKit records, asset transfers, scheduling, and retries. There is no custom CloudKit record transport, upload queue, change token, polling loop, or retry scheduler.

The `Library` model configuration contains native attributes for profiles, rigs, trips, individual checklist items, templates, photos, assets, saved campgrounds, and note revisions. Every mirrored attribute is optional or has a default, and mirrored entities have no uniqueness constraints, as required by CloudKit. `RoamReadyManaged.sqlite` stores these entities. A separate `Device` configuration in `RoamReadyDevice.sqlite` holds migration markers and a last coherent UI projection. Device metadata never mirrors.

A private managed-object context serializes app reads and writes, automatically merges imported changes, and uses a property merge policy. `CampStore` changes only fields that differ between its accepted baseline and the user's desired state, preserving unrelated changes. Codable domain values remain independent of Core Data. The retained record projection/version types also decode the previous development store; they are not a network replication engine.

The app still projects its library into memory. The projection cache is a device-only recovery view, not the authoritative database or an archive used for synchronization. It preserves the last complete view across a restart if a cloud import has delivered parents before their rig/checklist dependencies. Subsequent managed-store notifications refresh the view as remaining records arrive. Large-library memory and save performance require measurement before release.

## Attachments

Core Data binary attributes with **Allows External Storage** hold durable attachment contents. Core Data may store smaller bytes in SQLite and larger bytes in its private external files. This is intentionally not a strict metadata-only database. Core Data and its CloudKit mirroring own physical file placement and transfer; the app must not inspect or manipulate those private files.

Existing photo import resizes and recompresses JPEGs to at most 2560 pixels. `Media/` contains readable local copies; when one is missing it is recreated from the managed binary attribute. Imported or downloaded contents remain available offline. A new device needs an online initial download before attachments are available offline. There is no guarantee that every cloud attachment has finished downloading simply because metadata is visible. Camera capture, PDF/manual import, original-quality preservation, and storage eviction controls are not implemented by this change. The same managed binary storage can support those future attachment types.

Photo removal drops visible references. Durable assets and soft-deleted rows currently remain retained; automatic pruning needs a separately tested multi-device retention policy. Cache copies are not the sole durable source.

## Conflicts and logical identities

Apple manages synchronization conflicts and timing; this is eventual consistency, not an immediate-sync service. A local merge policy is not a promise of a particular winner for concurrent CloudKit edits to the same value. Independent checklist items remain separate managed objects. Saved note edits create immutable revision objects so previously saved text can be recovered, but unsaved text or every possible remote conflict loser is not guaranteed to be retained.

Because CloudKit does not support unique constraints, offline devices can independently create the same logical singleton or migrate the same library into distinct physical objects. The projection chooses a stable winner by persisted row UUID for each logical key, rather than crashing or duplicating visible trips. Duplicate singleton fields are not automatically combined; the selected profile/template is consistent once both devices receive the rows. Retained soft deletions take precedence within a logical identity; stale app edits do not explicitly clear deletion. Reordering remains numeric positions with a stable identity tie-break.

## Migration and recovery

The previous development store's frozen v1 model remains in `LegacyStoreModel.swift`. Before enabling mirroring, the app opens `RoamReady.sqlite` read-only, imports domain records, deletion markers, note revisions, and managed asset bytes into the new local store, verifies the reconstructed library, then saves device-only completion markers. Repeating an interrupted import skips existing logical rows. The source SQLite, its external files, the original JSON archive, and Media directory are preserved.

If the previous custom transport left incomplete records in its incoming staging table, the verified active local library is still imported and remains usable offline. A visible migration notice explains that unfinished downloads remain preserved in the old source database for recovery; they are not silently considered migrated. This is a development migration, not a cloud-schema conversion.

For older JSON installations, the legacy decoder imports validated data and available photos idempotently. A corrupt/future archive fails without marking migration complete; missing old photos do not discard trips. JSON is not re-imported over a successfully migrated SQLite library. Import data commits before its device-only completion marker; the separate stores are not claimed to provide a cross-store atomic transaction.

Profile's explicit JSON export includes metadata and saved campground IDs, not attachment bytes. Copying a `.sqlite` file alone is not a complete backup: WAL and Core Data external asset files belong to the store. A full backup must use supported Core Data mechanisms.

## iCloud setup

The default build has empty entitlements and an empty `ROAMREADY_MIRRORING_CONTAINER`. It makes no CloudKit requests and needs no account for local features.

1. Register the App ID, team, and a **new dedicated CloudKit container** for managed mirroring. Do not reuse the previous custom-transport container/schema: automatic mirroring cannot adopt those records. Existing cloud-only data must first download through the previous build; this change migrates on-device data only.
2. Apply `Config/Cloud.xcconfig.example`, set the actual new `ROAMREADY_MIRRORING_CONTAINER`, and use `Config/Cloud.entitlements`. Enable the iCloud/CloudKit and Push Notifications capabilities in Xcode. Let signing supply the appropriate `aps-environment`. `remote-notification` background mode is declared in Info.plist.
3. In Profile or onboarding, enable iCloud sync. This preference applies on the **next app launch after closing the app**. Disabling also takes effect on next launch; transfers may continue in the current session. This avoids tearing down a live mirroring coordinator while local writes or imports are running. Existing local/cloud copies are not explicitly deleted by the setting.
4. Run a signed development build on Apple hardware. In a developer-only harness call `initializeCloudKitSchema(options: [])` on the configured container to initialize all entity/attribute types, including entities not yet created in normal app use. Never initialize the schema in a production build. Inspect Core Data's generated schema in CloudKit Console and deploy it to production before TestFlight/production testing. Do not manually create the old `RoamReadyRecord` type or mutate generated system fields.
5. Test two devices, account transitions, offline operation, and large attachments before shipping.

Managed import/export/setup event notifications provide progress/error reporting. A completed event means that activity completed, not that every device is up to date. No force-sync button or immediate transfer guarantee is exposed. Apple controls foreground/background scheduling; silent notifications need correct provisioning and remain subject to OS constraints.

The OS iCloud account supplies private CloudKit identity; an app OAuth login is not required. Account transitions are handled by Apple's mirroring stack, with availability reported by the UI. The previous custom account binding is not reused and no cross-account isolation behavior beyond Apple's documented lifecycle is claimed. Sign-out/switch behavior, local-cache retention, and cloud deletion/reset semantics must be validated on devices before release. Do not implement an automatic cloud reset/reupload on errors. Sign in with Apple remains a separate future backend identity.

## Validation and outstanding release gates

macOS integration tests exercise actual Core Data SQLite: model compatibility, close/reopen/export, JSON and v1 SQLite migration, attachment persistence without Media copies, incremental field saves, note recovery, logical duplicates, deletion, and partial-import recovery across restart. Linux tests cannot compile Core Data. Apple CI also builds the SwiftUI app; compiling against a pre-iOS-27 SDK with a temporary target override does not establish iOS 27 readiness.

Still required on provisioned devices:

- Airplane-mode first launch and relaunch, checklist edits, notes, photos, favorites, exports, interrupted local saves, low storage.
- Two-device initial download, same-value and independent edits, concurrent onboarding, duplicate migrations, template replacement, reordering, and offline deletion.
- Large/interrupted attachment transfers, quota exhaustion, throttling, delayed push delivery, app termination, and long periods offline.
- Sign out/switch accounts during imports/exports, reopen offline, inspect local retention and verify account separation; cloud-library deletion and re-enable behavior.
- Actual iOS 27 runtime, accessibility, WeatherKit/Foundation Models behavior, and measured save/memory/storage limits with large trip histories.

Passing local tests is not certification of live CloudKit operation or production readiness.
