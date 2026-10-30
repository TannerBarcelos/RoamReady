# Interface design

[Documentation index](README.md) · [Architecture](architecture.md)

## System-first direction

RoamReady follows the approved **A · System-first** design. The interface uses native SwiftUI lists, forms, navigation stacks, and tab controls, with semantic colors and a default System appearance with device-local Light/Dark overrides in Settings. Standard navigation and tabs receive the operating system's Liquid Glass styling at the app's iOS 27 deployment target.

The [approved visual reference](design-A.png) records the design direction. Current behavior and labels are defined by the SwiftUI source; the image is not a complete feature specification.

## Navigation and information hierarchy

The root view resolves optional native location and camera prompts before showing onboarding when there is no profile, then four tabs (Trip opens the new-trip sheet). On devices eligible for Apple’s on-device model, Assistant opens as a sheet from a native **Ask Assistant** toolbar button on every tab. Toolbar placement follows the platform and window, with no device-specific floating control:

| Tab | Primary responsibility |
| --- | --- |
| Home | The current trip during its arrival/departure dates, checklist progress, memories, quick trip creation, and local temperature. Before arrival day it shows the next trip's countdown and setup checklist. |
| Trip | Open the new-trip sheet while keeping the current tab selected. |
| Camp Finder | Online campground/RV park map and search, place details, and saved lists. |
| Profile | Your profile, rig, default lists, documents, completed trip history, and saved campgrounds. The gear opens Settings for appearance, iCloud, export, and library maintenance. |

Home keeps every current and upcoming trip accessible, including overlapping bookings. Completed trips are in Profile › Trip history, newest first.

With no current or upcoming trip, Home shows two standard iOS action rows: Add a trip and Find a campground. A small section heading and compact section spacing keep this state quiet and easy to scan. Everyday screens focus on the trip or document; connection and sync details belong in Settings or actionable availability and save errors.

Trip details keep booking information together and link to setup/teardown, **Photos & site notes**, documents, and camping help. Forms group campground, rig, dates, optional site details, booking, timing, and cost so users can save a minimal trip before adding paperwork.

## Interaction rules

- Use standard list/form controls and system sheets for editing, document preview, camera/photo import, and sharing.
- Edit drafts in forms so **Cancel** discards edits before save.
- Keep checklist progress visible and make complete, skip, reorder, and customization actions available near the relevant steps.
- Lay out checklist steps like Reminders: priority as `!`–`!!!` in the accent color before the title, the owner's notes in secondary text under it (two lines at most), then the section.
- Keep optional booking/site fields optional; show length warnings near site details.
- Explain permanent deletion before confirming it, including what is deleted and what is kept.
- Keep routine saving and synchronization in the background. Surface save failures with retry; show cloud status in Settings without claiming every device has received a change.
- Explain network and AI unavailability at the affected feature, while local workflows remain available.
- Show forecast retrieval times and explain Apple Maps coverage and missing place details so users can judge the data.

- Empty states use `ContentUnavailableView` with a tinted SF Symbol, copy that names what the screen will hold, and buttons for the next step (add a trip, open Camp Finder). They never point at the tab bar.

These patterns support the core use case: opening a saved trip at a campground with limited connectivity.

## Privacy and permissions in the interface

Before rig onboarding, launch checks request unanswered location and camera permissions with the system prompts, skipping camera requests on devices without a camera. Denials never block setup. Home weather is plain temperature text with an explicit degree unit and no shared toolbar background. Denied location keeps a muted, crossed-out icon with a Settings explanation; Near me and camera capture use crossed-out, disabled controls with a nearby Settings action. Foregrounding refreshes permission status. Approximate location is supported. Text search and manual trip entry do not require location permission. PhotosPicker provides access to selected items without a broad library permission. Document categories determine protection, so the user explicitly chooses one before saving.

Sync is configured through the onboarding/Settings toggle, which works offline and explicitly shows that changes apply on the next app launch. Export copy explains that documents leave iCloud protection as readable originals. Full-library erase and trip deletion have separate confirmation flows. See the [identity contract](account-and-offline-contract.md) and [document vault](document-vault.md).

## Accessibility and adaptive layout

The app targets iPhone and iPad in portrait and landscape, and Mac through Mac Catalyst, and defaults to system appearance, with explicit Light/Dark choices applied at the window root. Native controls provide the starting point for Dynamic Type, VoiceOver, and platform interaction conventions.

All platforms receive their real window traits; there is no device/hinge gate or forced compact size class. Home uses `NavigationSplitView` everywhere: the system expands it to show the selected trip beside Home and collapses it at compact width. Selection and checklist phase live above the columns. The four tabs and Trip's Add trip sheet remain. Assistant uses the native toolbar on every eligible device; Apple’s runtime eligibility determines whether it appears, independently of layout.

In expanded Home, current-location weather and the general Assistant belong to the detail toolbar, including the empty detail. The Home sidebar toolbar keeps its navigation controls. Only the detail column participates in Duo's vertical bar, as explained in [Raise the bar with iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111462/). Compact Home also exposes the actions before a trip is opened. Weather keeps its read-only temperature and explicit degree unit in either toolbar orientation, with `.verticalPreferred` on its custom toolbar item. Its spoken label also includes conditions. The weather model, refresh work, and permission-alert state live above the columns so folding cannot recreate separate weather sessions. Catalyst and iOS 27.0 retain horizontal placement through API availability guards.

Camp Finder uses `ArrangementView(.split)` at regular width on iOS 27.1 or newer, with the map and results as separate panes and navigation outside. The system owns the axis and reserved-region handling. Catalyst and earlier supported runtimes use flexible regular-width panes, and compact width keeps the map in the results list. Query, results, camera, and open-place state live above the layout branch. Place details always use a native sheet, preserving presentation when the window changes width.

Onboarding's primary action and trip details' overflow use system toolbar APIs on every platform. Search buttons and document metadata wrap when space or Dynamic Type requires it. See the [Duo readiness audit](duo-readiness.md) for source guidance and validation limits.

Rig thumbnails expose a single labeled image to VoiceOver for both photos and emoji. Their decorative contents stay within the thumbnail; surrounding rig details and actions scale with Dynamic Type.

Release acceptance must still verify large text, VoiceOver labels and order, reduced motion/transparency, light/dark contrast, rotation, iPad split view, long campground names, and outdoor readability. Treat these as validation requirements, not completed accessibility certification. The [validation guide](validation.md#airplane-mode-acceptance-pass) includes the device checklist.

## First-rig onboarding

Three native form screens introduce the setup, collect rig details, and personalize the library. The welcome uses an SF Symbols campsite illustration and full-width rig choices with explicit selection indicators. The primary action is a native confirmation toolbar button with a title and symbol. A labeled step count provides progress, and field validation stays beside the form. System bars choose their placement for each window, leaving the form and keyboard their available space. Each stage opens at the top; transitions respect Reduce Motion. Semantic colors, system typography, and standard navigation/materials follow the system appearance.

Required RV details stay enforced; tent and car camping can continue without them. Registration (VIN, plate, state or province) is optional, hidden for tents, and reports its own problem in place of the required-details hint. The last screen previews the saved rig and prepared checklists. Name, documents, and configured iCloud preferences remain optional; documents and sync follow rig creation so the first choice stays focused. The optional launch permission prompts precede these screens; granting access and creating an account are not required to begin. Rig and profile writes must succeed before advancing; failed profile insertion is removed so setup can be retried.

Before release, check all eight rig types, back navigation without losing draft details, interrupted setup/relaunch, save failures, optional document/photo import, keyboard dismissal, large text, VoiceOver selection/progress, reduced motion/transparency, landscape/iPad, and light/dark appearance on an iOS 27 device or simulator.

## App icon

The icon is a blaze-orange map pin holding a three-quarter progress ring and a check: finding a campsite and getting it set up. The light appearance uses a sand background and the dark appearance uses a forest-green background. Neither depends on the rig type.

![RoamReady app icon in light and dark appearances](app-icon.png)

`Camp/AppIcon.icon` is an Icon Composer bundle, so iOS applies Liquid Glass and derives the Clear and Tinted appearances from its layers. The `Pin` group contains the pin, with the ring and check cut out of it. The `Progress` group contains the white ring and check, which fill those cut-outs. Because the layers never overlap, stacking order does not affect the result. The target selects the bundle through `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`.

The bundle was written by hand rather than exported from Icon Composer. Open it in Icon Composer on a Mac to check its glass, shadow, and translucency settings in each appearance. Use the Home Screen, Spotlight, and Settings sizes to judge it, and check Clear and Tinted on a device. The preview image above approximates the flat artwork; it does not show Liquid Glass.

Settings opens as a native sheet at standard text sizes and full screen when opened at accessibility text sizes, giving large text the available width. Its close icon retains a spoken Done label.
