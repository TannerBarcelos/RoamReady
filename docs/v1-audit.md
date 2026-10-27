# V1 readiness audit — October 27, 2026

[Documentation index](README.md) · [Release plan](integration-plan.md)

**Verdict: not certified for release.** The confirmed v1 workflows are implemented, but implementation and deterministic tests do not establish live Apple services, physical-device behavior, accessibility, or App Store readiness. Keep the unexecuted checks in #6 unchecked.

This audit uses `docs/features.md`, the identity/offline contract, and release issue [#6](https://github.com/TannerBarcelos/RoamReady/issues/6). Work is on one branch, `codex/v1-audit`, in [PR #76](https://github.com/TannerBarcelos/RoamReady/pull/76), based on main after #75. On October 27 the owner explicitly confirmed: **keep documented v1 chat behavior; conversations survive closing and clear on app quit; saved sessions stay separate.** This settles the saved-session scope question for this audit. It does not settle whether Mac ships or change unsupported-device AI eligibility.

## Requirement coverage

“Implemented” below means source reviewed against the contract, with the listed automated coverage. It is not a claim that every screen was manually operated or that device acceptance passed.

| Area | Implementation and automated evidence | Still required for release |
| --- | --- | --- |
| Account-free onboarding; rig details, registration, one active rig, replace/archive | `OnboardingView`, `RigViews`, `Rig+Library`; `RigDraftTests`, `LibraryTests`, legacy migration test. New UI workflow completes real tent onboarding. | Fresh offline install on signed hardware; VIN/plate forms and registration in iCloud. |
| Home, Plan, five tabs, new-trip action | `HomeView`, `PlanView`, `MainTabs`; current/upcoming/date/DST tests; UI tests for five tabs, Assistant on each tab, Trip sheet retaining the selected tab. | Midnight/foreground behavior, full navigation and accessibility on devices. |
| Trips, bookings, site notes, completion and deletion | `Trip+Library`, trip forms/detail; `TripDetailsTests`, `SiteDetailsTests`, `LibraryTests` exercise dates, booking links, completion, independent snapshots, deletion/cascades and unattached documents. New UI test creates a booking and reopens it after app termination. | Provider links/directions; confirmation preview/share; time-zone UI and destructive confirmations on devices. |
| Checklists and defaults | `ChecklistView`, `TemplateEditorView`, `Rig+Library`; factory/draft/persistence tests cover progress, priorities/notes, defaults, independent copies. New tests cover intentionally empty defaults and stable priority values; UI workflow adds a step and relaunches. | Reorder/delete/skip and editing every field with touch, keyboard and VoiceOver. |
| Document vault and export | `DocumentEditorView`, `DocumentDetailView`, `StoredDocument+Library`; `DocumentVaultTests` and persistence tests cover content types, SHA-256, size, HTTPS, staging, encryption, disk migration and archive generation. | Real Files providers, cloud-only imports, 45 MiB PDFs, Quick Look/share, interrupted download and signed CloudKit asset delivery. |
| Photos and memories | `PhotoImport`, `MemoriesView`, `CameraCapture`; persistence tests cover stored photos, captions, notes/revisions and cascades. Images are downsampled off the main actor to bounded dimensions; grid thumbnails are lazy. | Camera/Photos permission states, HEIC/Live Photos, cloud-only selection, orientation and large-photo imports. |
| Camp Finder and saved lists | `CampFinderService/Search/View`, details and saved lists; `CampgroundsTests` cover identity, merging/search cleaning and outbound links; persistence tests cover saved marks/completion. | Live Maps search/map selection, coverage, permissions, throttling, offline retry and external actions. No offline maps, rig-fit or amenity filtering are promised in v1. |
| Weather and cache | `WeatherStore`, `CurrentWeatherBadge`, `WeatherView`; trip tests cover destination civil-day forecast windows and DST. Audit adds first-fetch failure recovery and foreground permission refresh. | Provision WeatherKit; live readings/attribution, permission denial/revocation and cached offline readings on signed devices. UI compilation cannot establish live weather. |
| On-device Assistant | `AppleCampingResponseGenerator`, `CampingAssistant`, `AssistantView`; generation/request/availability tests cover unmatched questions, bounded history, cancellation, errors, refusal mapping and one compact-prompt overflow retry; UI tests cover simulated availability/send/retry and sheet continuity. | Real Foundation Models response/follow-up in airplane mode after model download; languages, safety behavior, no outbound question transfer. Opt-in hardware smoke test remains required. |
| Appearance, iPad, Mac | Root appearance preference and native semantic colors; iPhone/iPad UI workflow matrix; Catalyst Debug/Release build. Audit uses a toolbar Assistant button on regular layouts and Mac, and hides camera capture when unavailable. | VoiceOver, maximum Dynamic Type, contrast, reduced motion/transparency, rotation, split view, signed Mac operation if Mac ships. |
| Offline library, iCloud, erase | `LibraryController`, `LibraryStore`, `ICloudSettings`, `LibraryErase`; real-store reopen/migration/cascade tests and settings tests. Network services do not gate local edits. | Dedicated CloudKit container/schema, two-device conflicts and account changes, interrupted uploads, quota/low-storage failures, full erase, background delivery. |
| Price and distribution | No paywall/StoreKit; documented $4.99 one-time price. Icon is checked in. | Final bundle ID/team, entitlements, privacy policy/disclosures, signed archive/icon, App Store listing and pricing schedule, TestFlight and review. |

## Defects fixed on this branch

- **Persistence crash:** main's Mac suite aborts with `Could not cast value of type 'Swift.Optional<Any>' to 'CampCore.ChecklistPriority'`. Persist priority as a primitive string and expose a typed accessor, matching the document models' raw-value approach. Existing pre-priority libraries gain no priority. Disk reopening, legacy migration, all priority values and unknown-value handling are regression coverage.
- **Empty defaults:** deleting every default step previously triggered automatic regeneration. A defaulted `hasConfiguredDefaults` flag distinguishes intentional emptiness from older rigs with no defaults. New trips honor empty lists; existing trip snapshots stay intact; Reset still regenerates.
- **Assistant entry:** compact layouts retain the bottom accessory; regular iPad layouts and Mac get an explicit toolbar action. UI tests attempt entry from every tab.
- **Unavailable camera:** hide Take a photo when the system reports no camera; retain permission handling for available cameras.
- **Weather recovery:** allowed location with no successful weather reading previously produced no badge and no retry action. Keep an entry control and show loading/failure/offline/retry states. Recheck permission on foregrounding.
- **Saved campground failures:** stop swallowing database errors from list toggles/removals and show a recoverable alert.
- **Trip date editor consistency:** new-trip forms use the draft's planning time zone, like the existing edit form.

Changes are localized; existing off-main media downsampling, lazy photo grids and file staging remain the storage/performance strategy. No unmeasured launch/scroll performance claim is made. The 300-trip/2,000-photo device benchmark in #6 remains open.

The priority representation changes a newly introduced, pre-release field. An optional legacy attribute with `originalName: "priority"` preserves development-build enum values while new edits use raw values. `PriorityMigrationTests` exercises every old priority through migration and a subsequent save/reopen. A deployed CloudKit Production schema still needs a separate compatibility review before this pre-release rename; do not erase user stores to make validation pass.

## Validation record

- Baseline main, Mac run [40444911329](https://github.com/TannerBarcelos/RoamReady/actions/runs/40444911329): failed in persistence tests with the priority cast abort; Catalyst build did not run.
- Initial fix `5df32e3`, Mac run [40445339230](https://github.com/TannerBarcelos/RoamReady/actions/runs/40445339230): package build and unit-test steps passed, including the previously aborting persistence suite. Superseded by further work, so it is not final-branch build evidence.
- Code commit `67612af`: [Mac run 40445923327](https://github.com/TannerBarcelos/RoamReady/actions/runs/40445923327) passed all 104 package tests (72 XCTest and 32 Swift Testing), plus Debug/Release Catalyst builds. [iPhone/iPad run 40445923300](https://github.com/TannerBarcelos/RoamReady/actions/runs/40445923300) passed both Debug build-for-testing jobs and iPhone Release; UI execution was still running when the second audit pass began.
- The follow-up pass adds signing override verification, a 300-trip/2,000-photo real-store regression, appearance persistence at accessibility text size, and a focused native Dynamic Type/text-clipping audit. Native results for this follow-up must pass before counting those checks as verified.
- Local environment is Linux without Swift/Xcode or a connected iOS device. Source/configuration review and `git diff --check` were performed here; native execution uses the repository's existing Xcode 27 CI runners.
- No signed physical-device, live WeatherKit, real Foundation Models, CloudKit multi-device, accessibility, performance or App Store submission checks were performed in this audit.

## Follow-up fixes and checks

- Wire both app configurations to `Config/App.xcconfig`; optional `Config/Local.xcconfig` now overrides actual resolved signing, bundle, container and capability settings. Target-level empty values previously took precedence over base configurations. CI verifies defaults and fixture overrides without signing or contacting Apple provisioning.
- Honor Reduce Motion when scrolling Assistant transcripts, give checklist controls 44-point targets, and stack forecast details at accessibility text sizes.
- Add real-store scale coverage for 300 trips, 2,000 synthetic 16 KiB photos and their relationships, including reopen/fetch timing. This measures storage operations, not camera decode or smooth scrolling with real images.
- Extend the real UI workflow to verify Dark appearance survives relaunch and run native Dynamic Type/text-clipping checks on the visible Profile screen at the largest accessibility size. VoiceOver navigation, contrast, the rest of the app and physical-device acceptance still require their documented passes.
- Bound simulator warmup and UI-test steps so a stuck runner produces a specific failure; retain result bundles for successful as well as failed runs.

## Remaining decisions and missing release work

1. Confirm whether Mac Catalyst ships in v1 (#74). Its implementation stays enabled while that decision is open.
2. Confirm that hiding AI entry on hardware without Apple Intelligence is the intended v1 policy (#74). Current implementation and docs agree; a future alternate provider is separate work.
3. Complete Apple provisioning and all unexecuted acceptance checks from #6, with commit, OS, device, date and evidence. Passing CI does not close those gates.
4. Track persistent sessions, summarization/compaction, and richer global rig/trip grounding from #65 separately. V1 keeps bounded recent turns and the existing context-overflow retry. The owner's scope choice does not claim these enhancements are implemented.
