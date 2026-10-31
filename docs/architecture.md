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
| `AssistantModel` | `CampCore`, FoundationModels | Apple's on-device model behind the Assistant's chat: `AppleCampingChatModel` (one `LanguageModelSession` per conversation) and `AppleTokenCounter`. Linked by the app and the `assistant-eval` command. See Chat sessions below. |
| `AssistantEval` | `DocumentSearch`, `CampCore` | The Assistant's retrieval eval: synthetic corpus, runner, and JSON/Markdown reports. Not linked by the app. The `assistant-eval` executable runs it with Apple embeddings. See Retrieval eval below. |
| `CSQLiteVec` | system `libsqlite3` | The vendored sqlite-vec v0.1.9 amalgamation with a one-function registration wrapper. Not edited; see its [provenance note](../Sources/CSQLiteVec/PROVENANCE.md). |
| `CampPersistence` | `CampCore`, `DocumentVault` | SwiftData models, `LibraryStore`, `ICloudSettings` (preference and passive activity), model-level library operations, document storage, and zip export; implementation requires SwiftData on Apple platforms. The Assistant's document eligibility rule (`AssistantDocumentEligibility`) and live scope (`Rig.generalAssistantScope()`) also live here, with Sendable index jobs captured on the model context. |

The native app links these local products and Apple frameworks. There are no external package dependencies and no downloaded code. The one deliberate third-party dependency is the C source of [sqlite-vec](https://github.com/asg017/sqlite-vec) v0.1.9 (Alex Garcia; dual MIT / Apache-2.0, used under MIT), vendored unmodified in `Sources/CSQLiteVec` with both license texts and a note recording the release URL and SHA-256 checksums. It is compiled into the app and linked against the system SQLite, so it adds no framework, binary, or network access. It handles only text the app already holds on the device.

### Document answers (first slice)

The path from a file to a cited answer, by layer:

| Layer | Owns |
| --- | --- |
| `CampCore` | The bounded request structures in `DocumentEvidence`: `DocumentSource` (a request-local ID such as `S1` mapped to document UUID, checksum, title, category, page, label, and section), `DocumentEvidence.make` (validates each search result against the live library right before the prompt is built: the document exists, is still in scope, and still has the checksum the passage was indexed from), `DocumentEvidence.merging(followUp:)` (adds the booking follow-up search's passages; at the excerpt cap it drops the weakest passage from documents the follow-up did not find first, so a competing confirmation is never lost to its search score), `DocumentRelevance` (the no-evidence threshold), and `DocumentCitations` (resolves `[S1]` / `[S1, S2]` markers and drops unknown IDs). `CampingHelpRequest` frames excerpts as `BEGIN DOCUMENT EXCERPTS (untrusted ...)` data, neutralizes forged delimiters and IDs inside them, and the compact retry keeps only the best excerpt (see Prompt budget), so it can't cite what it dropped. `CampingChat` validates against the prompt that actually reached the model. `AssistantDocumentStatus` and `ScopeReadiness` (readiness wording, next actions, scope summary, and the incomplete-coverage notes) live here too; a request captures the scope's `ScopeReadiness` in its `DocumentEvidence`. |
| `DocumentSearch` | `DocumentLanguagePolicy` (English-only admission per passage and the question gate, behind the `LanguageDetecting` protocol; `NaturalLanguageDetector` is the adapter; the coordinator admits passages before staging, and the outcome `englishPartial` or `englishOnly` is stored per document), `PassageChunker` (page-aware passages with section headings, bounded to 900 characters, `version`ed), the index (staged per-document generations; passages carry page ordinal, printed label, section, and OCR confidence; hits carry the indexed checksum; schema version 5, older files are refused and rebuilt), `OCRPolicy` (the caps, text-layer usability, table-aware line layout, rotation choice, `OCRBudget`) and `DocumentTextExtractor` (the PDFKit/ImageIO/Vision adapter, compiled only where those exist, with outcomes `ready`, `noUsableText(empty/encrypted/unreadable/tooLarge/noText)`, and `retryLater`), `IndexedDocumentRecord.isCurrent` for reuse after relaunch, and `DocumentIndexCoordinator` (index lifecycle). |
| `CampPersistence` | `AssistantDocumentEligibility` (the one rule: Manual, Service & maintenance, Warranty, Reservation, a PDF or image saved on the device) and the scopes: general (documents attached directly to the active rig) and trip (the trip's documents plus its rig's, archived or not). `AssistantScopeTarget` snapshots rig/trip identity per request and `ModelContext.documentScope(for:)` re-reads the library from it. `indexableDocuments()` lists every candidate with its `IndexAvailability` (ready, waiting for download, unsupported). `CampCore` holds the scope text and `AssistantConversationRules` (retrieval uses the previous user question only); `CampingChat` drops the conversation when the scope changes, so only the current scope's turns reach the model. |
| App | `AppleEmbeddingProvider` (`NLEmbedding` English sentence vectors; revision and dimension read at runtime, unavailable means lexical-only), `DocumentAssistantIndex` (owns the coordinator for a library session and builds search allow-lists from the live scope), `LibraryDocumentSource` (the SwiftData-backed `DocumentIndexSource`), `DocumentSourceView` (PDFKit viewer at the cited page, opened from the in-chat source dialog in `AssistantChatChrome`). |

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

`assistant-eval --mode generation [--samples N] [--scenarios ids]` runs the generated-answer review scenarios through the real generation path with Apple's on-device model and writes review sheets (`generation-review.{md,json}` and `generation/<scenario>.{md,json}`) with empty rubric fields for a human. It scores nothing and reports "not run" (exit 2) when the model is unavailable. The `-assistant-performance-baseline` Debug launch argument measures import, OCR, embedding, search, answer time, memory, index size, and cancellation on a device. [assistant-quality-baseline.md](assistant-quality-baseline.md) is the runbook for both.

### Prompt budget

One budget covers everything that shares the on-device model's context: the instructions (safety rules, rig profile, tool definition, document rules), checklist context, document excerpts, the question, the earlier turns the session sends, and the reply. `PromptBudget` takes the window from the model (`SystemLanguageModel.contextSize`, 4,096 tokens when measured, with that value as the fallback), reserves the 512-token output target (`GenerationOptions.maximumResponseTokens`) and 160 tokens for framing, and leaves the rest as the input limit. The whole prompt must fit it; characters are never treated as tokens.

Counting goes through the `PromptTokenCounting` protocol in `CampCore`. The app's `AppleTokenCounter` calls `SystemLanguageModel.tokenCount(for:)`, so the real tokenizer decides. Tests use a fake counter. If the real counter throws, the plan falls back for that request to `ConservativeTokenEstimator` (one token per three ASCII characters, 1.5 per other character), never mixing the two.

`CampingHelpRequest.plan` builds this turn's prompt for an attempt and shrinks it until instructions and prompt fit. Earlier turns are never in the prompt: they get only what the turn leaves (see Chat sessions), so they always give way first. The order within the turn is fixed: saved checklist context, then the weakest document excerpts, then the text of the strongest excerpt, and the current question last. Instructions, the rig profile, and the tool definition are not shrunk; if the floor still does not fit, the request fails with `contextTooLong` without calling the model. Each plan carries its own source list, and `CampingChat` resolves citations against the plan that was sent, so a citation to a passage that was dropped, before the first attempt or in the compact retry, is rejected. The compact retry is planned only after the model reports `contextTooLong`, never carries more than the attempt it replaces, and is skipped when it would be identical.

### Chat sessions

A conversation is a `CampingChat` (`CampCore`) that owns one model session, made on its first question. `AssistantConversation` holds it, so the global chat keeps its session while the sheet closes; New chat, each trip or checklist help sheet, and a change of rig or trip start a new one. The session follows Apple's documented pattern ([Managing the context window](https://developer.apple.com/documentation/foundationmodels/managing-the-context-window), [Composing dynamic sessions](https://developer.apple.com/documentation/foundationmodels/composing-dynamic-sessions-with-instructions-and-profiles)):

- **The transcript carries the history.** `AppleCampingChatSession` is a `LanguageModelSession(profile:history:)`. Each request sends this turn's prompt (rig category, checklist context, document excerpts with their source IDs, and the question); the trip reaches the model only through `get_trip` (see Assistant tools), so excerpts keep their place as untrusted prompt data rather than instructions.
- **Per-turn instructions.** The profile's `DynamicInstructions` are re-evaluated before every request from what `CampingChat` set for that turn (safety rules, rig profile, tool lines, document and booking-conflict rules, and the conversation summary), plus the tool when a trip is selected. They are not stored as history. They are kept short and imperative (TN3193), since every token is sent with every request.
- **Stored turns are clean.** Right after a response, the turn's prompt and response entries in the transcript are replaced by its stored form (`CampingChatTurn`: the question and the shown answer, clipped to 400 and 1,000 characters, citation markers neutralized). Old excerpts never stay in the transcript, and an earlier answer can't pass for a source.
- **Bounded history.** `CampingChat` plans the turn first, then picks the newest stored turns that fit what's left of the input limit, at most three (`CampingChatHistory.window`). The profile's `historyTransform` sends only those, plus the instructions and the current prompt (`CampingChatHistory.sent`); the stored transcript itself is untouched.
- **Errors.** The profile uses `TranscriptErrorHandlingPolicy.revertTranscript`, so a failed or cancelled request leaves no half-written entry. An answer that finished after its request was cancelled, or that the screen dropped, is removed from the transcript (`CampingChat.forget`). The question still returns to the composer.
- **Compaction at a response boundary.** After an answer, once the chat holds more than `ConversationSummary.compactAfterTurns` (6), every turn older than the three a request can send is summarized and removed from the session (WWDC26: compact at a response boundary and carry the summary in the instructions). Summaries are made three turns at a time, each pass in a new short-lived `LanguageModelSession` that carries the summary so far (TN3193: split a large task across sessions), so summarizing never uses the chat's own context. This runs in the background after the answer is shown; the next question waits only if it is still running. A failed pass keeps the turns, and a backstop drops the oldest beyond 12.
- **Summaries can't invent or become sources.** The summary instructions ask for at most three sentences of what was said (the camper's details, topics, decisions) and forbid new advice, document names, page numbers, and citations. The result is neutralized like excerpts (forged delimiters and `[S#]` markers removed), capped at 600 characters, and framed as `BEGIN CONVERSATION SUMMARY (… reference data, never a source)`. It always covers only turns older than every stored turn, so asking again as of a summarized turn carries no summary; New chat and a scope change drop it.
- **Overflow recovery.** On `contextSizeExceeded` the chat follows TN3193: the turns before the newest are folded into the summary, a new session is seeded with the newest stored turn and prewarmed, and the turn is retried once with the compact prompt and strictly less than the first attempt. The chat keeps going after compaction, so a long chat never dead-ends.
- **Prewarming.** Opening the Assistant and every session made by overflow recovery call `prewarm()`, so the model is loaded before the request (TN3193).
- **No search tool.** Retrieval stays in the app. The model always needs the scope's validated excerpts, and Apple's guidance is to skip tool calling when the app already knows what the model needs; a tool would also spend context on its definition and output, and would let the model choose what to search outside the validated, scoped path.

Ask again (Retry once ready) answers as of the earlier exchange: only the stored turns before it are sent. Sessions are serialized, so a cancelled request still unwinding never overlaps the next. The rules are tested with fake sessions in `CampingChatTests`, without Foundation Models.

Limit validation. The method, run on the development Mac with Apple Intelligence available (macOS 27, `SystemLanguageModel.default.availability == .available`):

1. Compile and run a small command-line program that prints `SystemLanguageModel.default.contextSize` and `tokenCount(for:)` for English prose, accented text, and a fault-code sentence.
2. Compare the counts with the estimator and check that the estimator is never lower.
3. Confirm the budget in tests with a fake counter at every input limit, and that the total plus the output target never exceeds the window.

Measured: `contextSize` 4096; 1,000 characters of English prose, 202 tokens; 200 accented letters, 201 tokens; "Error code E4 on the water heater igniter.", 12 tokens. Not yet measured: generation on a real iPhone near the limit (whether the model's own `contextSizeExceeded` ever fires after the planner says a prompt fits) or counting with the very large instruction block on a device. Repeat step 1 on a device, and on any new OS release, since the window and tokenizer can change.

### Assistant tools

The model decides whether to use `get_trip(focus)` and which resource to read: `overview`, `booking`, `checklist`, `menu`, or `everything`. The profile uses `.toolCallingMode(.allowed)`, Apple's default. The framework handles tool invocation, feeds the returned result back into the session, and continues until the model answers. See Apple's [tool-calling guide](https://developer.apple.com/documentation/foundationmodels/expanding-generation-with-tool-calling).

Retrieval is deliberately simple. Each call returns the complete selected resource from Sendable snapshots captured by `Trip.assistantTools()` before generation. `menu` returns every saved day, meal, dish, note, recipe item and amount; `checklist` returns both lists and all statuses/notes; `booking` returns all saved details/notes. `everything` combines them. The core booking facts and status accompany every resource. There are no day/meal filters, content modes, paging arguments, per-resource character limits, or ingredient cutoffs. Photos and registration remain outside the text resources. Owner text is JSON-quoted and forged block markers are neutralized.

Context management belongs to orchestration:

- `CampingChat` plans the current prompt and reserves working space before choosing recent history. On context overflow, it summarizes older conversation turns, starts a fresh session, and retries once with less context.
- `AppleToolResults` serializes result preparation and tracks the shared remaining token allowance across calls. A result that fits passes through unchanged.
- Oversized results use the resource-independent `ToolResultCompaction` helper. It counts complete candidate prompts, splits the full returned text into chunks that fit separate model sessions, and carries a question-relevant summary forward. Every chunk is processed; retrieval does not choose records to drop. This follows Apple's [large-task context guidance](https://developer.apple.com/documentation/foundationmodels/managing-the-context-window).
- Condensed results are labeled as model summaries, not complete verbatim data. Summarization can omit details; it is not lossless. Empty or over-budget summaries fail instead of being silently cut. Cancellation stops processing. Native context failures still reach the existing compact retry.
- The tool loop and result preparation are independent of the subject of the user's question. General questions can be answered without tools. A trip source is shown only when the session reports a trip lookup (or a legacy prompt-based caller uses saved trip facts).

The rig profile remains small context in the instructions. Completed turns retain their question and answer, while raw tool calls/results are removed after the response. Earlier answers and conversation summaries do not establish current saved values. Document search still runs through the existing scoped retrieval path before generation; this change does not convert it into a new tool.

Core tests verify complete retrieval across long menus, ingredient lists over 20 items, booking notes and checklists, plus bounded generic compaction and cancellation. Actual model choices, summary accuracy, latency, and iOS compilation require validation on Apple hardware; see the [manual checks](assistant-evals.md#trip-tool-calling-checks). The estimated schema reservation is still 160 tokens; measure the actual framework definition with Instruments.

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
| [Camp/Shared/](../Camp/Shared/) | Connectivity gate, debug layout markers, and small shared views. |
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
3. `AppPermissions` checks native location and camera authorization before `RootView` shows profile content, requests only unanswered permissions, and refreshes status on foregrounding. Location access uses the manager’s cached authorization status and delegate updates, avoiding a synchronous global-services query on the main thread. Core Location reports global Location Services being disabled as denied authorization ([Apple documentation](https://developer.apple.com/documentation/corelocation/clauthorizationstatus/denied)). Denial does not block setup. `RootView` queries for a profile, displaying onboarding or four tabs: Home, Trip (add sheet), Camp Finder, and Profile. The shared circular Assistant accessory opens a sheet on supported AI devices. Home lists current/upcoming trips; Profile links to completed trip history and saved campgrounds, with app preferences and library tools in its Settings sheet.
4. Screens read models with `@Query`. Forms edit drafts such as `TripDraft`, `RigDraft`, and `ChecklistStepDraft`, then validate and apply them.
5. Model extensions enforce library rules. `LibraryController.save()` performs deliberate saves and surfaces failures; scene transitions also trigger saving.
6. If configured and enabled at launch, Apple mirrors the library to the device's private CloudKit database and manages connectivity, retries, and account transitions.

There is no raw SQL, custom CloudKit record transport, hosted user-data service, or app account/session backend. See [storage and synchronization](offline-storage.md) for model relationships, schema constraints, conflict behavior, and identity transitions.

### Adaptive workspace

The app uses the window's real size classes, safe areas, and native containers on iPhone, iPad, and Catalyst. There is no hinge capability gate, model-name check, or forced compact size class. Native `TabView`, `NavigationSplitView`, toolbars, forms, and sheets own their platform adaptation. `MainTabs` owns selection and presented sheets; the Assistant conversation also lives there. The Assistant action is a native toolbar button everywhere, gated only by Apple's runtime model eligibility.

`HomeWorkspace` owns Home's clock, selected trip identifier, and `[TripPage]` detail path above both split columns. `HomeDestination` identifies a trip or a Home shortcut to its checklist, menu, or memories. The sidebar rows are actionable buttons with rectangular hit areas and selection tags, so the full row activates its shortcut and reselecting the trip clears its detail path even if the row is already selected. The detail stack always starts at `TripDetailView`; `TripPage` values push checklists, menu, memories, and documents above it, providing native back navigation. At regular width, sidebar selection reflects the first detail page. At compact width, the list has no selection binding: the row action alone reveals the detail and pushes its page, preventing the split view’s automatic selection navigation from clearing that path. Checklist phase changes update the same path. Only changing trips changes the stack identity, so the path survives layout changes. Native navigation collapses at compact width and expands when space allows. The detail shows the valid pick or featured trip (`displayedTrip(selected:asOf:)` in `CampCore`).

Home's list selection is a read-only projection of the detail path. Explicit row button actions alone replace that path, including reselecting a trip to return to its details. SwiftUI can write stale or nil row selections while reconciling a push or layout change; those writes must not act as navigation commands or they can immediately pop the new page.

`TripPageLink` uses Home's value path only inside that workspace. Trip history retains its existing view-based links through Profile, history, and trip subpages: pushing a new value above those view destinations would pop them under SwiftUI's navigation rules.

`HomeWorkspace` also owns one `LocalWeather` instance, its refresh lifecycle, and the location-permission alert. `CurrentWeatherBadge` renders that shared model without creating a session of its own. Expanded layouts attach both weather and the global Assistant to detail content so their items can use the system vertical bar; compact Home retains the actions in its own bar until navigation opens a detail. Weather’s custom item opts into `.verticalPreferred` on supported iOS SDKs, with a horizontal fallback on Catalyst and iOS 27.0. Its read-only text always includes °F or °C; denied location shows a crossed-out recovery action instead. The item hides its shared toolbar background, and Home’s list keeps attribution and the retrieval time.

Camp Finder separates map and results at regular width. On iOS 27.1 or newer it uses `ArrangementView(.split)`, with navigation outside the arrangement. Catalyst and earlier supported runtimes use flexible side-by-side panes; compact width embeds the map in the list. Query, camera, search service, and open-place sheet state live above the branch. Onboarding uses a native confirmation action and trip details use system overflow, independent of device identity.

`-layout-ui-test` adds media fixtures and accessibility markers in Debug builds; it never changes size classes or selects an alternate UI. The former hinge observer and `HingeCapability` were removed. See [Duo readiness](duo-readiness.md) for the source guidance and acceptance matrix.

The device-local appearance preference is stored through `AppAppearance`/`@AppStorage` and applied at the window root. System follows the OS; Light/Dark overrides also apply to navigation and sheets.

## Domain rules

A trip is one campground booking and references its rig. Editing a rig changes the details shown on all related trips; replacing it archives the old rig. New trips copy the rig's default setup/teardown steps, then own their checklist copies independently.

Rig and trip validation is shared through `RigDetails` and `TripDetails` protocols implemented by both drafts and persisted models. `CampCoreTests` exercise those rules without SwiftUI or SwiftData.

Deleting a trip cascades to its steps, photos, note revisions, and menu (meals, dishes, and recipe items). Documents are retained as unattached.

A trip's menu is its `TripMeal`s, keyed by a day offset from arrival so date edits keep meals on the same trip day. `TripMenuFacts` (in `CampCore`) is the Assistant's complete, JSON-quoted snapshot of the menu, built from the library by `Trip.menuFacts(asOf:)` and returned by `get_trip` with a menu focus; see Assistant tools. `CampCore` also defines the meal kinds, the menu's days (`menuDays`, arrival through departure in the planning time zone, capped at 60), and the dish, item, and meal drafts. `Trip+Menu.swift` groups standard meals by day and kind, so duplicates created on two devices read as one, and keeps meals outside the trip's dates until they're moved or removed. A rig can be deleted only when unused by trips. See [feature behavior](features.md) and [erasing data](erase-data.md).

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

Profile › Settings exports `RoamReady Export.zip`: `library.json`, `documents.json`, and verified original files under `Documents/`. Photo metadata/captions are included, not image bytes; photos are shared individually. `library.json` schema version 4 adds each trip's menu (day, meal, dishes, and recipe items, without dish photos). Exported encrypted documents are readable originals. The export is an explicit user copy, not an implemented restore/import workflow.

## Validation boundaries

Package tests cover shared policies, validation, place identities, search-result merging, document integrity/crypto, and real SwiftData stores. A native simulator build checks Apple SDK compilation; physical devices are still needed for permissions, model availability, iCloud account/asset behavior, accessibility, and release acceptance. See [build and validation](validation.md).

### Scanned documents (OCR)

`DocumentTextExtractor` reads a PDF page by page. A page whose text layer has at least 20 letters or digits and isn't mostly replacement characters is used as is; any other page is rendered and recognized with `VNRecognizeTextRequest` (accurate, en-US), and the reading with more text wins. Image documents are one page (a multi-page TIFF is one per frame), decoded through an ImageIO thumbnail so the full bitmap is never held. Ordinals stay one-based positions in the file, so citations and the viewer agree for mixed PDFs.

Caps (`OCRPolicy`): bitmap at most 2,400 px on the long side, 5,000,000 px, 3x page points, 8-bit gray (about 5 MB, one at a time); 120 recognized pages and 240 s per document; image documents over 64,000,000 px refused; 40 TIFF frames. The 50 MiB file cap bounds stored bytes only, so these bound decoded memory. Peak memory was bounded by construction and by a test that a 14,400 pt page renders within the pixel cap; it was not profiled with Instruments.

Outcomes: empty (no pages), encrypted (locked), unreadable, too large, and no text each record the document as indexed with no passages, so it isn't read again until its checksum changes. A Vision error with nothing else readable is `retryLater`: not recorded, retried on the next sync. A page read upright with little text or low confidence is retried at the other three orientations and a turned reading is taken only if it scores 25% higher. Layout puts lines top to bottom and joins short cells on one row with " | " so table values stay with their labels; long lines (prose columns) are never joined. Per-page confidence (length-weighted line mean; lines under 0.3 are dropped) is stored on every passage of that page, carried through `SearchHit`, `DocumentEvidenceCandidate`, and `DocumentSource`. Below 0.75 the excerpt header says "scanned text, low confidence: may be misread", the instructions forbid stating its numbers as exact, and the UI shows a caution. Known limits: confidence is per page, not per line; two-column prose isn't reordered by column; recognition is English only.
