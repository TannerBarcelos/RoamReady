# iPhone Duo readiness

[Documentation index](README.md) · [Design](design.md) · [Build and validation](validation.md)

Audited October 30, 2026, starting from `main` at `be023b44f242425257e1b35fb140934a3f43f7b1`. This is an implementation audit and acceptance runbook. Full Duo optimization is **not yet verified**: the open display, live folding, physical accessibility, and performance measurements still need evidence on the final build.

## Apple guidance consulted

- [Designing for iPhone Duo — HIG](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo): retain hierarchy, functionality, and state across poses; use size classes and safe areas, native bars, reserved-region-aware containers, and the system overflow.
- [Three steps to make your app shine on iPhone Duo](https://developer.apple.com/iphone-duo/prepare/): build with a 27.1 SDK for full-display support, remove screen/orientation assumptions, and validate resizing. Apple also recommends exporting Xcode's App Resizability skill with `xcrun agent skills export`.
- [Design for iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111466/): control placement, sheets, and display continuity.
- [Strike a pose with adaptive layouts](https://developer.apple.com/videos/play/tech-talks/111463/): system split arrangements handle division regions; keep navigation outside arrangements and arrangements outside scrolling containers.
- [Raise the bar with iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111462/): vertical bars, semantic placement, and `ToolbarOverflowMenu`.
- [Get started with Dynamic Type](https://developer.apple.com/videos/play/wwdc2024/10074/): switch horizontal content to vertical layouts when larger text needs room.

The web reader supplied the preparation guide, HIG text through search, and talk transcripts/code. Direct workspace requests to `developer.apple.com` returned proxy 403s during the audit. Xcode's exported App Resizability skill was unavailable in this Linux environment; it was not run. No claim is made that Apple's skill or a device audit passed.

## Findings and implementation

| Area | Existing evidence or gap at the starting commit | Follow-up |
| --- | --- | --- |
| Build SDK | Project selects the current SDK, but CI accepted 27.0. Deployment floor is 27.0. | All native workflows require an iOS SDK of at least 27.1 through `scripts/check-apple-sdk.sh`; deployment floor stays 27.0. Archive metadata must still confirm the shipping SDK. |
| Geometry | No `UIScreen.main`, interface-orientation layout decisions, phone-idiom layout branches, or full-screen requirement in app source/configuration. Hinge detection is scene-local and latched. | Retain the existing capability detection and size-class-driven layouts. Test real scene resizing, including Split View on either side. |
| Home | Native `NavigationSplitView`; trip and checklist phase selection live above its columns. | Retain it. Verify selection and nested destinations during an actual fold; rotation tests alone don't establish this. |
| Camp Finder | A custom `HStack` used a results pane constrained to 280–400 points, independent of reserved regions. | Use native `ArrangementView(.split)` at regular width on Duo, with no fixed pane widths. Both axes are allowed so a tall window can stack both panes. Navigation stays outside; query/camera/search/sheet state stays above the branch. Compact width keeps the existing list/map. |
| Search actions | Two labeled buttons competed for row width. | `ViewThatFits` stacks them when the horizontal version does not fit. |
| Onboarding | A custom bottom action panel used scarce cover-display and keyboard space. | Duo uses a labeled native confirmation toolbar action; the existing step count remains. Validation, draft ownership, and non-Duo bottom presentation remain. |
| Trip toolbar | A separate ellipsis menu duplicated the overflow pattern. | Duo edit/delete actions join `ToolbarOverflowMenu`. The list's delete action and confirmation remain. |
| Document rows | Category and expiry shared a single horizontal row; the prior audit identified large-text truncation. | Stack metadata at accessibility sizes and when horizontal content doesn't fit; allow full title and metadata height. |
| Sheets and viewers | Editors use native sheets/forms; preview uses Quick Look; camera uses `UIImagePickerController`. | Retain system presentation. Verify live fold with a draft, import, camera, image, and PDF open. |
| Responsiveness | Imports and image downsampling already use detached work; thumbnails and stored photo sizes are bounded. Search state lives above its layout branch. | Retain these paths. No timing, memory, battery, or thermal improvement is claimed without profiling. |
| Accessibility | Native controls, semantic colors, Reduce Motion support, labeled images. Earlier evidence is incomplete, including #91/#93 follow-up. | Add document-row audit and draft-preservation regressions; run the complete accessibility and physical-device pass below. |

## Verification for this follow-up

Checks available in the editing environment:

- Swift frontend syntax parsing of changed app and UI-test files. This does **not** type-check SwiftUI or prove iOS SDK availability.
- Workflow YAML/plist parsing, shell syntax, SDK-version boundary cases, simulator-selection scenarios, and `git diff --check`.
- Full `swift test` was attempted with the installed Linux Swift 6.2.1 toolchain. After supplying SQLite development headers outside the repository, compilation stopped at the existing `import CryptoKit` in DocumentVault. It did not complete the package suites. Native package tests remain a macOS CI requirement.

New/updated UI regressions are authored, not executed here:

- Camp Finder checks separate, visible arrangement panes without assuming fixed pane proportions or one split axis.
- Add-trip draft text and the originating tab survive rotation with the sheet open.
- A long service-record title, category, and expiry remain reachable at the largest text size, with Dynamic Type and clipping audits and no waiver.
- The disk onboarding workflow accepts the action in either a bottom panel or the native bar; selected-trip deletion uses the list action.

No Xcode, iOS SDK, Simulator, or Device Hub is available here. Native Debug/Release builds, package tests on macOS, and the UI suite must pass for this revision before merging. Earlier green runs in `validation.md` are not evidence for these changes.

## Required acceptance matrix

Run the manual UI workflow with **iPhone Duo**, **iPhone**, and **iPad**. It selects an available device on the newest compatible installed runtime, excludes Duo from the ordinary iPhone choice, and fails clearly if the selected family is missing. A Duo run needs iOS 27.1 or later. The workflow does not operate Device Hub pose controls.

On a Mac with Xcode 27.1 or newer:

```sh
bash scripts/check-apple-sdk.sh
swift test
xcodebuild -project RoamReady.xcodeproj -scheme RoamReady -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone Duo' -derivedDataPath .derivedData \
  CODE_SIGNING_ALLOWED=NO test
```

Use Device Hub to repeat these scenarios without relaunching the app:

| Configuration | Scenarios and expected result | Follow-up result |
| --- | --- | --- |
| Closed cover, portrait and both landscapes | Finish all onboarding stages, with keyboard and required-field errors. Reach Home, Profile, Settings, Camp Finder, Add trip, and Assistant. Controls remain reachable when bars overflow. | Not run |
| Inner display, flat, wide and tall | Home and selected trip/checklist share space. Camp Finder's two panes remain usable. No stretched fixed-width pane or clipped controls. | Not run |
| Partially folded, book and tabletop | Home columns and Camp Finder panes avoid the active division appropriately. Onboarding and overflow controls remain reachable. Check camera-active occlusion too. | Not run |
| Continuous open/close/fold | Select another trip, change checklist phase, push a document, edit a trip, import a file/photo, capture a photo, generate a reply, and pan/search the map. Preserve work; no duplicate import/search or lost sheet. | Not run |
| Split View, app on left and right | Verify both outer control edges and asymmetric safe areas, keyboard, search, overflow, and every sheet. Include PiP-driven vertical resizing. | Not run |
| Accessibility and localization | Default through largest text, Display Zoom, VoiceOver focus/order/actions, long names, RTL, light/dark, Increase Contrast, Reduce Motion/Transparency. Audit every screen and sheet. Review known #93 waiver separately. | Not run |
| Regular devices | Compare the existing regular-iPhone baselines; check iPad multitasking and Catalyst builds. Large-text metadata/action wrapping is intentional. | Not run |
| Physical Duo | Repeat the pose workflows one-handed and on a table, including camera, offline checklists and documents, permission prompts, and VoiceOver. Verify outdoor readability and reachability. | Not run |
| Release performance | Profile cold/warm launch, scrolling, folds during image/PDF import and AI generation, peak memory, main-thread stalls, energy, and thermal behavior on a signed Release build using Instruments. Record OS, build, corpus, timings, traces, and chosen limits. | Not run |

Attach screenshots, `.xcresult` bundles, and Instruments traces to the reviewed revision. Record actual results and failures in the table; a forced `-duo-ui-test` workspace on an iPad, a closed-display run, or a rotation is not proof of hinge behavior. App Store Duo screenshots and preview assets are a separate release task described in Apple's preparation guide.
