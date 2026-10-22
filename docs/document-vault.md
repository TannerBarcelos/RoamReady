# Document vault and shared managed-document API

RoamReady stores rig manuals, registration, insurance, warranties, service records, reservation confirmations, and other paperwork through **one** document API. Any feature that needs attachments (reservation confirmations, backup/recovery, future maintenance logs) must use it instead of adding its own storage, file cache, or transfer path.

## What users can do

| Where | Behavior |
| --- | --- |
| Onboarding, step 2 (“Your rig”) | Optional **Manuals & paperwork** section. Documents attach to the rig being created. |
| Profile › Rig documents | Add, preview, share, edit, and delete rig documents. Available offline (not gated on connectivity). |
| Trip details › Paperwork | The same controls for documents owned by the trip. |
| Profile › Unattached documents | Documents whose trip was deleted or whose rig was replaced. Deleting a trip never deletes its documents silently. |

Sources:

- **Files** from the system document picker (`.fileImporter`, PDF or image types). Files from a file provider are read through `NSFileCoordinator`, so they download first.
- **Photos** from the system photo picker with `preferredItemEncoding: .current`, so the stored encoding (for example HEIC) is kept instead of being transcoded.
- **HTTPS links**. A link stays **online-only** until the user picks **Save a copy for offline use**. That explicitly downloads the contents and stores them as the document's file. The link is kept.
  - The response is written to a temporary file as it arrives, through `BoundedDocumentWriter`, which applies the size limit and checks the file signature as bytes arrive. It accepts HTTPS responses only.
  - A response that declares more than the limit is refused before any body is read. Anything that grows past the limit, or whose first bytes aren't a PDF or image (for example an HTML page), is abandoned early, so it can't fill the device's storage.
  - The download continues under a UIKit background task if the user leaves the app. If iOS ends that time, the download is cancelled and nothing partial is saved.

Each document has a title, a **document type** (`manual`, `registration`, `insurance`, `warranty`, `maintenance`, `reservation`, `other`, plus unknown future values, which are preserved), notes, an optional issue/effective date, and an optional expiration/renewal date.

The type has no default. The user must choose it before saving, because it decides how the file is protected (see [Protection](#protection)). The editor states the protection before saving. Encrypted documents show a lock in lists, and the detail screen says "End-to-end encrypted in iCloud" or "Encrypted at rest in iCloud".

Detail screens provide Quick Look preview for PDFs and images, a share sheet for the file or link, link opening (disabled offline), and **deliberate deletion** behind a confirmation dialog.

## Guarantees

- **Original bytes.** Uploaded bytes are stored exactly as received: no resizing, recompression, or metadata stripping. This differs from trip photos, which are still resized to 2560 px. The SHA-256 of the bytes is recorded when they are added. Every read (`contents(ofDocument:)` and `exportContents(ofDocument:to:)`) re-hashes the plaintext and throws `contentIntegrity` instead of returning altered bytes.
- **Type detection from bytes.** PDF, JPEG, PNG, HEIC/HEIF, GIF, TIFF, and WebP are recognized by their signatures. Filename extensions are never trusted; a renamed ZIP or HTML page is rejected with `unsupportedFileType`. Empty files are rejected, and so are files over `DocumentPolicy.maximumByteCount` (250 MB). CloudKit assets allow far larger files (an Apple engineer cites up to 50 GB, bounded by the user's iCloud quota). The limit bounds storage and quota use, not memory, and should be revisited after large-transfer device testing.
- **Streaming.** Imports never hold a whole file in memory in RoamReady's code:
  - Picked files are copied byte for byte to a temporary file under `NSFileCoordinator`. Photos arrive as files through a `FileRepresentation`, and links stream to disk.
  - Inspection hashes in 1 MiB chunks. Protected files are encrypted chunk by chunk into a staging file.
  - Core Data receives memory-mapped data. Exports for preview and share decrypt and verify chunk by chunk into a file, and only a fully verified file is moved into place.
  - How Core Data itself buffers an external binary value internally is up to Core Data. Measure peak memory with very large files on devices.
- **Offline.** Uploaded and downloaded contents live in the Core Data store, so they reopen after relaunch with no network. Quick Look and sharing use a readable, verified copy (decrypted when protected) under `Caches/RoamReadyDocuments/<sha256>/`, with `completeUntilFirstUserAuthentication` data protection. The cache is disposable: it is rebuilt from the store when missing, and it is removed when the library is suspended for an account change.
- **Links.** Only `https://` URLs with a host and no embedded credentials are accepted. `http://` is rejected, not upgraded. A bare host typed by the user gets `https://`.
- **Deletion.** Only `deleteDocument(id:)` deletes. It hard-deletes the content rows, so storage is released and CloudKit deletes the asset. It also leaves an identity-only tombstone: title, notes, link, file facts, and dates are cleared, and the tombstone prevents another device's stale copy from resurrecting the document. Deleted identifiers are never reused (`duplicateDocument`).

## Storage

Document data lives in the existing `NSPersistentCloudKitContainer` **Library** configuration (`RoamReadyManaged.sqlite`), so it mirrors automatically to the private CloudKit database when sync is enabled. No raw SQLite APIs are used, and there is no custom upload queue, retry loop, or CloudKit record code.

| Entity | Purpose |
| --- | --- |
| `RR_document` | Metadata: `id`, `ownerKind`, `ownerID`, `title`, `category`, `notes`, `linkURL`, `filename`, `contentType`, `byteCount`, `checksum`, `issuedOn`, `expiresOn`, `createdAt`, `updatedAt`, plus the shared `key`/`rowID`/`removed`. No binary attributes, so listings never fault bytes. |
| `RR_documentContent` | `documentID`, `checksum`, `byteCount`, and `bytes` (Binary Data, **Allows External Storage**). |

Core Data decides whether a given `bytes` value stays inline in SQLite or moves to its private external-storage directory, and CloudKit mirroring decides how it transfers (typically as a `CKAsset`). **Do not assume any particular binary is outside SQLite**, and never read or modify Core Data's external files directly.

**End-to-end encrypted metadata.** `title`, `notes`, `linkURL`, and `filename` set `allowsCloudEncryption`. CloudKit stores them in `encryptedValues`, encrypted with keys in the user's iCloud Keychain, so they are end-to-end encrypted even without Advanced Data Protection. CloudKit can't change a field's encryption after the schema is deployed to production, so this set is part of v3's frozen contract; changing it later means new fields in a new model version.

These metadata fields are not readable in the CloudKit Console, and they can't be queried server-side; mirroring doesn't need that. If the user's iCloud Keychain is reset, CloudKit can't decrypt the existing encrypted values; on-device copies are unaffected. Validate that recovery path on devices.

### Protection

CloudKit's field encryption does not cover assets, and Core Data mirrors large binary values as assets. So file bytes are protected in one of two ways:

| `DocumentProtection` | When | File bytes in iCloud |
| --- | --- | --- |
| `.endToEnd` | Always for **registration, insurance, and reservation** (`DocumentCategory.sensitive`), and opt-in for any other type. | Encrypted on the device before they sync. Readable only by the user's devices. |
| `.standard` | Other types, unless the user opts in. | Encrypted at rest by Apple; end to end only with Advanced Data Protection. |

How `.endToEnd` works:
- `DocumentCipher` (`aes256gcm-chunked-v1`) encrypts the original bytes in 1 MiB AES-256-GCM chunks with a random key for each document.
- Each chunk's authenticated data binds the document ID, the chunk index, and a final-chunk flag. A chunk moved between documents, reordered, or truncated at a chunk boundary therefore fails, as does any flipped bit or wrong key. This is tested.
- The 32-byte key is stored in `RR_documentContent.contentKey`, marked `allowsCloudEncryption`. CloudKit end-to-end encrypts it with the user's iCloud Keychain.
- There is therefore no separate key management, and no new way to lose data beyond the iCloud Keychain reset that already applies to encrypted fields.
- The checksum always describes the plaintext, so original-byte verification is unchanged.

Rules:
- **Never lowered.** A repository never lowers a document's protection. Changing a document to a sensitive type, or opting in, re-encrypts the existing file and replaces the unencrypted copy. Changing it back to a non-sensitive type keeps it encrypted.
- **Needs the file.** Raising protection requires the file on this device; otherwise it fails with `protectionNeedsContent`.
- **Earlier copies.** An earlier unencrypted copy may persist in iCloud or device backups until Apple reclaims it.
- **On the device.** The local store holds the key next to the ciphertext. On the device, data is protected by iOS Data Protection; the end-to-end protection applies to iCloud.

Changing the sensitive set later is safe: it only affects documents saved or edited afterwards. Existing encrypted documents stay encrypted.

Both entities follow the mirrored-model rules: every attribute is optional or has a default, with no uniqueness constraints and no relationships. Ownership is a string pair, not a relationship. Duplicate logical rows, which are possible without unique constraints, resolve as they do elsewhere in the library: any tombstone wins; otherwise the lowest `rowID` wins.

On a new device, document metadata can arrive before its content row. That document reports `availability == .awaitingDownload`, and `contents` throws `contentNotDownloaded` until Core Data imports the bytes. A remote-change notification refreshes the list.

## Schema versions and migration

`Sources/CampPersistence/ManagedStoreModel.swift` holds versioned, code-built models:

- `v2()`: **frozen**. This is the first managed-mirroring model. `DocumentVaultTests.testFrozenV2ModelShapeIsUnchanged` pins every entity, attribute, and type. `v2RecordKinds` is a literal list, so adding a `RecordKind` case cannot alter v2. `LegacyStoreModel.v1()` remains frozen for the earlier custom-sync store.
- `v3()`: v2 plus `RR_document` and `RR_documentContent`. Current (`make()`).

`ManagedStoreMigration` migrates explicitly. Before the Library store loads:

1. It reads the store metadata. If the store is already compatible with v3, nothing happens. If it is compatible with frozen v2, the store migrates. **Anything else is refused** (`unrecognizedStoreVersion`), and nothing is inferred or changed.
2. It confirms that an inferred v2→v3 mapping exists before touching anything.
3. It opens the v2 store read-only and fingerprints every v2 row and attachment byte, including existing photo assets.
4. It copies the v2 store to `Backups/RoamReadyManaged-v2.sqlite` using `replacePersistentStore`, which includes WAL and external-storage files.
5. Core Data performs an **in-place** lightweight migration through an `NSStagedMigrationManager` stage that is handed the frozen v2 and v3 models directly. The models are built in code, so there is no compiled `.momd` for Core Data to discover. In-place migration keeps persistent history and CloudKit mirroring metadata. A copy-to-new-store migration would discard them and force a full re-upload.
6. It re-fingerprints the migrated store and records `managedSchemaV3 = migrated-from-RoamReady.Managed.v2` in device-only metadata.

Migration always runs during the local-only bootstrap open, before mirroring can start.

If the app stops after step 5, the next launch re-verifies the converted store against the preserved backup. If verification ever fails, the marker becomes `verification-failed` and the library refuses to open on every launch. A damaged library is never mirrored, and the backup is kept for recovery.

Before testing or shipping cloud sync with this build, re-run the developer-only `initializeCloudKitSchema` harness and deploy the two new record types to production (see [offline-storage.md](offline-storage.md#icloud-setup)). Additive entities are compatible with existing mirrored records.

**Adding a version later:** add `v4()`, keep `v3()` unchanged, add a v3→v4 stage to `stagedMigrationManager()`, extend `prepare` to recognize v3 stores, freeze v3 in a shape test, and add fixture-based migration tests.

## API for other work orders

The contract is `CampCore.DocumentRepository`. It is portable and Foundation-only. `CampPersistence.SQLiteStore` conforms with the Core Data implementation. `InMemoryDocumentRepository` applies the same `DocumentPolicy`, for previews and portable tests.

```swift
public protocol DocumentRepository: Sendable {
    func documents(ownedBy owner: DocumentOwner?) async throws -> [ManagedDocument]   // nil = all owners
    func document(id: UUID) async throws -> ManagedDocument?
    @discardableResult func addDocument(_ draft: DocumentDraft) async throws -> ManagedDocument
    @discardableResult func updateDocument(id: UUID, metadata: DocumentMetadata) async throws -> ManagedDocument
    @discardableResult func attachContent(toDocument id: UUID, source: DocumentByteSource, filename: String) async throws -> ManagedDocument
    func contents(ofDocument id: UUID) async throws -> DocumentContents                // verified bytes in memory (small files)
    @discardableResult func exportContents(ofDocument id: UUID, to url: URL) async throws -> DocumentFile // verified, streamed to a file
    func deleteDocument(id: UUID) async throws
}
```

Key types (all `Sendable` value types):

- `DocumentOwner`: `.rig(UUID)` or `.trip(UUID)`. Rig documents use `profile.rig.id`; trip documents use `trip.id`.
- `DocumentMetadata`: `title`, `category: DocumentCategory`, `notes`, `issuedOn`, `expiresOn`.
- `DocumentSource`: `.file(Data, filename:)`, `.fileAt(URL, filename:)` (streamed; prefer this for anything large), or `.link(URL)`.
- `DocumentMetadata.protection`: `.standard` or `.endToEnd`. Validation raises it to `.endToEnd` for sensitive types.
- `DocumentByteSource`, `DocumentHasher`, `BoundedDocumentWriter`: portable chunked reading, hashing, and bounded writing.
- `DocumentDraft(id:owner:metadata:source:createdAt:)`: `id` and `createdAt` can be supplied to restore an archived document.
- `ManagedDocument`: metadata plus `link`, `file: DocumentFile?`, `availability` (`.offline`, `.awaitingDownload`, `.onlineOnly`).
- `DocumentFile`: `filename` (sanitized), `contentType` (detected), `byteCount`, `checksum` (SHA-256 hex).
- `DocumentError`: localized, user-presentable errors.

In the app, use `CampStore` (`addDocument`, `updateDocument`, `deleteDocument`, `saveLinkedContentsOffline`, `documentFileURL`, `documents(for:)`). It serializes calls with the library lifecycle and keeps `documents` current. `DocumentVaultSection(owner:header:footer:)` is the reusable SwiftUI section.

### Reservation confirmations

```swift
// A confirmation PDF received from a booking flow or share extension:
let confirmation = try await store.addDocument(DocumentDraft(
    owner: .trip(trip.id),
    metadata: DocumentMetadata(title: "Site 42 confirmation", category: .reservation,
                               notes: "Confirmation #A1B2", issuedOn: bookedAt, expiresOn: trip.departure),
    source: .file(pdfBytes, filename: "confirmation.pdf")))

// A provider's booking page: online-only until the user saves a copy.
_ = try await store.addDocument(DocumentDraft(owner: .trip(trip.id),
    metadata: DocumentMetadata(title: "Booking", category: .reservation), source: .link(bookingURL)))
```

Reservations should store their own structured fields (confirmation number, dates, site) on their own record and reference the document's `id`, rather than putting bytes in a reservation entity.

### Backup and recovery

```swift
// Backup: enumerate everything, including unattached documents.
for document in try await repository.documents(ownedBy: nil) {
    archive.write(metadata: document)                       // id, owner, metadata, link, file facts, createdAt
    guard document.file != nil else { continue }            // link-only: metadata is the whole document
    do { try await repository.exportContents(ofDocument: document.id, to: archive.fileURL(for: document.id)) } // streamed
    catch DocumentError.contentNotDownloaded { archive.markPending(document.id) } // never fabricate bytes
}

// Recovery: restore identifiers and creation dates; skip documents that already exist.
guard try await repository.document(id: archived.id) == nil else { continue }
try await repository.addDocument(DocumentDraft(id: archived.id, owner: archived.owner, metadata: archived.metadata,
                                               source: archived.bytes.map { .file($0, filename: archived.filename) } ?? .link(archived.link!),
                                               createdAt: archived.createdAt))
```

A deleted document's identifier is tombstoned, so restoring it returns `duplicateDocument`. Recovery should report that rather than work around it. The current JSON export still excludes documents and photo bytes. The backup work order owns adding them.

## Tests

- Portable (`Tests/CampCoreTests/ManagedDocumentTests.swift`, Linux and macOS): SHA-256 vectors and chunked hashing, streamed file inspection, sensitive-type protection rules, signature detection, invalid imports (empty, oversized, renamed non-documents), filename sanitizing, HTTPS link rules, the bounded download buffer (declared or actual size over the limit, early rejection of web pages, chunked bytes kept intact), metadata validation, unknown categories, and the in-memory repository contract (including missing content).
- Core Data (`Tests/CampPersistenceTests/DocumentVaultTests.swift`, macOS CI): frozen v2 shape and v3 additive hashes, stable checksums for the frozen models, CloudKit model rules and the encrypted-field set, 3 MB original-byte round trip across close/reopen with no network, metadata edits and owner separation, link-only until import and re-import replacement, invalid imports leaving the store unchanged, metadata without downloaded content, tamper detection, deletion and tombstones, duplicate-row reconciliation, explicit v2→v3 migration preserving photos and assets with a backup, interrupted-migration re-verification and fail-closed behavior, refusal of unknown store versions, the new-store marker, sensitive types encrypted in the store with no plaintext in the mirrored attribute, a 30 MB streamed file export, re-encryption when protection is raised and refusal to lower it, detection of flipped, truncated, reordered, cross-document, and wrong-key ciphertext, and encrypted link imports.

## Not yet validated

Two-device CloudKit transfer of large and end-to-end encrypted documents (the key field and asset arriving together), iCloud Keychain reset with encrypted documents, peak memory with 250 MB files, metadata-before-asset timing, quota exhaustion, Quick Look and share behavior on iOS 27 devices, VoiceOver, and file-provider edge cases (for example cloud-only files picked while offline) require provisioned-device testing.
