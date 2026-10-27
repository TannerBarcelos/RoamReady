# Feature reference

[Documentation index](README.md) · [User guide](user-guide.md)

These features are implemented in source. RoamReady remains a development build; service provisioning and physical-device acceptance are tracked in the [release plan](integration-plan.md).

## Onboarding and rigs

First launch goes directly to rig/profile onboarding without an account or connection. Choose a rig category and confirm equipment, then add a photo or emoji, an optional name, and experience level.

RVs require year, make, model, and length. Optional details include slide-out count (Not specified, None, or 1–8), axles for towables, bunkhouse, and floorplan. Details are owner-entered; there is no rig catalog. Older profiles without a length can still open, and their next edit requests the required fields.

Every rig type except a tent has an optional **Registration** section, in onboarding and in Add, Edit, and Replace rig: VIN, license plate, and state or province.

| Field | Rule |
| --- | --- |
| VIN | Saved in uppercase with spaces and dashes removed. A rig from 1981 or later, or with no year entered, needs the standard 17 letters and digits without I, O, or Q. A rig with an earlier year accepts 1–17 letters and digits, because older vehicles used shorter manufacturer serials. The check digit isn't verified; only North American VINs require it. |
| License plate | Saved in uppercase with extra spaces collapsed; up to 12 characters. |
| State or province | Free text, trimmed. |

A VIN or plate problem appears under Registration and blocks saving. Changing the rig type clears registration with the other type-specific details. Profile › Your rig shows the plate and VIN as selectable text, so they can be copied into a booking or check-in form. Registration is stored in cloud-encrypted fields and included in the export. A scan of the registration card belongs in the rig's **Manuals & paperwork**.

There is one active rig per owner, controlled by `RigPolicy.maxActiveRigs`. Editing a rig updates every trip that references it. **Replace rig** archives the current rig so past trips retain it. An archived rig can be reactivated within the active-rig limit or deleted when no trip uses it.

## Home and trip planning

Home shows the earliest-arriving active trip, checklist progress, memories, local save status, and quick trip creation. Active means today falls within the inclusive arrival/departure dates in the campground’s time zone and the trip has not been marked complete. The card disappears after departure day; other current and upcoming trips remain accessible on Home, including overlapping bookings. Completed trips live in **Profile › Trip history**, newest first, alongside **Your campgrounds**. Home refreshes at campground midnight and on foregrounding, without storing an active flag. The tab bar has Home, Trip (add), Camp Finder, and Profile. Profile’s gear opens Settings for appearance, iCloud, export, library maintenance, and app information.

A trip represents one booking at one campground. Campground name, rig, and dates are required. Create a trip from a Camp Finder listing online or enter its campground by name offline. RoamReady records a booking; it does not make reservations.

Optional fields can be edited at any time:

| Group | Fields and behavior |
| --- | --- |
| Site | Number, loop, parking type, length limit, electric, water, and sewer. Copy site details from the reservation or enter them on arrival; listings do not automatically fill these fields. A warning appears when the rig exceeds the entered length limit. |
| Booking | Confirmation number, provider, and an HTTPS-only manage-booking link. |
| Timing | Check-in and check-out in the campground's time zone; a display-only cancellation deadline. |
| Cost | Total cost and amount paid. |
| Paperwork | Confirmation files and other attached documents. |
| Memories | Initial site notes during creation; more notes, photos, and ratings in **Photos & site notes**. |

The booking card offers **Open booking link**, **View confirmation & documents**, and **Directions** when the corresponding data exists. Planning dates retain their original time zone; forecasts match dates in the campground's time zone, including daylight-saving transitions.

Trips complete the day after departure and can also be marked complete manually. Completed trips linked to a Camp Finder campground contribute to **Have been**. **Cancel & delete trip** permanently deletes the trip and its history after confirmation; it does not cancel the reservation with its provider. Documents become unattached, while the rig, its defaults, and original library photos are kept. See [deletion behavior](erase-data.md).

## Checklists

Each rig has default setup and teardown lists. A new trip receives fresh copies of its rig's defaults and keeps independent progress and edits afterward.

Steps can be completed, unchecked, skipped, added, renamed, deleted, and reordered.

Each step also has a **priority** and **notes**, as in Apple Reminders:

- **Priority** is None, Low, Medium, or High. The list shows it as `!`, `!!`, or `!!!` before the step's title.
- **Notes** are your own text, shown in up to two lines under the title. They are kept apart from the step's **Guidance**, the generated advice, so editing one never touches the other.
- Generated steps start with no priority and no notes.

**Save as defaults for <rig>** requires confirmation and writes that trip's lists to its own rig, priorities and notes included; only progress resets. New trips copy priorities and notes from the defaults, which Profile › **Default checklists** edits the same way, and each trip then owns its copy. Resetting rig defaults regenerates them from the rig type, dropping custom priorities and notes; existing trips keep their lists.

Checklist help sends a step's notes to the on-device model, labeled as your notes, along with its guidance. Notes can also match a question on their own.

Checklist wording is original, with the [Camping World setup and teardown article](https://blog.campingworld.com/learn-to-rv/rv-setup-checklist/) used as background reference. It is not a licensed reproduction or endorsement. Equipment-specific procedures and ordering remain subject to the rig manufacturer's manuals.

## Documents

Attach rig manuals, registration, insurance, warranties, and trip confirmations during onboarding or later. Upload PDFs/images or add HTTPS links, with a title, chosen category, notes, and optional issue/expiration dates.

Uploaded originals are preserved byte-for-byte, limited to 50 MiB, and checked by SHA-256 on every read. Downloaded files open offline; links require connectivity until a copy is saved. Quick Look, sharing, confirmed deletion, and a Settings zip export are available.

All new files use Apple-managed encrypted SwiftData fields and CloudKit assets; no encryption toggle or app-generated file keys are needed. Existing files remain readable in their original format. A new device must download file content before it can open it offline. See the [document vault](document-vault.md) for storage, encryption, and export details.

## Memories

Capture photos with the native camera or import locally available photos while offline. Images are resized to a maximum of 2560 pixels and stored with their rig or trip. Add captions, site notes, a site number, and a return-or-avoid rating, then share photos individually. Prior memories appear in matching campground details. Original imported photos remain in the user's photo library; cloud-only Photos items may need downloading first.

## Camp Finder

Camp Finder is online-only discovery through Apple Maps (MapKit), with no server or API key. The map shows campground and RV park points of interest as you pan; tap one to open its detail. Use **Near me**, **Search this area**, or search by campground name, city, park, or ZIP. Location permission is optional; text search works without it.

Details include an address, **Website** for booking, **Call**, **Directions**, and Apple's **Photos, ratings & hours** place card where available. Save places to **Want to go**, **Have been**, or **Favorites**. **Add trip** prefills the campground identity, name, coordinates, and time zone; the time zone can be checked or set manually.

The app does not infer prices, hookups, amenities, rig fit, accessibility, or booking availability. There are no amenity/length/budget filters or **Use my rig** control. Apple Maps coverage is partial; an empty search does not mean there are no campgrounds. Offline, Camp Finder explains that it needs a connection and offers retry. Apple can throttle searches per device, with a specific explanation in the app.

Saved lists persist only Apple place identifiers; details are looked up online or names taken from the owner's trips. A saved identifier alone does not guarantee offline details. Offline maps and regional lists are deferred. See [data coverage](campground-data.md) and the [Camp Finder source guide](campground-sourcing.md).

## Weather

Tap the reading at the top right of Home to request location access. Location is approximate by default, rounded to about 1 km, and sent only to WeatherKit. The last reading remains visible offline.

Trips with campground coordinates also show per-day forecasts, cached with their download time for offline use. Home weather and trip forecasts display Apple Weather attribution. Fresh readings require connectivity and a provisioned WeatherKit capability.

## Camping help

The global **Assistant**, opened from the circular sparkle button at the bottom right above the tab bar on any tab, supports general camping troubleshooting without requiring a trip or a matching checklist entry. It keeps the conversation in memory when the sheet closes, so reopening continues it until New chat or the app quits, sends bounded recent turns to Apple’s on-device Foundation Models for follow-ups, and offers New chat. Conversations are not persisted or attached to trips. The button is hidden where Apple reports the device ineligible for Apple Intelligence; supported hardware keeps it for Apple Intelligence setup/model-download explanations. Disabled, preparing, and unavailable AI show a native recovery screen instead of the conversation or composer. Availability refreshes on foregrounding, retry, and while the screen is open. The conversation uses a scrolling transcript and fixed text/send composer, without attachments.

Initial model instructions include a bounded snapshot of the selected rig's saved make, model, year, floorplan code, length, slide/axle counts, bunkhouse, and equipment. It is retained on a context-overflow retry. These are owner-entered facts, not verified manufacturer specifications; numbers in model or floorplan names do not establish dimensions. Registration and photos are excluded. Routine questions receive task-specific guidance; emergency instructions are reserved for danger actually reported by the user.

Every answer comes from the model; there are no canned replies. Trip/checklist help sends the trip’s matching saved steps (or the selected step) as context and answers from general knowledge when they don’t cover the question. Hazard questions (gas, carbon monoxide, smoke, sparking, shock, fire) are answered by the model under instructions to lead with stopping and getting to safety. General chat uses the active rig’s default checklist notes when relevant. Questions stay on the device. The production adapter explicitly uses `SystemLanguageModel.default` and `LanguageModelSession.respond(to:options:)`; no remote provider, account, API key, or AI entitlement is required. It checks model and locale support before generation, uses fresh sessions with bounded recent context, limits unusually verbose output, and retries a context overflow once with a smaller prompt. Refusals, language/context failures, rate limits, and other generation errors show a retryable error and preserve the question instead of substituting checklist text, in both general chat and trip/checklist help. Questions longer than 1,500 characters are rejected for shortening rather than silently truncated.

Assistant works on iPhone, iPad, and Mac wherever Apple’s runtime reports Apple Intelligence available; there is no app-side device list. Disabled Apple Intelligence, a model not yet ready, and other runtime unavailability states show the recovery screen. Checklists and their notes remain available offline everywhere. Initial model download requires connectivity.

There is no hosted AI or model picker in v1. See the [identity and AI contract](account-and-offline-contract.md#apple-only-ai) for exact device identifiers and runtime policy; remote models are proposed for v2 (#34).

## Appearance

Profile offers **System** (the default), **Light**, and **Dark**. The choice applies throughout the app, persists on this device, and works offline. System follows the device appearance; explicit Light/Dark stays fixed. Erasing all data resets the preference to System.

## Profile and library management

Edit profile and rig details (including registration) offline, manage archived rigs and per-rig checklist defaults, view storage/sync status, access unattached documents, prepare an export, or erase all data.

SwiftData stores the library locally. When a dedicated CloudKit container is configured, private iCloud mirroring is on by default. Apple manages connectivity, account transitions, scheduling, and retries. The onboarding/Settings toggle works offline and takes effect on the next app launch, with pending changes shown explicitly; turning it off deletes neither local nor cloud data. The default unconfigured build stays local-only. See [storage and sync](offline-storage.md) and [erasing data](erase-data.md).

## Connectivity at a glance

| Workflow | Offline behavior |
| --- | --- |
| Onboarding, profile, rigs, manual trips, checklists, notes, ratings | Available locally. |
| Camera and photo import | Available for captured or locally accessible photos. |
| Uploaded documents and export | Available for content already on the device. |
| Camping help | Bundled guidance available; generation depends on a ready, eligible on-device model. |
| Weather | Last saved reading/forecast available; refresh needs a connection. |
| Camp Finder map/search/place details and web links | Need connectivity; saved list marks remain local, but an identifier alone does not make place details available offline. No offline maps. |
| iCloud | Transfers require connectivity and provisioning; local edits do not wait for sync. |
| Erase all data | Local-only builds can erase offline; configured cloud builds must erase their iCloud zone first while connected. |
