# Document vault

[Documentation index](README.md)

RoamReady stores manuals, registration, insurance, warranties, service records, reservation confirmations, and other paperwork as `StoredDocument` models. Onboarding, rig documents, trip documents, and Unattached documents use the same import and storage path.

## Import and memory

- **Files:** `.fileImporter` supplies a security-scoped provider URL. `DocumentImport` coordinates access on a worker task and copies the file into an app-owned temporary directory before the provider callback ends.
- **Photos:** `PickedImage` uses `Transferable.FileRepresentation` with the system Photos picker and `.current` encoding. It copies the temporary representation before returning. Documents retain their original encoding; trip/rig photos are downsampled from the staged URL with ImageIO to JPEGs of at most 2560 pixels.
- **HTTPS links:** remain online-only until **Save a copy for offline use** downloads and imports a PDF or image. The source link is retained.

`ImportFile` copies in bounded chunks, enforces the size limit even when provider size metadata is missing or stale, and removes its staging directory when its last owner releases it (including Cancel and failures). iOS Data Protection applies to staging files. No persistent upload folder or custom transfer queue exists.

The app accepts files and selected photo originals up to **50 MiB** (`DocumentPolicy.maximumByteCount`). This is an app memory/storage limit, not a claim about native CloudKit's maximum asset size. Documents are detected by signature, not filename. Streaming inspection hashes in bounded chunks without retaining the whole document in view state.

SwiftData's binary attributes accept `Data`, so a bounded document is still materialized when saved. Reading and hashing that payload run off the UI thread; model insertion does not repeat the hash. This is not a zero-memory or streaming SwiftData API. Large file imports, unsupported files, cancellation, provider failures, and peak memory still need physical-device acceptance.

## Apple-managed storage and encryption

| Model | Holds |
| --- | --- |
| `StoredDocument` | Title, category, notes, dates, link, original filename/type/size/checksum, and optional rig/trip ownership. |
| `DocumentContent` | Original bytes in `protectedBytes`, marked `@Attribute(.externalStorage, .allowsCloudEncryption)`. |
| `Rig` / `TripPhoto` | New JPEGs in `protectedPhoto` / `protectedImage`, with the same attribute options. |

SwiftData owns the external files adjacent to its database. Its CloudKit mirroring automatically maps large values to assets and manages upload, download, retry, and deletion. Small values are covered by the encrypted-field option; CloudKit automatically encrypts private-database assets. Do not inspect or manipulate SwiftData's storage files, create separate CKAssets, or add an S3 transfer path.

Document `title`, `notes`, `link`, and `filename` also use `.allowsCloudEncryption`. Encryption applies when syncing to the private CloudKit database; local files rely on iOS Data Protection. There is no per-category encryption toggle and no new application-level encryption or key generation. iCloud Keychain loss/reset and cloud recovery follow Apple's behavior and require signed-device testing.

Apple references:

- [SwiftData external storage](https://developer.apple.com/documentation/swiftdata/schema/attribute/option/externalstorage)
- [SwiftData cloud encryption](https://developer.apple.com/documentation/swiftdata/schema/attribute/option/allowscloudencryption)
- [Syncing model data across a person's devices](https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices)
- [Core Data's mapping of large values to CloudKit assets](https://developer.apple.com/documentation/coredata/reading-cloudkit-records-for-core-data)
- [Encrypting User Data — Use Assets](https://developer.apple.com/documentation/cloudkit/encrypting-user-data)
- [Photos picker — file representations for large/multiple selections](https://developer.apple.com/documentation/photokit/bringing-photos-picker-to-your-swiftui-app)

## Existing libraries and schema

CloudKit doesn't permit changing an existing field from unencrypted to encrypted. The encrypted content/photo attributes are therefore **new optional fields**. Existing `DocumentContent.bytes`/`key`, `Rig.photo`, and `TripPhoto.image` remain readable. Do not remove those fields or change their encryption settings in a production schema.

Older app-encrypted documents are opened by the read-only `LegacyDocumentSealing` AES-GCM decoder. New writes never generate keys or seals. Replacing a document writes its verified original bytes to the new encrypted field and clears that document's legacy bytes/key. Editing metadata does not rewrite or require downloading the attachment. Legacy protection metadata remains accurate until content is replaced; legacy unmarked binary fields may contain inline data or automatically encrypted assets, so they must not be described as uniformly lacking asset encryption.

`StoredDocument.includeInAssistant` (`Bool`, default `false`) stores the per-document Assistant opt-in for Other documents. It is an additive, unencrypted, non-unique attribute; older records read as off, and no existing attribute changed. The CloudKit schema has not been deployed to Production yet (owner-confirmed Oct 29, 2026), so this attribute ships in the initial schema: it must be present in the Development schema before the first Production deployment. After that deployment only additive changes are allowed. Eligibility ignores it for every category except Other.

No bulk rewrite is performed. Old app builds do not understand the new fields; test and deploy compatible client versions. Exercise every new field in a signed development build, inspect the generated CloudKit schema, and promote it before releasing these clients. The default development build remains local-only until a real CloudKit container and signing capabilities are configured.

## Availability, preview, and export

Files save locally first and open offline after import/download. Metadata can arrive before its bytes. A legacy encrypted document is ready only after both its bytes and key arrive. Links without an imported copy remain online-only.

Reads check original size and SHA-256. Quick Look and sharing capture a Sendable content snapshot on the model context's actor, then verify/decrypt and write a protected disposable cache file on a worker task. Cached previews are regenerated from verified content, so a same-size corrupted cache file is not trusted. Cancellation prevents stale preview results from replacing a newer view state.

Deleting a document cascades to its content. Deleting a trip/rig retains documents as unattached. Profile › Settings exports `RoamReady Export.zip` with `library.json`, `documents.json`, and verified original files under `Documents/`. `library.json` is schema version 3, which added rig registration (VIN, plate, region) and checklist step priority and notes. Rig photos are left out. Encrypted documents are exported readable, as stated in the UI. There is no restore/import workflow for that archive.

## Validation

`DocumentVaultTests` cover streaming inspection, format/signature checks, exact original bytes, app-owned staging after provider URL removal, cleanup, limits, metadata/HTTPS validation, and fixed legacy encryption fixtures with wrong-key/tamper failures. `CampPersistenceTests` cover encrypted attribute configuration (including small inline payloads), exact content, missing/corrupted content, metadata editing without bytes, legacy document/photo reads, replacement without app keys, persistence/reopen, cascade rules, and export.

Provisioned-device release checks include two-device transfers of small and large attachments, metadata before bytes, legacy key arrival, offline imports, reconnection, quota exhaustion, iCloud Keychain reset, provider/Photos failures and cancellation, peak memory near the file limit, Quick Look/sharing, and VoiceOver. CI verifies model behavior and compilation; it cannot establish live CloudKit encryption/delivery.
