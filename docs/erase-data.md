# Erasing data

RoamReady has no accounts (see [identity contract](account-and-offline-contract.md)), so there is no account to delete and App Store Guideline 5.1.1(v) doesn't apply. The owner can still remove everything: Profile › **Erase all data** (`EraseDataView`, `LibraryErase`).

1. The screen lists everything that is erased; the owner turns on "I understand this can't be undone" and confirms.
2. **iCloud**: when the build syncs (a container is configured), SwiftData's mirroring zone (`com.apple.coredata.cloudkit.zone`) is deleted from the app's private CloudKit database. This needs a connection and a signed-in iCloud account; without them the flow stops before anything is erased. Builds without a container skip this step, so erasing works offline.
3. **This device**: the library closes, then the SwiftData store directory (with its external photo and document files), document imports, the forecast cache, and stored preferences are deleted. The app reopens empty at onboarding.

A failure names the step and stops, so a half-erased library never looks finished. Other devices using the same iCloud account see the zone removed: mirroring stops and their local copy stays until erased there.

## Deleted records

Deletions are real deletes: SwiftData removes the model and mirroring deletes its CloudKit record. Deleting a trip cascades to its checklist steps, photos, and note versions in the same save; its documents stay as unattached. Deleting a document deletes its content.

Apple's mirroring tracks deletions in persistent history, so a device that was offline applies them when it next syncs. An offline device that edited a record another device deleted can, depending on timing, bring that record back; the delete confirmation copy says the deletion applies to every device, and validating this on two devices is a release gate (see [offline storage](offline-storage.md#validation-and-outstanding-release-gates)).

- **Note revisions of live trips:** proposed to keep the 50 most recent per trip. Not implemented yet; this needs a decision.
- Erase all data removes everything, locally and in iCloud.
