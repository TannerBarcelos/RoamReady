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

On iPhone Duo, Home shows the selected trip beside it. The current trip is selected at first, or else the next upcoming one; overlapping trips follow Home's rule and choose the earliest arrival (`featuredTrip(asOf:)` in `CampCore`). Picking another trip replaces the details, and the setup and teardown checklist shortcuts open that checklist there. If the picked trip is deleted, the pick is cleared and the details go back to the featured trip. With no current or upcoming trip, the details side is empty.

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

Trips complete the day after departure and can also be marked complete manually. Completed trips linked to a Camp Finder campground contribute to **Have been**. **Cancel & delete trip** permanently deletes the trip and its history after confirmation; it does not cancel the reservation with its provider. Documents become unattached (and out of every Assistant scope until assigned to a rig or trip from document details), while the rig, its defaults, and original library photos are kept. See [deletion behavior](erase-data.md).

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

**Assign to rig or trip** in document details moves a document to one rig (archived rigs included) or one trip, or leaves it unattached. It is a metadata-only change saved through `StoredDocument.assign(to:)`: a trip clears the direct rig, a rig clears the trip, and bytes and checksum are untouched. A failed save shows an error and keeps the prior assignment. Unattached documents, including paperwork kept after a trip is deleted, stay previewable and shareable but are outside every Assistant scope. Assignment re-evaluates scope and queues indexing only if the document is already eligible; category, the Other opt-in, and the local-content rule still apply.

## Memories

Capture photos with the native camera or import locally available photos while offline. Images are resized to a maximum of 2560 pixels and stored with their rig or trip. Add captions, site notes, a site number, and a return-or-avoid rating, then share photos individually. Prior memories appear in matching campground details. Original imported photos remain in the user's photo library; cloud-only Photos items may need downloading first.

## Camp Finder

Camp Finder is online-only discovery through Apple Maps (MapKit), with no server or API key. The map shows campground and RV park points of interest as you pan; tap one to open its detail. Use **Near me**, **Search this area**, or search by campground name, city, park, or ZIP. Location permission is optional; text search works without it.

On iPhone Duo's open display, the results sit beside a map that fills the rest of the screen. On the cover display, and on every other device, the map stays at the top of the results list. Moving between the two keeps the search text, results, map position, and open place, and doesn't search again. On iPhone Duo, a campground's details open in a sheet over Camp Finder; tap **Done** to return to the same search.

Details include an address, **Website** for booking, **Call**, **Directions**, and Apple's **Photos, ratings & hours** place card where available. Save places to **Want to go**, **Have been**, or **Favorites**. **Add trip** prefills the campground identity, name, coordinates, and time zone; the time zone can be checked or set manually.

The app does not infer prices, hookups, amenities, rig fit, accessibility, or booking availability. There are no amenity/length/budget filters or **Use my rig** control. Apple Maps coverage is partial; an empty search does not mean there are no campgrounds. Offline, Camp Finder explains that it needs a connection and offers retry. Apple can throttle searches per device, with a specific explanation in the app.

Saved lists persist only Apple place identifiers; details are looked up online or names taken from the owner's trips. A saved identifier alone does not guarantee offline details. Offline maps and regional lists are deferred. See [data coverage](campground-data.md) and the [Camp Finder source guide](campground-sourcing.md).

## Weather

Tap the reading at the top right of Home to request location access. Location is approximate by default, rounded to about 1 km, and sent only to WeatherKit. The last reading remains visible offline.

Trips with campground coordinates also show per-day forecasts, cached with their download time for offline use. Home weather and trip forecasts display Apple Weather attribution. Fresh readings require connectivity and a provisioned WeatherKit capability.

## Camping help

The global **Assistant**, opened from the circular sparkle button at the bottom right above the tab bar on compact layouts, or Ask Assistant in the toolbar on regular iPad layouts, Mac, and accessibility text sizes, supports general camping troubleshooting without requiring a trip or a matching checklist entry. It keeps the conversation in memory when the sheet closes, so reopening continues it until New chat or the app quits, sends bounded recent turns to Apple’s on-device Foundation Models for follow-ups, and offers New chat. Conversations are not persisted or attached to trips. The button is hidden where Apple reports the device ineligible for Apple Intelligence; supported hardware keeps it for Apple Intelligence setup/model-download explanations. Disabled, preparing, and unavailable AI show a native recovery screen instead of the conversation or composer. Availability refreshes on foregrounding, retry, and while the screen is open. The conversation uses a scrolling transcript and fixed text/send composer, without attachments.

Initial model instructions include a bounded snapshot of the selected rig's saved make, model, year, floorplan code, length, slide/axle counts, bunkhouse, and equipment. It is retained on a context-overflow retry. These are owner-entered facts, not verified manufacturer specifications; numbers in model or floorplan names do not establish dimensions. Registration and photos are excluded. Routine questions receive task-specific guidance; emergency instructions are reserved for danger actually reported by the user.

Every answer comes from the model; there are no canned replies. Trip/checklist help sends the trip’s matching saved steps (or the selected step) as context and answers from general knowledge when they don’t cover the question. Reports of immediate danger (gas, carbon monoxide, smoke, sparking, shock, fire) instruct the model to prioritize getting to safety and contacting emergency services, without troubleshooting or repair steps. Routine maintenance receives precautions suited to the task. General chat uses the active rig’s default checklist notes when relevant. Questions stay on the device. The production adapter explicitly uses `SystemLanguageModel.default` and `LanguageModelSession.respond(to:options:)`; no remote provider, account, API key, or AI entitlement is required. It checks model and locale support before generation, uses fresh sessions with bounded recent context, limits unusually verbose output, and retries a context overflow once with a smaller prompt. Refusals, language/context failures, rate limits, and other generation errors show a retryable error and preserve the question instead of substituting checklist text, in both general chat and trip/checklist help. Questions longer than 1,500 characters are rejected for shortening rather than silently truncated.

Assistant works on iPhone, iPad, and Mac wherever Apple’s runtime reports Apple Intelligence available; there is no app-side device list. Disabled Apple Intelligence, a model not yet ready, and other runtime unavailability states show the recovery screen. Checklists and their notes remain available offline everywhere. Initial model download requires connectivity.

### Answers from your documents

The Assistant reads eligible documents on this device and offline, in the **Assistant scope** shown at the top of the chat. A Manual, Service & maintenance, Warranty, or Reservation document counts once its PDF or photo is saved on the device. Registration and Insurance are never read, even if an opt-in is somehow stored on one. Other is read only when the owner turns on **Include in Assistant** for that document (off by default). A link counts only after a copy is saved on the device, and chat never fetches a URL. Documents attached to nothing are never read. The rule lives in `AssistantDocumentEligibility`.

The opt-in is `StoredDocument.includeInAssistant`, shown in document details for Other documents only. Changing it saves through the library, which schedules the index sync: turning it on queues indexing, and turning it off removes the document from the index and from the next question's allow-list. It syncs through the existing iCloud mirroring.

- **General chat** (the sparkle button) is scoped to the active rig ("Rig: Forest River No Boundaries"): documents attached directly to that rig. It never reads a trip's documents and never picks a current or next booking.
- **Trip and checklist help** is scoped to that trip and its rig ("Trip: Pines · Rig: Forest River No Boundaries"): the trip's own documents plus the rig's. A past trip uses its rig even after the rig was replaced, shown as "(archived)". Another trip's documents are never read, even for the same rig.
- **Each request keeps its own scope.** The rig and trip are captured when the question is sent, and the documents are re-read from that scope right before the prompt is built. If the scope changes while a request runs (the active rig changes, or the trip moves to another rig), the request is canceled and the question returns to the message field. Earlier exchanges from another scope stay on screen, labeled "Asked in …", but are left out of the next prompt.
- **Follow-ups search again.** Document search uses the current question plus the previous user question in the same scope. Earlier answers are never part of the search text and are marked in the prompt as not sources; only passages found for this question can be cited.
- **Conversations.** General chat lasts until New chat or the app quits, even after closing the sheet. Each trip or checklist help sheet starts a new conversation.
- **Indexing** starts by itself after a PDF is saved or a link's copy is saved, and again on launch. Text comes from the PDF's text layer page by page, keeping each page's number and printed label; a page with no usable text layer (a scan) and every image document (JPEG, HEIC, PNG, TIFF, and so on) is read with on-device text recognition (Vision), so mixed PDFs are searchable on every page and sideways or upside-down scans are turned upright, and is split into short passages that never cross a page. Passages are searched by exact words (so a fault code or part number such as `E4` or `11-2047-B` is found as written) and by meaning, using Apple's English sentence embeddings. If the embedding model isn't on the device, search uses exact words alone. The index is stored once, reused when the app opens again, and only a changed or new file is read again.
- **English only.** Document questions work in English in this version. Each passage's language is read from its prose (never from the file name, a fault code, or a part number), and only confidently English passages are indexed, so other-language text can't be found by exact words or by meaning. A bilingual document contributes its English passages and is marked partial coverage (`englishPartial`); a document with no eligible English text is marked English-only. Both stay viewable and shareable. Short code rows take the language of their page. A question about the documents that is confidently in another language gets a short explanation and an invitation to ask in English, with no translation and no search; short or code-only questions such as `E4?` are never turned away. Chat with no documents in scope, and the model's own language support, are unchanged.
- **Asking** searches only the eligible documents in the current scope, uses what is already indexed, and never waits for the rest. While it works the chat shows "Searching your documents…".
- **Progress and cancel.** While a question runs, the chat lists only the stages that actually happened, in order: "Searching your documents…" (only when documents are searched), "Preparing your question…", and "Writing an answer…". Finished stages get a checkmark and the current one spins; there are no percentages. VoiceOver hears each stage as it begins and any failure. A failure shows "Couldn’t get a response" with **Retry**, which resubmits the same question even if the message field was edited. Each question has its own request identity: closing the sheet, a scope change, or a newer question cancels the running one, and its late result is dropped, so reopening shows nothing from it and the question returns to the message field.
- **Readiness.** Each document shows one status in its details, under **Assistant**: Queued, Reading, Indexing (with passages done), Ready, Read partially, Waiting for download, No usable text (with the reason: empty PDF, password-protected, can't be opened, image too large, or no text found), English only, Not supported, or Couldn't read yet. Each says what to do: queued, reading, indexing, and waiting for download say to wait (waiting for download is an iCloud file still arriving, never shown as a failure); no usable text and unsupported say to replace the file; a failure offers **Try again**; Ready and English only need nothing. Documents the Assistant never reads (other categories, links without a saved copy) show no status. The rules and wording are `AssistantDocumentStatus` and `ScopeReadiness` in CampCore, and `DocumentIndexState` maps onto them.
- **Coverage in chat.** Under the scope line, the chat summarizes the current scope ("2 of 3 documents ready · 1 being prepared"). Each request captures the scope's readiness when it is asked, including documents still waiting for download. If any document wasn't fully covered, the answer says so ("Not every document was searched: … This answer may be missing what they say."). If nothing relevant was found and some documents couldn't be searched, the answer says it can't yet support an answer from them (or that they can't be used, when that is final) instead of "your documents don't cover this", and the model is told the unread documents' contents are unknown and to state no document facts. Chat never waits for indexing.
- **Retry once ready.** When a document an answer was missing becomes ready, a **Retry** control appears under that answer. The earlier answer is kept; tapping Retry asks the same question again (with only the conversation that preceded it) as a new answer, and nothing is ever asked or replaced automatically. It is offered only in the scope the question was asked in, and does not touch what is typed in the message field.
- **Answers** cite passages as `[S1]`-style markers that the app resolves. Only sources the model actually cited from the excerpts it was given appear, as a Sources list under the answer (document title, type, and page). An ID that wasn't supplied is dropped.
- **Scanned paperwork** is read with these limits: each page is drawn to a bitmap of at most 2,400 pixels on a side and 5 million pixels (one at a time, so memory stays bounded however large the page declares itself); at most 120 pages and 240 seconds of recognition per document (later scans stay unread and the document is marked partly read); image documents over 64 million pixels are not decoded; a multi-page TIFF is read to 40 frames. Table rows are kept on one line ("Front axle | 35 psi") so a value stays beside its label. A blank, empty, password-protected, or unreadable file is recorded once as having no usable text and isn't read again until it changes. If recognition itself fails (for example while its model is still preparing), nothing is recorded and the next sync tries again.
- **Scanned text may be misread.** Recognized passages carry the recognizer's confidence. The Assistant is told which excerpts are scanned, and for low-confidence ones to say the text may be misread, ask the owner to check the original page, and never state a number, part code, or fault meaning from them as exact. The Sources list marks scanned sources, and an answer that cites low-confidence text shows a caution to check the original page.
- **Sources and references searched** are kept apart under each answer. "Sources" are the passages the model cited, validated against what it was given. "References searched" (dashed, with a search icon, and read by VoiceOver as "Searched, not cited") are excerpts it was given but did not cite; they are never described as used. An answer with no citation shows a short note instead of an empty list ("General advice. No document was cited.", "Your documents don't cover this.", or "No documents were searched."). Bundled checklist attribution is a separate link and never appears among document sources.
- **Opening a source** checks the library at the moment of the tap, comparing the document's current checksum with the one the passage came from. An unchanged PDF or image opens at the cited page. A replaced file shows "Changed since this answer" and opens the current version only if the camper chooses "Open current version" (at its first page, since the cited page may not apply). A deleted document shows "No longer in your library". A document whose file hasn't downloaded yet says it is waiting. The state rules live in `CampCore` (`SourceResolution`, `AnswerSources`). Quick Look preview and share in Documents are unchanged.
- **Saved trip facts.** Trip and checklist help also gets the trip's saved booking facts in their own labeled block, apart from document excerpts and marked as entered by the owner, not instructions: campground, arrival and departure dates, check-in and check-out times (with the campground's time zone), site, and confirmation number. Facts you left empty are left out. General chat gets none of this. When a question is about the booking, the Sources list begins with a plain, non-tappable **Saved trip** row.
- **Conflicting booking facts.** When the saved trip and a Reservation document give different values for the same fact on the same date and time zone, or two documents differ, the Assistant gives each value with its source (saved trip, or document title and page with its `[S#]` marker) and leaves the choice to you. It never ranks by file name, import date, or search score, never says it checked every document (it only sees the excerpts supplied), and never changes saved trip data. A time on a different date or in another time zone is not reported as a conflict. For booking questions in trip help the app runs one more search, limited to the trip's Reservation documents, so a second confirmation that disagrees is not missed; up to two of its passages are added ahead of the weakest first-pass ones.
- **Not covered:** when no passage is relevant, the answer says the documents don't cover it, with no invented specifications. A passage is relevant if it contains the exact fault code asked about, or a number from the question, or at least half of the question's significant words (see `DocumentRelevance`). An answer that doesn't cite anything is labelled general advice.
- **Safety and privacy:** excerpts are untrusted text. Instructions inside a document are ignored and links in it are never opened. Document text, vectors, and questions are never logged or sent off the device. The index is excluded from backups and removed by Erase all data.

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
