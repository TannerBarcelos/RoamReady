# RoamReady offline storage and synchronization

## Implemented architecture

SwiftUI reads a local value projection. Core Data owns `RoamReady.sqlite` (WAL mode, full synchronization); a single private context serializes transactions. Separate entities store profile, rig, trip, checklist item, template, photo, asset, favorite, and immutable note revision records. Attributes are native SQLite/Core Data attributes; a small per-row version map supports deterministic field merges. Photo bytes use external binary storage. The existing `Application Support/Camp` directory stays unchanged to preserve installed data.

`CampStore` compares the last accepted UI projection with the desired projection. The persistence layer changes only fields the user actually edited; it never replaces all database rows with an old UI snapshot. Remote additions or changes to unrelated fields therefore survive local saves. The UI currently retains an in-memory library projection; record writes are incremental, but projection/diff computation is still proportional to library size. Pagination and query-driven UI are future optimizations that must be driven by measurements.

Every local record mutation updates its persistent `dirty` flag and revision in the same SQLite transaction. This is the durable outbox. An upload acknowledgement clears a flag only if the local revision still matches the uploaded revision. Network failures, app termination, and newer edits leave the appropriate work pending.

### Why explicit CloudKit transport

This implementation uses `NSPersistentContainer` plus an explicit private CloudKit transport, rather than automatic `NSPersistentCloudKitContainer` mirroring. We need application-controlled field merges, retained competing note text, permanent deletion semantics, and a persistent account binding before an upload. This is a deliberate change from the original plan. Do not also enable managed mirroring on this SQLite store.

Sync uses one private custom record zone, stable logical record names, change tokens, and conditional writes with server change tags. Each cloud record contains one versioned domain document; images travel as CKAssets. Downloaded pages and their tokens commit together in durable staging. Coherent records are promoted transactionally; a parent waiting for initial checklist/rig records stays staged across restarts, while the existing local library remains usable. An interrupted page can be replayed. Expired tokens trigger a full re-read without discarding local edits. A removed cloud zone pauses sync and requires explicit re-enablement before recreating/uploading a library; cloud removal never silently triggers a local-data reupload. Foreground polling and reachability hints schedule bounded batches with exponential retry and server retry-after handling. No continuous background delivery or push subscription is claimed.

## Conflict and deletion rules

- Each field has a Lamport counter plus stable installation writer ID. Counters advance past observed remote counters; device wall clocks do not decide winners. Writer IDs live in a non-backed-up installation folder, so restoring a database onto another device cannot clone an active writer identity.
- Independent fields merge. Concurrent changes to the same field resolve deterministically by counter, then writer ID. Reordering uses per-item numeric positions with identity as a stable tie-break; it is not a collaborative sequence editor.
- Notes also create immutable revision records. Losing text remains recoverable from **Earlier note versions**. Revisions may include intermediate saved drafts; timestamps are display information only.
- A tombstone permanently deletes an identity, even if an old device later edits it. Restoring a deleted object requires a new identity. Saved campground toggles use a versioned boolean so saving a favorite again remains possible.
- Newly created trips/templates carry initial child-record membership. A partial first download cannot appear as an incorrectly complete checklist. Related records are retained while the UI waits for a coherent projection.
- Tombstones are not automatically pruned. Photo deletion removes visible references; asset bytes are retained pending a tested retention/garbage-collection policy. This trades storage usage for recoverability and avoids premature multi-device deletion.

## Migration and recovery

On first upgraded launch, read and validate the existing version-zero/version-one JSON with the legacy decoder. Import the profile, rig snapshots, trips, list order, task states, photos/captions, and saved campground UserDefaults into one database transaction. Copy available referenced JPEG bytes into external database assets, verify the reconstructed projection, and commit the completion marker with the records/outbox flags.

The source JSON and existing media are never overwritten or deleted by migration. Corrupt/future archives fail without marking migration complete. Missing old photos do not discard their trip records. Retrying after interruption is idempotent. If a newer application changes the Core Data model, preserve the frozen v1 model and provide an explicit next-version migration; never edit v1 in place after release.

Use Profile's explicit export to produce a fresh JSON snapshot including saved campground IDs. It excludes image bytes. A raw copy of `RoamReady.sqlite` alone is **not** a safe backup: the WAL and external binary files belong to the store too. Use supported Core Data backup/migration mechanisms for a future complete-library backup feature.

## Photo availability

Import resizes JPEGs to at most 2560 pixels. The database asset is durable; `Media/` files are a readable local copy. When that copy is missing, the app restores it from the database. A cloud photo that has not downloaded displays an availability placeholder. iCloud Photos originals still require downloading before they can be imported. App-managed thumbnails decode at bounded sizes.

## iCloud configuration

The checked-in default has empty entitlements and `ROAMREADY_CLOUD_CONTAINER` empty. It creates a local SQLite library and makes no CloudKit requests. Offline onboarding, trip changes, photos, exports, and saved campgrounds require no account.

To test sync on Apple hardware:

1. Register your actual App ID, developer team, and private iCloud container in Apple Developer. Enable CloudKit for that App ID.
2. Apply the settings from `Config/Cloud.xcconfig.example` to both build configurations, replacing identifiers. `Config/Cloud.entitlements` requests only the chosen CloudKit container. Sign/provision through Xcode.
3. Run on a development device, explicitly enable iCloud sync in Profile (or onboarding to restore a library), and create sample records/assets. Inspect the development schema in CloudKit Console.
4. Confirm the `RoamReadyRecord` type has `payload` (Bytes) and `image` (Asset), and deploy the schema to production before TestFlight/production validation. First test in an isolated development container.
5. Perform all acceptance checks below before shipping with sync enabled.

The first explicit opt-in binds the local library to the verified CloudKit user record ID. Every sync checks that binding; every upload rechecks identity, and account-change notifications cancel active operations and pause scheduling. A different account cannot automatically adopt or upload this library. Turning sync off leaves both existing copies intact. Rebinding a library, clearing cloud data, and automatically switching local libraries are deliberately unavailable; such workflows require a separately reviewed migration design. A connection is needed to enable/verify cloud access, never to edit the existing local library. Sign in with Apple is a separate future backend identity.

## Verification and release gates

`swift test` on macOS compiles and runs the real Core Data SQLite integration suite. Linux runs the portable domain, migration-decoder, and merge tests; conditional Apple code is excluded there. The Apple validation workflow runs macOS tests and builds the SwiftUI app. If the installed SDK is below iOS 27, its temporary deployment override is only a compile check and does not establish iOS 27 readiness.

Required physical-device acceptance, still outstanding:

- Airplane-mode first launch, create/edit/reorder/check off steps, add photos, save favorite, relaunch, export, and interrupted background saves.
- Interrupt migration before/after commit; corrupt and future archives; absent media; low storage and write permission errors. Verify all original files remain intact.
- Two devices: independent item/field edits, same-field conflicts, competing notes and restoration, reordered lists, concurrent favorite toggles, trip deletion while a second device is offline.
- Partial first download, interrupted image transfer, missing assets, token expiration, zone removal, quota exhaustion, throttling, and queued local edits during sync.
- Sign out/switch iCloud during fetch/upload, app termination during those operations, launch offline afterwards, verify no new-account records enter the old library or old-library records enter the new account.
- Measure save latency, UI responsiveness, memory, SQLite size, and cloud bandwidth with representative large histories (e.g. 1,000 trips and 50,000 checklist items). The full UI projection and indefinite revision/asset retention need measured limits before release.

A passing portable suite does not certify Core Data compilation, live CloudKit behavior, or production readiness.
