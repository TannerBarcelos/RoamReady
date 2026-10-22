# Erasing data

RoamReady has no accounts (see [identity contract](account-and-offline-contract.md)), so there is no account to delete and App Store Guideline 5.1.1(v) doesn't apply. The owner can still remove everything: Profile › **Erase all data** (`EraseDataView`, `LibraryErase`).

1. The screen lists everything that is erased; the owner turns on "I understand this can't be undone" and confirms.
2. **iCloud**: when the build syncs (a container is configured), the Core Data mirroring zone (`com.apple.coredata.cloudkit.zone`) is deleted from the app's private CloudKit database. This needs a connection and a signed-in iCloud account; without them the flow stops before anything is erased. Builds without a container skip this step, so erasing works offline.
3. **This device**: the library closes, then the `Camp` directory (Core Data stores, backups, Media, forecast cache), document caches and imports, and stored preferences are deleted, along with any sign-in data left by earlier development builds. The app reopens empty at onboarding.

A failure names the step and stops, so a half-erased library never looks finished. Other devices using the same iCloud account see the zone removed: sync turns off (`ReplicationError.cloudLibraryRemoved`) and their local copy stays until erased there.

## Retention policy for deleted records (proposed; needs product sign-off)

Deletions are soft: a row is marked `removed`, and that flag syncs, so a stale offline edit can never bring a deleted trip back (`testSoftDeleteWinsOverStaleEditAndFavoriteCanBeSavedAgain`). If a tombstone were hard-deleted, a device returning from weeks in the backcountry with an offline edit to that record would re-upload it as new. So:

- **Keep tombstones (identity plus the `removed` flag) indefinitely.** They are a few bytes each. Pruning them is the only way a deleted trip can return.
- **Clear personal content when a record is deleted, not later.** A deleted trip's note text and all of its note revisions are cleared and tombstoned in the same save (#28). Photo bytes are purged when their last reference goes. Document content rows are deleted with an identity-only tombstone.
- **Note revisions of live trips:** proposed to keep the 50 most recent per trip, pruning older ones on save. Not implemented yet; this needs a decision.
- Erase all data removes everything, tombstones included, locally and in iCloud.
