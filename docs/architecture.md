# Application architecture

[Documentation index](README.md) · [Design](design.md) · [Build and validation](validation.md)

## Overview

RoamReady is a native SwiftUI app with a local SwiftData library and optional Apple-managed private CloudKit mirroring. Core editing works without a network or app account. Online discovery and weather are feature services; camping AI runs on device when eligible.

The app targets iOS 27.0 on iPhone and iPad, and Mac through Mac Catalyst. The local Swift package uses Swift tools/language version 6 and lower platform floors (iOS 17/macOS 14) so shared logic can be tested independently. Those package floors do not lower the app's deployment target.

## Package boundaries

[Package.swift](../Package.swift) defines five libraries (plus the C target `CSQLiteVec`) and their test targets:

| Module | Dependencies | Responsibilities |
| --- | --- | --- |
| `CampCore` | Foundation | Shared rig/trip rules and form drafts, booking/site validation, checklist templates, campground lists, Assistant availability and request preparation, and campground identities. |
| `Campgrounds` | `CampCore` | Apple Maps place model, website/phone links, cleaned search text, and result merging. |
| `DocumentVault` | CryptoKit | Document types/import policy, bounded temporary files, SHA-256 integrity, and read-only legacy AES-GCM decoding. |
| `DocumentSearch` | `CSQLiteVec`, system SQLite | The document Assistant's search index: a separate, disposable SQLite file (never SwiftData's store) with FTS5 and sqlite-vec. Versioned schema, staged per-document generations published atomically, lexical and vector readiness tracked separately, scoped lexical and KNN search with a document ID allow-list applied during candidate selection, safe FTS expressions, and an `EmbeddingProvider` protocol with a deterministic test fake. Embedding revision and dimension come from the provider at runtime. It also owns the index lifecycle rules: `DocumentIndexCoordinator`, `ReconciliationPlan`, and the `DocumentIndexSource` protocol (see Index lifecycle below). |
| `AssistantEval` | `DocumentSearch`, `CampCore` | The Assistant's retrieval eval: synthetic corpus, runner, and JSON/Markdown reports. Not linked by the app. The `assistant-eval` executable runs it with Apple embeddings. See Retrieval eval below. |
| `CSQLiteVec` | system `libsqlite3` | The vendored sqlite-vec v0.1.9 amalgamation with a one-function registration wrapper. Not edited; see its [provenance note](../Sources/CSQLiteVec/PROVENANCE.md). |
| `CampPersistence` | `CampCore`, `DocumentVault` | SwiftData models, `LibraryStore`, `ICloudSettings` (preference and passive activity), model-level library operations, document storage, and zip export; implementation requires SwiftData on Apple platforms. The Assistant's document eligibility rule (`AssistantDocumentEligibility`) and live scope (`Rig.generalAssistantScope()`) also live here, with Sendable index jobs captured on the model context. |

The native app links these local products and Apple frameworks. There are no external package dependencies and no downloaded code. The one deliberate third-party dependency is the C source of [sqlite-vec](https://github.com/asg017/sqlite-vec) v0.1.9 (Alex Garcia; dual MIT / Apache-2.0, used under MIT), vendored unmodified in `Sources/CSQLiteVec` with both license texts and a note recording the release URL and SHA-256 checksums. It is compiled into the app and linked against the system SQLite, so it adds no framework, binary, or network access. It handles only text the app already holds on the device.

### Document answers (first slice)

The path from a file to a cited answer, by layer:

| Layer | Owns |
| --- | --- |
| `CampCore` | The bounded request structures in `DocumentEvidence`: `DocumentSource` (a request-local ID such as `S1` mapped to document UUID, checksum, title, category, page, label, and section), `DocumentEvidence.make` (validates each search result against the live library right before the prompt is built: the document exists, is still in scope, and still has the checksum the passage was indexed from), `DocumentRelevance` (the no-evidence threshold), and `DocumentCitations` (resolves `[S1]` / `[S1, S2]` markers and drops unknown IDs). `CampingHelpRequest` frames excerpts as `BEGIN DOCUMENT EXCERPTS (untrusted ...)` data, neutralizes forged delimiters and IDs inside them, and the compact retry keeps only the best excerpt, so it can't cite what it dropped. `CampingGeneration.answer` validates against the prompt that actually reached the model. |
| `DocumentSearch` | `PassageChunker` (page-aware passages with section headings, bounded to 900 characters, `version`ed), the index (staged per-document generations; passages carry page ordinal, printed label, section, and OCR confidence; hits carry the indexed checksum; schema version 4, older files are refused and rebuilt), `OCRPolicy` (the caps, text-layer usability, table-aware line layout, rotation choice, `OCRBudget`) and `DocumentTextExtractor` (the PDFKit/ImageIO/Vision adapter, compiled only where those exist, with outcomes `ready`, `noUsableText(empty/encrypted/unreadable/tooLarge/noText)`, and `retryLater`), `IndexedDocumentRecord.isCurrent` for reuse after relaunch, and `DocumentIndexCoordinator` (index lifecycle). |
| `CampPersistence` | `AssistantDocumentEligibility` (the one rule: Manual, Service & maintenance, Warranty, Reservation, a PDF or image saved on the device) and the scopes: general (documents attached directly to the active rig) and trip (the trip's documents plus its rig's, archived or not). `AssistantScopeTarget` snapshots rig/trip identity per request and `ModelContext.documentScope(for:)` re-reads the library from it. `indexableDocuments()` lists every candidate with its `IndexAvailability` (ready, waiting for download, unsupported). `CampCore` holds the scope text and `AssistantConversationRules` (only the current scope's turns reach a prompt; retrieval uses prior user turns only). |
| App | `AppleEmbeddingProvider` (`NLEmbedding` English sentence vectors; revision and dimension read at runtime, unavailable means lexical-only), `DocumentAssistantIndex` (owns the coordinator for a library session and builds search allow-lists from the live scope), `LibraryDocumentSource` (the SwiftData-backed `DocumentIndexSource`), `DocumentSourceView` (PDFKit viewer at the cited page). |

`LibraryController` owns the index for a library session, not the Assistant sheet, so indexing carries on after the sheet closes. Nothing logs document text, vectors, or questions.

### Index lifecycle

`DocumentIndexCoordinator` (an actor in `DocumentSearch`) is the only writer. It keeps `Application Support/Search/documents.sqlite` true to the library, with file protection and the backup-exclusion flag, and it has no dependency on SwiftData: the app hands it a `DocumentIndexSource` that lists library documents (ID, checksum, availability) and reads one document's text, so the rules are covered by `swift test` against a fake source.

- **Generations.** A document is indexed into a *staged* generation (`beginStaging`, `stage` in page-aligned batches of about 50 passages, `commit`). Staged passages carry a generation number no document row references, so no query can see them. `commit` removes the previous generation and points the document row at the staged one in one transaction. A crash or cancellation mid-index leaves the old generation intact and the unfinished one invisible; opening the index discards it. Schema version 3.
- **Stale rows can't be evidence.** Search takes `live`, a map from document ID to the checksum the library holds now, and applies it during candidate selection in both the lexical and the vector query. A replaced file's old passages, and the rows of a deleted, reassigned, or opted-out document, are never candidates even if still on disk, and no pass has to run first. `DocumentEvidence.make` repeats the live check right before the prompt is built. Stale rows are reclaimed by the next pass.
- **Reconciliation.** `ReconciliationPlan.make` decides from metadata alone (library list against `indexedDocuments()`): remove what is gone or unreadable, queue what is missing, replaced, or was indexed under an older extraction version, and report the rest. No file bytes are read for documents that are already current. Passes run when the library opens (`startup`), after every save (`change`), and when the app becomes active (`foreground`, folded if one ran in the last 10 seconds). Requests during a pass fold into one more pass, so there is one job at a time and never two for the same document.
- **States.** `documentStates()` and `stateUpdates()` expose `[String: DocumentIndexState]`, a `Sendable` value: queued, extracting, indexing(done, of), ready, waitingForDownload, noUsableText, englishOnly, unsupported, retryableFailure. Outcomes with nothing to search are stored with the document, so they survive relaunch and aren't read again until the file or the rules change. `DocumentAssistantIndex.statuses` mirrors this by document UUID for a later status screen.
- **iCloud metadata before bytes.** A document whose details arrived without its file is `waitingForDownload`, never a failure, and isn't read. While any document waits and the app is active, the coordinator looks at the library again every 30 seconds and indexes the document when its bytes land, with no other trigger.
- **Checkpoints and interactive work.** Between staging batches, before each job, and before each vector batch the coordinator checks cancellation and the session, and waits while a question is being searched, so indexing never makes a question wait behind a long job.
- **Failures are bounded.** A read or write error marks the document `retryableFailure`. Saves retry it up to three times per session; startup and foreground give it a fresh set.
- **Embedding revision.** Vectors carry the provider's revision and dimension and are used only when they match it. After a change, search keeps answering lexically; the next pass retires the incompatible vectors and re-embeds in batches, cancellable between batches.
- **Corruption.** Opening runs SQLite's `quick_check`. A file that fails it, isn't a database, or has another layout is deleted along with its journal sidecars and started fresh; a corruption error during a pass or search does the same, and every document is read again. Only index files are removed; the originals are in the library.
- **No index until needed.** An empty library, or one whose documents aren't readable yet, leaves no index file on disk.
- **Erase.** See [erasing data](erase-data.md#the-search-index): `erase()` stops the writer, awaits it, then deletes. Until `open()` starts a new session, reconciles, polls, and searches do nothing.

The retrieval threshold is intentionally simple. Ranking always returns the nearest passages, so relevance is decided separately: a passage qualifies if it contains the exact fault code the question names (letters plus digits such as `E4`; a different code never qualifies), or a bare number from the question, or at least half of the question's significant words after a light stem. Apple's sentence-embedding distances for related and unrelated pairs overlapped when measured (roughly 1.13–1.20 related, 1.20–1.42 unrelated), so vectors improve ranking only. The synthetic eval cases in `Tests/DocumentAssistantEvalTests` are the regression suite for changing this rule; they run against both lexical-only and vector-assisted search. Retrieval quality on real manuals is not yet measured.

### Retrieval eval

`Sources/AssistantEval` holds the retrieval eval: a versioned synthetic corpus (`Corpus/corpus-v1.json`: invented rigs, trips, and paperwork, no private documents), the runner, and the JSON and Markdown reports. Each question names its scope and its expected evidence by document, document version, page, and a quoted span, grouped into interchangeable evidence units. Chunk IDs never appear in labels. Cases are split into a `dev` and a `heldout` subset, and into `required` cases (a release gate) and `challenge` cases (known-hard, or waiting on a feature such as OCR normalization or language gating), which are aggregated and reported apart.

The runner indexes the corpus into a throwaway `DocumentSearchIndex`, searches with the case's scope allow-list, validates against the live library with `DocumentEvidence.make`, builds the `CampingHelpRequest`, and audits the result per case: Hit@5, Recall@5 (labeled units found in the top 5 over units labeled; overlapping labels merge into one unit), MRR over answerable cases only, exact-code success, scope or exclusion violations, stale evidence, no-evidence false positives, citation validity (including forged IDs and the compact retry), and prompt isolation. It does not run the language model; generated answers stay a manual rubric review, and reports say so.

```bash
swift test --filter DocumentAssistantEvalTests            # deterministic: lexical search and fake embeddings; runs in the regular package tests
swift run assistant-eval --mode apple                    # manual: Apple's on-device sentence embeddings; writes EvalReports/retrieval-apple-all.{json,md}
swift run assistant-eval --mode lexical --subset heldout # also: --mode fake, --subset dev, --out DIR, --corpus FILE
```

`assistant-eval` exits 0 when every required case passed, 1 when one failed, and 2 when the embedding model is unavailable on the machine. That last case is reported as "not run" with no scores and is never a pass. `EvalReports/` is git-ignored. The same command is available as the manual-only "Assistant eval" workflow; it is not part of the regular CI triggers. The full guide and walkthrough are a later issue.

### Search package decision

`DocumentSearch` ships as its own local package product, with the C code in a sibling `CSQLiteVec` target. It was not folded into `CampPersistence` or another existing target. Evidence from the foundation work:

- **System SQLite is enough.** The SDK's `libsqlite3` provides FTS5 (the schema's `CREATE VIRTUAL TABLE ... USING fts5` succeeds) and JSON1 on macOS (the `swift test` host) and in the iOS Simulator SDK; there is no bundled SQLite copy. The C target defines `SQLITE_CORE`, so sqlite-vec calls the system library directly and is registered per connection by calling `sqlite3_vec_init` (wrapped as `csqlitevec_register`), not through `sqlite3_auto_extension` or runtime extension loading.
- **Linking passes on every platform.** `swift test` (macOS) runs the file-backed insert, FTS query, KNN query, close/reopen, and delete cycle. The `RoamReady` scheme built unsigned for `platform=iOS Simulator,name=iPhone 18 Pro` and `platform=macOS,variant=Mac Catalyst` with the product linked through the same local-package reference as the other products. A DEBUG-only launch argument, `-document-search-smoke`, ran the same cycle inside the app and logged `DOCUMENT-SEARCH-SMOKE: PASS (sqlite-vec v0.1.9)` on the iOS 27.0 simulator and in the Mac Catalyst app. iPad uses the same iOS slice and binary as iPhone, so it needs no separate link check.
- **Why a separate package.** The C target and its linker setting stay out of `CampCore`, `DocumentVault`, and `CampPersistence`, which are Foundation, CryptoKit, and SwiftData only, so their tests and builds are unchanged. The search index must never open SwiftData's store, and a package boundary enforces that: `DocumentSearch` depends on nothing else in this repository.
- **No new CI.** Package tests are picked up by the existing `swift test` in the Mac workflow, and the iOS and Mac app builds already compile every linked product. No simulator is booted in regular CI.

The index file is disposable: if it can't be opened or reports a newer schema, delete it and rebuild from the documents. Extraction (PDFKit) and the Apple embedding adapter sit outside this package's interface, in the app; chunking is in the package.

## Source layout

| Path | Contents |
| --- | --- |
| [Camp/App/](../Camp/App/) | Entry point, root view, tabs, and `LibraryController`, which opens the container, surfaces save failures, and handles explicit erase. |
| [Camp/Features/](../Camp/Features/) | Feature views and services for Home, Trips, Checklists, CampFinder, Documents, Memories, Profile (including iCloud settings), Onboarding, Weather, and Assistant. |
| [Camp/Shared/](../Camp/Shared/) | Connectivity gate, iPhone Duo hinge detection, and small shared views. |
| [Sources/](../Sources/) | Swift package modules. |
| [Tests/](../Tests/) | One test target per package module, plus the app's `RoamReadyUITests` (run by the Xcode scheme, not `swift test`). |
| [RoamReady.xcodeproj/](../RoamReady.xcodeproj/) | Native app project and shared RoamReady scheme. |
| [Config/](../Config/) | Optional signed-build capability configuration. |
| [.github/workflows/](../.github/workflows/) | `app.yml`: simulator builds and UI tests on iPhone and iPad (a device matrix); the iPhone job adds configuration checks and a Release build. `mac.yml`: package tests and Debug/Release Mac Catalyst builds on macOS. |
| [docs/](./) | Product, design, engineering, validation, and planning guides. |

The Xcode project uses filesystem-synchronized groups: new source files under `Camp/` join the app target automatically. `Info.plist` and entitlements are excluded from resource copying.

## State and data flow

1. `RoamReadyApp` creates `LibraryController` and connectivity state, then opens the library.
2. The library exposes a SwiftData model container. If opening fails, the root shows an error and retry.
3. `RootView` queries for a profile, displaying onboarding or four tabs: Home, Trip (add sheet), Camp Finder, and Profile. The shared circular Assistant accessory opens a sheet on supported AI devices. Home lists current/upcoming trips; Profile links to completed trip history and saved campgrounds, with app preferences and library tools in its Settings sheet.
4. Screens read models with `@Query`. Forms edit drafts such as `TripDraft`, `RigDraft`, and `ChecklistStepDraft`, then validate and apply them.
5. Model extensions enforce library rules. `LibraryController.save()` performs deliberate saves and surfaces failures; scene transitions also trigger saving.
6. If configured and enabled at launch, Apple mirrors the library to the device's private CloudKit database and manages connectivity, retries, and account transitions.

There is no raw SQL, custom CloudKit record transport, hosted user-data service, or app account/session backend. See [storage and synchronization](offline-storage.md) for model relationships, schema constraints, conflict behavior, and identity transitions.

### iPhone Duo workspace

Each window's root applies `observesDuoWorkspace()` ([DuoWorkspace.swift](../Camp/Shared/DuoWorkspace.swift)). It hosts a `UIHingeInteraction` (iOS 27.1, guarded by availability and excluded from Mac Catalyst) and feeds every update, including the initial one, into `HingeCapability` in `CampCore`. The first non-nil hinge turns the scene's Duo workspace on; it stays on, because a nil report only means the observing view left a hierarchy that provides hinge updates. Screens read the `\.usesDuoWorkspace` environment value. There are no model-name checks or device dimensions; Duo screens adapt with size classes and available space.

`MainTabs` forces a compact horizontal size class everywhere except the Duo workspace, where the scene's own size class passes through. Tab selection, the Add trip and Assistant sheets, and the Assistant conversation stay in `MainTabs`, above the content that resizes. Debug builds force the workspace with `-duo-ui-test`.

Home's root is `HomeWorkspace` ([HomeWorkspace.swift](../Camp/Features/Home/HomeWorkspace.swift)). It owns Home's clock and, on Duo, a `NavigationSplitView` with its selection, a `HomeDestination?` value holding a trip's `PersistentIdentifier` rather than the model. Because this state lives above both columns, it survives the display changing size. `MainTabs` doesn't wrap Home in its stack on Duo. Other iPhones keep Home in that stack with push links. The detail shows the picked trip while it still exists, or else the featured one (`displayedTrip(selected:asOf:)` in `CampCore`). With `-navigation-ui-test`, `-empty-library` keeps the fixture profile and rig but adds no trips.

The device-local appearance preference is stored through `AppAppearance`/`@AppStorage` and applied at the window root. System follows the OS; Light/Dark overrides also apply to navigation and sheets.

## Domain rules

A trip is one campground booking and references its rig. Editing a rig changes the details shown on all related trips; replacing it archives the old rig. New trips copy the rig's default setup/teardown steps, then own their checklist copies independently.

Rig and trip validation is shared through `RigDetails` and `TripDetails` protocols implemented by both drafts and persisted models. `CampCoreTests` exercise those rules without SwiftUI or SwiftData.

Deleting a trip cascades to its steps, photos, and note revisions. Documents are retained as unattached. A rig can be deleted only when unused by trips. See [feature behavior](features.md) and [erasing data](erase-data.md).

## Feature services and network boundaries

| Service | Integration and boundary |
| --- | --- |
| Camp Finder | MapKit campground/RV park points of interest, typed/area searches, and place lookups. Session-only results; saved lists keep Apple identifiers. No server, API key, owned dataset, or live availability. |
| Weather | WeatherKit for location temperature and campground forecasts; saved readings have timestamps and work offline. |
| Camping assistant | Bundled guidance plus Foundation Models after product/device and runtime availability checks. No remote question transfer in v1. |
| Memories | Native camera, PhotosPicker, bounded image import, and system sharing. Cloud-only Photos items may need a download. |
| Documents | System file representations, bounded staging, Quick Look, HTTPS links, verified bytes, and Apple-managed encryption. |
| Sync | SwiftData/CloudKit mirroring, enabled by configuration and a default-on launch preference. Apple owns its runtime lifecycle. |

Connectivity indicates an available path, not successful service authorization or delivery. Local edits never wait for cloud transfer. Capability provisioning, real service reachability, and device behavior are separate acceptance concerns.

## Media and exports

Rig/trip photos are downsampled from picker file representations to at most 2560 pixels and stored as JPEG data using SwiftData external storage and cloud-encrypted fields. They travel with their model through mirroring and are deleted with it. Original imported photos remain in the photo library.

Documents preserve original bytes up to 50 MiB. Content is separate from list metadata and uses SwiftData external storage plus cloud-encrypted fields. Apple handles large-asset encryption and transfer; there are no new app encryption keys. Legacy encrypted files remain readable, and reads verify size and SHA-256. Import inspection and preview verification run off the UI thread. See [document vault](document-vault.md).

Profile › Settings exports `RoamReady Export.zip`: `library.json`, `documents.json`, and verified original files under `Documents/`. Photo metadata/captions are included, not image bytes; photos are shared individually. Exported encrypted documents are readable originals. The export is an explicit user copy, not an implemented restore/import workflow.

## Validation boundaries

Package tests cover shared policies, validation, place identities, search-result merging, document integrity/crypto, and real SwiftData stores. A native simulator build checks Apple SDK compilation; physical devices are still needed for permissions, model availability, iCloud account/asset behavior, accessibility, and release acceptance. See [build and validation](validation.md).

### Scanned documents (OCR)

`DocumentTextExtractor` reads a PDF page by page. A page whose text layer has at least 20 letters or digits and isn't mostly replacement characters is used as is; any other page is rendered and recognized with `VNRecognizeTextRequest` (accurate, en-US), and the reading with more text wins. Image documents are one page (a multi-page TIFF is one per frame), decoded through an ImageIO thumbnail so the full bitmap is never held. Ordinals stay one-based positions in the file, so citations and the viewer agree for mixed PDFs.

Caps (`OCRPolicy`): bitmap at most 2,400 px on the long side, 5,000,000 px, 3x page points, 8-bit gray (about 5 MB, one at a time); 120 recognized pages and 240 s per document; image documents over 64,000,000 px refused; 40 TIFF frames. The 50 MiB file cap bounds stored bytes only, so these bound decoded memory. Peak memory was bounded by construction and by a test that a 14,400 pt page renders within the pixel cap; it was not profiled with Instruments.

Outcomes: empty (no pages), encrypted (locked), unreadable, too large, and no text each record the document as indexed with no passages, so it isn't read again until its checksum changes. A Vision error with nothing else readable is `retryLater`: not recorded, retried on the next sync. A page read upright with little text or low confidence is retried at the other three orientations and a turned reading is taken only if it scores 25% higher. Layout puts lines top to bottom and joins short cells on one row with " | " so table values stay with their labels; long lines (prose columns) are never joined. Per-page confidence (length-weighted line mean; lines under 0.3 are dropped) is stored on every passage of that page, carried through `SearchHit`, `DocumentEvidenceCandidate`, and `DocumentSource`. Below 0.75 the excerpt header says "scanned text, low confidence: may be misread", the instructions forbid stating its numbers as exact, and the UI shows a caution. Known limits: confidence is per page, not per line; two-column prose isn't reordered by column; recognition is English only.
