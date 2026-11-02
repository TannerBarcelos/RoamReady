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

**Menu**:
What a camper plans to eat on a **Trip**: its days, each with **Meals**. Deleting a trip deletes its menu.

**Meal**:
One eating occasion on one day of a **Trip**: Breakfast, Lunch, Dinner, Snacks, or one the camper names. A meal holds **Dishes**.

**Dish**:
One whole plate within a **Meal**, like "Steak with brussels sprouts and sourdough". It lists its **Ingredients**.
_Avoid_: Recipe, menu item

**Ingredient**:
One part of a **Dish** with an optional **Amount**, like "Ribeye, 2 lb".
_Avoid_: Recipe item, grocery item

**Amount**:
A number chosen from a list together with a unit chosen from a list, like "2" and "lb". **Grocery list** rows add up amounts that share a unit.
_Avoid_: Quantity (the retired free-text field)

**Repeat**:
Copying a **Meal**'s **Dishes** to other days of the **Trip**. Each day gets its own independent copy, so changing one day's dish doesn't change the others.
_Avoid_: Linked dish, recurring meal

**Grocery list**:
A **Trip**'s **Ingredients** gathered from its **Menu** to show what the camper still needs. It always reflects the current menu. A camper can set a different amount on a row without changing the **Menu**.
_Avoid_: Shopping list, generated list

**Category**:
The grocery store section a camper chooses for an **Ingredient**, like Produce or Dairy & Eggs.

**Have**:
An **Ingredient** the camper doesn't need to get, whether bought or already on hand. The opposite is **Need**.
_Avoid_: Bought, purchased, in stock

**Would not go**:
A campground the camper wants to avoid and hasn't visited.

**Would not return**:
A campground the camper has visited and wouldn't go back to.

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

**Camper:** I repeated breakfast across the trip, then changed Saturday's. Does Sunday change?

**Developer:** No. Repeat gives each day its own copy of the dishes and their ingredients.

**Camper:** I already bought the eggs, but I just repeated breakfast onto another day.

**Developer:** Eggs moves back to Need on your grocery list, because that new day's ingredient isn't something you have yet.
