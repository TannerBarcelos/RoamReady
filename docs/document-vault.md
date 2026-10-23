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
- **Bounded memory, end to end.** No layer handles a whole file as one value, including Core Data and CloudKit:
  - Picked files are copied byte for byte to a temporary file under `NSFileCoordinator`. Photos arrive as files through a `FileRepresentation`, and links stream to disk.
  - Each file version is stored as **1 MiB chunk rows**: one Core Data value and one CloudKit record per chunk. Writes read, hash, and (when protected) encrypt one chunk at a time, saving four chunks per Core Data save and then releasing them.
  - Reads fetch, verify, and release one chunk at a time. Peak memory is a few MiB whatever the file size.
  - A file is shown as available only when every chunk of one version is present. A partially imported file, or a write still in progress, is never exposed.
  - Previews and shares are decrypted and verified into a file, and only a fully verified file is moved into place.
- **Interrupted writes.** Before writing chunks, the device records a device-only marker. The marker is cleared in the same save that makes the document reference the new version. If the app stops first, the next launch deletes that version's unreferenced chunks. Only markers written on this device are considered, so chunks still arriving from another device through CloudKit are never removed.
- **Offline.** Uploaded and downloaded contents live in the Core Data store, so they reopen after relaunch with no network. Quick Look and sharing use a readable, verified copy (decrypted when protected) under `Caches/RoamReadyDocuments/<sha256>/`, with `completeUntilFirstUserAuthentication` data protection. The cache is disposable: it is rebuilt from the store when missing, and it is removed when the library is suspended for an account change.
- **Links.** Only `https://` URLs with a host and no embedded credentials are accepted. `http://` is rejected, not upgraded. A bare host typed by the user gets `https://`.
- **Deletion.** Only `deleteDocument(id:)` deletes. It hard-deletes the content rows, so storage is released and CloudKit deletes the asset. It also leaves an identity-only tombstone: title, notes, link, file facts, and dates are cleared, and the tombstone prevents another device's stale copy from resurrecting the document. Deleted identifiers are never reused (`duplicateDocument`).

## Storage

Document data lives in the existing `NSPersistentCloudKitContainer` **Library** configuration (`RoamReadyManaged.sqlite`), so it mirrors automatically to the private CloudKit database when sync is enabled. No raw SQLite APIs are used, and there is no custom upload queue, retry loop, or CloudKit record code.

| Entity | Purpose |
| --- | --- |
| `RR_document` | Metadata: `id`, `ownerKind`, `ownerID`, `title`, `category`, `notes`, `linkURL`, `filename`, `contentType`, `byteCount`, `checksum`, `issuedOn`, `expiresOn`, `createdAt`, `updatedAt`, plus the shared `key`/`rowID`/`removed`. No binary attributes, so listings never fault bytes. |
| `RR_documentContent` | One row per 1 MiB chunk: `documentID`, `versionID`, `checksum` and `byteCount` (of the whole plaintext file), `chunkIndex`, `chunkCount`, `chunkChecksum` (SHA-256 of the chunk's plaintext), `encryption`, `contentKey` (cloud-encrypted), and `bytes` (Binary Data, **Allows External Storage**). |

Core Data decides whether a given `bytes` value stays inline in SQLite or moves to its private external-storage directory, and CloudKit mirroring decides how it transfers (typically as a `CKAsset`). **Do not assume any particular binary is outside SQLite**, and never read or modify Core Data's external files directly.

**End-to-end encrypted metadata.** `title`, `notes`, `linkURL`, and `filename` set `allowsCloudEncryption`. CloudKit stores them in `encryptedValues`, encrypted with keys in the user's iCloud Keychain, so they are end-to-end encrypted even without Advanced Data Protection. CloudKit can't change a field's encryption after the schema is deployed to production, so this set is fixed once the schema reaches Production; changing it later means new fields.

These metadata fields are not readable in the CloudKit Console, and they can't be queried server-side; mirroring doesn't need that. If the user's iCloud Keychain is reset, CloudKit can't decrypt the existing encrypted values; on-device copies are unaffected. Validate that recovery path on devices.

### Protection

CloudKit's field encryption does not cover assets, and Core Data mirrors large binary values as assets. So file bytes are protected in one of two ways:

| `DocumentProtection` | When | File bytes in iCloud |
| --- | --- | --- |
| `.endToEnd` | Always for **registration, insurance, and reservation** (`DocumentCategory.sensitive`), and opt-in for any other type. | Encrypted on the device before they sync. Readable only by the user's devices. |
| `.standard` | Other types, unless the user opts in. | Encrypted at rest by Apple; end to end only with Advanced Data Protection. |

How `.endToEnd` works:
- `DocumentCipher` (`aes256gcm-chunks-v1`, in the `DocumentVault` module) seals each 1 MiB chunk row with CryptoKit's AES-256-GCM, using a random key for each stored file version. The cipher is Apple's; the app only chooses the key scope and the authenticated data.
- Each chunk's authenticated data binds the document ID, the chunk index, and a final-chunk flag. A chunk moved between documents, reordered, or truncated at a chunk boundary therefore fails, as does any flipped bit or wrong key. This is tested.
- The 32-byte key is stored in `RR_documentContent.contentKey`, marked `allowsCloudEncryption`. CloudKit end-to-end encrypts it with the user's iCloud Keychain.
- There is therefore no separate key management, and no new way to lose data beyond the iCloud Keychain reset that already applies to encrypted fields.
- The checksum always describes the plaintext, so original-byte verification is unchanged.

Rules:
- **Never lowered.** A repository never lowers a document's protection. Changing a document to a sensitive type, or opting in, re-encrypts the existing file and replaces the unencrypted copy. Changing it back to a non-sensitive type keeps it encrypted.
- **Needs the file.** Raising protection requires the file on this device; otherwise it fails with `protectionNeedsContent`.
- **Earlier copies.** When protection is raised, the unencrypted chunk rows are deleted in the same save that switches to the encrypted version. Core Data then deletes their CloudKit records and external files. Both stores also open with SQLite `secure_delete` (set through Core Data's `NSSQLitePragmasOption`), so removed inline bytes are zeroed rather than left in free pages.

  What the app cannot erase:
  - **Device backups** (iCloud Backup or a computer) taken before the change.
  - **Apple's server-side asset retention** after a record is deleted, whose timing Apple controls.

  This is why the document type is required at import: sensitive files are encrypted before their first save, so for them no unencrypted copy ever exists.
- **On the device.** The local store holds the key next to the ciphertext. On the device, data is protected by iOS Data Protection; the end-to-end protection applies to iCloud.

Changing the sensitive set later is safe: it only affects documents saved or edited afterwards. Existing encrypted documents stay encrypted.

Both entities follow the mirrored-model rules: every attribute is optional or has a default, with no uniqueness constraints and no relationships. Ownership is a string pair, not a relationship. Duplicate logical rows, which are possible without unique constraints, resolve as they do elsewhere in the library: any tombstone wins; otherwise the lowest `rowID` wins.

On a new device, document metadata can arrive before its content row. That document reports `availability == .awaitingDownload`, and `contents` throws `contentNotDownloaded` until Core Data imports the bytes. A remote-change notification refreshes the list.

## Schema

`Sources/CampPersistence/LibraryModel.swift` builds the model in code. `RR_document` and `RR_documentContent` sit beside the library's record entities in the mirrored `Library` configuration. `LibraryStoreDocumentTests.testRecordEntitiesStoreExactlyTheirDeclaredFields` and `testDocumentEntitiesAreCloudKitCompatibleAndMirrored` pin the attribute set, the CloudKit rules, and exactly which fields are cloud-encrypted.

The schema can change freely until it is promoted to CloudKit Production (#6); after that, follow the additive-only rules in [offline-storage.md](offline-storage.md#managed-persistence). In particular, the set of `allowsCloudEncryption` fields can never change once deployed. Before testing cloud sync, run the developer-only `initializeCloudKitSchema` harness (see [offline-storage.md](offline-storage.md#icloud-setup)).

## API for other work orders

The contract is `DocumentVault.DocumentRepository`. It is portable and Foundation-only. `CampPersistence.LibraryStore` conforms with the Core Data implementation. `InMemoryDocumentRepository` applies the same `DocumentPolicy`, for previews and portable tests.

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

A deleted document's identifier is tombstoned, so restoring it returns `duplicateDocument`. Recovery should report that rather than work around it. ### Export

Profile › **Prepare export** creates `RoamReady Export.zip` using `LibraryStore.exportArchive(to:)`. It contains:

| Path | Contents |
| --- | --- |
| `library.json` | Trips, checklists, notes, and saved campgrounds. |
| `documents.json` | Every document's details and an `ExportedDocument.Status`: `included`, `linkOnly`, or `notDownloaded`. |
| `Documents/` | Each included document's verified original file. |

Files are written chunk by chunk and zipped by `NSFileCoordinator`'s `.forUploading` option; no archive code ships in the app. End-to-end encrypted documents are exported **readable**, and the UI says so: the archive is the user's own copy, outside iCloud's protection.

The archive is a portable copy. Importing it back (recovery) belongs to the backup work order, which can use `documents.json` with the `DocumentDraft` restore pattern above. Trip photo bytes are still shared individually, not included.

## Tests

- Portable (`Tests/DocumentVaultTests/`, Linux and macOS): SHA-256 vectors and chunked hashing (CryptoKit on Apple platforms, Apple's swift-crypto on Linux), AES-GCM chunk sealing bound to document, position, and final flag (`DocumentCipherTests`), streamed file inspection, the fixed-size chunk reader, sensitive-type protection rules, signature detection, invalid imports (empty, oversized, renamed non-documents), filename sanitizing, HTTPS link rules, the bounded download buffer (declared or actual size over the limit, early rejection of web pages, chunked bytes kept intact), metadata validation, unknown categories, and the in-memory repository contract (including missing content).
- Core Data (`Tests/CampPersistenceTests/LibraryStoreDocumentTests.swift`, macOS CI): the declared field mapping, CloudKit model rules and the encrypted-field set, 3 MB original-byte round trip across close/reopen with no network, metadata edits and owner separation, link-only until import and re-import replacement, invalid imports leaving the store unchanged, metadata without downloaded content, tamper detection, deletion and tombstones, duplicate-row reconciliation, sensitive types encrypted in the store with no plaintext in the mirrored attribute, a 30 MB streamed file export, re-encryption when protection is raised and refusal to lower it, detection of flipped, truncated, reordered, cross-document, and wrong-key ciphertext, encrypted link imports, files stored as bounded chunk rows, missing chunks reported as not downloaded, interrupted writes removed only by the device that started them, secure delete enabled, and the zip export's manifest and verified files.

## iCloud status per document

`LibraryStore.cloudStatus(ofDocument:)` returns one of three values:
- `.localOnly`: sync is off.
- `.inICloud`: the document row and every chunk of its current file have CloudKit records, per `NSPersistentCloudKitContainer.records(for:)`.
- `.waitingToUpload`: otherwise.

The detail screen shows it, and it refreshes when sync events arrive. It reflects Core Data's mirroring metadata on this device. A metadata edit made after the first upload isn't tracked separately, because Core Data doesn't expose per-record pending-export state.

## Not yet validated

Two-device CloudKit transfer of large and end-to-end encrypted documents (the key field and asset arriving together), iCloud Keychain reset with encrypted documents, peak memory with 250 MB files, metadata-before-asset timing, quota exhaustion, Quick Look and share behavior on iOS 27 devices, VoiceOver, and file-provider edge cases (for example cloud-only files picked while offline) require provisioned-device testing.
