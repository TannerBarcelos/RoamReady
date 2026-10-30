# iPhone Duo readiness

[Documentation index](README.md) · [Design](design.md) · [Build and validation](validation.md)

Audited October 30, 2026, starting from `main` at `be023b44f242425257e1b35fb140934a3f43f7b1`. This is an implementation audit and acceptance runbook for iPhone (including Duo), iPad, and Mac Catalyst. The implementation uses Apple’s native containers and APIs; Apple does not provide one complete app to copy verbatim. Layout does not depend on model identity or AI capability. Full Duo optimization is **not yet verified**: the open display, live folding, physical accessibility, and performance measurements still need evidence on the final build.

## Apple guidance consulted

- [Designing for iPhone Duo — HIG](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo): retain hierarchy, functionality, and state across poses; use size classes and safe areas, native bars, reserved-region-aware containers, and the system overflow.
- [Three steps to make your app shine on iPhone Duo](https://developer.apple.com/iphone-duo/prepare/): build with a 27.1 SDK for full-display support, remove screen/orientation assumptions, and validate resizing. Apple also recommends exporting Xcode's App Resizability skill with `xcrun agent skills export`.
- [Design for iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111466/): control placement, sheets, and display continuity.
- [Strike a pose with adaptive layouts](https://developer.apple.com/videos/play/tech-talks/111463/): system split arrangements handle division regions; keep navigation outside arrangements and arrangements outside scrolling containers.
- [Raise the bar with iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111462/): vertical bars, semantic placement, and `ToolbarOverflowMenu`.
- [Configuring a multiplatform app](https://developer.apple.com/documentation/Xcode/configuring-a-multiplatform-app-target): check SDK/API availability across platforms. Catalyst’s current SwiftUI SDK does not expose `ArrangementView`, so it uses native flexible panes instead.
- [Get started with Dynamic Type](https://developer.apple.com/videos/play/wwdc2024/10074/): switch horizontal content to vertical layouts when larger text needs room.

The web reader supplied the preparation guide, HIG text through search, and talk transcripts/code. Direct workspace requests to `developer.apple.com` returned proxy 403s during the audit. Xcode's exported App Resizability skill was unavailable in this Linux environment; it was not run. No claim is made that Apple's skill or a device audit passed.

## Findings and implementation

| Area | Existing evidence or gap at the starting commit | Follow-up |
| --- | --- | --- |
| Build SDK | Project selects the current SDK, but CI accepted 27.0. Deployment floor is 27.0. | All native workflows require an iOS SDK of at least 27.1 through `scripts/check-apple-sdk.sh`; deployment floor stays 27.0. Archive metadata must still confirm the shipping SDK. |
| Geometry | The app forced compact width everywhere except a hinge-gated Duo workspace. | Remove the override, hinge observer, capability state, and device layout branches. Use real traits on iPhone, iPad, and Catalyst. Test resizing, including Split View on either side. |
| Home | Native split navigation was available only in the Duo workspace. | Use `NavigationSplitView` on every device with selection above its columns. Native navigation owns expansion/collapse. Verify folds and nested destinations; rotation alone is insufficient. |
| Camp Finder | A custom `HStack` used a results pane constrained to 280–400 points, independent of reserved regions. | Use native `ArrangementView(.split)` at regular width on iOS 27.1 or newer, with no fixed pane widths. Catalyst and earlier supported runtimes use flexible panes because the arrangement API is unavailable there. Navigation and state stay above the container. Compact width keeps the list/map; place sheets are stable across all widths. |
| Search actions | Two labeled buttons competed for row width. | `ViewThatFits` stacks them when the horizontal version does not fit. |
| Onboarding | A custom bottom action panel used scarce cover-display and keyboard space. | Every platform uses a labeled native confirmation toolbar action and step count. Validation and drafts remain in the form; system bars choose the appropriate placement. |
| Trip toolbar | A separate ellipsis menu duplicated the overflow pattern. | Edit/delete actions join `ToolbarOverflowMenu` on every platform. The list's delete action and confirmation remain. |
| Home global controls | Current-location weather was attached to the sidebar toolbar. Sidebar items stay horizontal on Duo, even with the detail's vertical bar visible. | Put weather and general Assistant in the expanded detail's toolbar, including empty detail. A shared weather model and sheet live above both columns. The weather item opts into the vertical axis and uses the system bar-edge environment for its compact representation; no device or pose checks are added. |
| Document rows | Category and expiry shared a single horizontal row; the prior audit identified large-text truncation. | Stack metadata at accessibility sizes and when horizontal content doesn't fit; allow full title and metadata height. |
| Sheets and viewers | Editors use native sheets/forms; preview uses Quick Look; camera uses `UIImagePickerController`. | Retain system presentation. Verify live fold with a draft, import, camera, image, and PDF open. |
| Responsiveness | Imports and image downsampling already use detached work; thumbnails and stored photo sizes are bounded. Search state lives above its layout branch. | Retain these paths. No timing, memory, battery, or thermal improvement is claimed without profiling. |
| AI and accessibility | AI eligibility already comes from Apple’s runtime; native controls, semantic colors, Reduce Motion support, and labeled images are present. Earlier evidence is incomplete, including #91/#93 follow-up. | Keep AI eligibility independent of layout. Older/noneligible hardware retains core workflows without Assistant mentions. Use native Assistant toolbar placement everywhere and run the unsupported-model regressions as well as accessibility/device checks. |

## Verification for this follow-up

Checks available in the editing environment:

- Swift frontend syntax parsing of changed app and UI-test files. This does **not** type-check SwiftUI or prove iOS SDK availability.
- Workflow YAML/plist parsing, shell syntax, SDK-version boundary cases, simulator-selection scenarios, and `git diff --check`.
- Full `swift test` was attempted with the installed Linux Swift 6.2.1 toolchain. After supplying SQLite development headers outside the repository, compilation stopped at the existing `import CryptoKit` in DocumentVault. It did not complete the package suites. Native package tests remain a macOS CI requirement.

New/updated UI regressions use real window traits on all devices (`-layout-ui-test` supplies media only), and are not executed in the editing environment:

- Camp Finder checks separate, visible arrangement panes without assuming fixed pane proportions or one split axis.
- Add-trip draft text and the originating tab survive rotation with the sheet open.
- A long service-record title, category, and expiry remain reachable at the largest text size, with Dynamic Type and clipping audits and no waiver.
- At regular width, weather and Assistant each appear once outside the Home sidebar toolbar, with a current trip and an empty library. These checks use actual window traits and skip compact windows; an open Duo pose still needs Device Hub validation.
- The disk onboarding workflow reaches the native primary action; selected-trip deletion uses the list action.

Native app and package CI is run remotely; no Xcode, iOS SDK, Simulator, or Device Hub is installed in the editing environment. PR CI also compiles the UI test bundle without booting a simulator, so UI regressions are type-checked even though their execution remains manual. Native Debug/Release builds, package tests on macOS, and the UI suite must pass for this revision before merging. Earlier green runs in `validation.md` are not evidence for these changes.

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
| iPhone 15–18 and older eligible OS hardware | Run compact portrait, landscape, keyboard, all forms/sheets, and supported/unsupported AI states. Test real hardware eligibility, not model-name rules. Core workflows must remain available without AI. Older devices must support the existing iOS 27.0 deployment floor. | Not run |
| iPad and Catalyst | Test regular/narrow windows, split navigation, Camp Finder panes, keyboard/pointer, and window resizing. Recapture baselines: native bars and regular-width content expansion are intentional changes. | Not run |
| Physical Duo | Repeat the pose workflows one-handed and on a table, including camera, offline checklists and documents, permission prompts, and VoiceOver. Verify outdoor readability and reachability. | Not run |
| Release performance | Profile cold/warm launch, scrolling, folds during image/PDF import and AI generation, peak memory, main-thread stalls, energy, and thermal behavior on a signed Release build using Instruments. Record OS, build, corpus, timings, traces, and chosen limits. | Not run |

Attach screenshots, `.xcresult` bundles, and Instruments traces to the reviewed revision. Record actual results and failures in the table; a fixture run on an iPad, a closed-display run, or a rotation is not proof of hinge behavior. App Store Duo screenshots and preview assets are a separate release task described in Apple's preparation guide.
