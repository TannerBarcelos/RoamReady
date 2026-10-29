# RoamReady

RoamReady keeps a camper's rigs, campground bookings, checklists, documents, and memories together for use while camping.

## Language

**Rig**:
The camper's camping setup, including a tent or RV. One rig is active; archived rigs remain associated with their past **Trips**.

**Trip**:
One booking at one campground, associated with a **Rig**. A trip owns its checklist copies, photos, and site notes.
_Avoid_: Itinerary, multi-stop journey

**Rig defaults**:
The setup and teardown checklist templates belonging to a **Rig**. A new **Trip** receives independent copies; changing those copies does not change the defaults.

**Document**:
A saved piece of paperwork, such as a manual, warranty, service record, or reservation confirmation, represented by an imported file or a link. It can be associated with a **Rig**, a **Trip**, or neither.

**Reservation document**:
A **Document** containing booking evidence or terms. Its contents are distinct from the dates, site, and confirmation details the camper enters on a **Trip**.
_Avoid_: Trip (when referring to the file)

**Conflicting booking facts**:
Different values for the same booking detail in a **Trip** and its **Reservation documents**, or across those documents. The Assistant presents the disagreement and its sources for the camper to resolve.

**Unattached document**:
A **Document** associated with neither a **Rig** nor a **Trip**, including paperwork retained after its former owner is deleted. It is outside every **Assistant scope** until assigned to a rig or trip.

**Assistant scope**:
The **Rig** or **Trip** whose documents the camper is asking about. General Assistant uses the active rig; Assistant opened from a trip includes that trip and its rig.

## Example dialogue

**Camper:** I replaced my rig. Does that change my old bookings?

**Developer:** Your old trips still refer to the archived rig. A new trip uses your active rig and copies its rig defaults.

**Camper:** If I delete a trip, do I lose its confirmation PDF?

**Developer:** Its reservation document stays in your library as an unattached document.

**Camper:** Can the Assistant use that retained document for another trip?

**Developer:** Only after you assign it to that trip, and only if its document category is allowed in Assistant search.

**Camper:** Which confirmation will the Assistant use for my check-in question?

**Developer:** Open the Assistant from that trip. Its scope includes that trip's documents and its rig's documents; general Assistant does not choose a booking for you.

**Camper:** My trip says check-in is at 2 p.m., but the confirmation says 3 p.m.

**Developer:** The Assistant shows both values and where they came from. Your saved trip stays unchanged until you edit it.
