# Erasing data

[Documentation index](README.md)

RoamReady has no accounts (see [identity contract](account-and-offline-contract.md)), so there is no account to delete and App Store Guideline 5.1.1(v) doesn't apply. The owner can still remove everything: Profile › Settings › **Erase all data** (`EraseDataView`, `LibraryErase`).

1. The screen lists everything that is erased; the owner turns on "I understand this can't be undone" and confirms.
2. **iCloud**: when the build syncs (a container is configured), SwiftData's mirroring zone (`com.apple.coredata.cloudkit.zone`) is deleted from the app's private CloudKit database. This needs a connection and a signed-in iCloud account; without them the flow stops before anything is erased. Builds without a container skip this step, so erasing works offline.
3. **This device**: the search index writer stops and is awaited, then the library closes, then the SwiftData store directory (with its external photo and document files), the search index folder, document imports and previews, the forecast cache, temporary files, and stored preferences are deleted. The app reopens empty at onboarding.

A failure names the step and stops, so a half-erased library never looks finished. Other devices using the same iCloud account see the zone removed: mirroring stops and their local copy stays until erased there.

## Deleted records

Deletions are real deletes: SwiftData removes the model and mirroring deletes its CloudKit record. Deleting a trip cascades to its checklist steps, photos, note versions, and menu in the same save; its documents stay as unattached. Deleting a document deletes its content.

Apple's mirroring tracks deletions in persistent history, so a device that was offline applies them when it next syncs. An offline device that edited a record another device deleted can, depending on timing, bring that record back; the delete confirmation copy says the deletion applies to every device, and validating this on two devices is a release gate (see [offline storage](offline-storage.md#validation-and-outstanding-release-gates)).

- **Note revisions of live trips:** proposed to keep the 50 most recent per trip. Not implemented yet; this needs a decision.
- Erase all data removes everything, locally and in iCloud.

## The search index

The Assistant's document search index is a disposable SQLite file in `Application Support/Search`, outside the library folder, excluded from backups, and never synced. Erasing removes it in this order, so nothing can bring it back:

1. `DocumentIndexCoordinator.erase()` marks the session erased, cancels the running pass, and **waits for it to finish**. An index job that is mid-read or mid-write cannot write after this point: every write is guarded by the session, and the pass is awaited before anything is deleted.
2. The database connection is closed.
3. `documents.sqlite`, its `-wal`, `-shm`, and `-journal` sidecars, and the whole `Search` folder (including any staging files) are deleted. The document states the coordinator reported are cleared.
4. `LibraryController.eraseDevice()` then deletes the library, the document preview cache, and every `RoamReady*` item in the temporary folder: staged imports (`RoamReady-Import-*`), the export archive, and photo previews. It deletes the `Search` folder again as a backstop and fails with a visible step if anything can't be removed.

After the erase the coordinator ignores saves, foreground events, waiting-document polls, and searches. A fresh, empty library starts a new session explicitly; a library with nothing to index creates no index file, and a new file appears only when a readable document needs indexing. The index holds document text, so it is covered by the same "everything is erased" promise as the originals; the originals themselves are SwiftData content and are removed with the store.
