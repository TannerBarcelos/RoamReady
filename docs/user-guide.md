# User guide

[Documentation index](README.md) · [Feature reference](features.md)

RoamReady organizes camping trips and their checklists, paperwork, and memories. The current app is a development build; see [build and validation](validation.md) to run it.

## Set up your rig

1. On first launch, choose your rig category and confirm its equipment.
2. For an RV, enter year, make, model, and length. Add optional details such as slide-outs or floorplan if useful.
3. Optionally, fill in **Registration**: VIN, license plate, and state or province. A VIN from 1981 on is 17 characters. Type it however it's printed; spaces, dashes, and lowercase are cleaned up. Tents skip this section.
4. Choose a rig photo or emoji and optionally add your name and experience level.
5. Complete onboarding. No account or internet connection is needed.

Your VIN and plate then appear in **Profile › Your rig**; press and hold to copy them into a booking or check-in form. Change them with **Edit rig**.

If your build supports iCloud, onboarding and Profile → Settings offer **Sync with iCloud**. The preference starts on in configured builds. You can change it offline; changes take effect the next time you launch the app, and the current session's setting is shown until then. Apple manages reconnection and retries automatically. Turning it off deletes neither your local data nor an existing iCloud copy. The default development build has no configured container and saves locally. [Storage and sync](offline-storage.md) explains configured builds.

## Find your way around

| Tab | Use it to |
| --- | --- |
| Home | Return to your current trip, see how long until your next one, review progress and memories, add a trip, or check local weather. |
| Trip | Add a booking without leaving your selected tab. |
| Camp Finder | Explore online campground listings and save places. |
| Profile | Edit your rig/profile, manage checklist defaults and documents, revisit Trip history and Your campgrounds, or open Settings with the gear. |

Home shows the earliest-arriving active trip from arrival through the end of departure day in the campground’s time zone. It disappears when its dates end or you mark it complete; other current and upcoming trips stay on Home. Completed trips move to **Profile → Trip history**, newest first. Setup, teardown, and Photos & site notes open directly from Home.

## Add and manage a trip

Reserve with the campground or booking provider first. RoamReady keeps the details of that booking.

1. Tap **Trip** (the + in the tab bar) from anywhere, or start from a Camp Finder listing.
2. Enter the campground name, select your rig, and set arrival/departure dates. Offline, enter the name directly.
3. Optionally add site/loop, site length and hookups, booking provider, confirmation number, HTTPS booking link, check-in/out times, costs, cancellation deadline, and initial site notes.
4. Save. The trip gets fresh setup and teardown lists from its rig's defaults.

Open the trip to use its booking link, view confirmation documents, or open directions when available. Use **Trip options → Edit trip** to change details. Check-in/out times use the campground's local time zone. A cancellation deadline is a reference field; the app does not send a reminder or cancel a booking.

Trips become complete after departure; you can also choose **Mark trip complete**. A manually completed trip can be reopened while its dates have not passed.

## Use and customize checklists

Open a trip's **Setup** or **Teardown** checklist. Complete, uncheck, or skip steps as you go; add, rename, delete, or reorder them to suit the trip.

Tap a step's info button to set its **Priority** (None, Low, Medium, or High) and add **Notes**, as in Reminders. The list shows `!` to `!!!` before the title and your notes under it. Notes are separate from the step's **Guidance**. Saving a trip's lists as defaults keeps their priorities and notes, so the next trip starts with them.

Trip edits do not change other trips or the rig's defaults. To reuse a trip's customized lists, choose **Save as defaults for <rig>** and confirm. In Profile, **Default checklists** edits a rig's reusable lists, and **Reset default checklists** regenerates them from its rig type. Existing trips keep their copies.

Follow your manufacturer's instructions for equipment-specific procedures.

## Keep documents available

Use your rig's **Manuals & paperwork**, a trip's **View confirmation & documents**, or document import during onboarding.

1. Choose a PDF/image file or add an HTTPS link.
2. Give it a title and choose its document category. Optionally add notes and issue/expiration dates.
3. Save, then open it to preview or share.

Files can be up to 50 MiB. Imported originals already on the device open offline. A link needs a connection until a copy is saved; **Waiting to download from iCloud** means the file is not yet on this device. New files are encrypted automatically when synced to your private iCloud; there is no separate encryption setting.

Documents retained after a trip or rig is deleted appear in **Profile → Unattached documents**. See the [document vault](document-vault.md) for protection and availability details.

## Add memories

Open **Photos & site notes** from a trip. Take a photo or import one, add captions and notes, record the site number, and choose whether you would return or avoid it. Share photos individually when needed. A photo stored only in iCloud Photos may need downloading before an offline import.

Memories linked to a Camp Finder campground also appear in that campground's detail view on a later visit.

## Discover campgrounds

Use **Camp Finder** while connected. Pan the map to see campgrounds and RV parks, then tap a place; choose **Near me** or **Search this area** for regional results, or submit a campground name, city, park, or ZIP. Near me asks for location permission; text search works without it.

Open **Website** or **Call** to arrange a reservation with the operator, then return and choose **Add trip**. Check the prefilled campground time zone and enter the booking/site details yourself. **Directions** opens Apple Maps, and **Photos, ratings & hours** opens Apple's place card. Save places to **Want to go**, **Have been**, or **Favorites**.

Apple Maps does not list every campground or provide site availability, hookups, prices, or rig compatibility. An empty result does not prove there are no campgrounds; you can always add a trip by name. Offline, use the retry action after reconnecting; saved marks remain local, but a place identifier alone does not preserve its details offline. See [coverage and sources](campground-data.md).

## Check weather and camping guidance

Tap Home's weather reading to request location access and fetch local temperature. Trips with campground coordinates show forecasts. Offline readings are saved data; check their retrieval time. Live weather requires a build configured for WeatherKit.

Tap the circular sparkle button at the bottom right above the tab bar on compact layouts, or **Ask Assistant** in the toolbar on regular iPad layouts, Mac, and accessibility text sizes for general camping or troubleshooting questions, including when you have no active trip. Follow up in the same conversation or choose **New chat** to start over. Closing the Assistant keeps the conversation for when you reopen it; it isn't saved once the app quits. The button is hidden on devices that can’t run Apple Intelligence. Supported iPhones, iPads, and Macs still show it when Apple Intelligence needs enabling or its model is preparing. In those states, a native recovery screen replaces the conversation and composer; enable AI in Settings or wait for the model, then choose Try again. Availability also refreshes on foregrounding and while the screen is open.

The text-only conversation has a message field and send button, with no file or image uploads. It stays while switching tabs, but is not saved across app launches or attached to a trip. The model receives a bounded recent conversation and relevant rig checklist guidance.

Use **Ask for camping help** from a trip or checklist for answers that draw on that trip’s checklist notes. AI runs on device when Apple Intelligence is enabled and its model is ready. If it can’t answer, you see an error and your question is kept so you can edit or retry. Unsupported languages show recovery instructions. Keep questions within 1,500 characters; longer questions are preserved with a request to shorten them.

## Choose an appearance

In **Profile → Settings → Appearance**, select **System**, **Light**, or **Dark**. System follows your device setting; the other choices stay fixed. The setting is saved on this device and works offline.

## Change rigs

In Profile, **Edit rig** changes details shown by every trip using that rig. When changing to a different rig, use **Replace rig**: the old rig is archived and remains on past trips.

Only one rig can be active in v1. Open **Archived rigs** to reactivate one within that limit, or delete a rig that no trip uses. Deleting an unused rig removes its defaults and leaves its documents unattached. If two devices produce extra active rigs before syncing, archive the one you no longer use.

## Export or delete data

**Profile → Settings → Prepare export** creates a zip containing library metadata and verified original document files. Encrypted documents are readable in the export, so store it privately. Photo bytes are not included; share trip photos individually. Review missing-file statuses before relying on the archive. There is no in-app restore workflow.

**Cancel & delete trip** permanently removes its checklists/progress, notes/history, trip photos/captions, and site rating after confirmation. Its documents are kept as unattached, and its rig/defaults and original library photos remain. Cancel the actual reservation separately with its provider.

**Profile → Settings → Erase all data** removes the app's library and, in a configured build, its iCloud zone. Read the confirmation carefully; the cloud step requires connectivity and the signed-in iCloud account, even if sync is currently off. Other devices retain their local copies until erased there. See [erasing data](erase-data.md) for the exact process and limits.
