# Document vault

[Documentation index](README.md)

RoamReady stores rig manuals, registration, insurance, warranties, service records, reservation confirmations, and other paperwork as `StoredDocument` models in the SwiftData library. Any feature that needs attachments uses these models; it does not add its own storage, file cache, or transfer path.

## What users can do

| Where | Behavior |
| --- | --- |
| Onboarding, step 2 ("Your rig") | Optional **Manuals & paperwork** section. Documents attach to the rig being created. |
| Profile › Rig documents | Add, preview, share, edit, and delete rig documents. Works offline. |
| Trip details › Confirmation & documents | The same controls for documents attached to the trip. |
| Profile › Unattached documents | Documents whose trip or rig was deleted. Deleting a trip never deletes its documents. |

Sources:

- **Files** from the system document picker (`.fileImporter`, PDF or image types), read through `NSFileCoordinator` so file-provider files download first.
- **Photos** from the system photo picker with `preferredItemEncoding: .current`, so the original encoding (for example HEIC) is kept.
- **HTTPS links.** A link stays online-only until the user picks **Save a copy for offline use**, which downloads it with `URLSession` and stores the contents; the link is kept. Only an HTTPS PDF or image within the limit is accepted.

Files are at most **50 MB** (`DocumentPolicy.maximumByteCount`). The type is detected from the bytes, not the extension, so a renamed web page is refused.

Each document has a title, a **type** (`manual`, `registration`, `insurance`, `warranty`, `maintenance`, `reservation`, `other`, plus unknown future values, which are preserved), notes, an optional issue date, and an optional expiration date. The type has no default: it decides how the file is protected, so the user chooses it before saving. Detail screens provide Quick Look, a share sheet, link opening (disabled offline), and deletion behind a confirmation.

## Storage

| Model | Holds |
| --- | --- |
| `StoredDocument` | Details, the original file's name, type, size, and SHA-256 checksum, and its owner (`rig`, `trip`, or neither). No binary data, so lists never load file bytes. |
| `DocumentContent` | `bytes` (`@Attribute(.externalStorage)`) and `key`. Deleted with its document. |

SwiftData decides where external-storage bytes live, and CloudKit mirroring transfers them as assets. Never read or change SwiftData's files directly.

**End-to-end encrypted fields.** `title`, `notes`, `link`, `filename`, and the file `key` use `.allowsCloudEncryption`: CloudKit stores them in `encryptedValues` with keys in the user's iCloud Keychain, end to end even without Advanced Data Protection. They are not readable in CloudKit Console. If the user's iCloud Keychain is reset, CloudKit can't decrypt the iCloud copies; on-device copies are unaffected. The set can't change once the schema is in Production.

### Protection

CloudKit's field encryption does not cover assets, so file bytes are protected in one of two ways:

| `DocumentProtection` | When | File bytes in iCloud |
| --- | --- | --- |
| `.endToEnd` | Always for **registration, insurance, and reservation** (`DocumentCategory.sensitive`), opt-in for any other type. | Sealed on the device before they sync; readable only by the user's devices. |
| `.standard` | Other types, unless the user opts in. | Encrypted at rest by Apple; end to end only with Advanced Data Protection. |

`DocumentSealing` (in `DocumentVault`) seals the whole file with CryptoKit's AES-256-GCM and a random key per stored file. The authenticated data is the document's ID, so bytes moved to another document fail to open. The key goes in the cloud-encrypted `DocumentContent.key`, so there is no separate key management. The checksum always describes the plaintext.

Every read (`contents()`) opens the seal and checks the size and SHA-256 against the recorded file. A wrong key, tampering, another document's bytes, or a file that doesn't match throws `contentIntegrity`; nothing unverified is returned.

Rules:

- **Never lowered.** `update(_:)` never lowers protection. Choosing a sensitive type, or opting in, re-seals the existing file in place; changing back to a non-sensitive type keeps it encrypted.
- **Needs the file.** Raising protection needs the file on this device; otherwise it fails with `protectionNeedsContent`.
- **Earlier copies.** Re-sealing replaces the stored bytes; the app can't erase device backups taken earlier or Apple's server-side retention of replaced assets. That is why the type is required at import: sensitive files are sealed before their first save, so no unencrypted copy of them ever exists.
- **On the device.** The local store holds the key next to the ciphertext and relies on iOS Data Protection; the end-to-end protection applies to iCloud.

### Availability

`availability` is `.offline` when the bytes for the current checksum are on this device, `.awaitingDownload` when the details have synced but the bytes haven't (on a new device), and `.onlineOnly` for a link without a saved copy. `contents()` throws `linkOnly` or `contentNotDownloaded` in those cases. Lists update through `@Query` when the bytes arrive.

## API

```swift
// Add a file: inspect the bytes, then attach them to a rig or trip (or neither).
let file = try DocumentPolicy.inspect(data, filename: "Insurance.pdf")
let document = try StoredDocument.add(
    DocumentMetadata(title: "Insurance", category: .insurance),   // sensitive: sealed end to end
    contents: (data, file), trip: trip, in: context)

// Edit details; raising protection re-seals the file.
try document.update(edited)

// Read the verified original bytes.
let bytes = try document.contents()

// Delete. Its content is deleted with it.
context.delete(document)
```

Reservation confirmations attach to the trip (`trip:`); the trip screen lists them. A backup restore would recreate documents with `StoredDocument.add` from `documents.json` and the exported files.

### Export

Profile › **Prepare export** creates `RoamReady Export.zip` (`LibraryExport`), zipped by `NSFileCoordinator`'s `.forUploading` option:

| Path | Contents |
| --- | --- |
| `library.json` | Rigs, trips, checklists, notes, and saved campgrounds. |
| `documents.json` | Every document's details and status: `included`, `linkOnly`, or `notDownloaded`. |
| `Documents/` | Each included document's verified original file. |

End-to-end encrypted documents are exported **readable**, and the UI says so: the archive is the user's own copy, outside iCloud's protection.

## Tests

- Portable (`Tests/DocumentVaultTests`, Linux and macOS): SHA-256 vectors, type detection from bytes, invalid imports (empty, oversized, renamed non-documents), filename sanitizing, HTTPS link rules, metadata validation, unknown types, sensitive types always end to end, standard files stored as they are, sealed files opening only for their own document, and wrong-key, tampering, and mismatched-file failures.
- SwiftData (`Tests/CampPersistenceTests`, macOS CI): files stored exactly and sensitive types sealed, tampered or missing bytes never returned, re-sealing when protection is raised and refusal to lower it, links online-only until saved, documents kept when their trip is deleted, reopening from disk, and the export's manifest and verified files.

## Not yet validated

Two-device transfer of large and end-to-end encrypted documents (key and asset arriving together), iCloud Keychain reset, peak memory with 50 MB files, details arriving before bytes, quota exhaustion, Quick Look and sharing on iOS 27 devices, VoiceOver, and file-provider edge cases (for example cloud-only files picked while offline) need provisioned-device testing.
