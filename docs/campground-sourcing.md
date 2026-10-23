# Camp Finder data source

Camp Finder (#26) finds campgrounds and RV parks with **Apple Maps (MapKit)**, online only. There is no server, API key, paid provider, scraping, or owned campground catalog. Offline maps and offline campground lists are v2 (#20).

## How it works

- **The map shows only campgrounds and RV parks.** `mapStyle(.standard(pointsOfInterest: .including([.campground, .rvPark])))` hides every other kind of place, so campgrounds appear as the person pans with no searching. Tapping one looks it up (`MKMapItemRequest(feature:)`) and opens its detail.
- **Near me / Search this area** list the campgrounds in a region with `MKLocalPointsOfInterestRequest`, filtered to campgrounds and RV parks. Location permission is optional.
- **Typed text** (a campground's name, a city, a park, a ZIP code) runs two lookups:
  - an `MKLocalSearch` for campgrounds matching the text;
  - an address search for the place it names, then the campgrounds within about 25 km of it.
  The results are merged, each place once, nearest first. Searches run when the person submits, never on every keystroke.
- **Cost and limits.** MapKit is free to use from an iOS app and needs no key. Apple throttles requests per device (`MKError.loadingThrottled`), which the app explains ("Apple Maps is limiting searches from this iPhone for a moment"). There is no shared quota that one person, or an abuser, can use up for everyone.

## What is shown

| From Apple Maps | Never shown or inferred |
| --- | --- |
| Name, campground or RV park, address | Nightly prices |
| Phone (Call) | Hookups, amenities, accessibility, rig or site-length limits |
| The business's website (Website): where people book | Site availability or booking |
| Location (Directions in Apple Maps) | Rig compatibility ("Use my rig" and the amenity filters were removed) |
| Time zone (prefills Add trip) | |
| Apple's place card: photos, ratings, and hours where Apple has them | |

MapKit gives the app no rating numbers, so list rows don't show ratings. **Photos, ratings & hours** opens Apple's own place card (`mapItemDetailSheet`), which shows whatever Apple Maps has for the place, attributed and rendered by Apple.

The booking flow: find a campground → **Website** (or **Call**) → book with the campground → come back → **Add trip** with the booking details.

Apple Maps doesn't list every campground, especially primitive or dispersed sites, so an empty search says so and points to adding a trip by name.

## Identity and storage

- Trips and saved lists refer to a Camp Finder place as `apple:<MKMapItem.Identifier>`. Apple provides this identifier so apps can store it and look the place up again (`MKMapItemRequest(mapItemIdentifier:)`).
- Saved lists (Want to go, Have been, Favorites) store **only the identifier** for Apple Maps places. Their details are never copied into the library. The saved-campgrounds screen:
  - shows the name from a trip there (the owner's own record), or
  - looks the place up in Apple Maps as each row comes into view while online (one lookup per visible row, never the whole list at once), or
  - shows "Saved campground" offline.
- Places found this session are kept in memory only, for showing details and directions; search results and place cards are not persisted. Adding a trip stores its chosen name, coordinates, and time zone in the booking record.
- **Add trip** prefills the identifier, name, location, and the campground's time zone from Apple Maps. The time zone is always shown in the form so it can be checked or set by hand. The trip's name and dates are the owner's record and stay readable if Apple Maps stops listing the place.
- Campgrounds entered by name get a local identity, `local:<uuid>`, reused for later trips with the same name, so they appear in Have been after a completed trip.

## To check before release

Tracked in the Camp Finder simulator and device sections of #10:

1. **Coverage where people camp:** national forest, BLM/desert, state park, and town RV park searches return sensible places, and tapping campgrounds on the map opens them.
2. **Place details:** how often Apple Maps has a website, a phone number, and a time zone for campgrounds. Each is optional in the app; a missing time zone leaves the device's zone selected in the trip form for the person to change.
3. **Throttling:** rapid searches show the throttling message rather than a generic failure.
4. **Place card:** Photos, ratings & hours opens Apple's card and returns to the app.
