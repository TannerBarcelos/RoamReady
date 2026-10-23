# Data sources and coverage

[Documentation index](README.md) · [Camp Finder data source](campground-sourcing.md)

## Owner-entered rig details

v1 stores owner-entered rigs; it does not ship or query a rig catalog. RV makes, models, years, and floorplans number in the tens of thousands, and the investigated free sources did not cover them adequately. Manual entry avoids presenting a partial catalog as complete.

Rig details are stored as SwiftData `Rig` models and referenced by trips. RV year, make, model, and length are required; older profiles without a length still open and request missing fields on their next edit. A licensed or permitted catalog lookup is post-v1 (#29); earlier rig-source research remains in git history.

## Current campground source

Camp Finder uses **Apple Maps through MapKit**, online only. There is no owned campground catalog, provider key, v1 backend, or dataset refresh pipeline to provision.

| Available from Apple Maps | Limits |
| --- | --- |
| Campground/RV park name and location | Coverage is partial, especially for primitive/dispersed sites. |
| Address, phone, website, and time zone where supplied | Each can be missing; the trip form lets the owner check/set its time zone. |
| Apple's own place card | Photos, ratings, and hours are rendered by Apple where available; list rows do not show numeric ratings. |
| Campground/RV park points of interest and search | Requests need connectivity and can be throttled per device by Apple. |

MapKit does not supply site inventory, booking availability, prices, hookups, accessibility, or rig/site-length compatibility for this app. Those facts are not inferred. There are no amenity, length, or budget filters. Reserve through the campground's website or by phone, then record the booking in RoamReady.

## Saved places and trip records

Apple Maps places use `apple:<MKMapItem.Identifier>` as the library identity. Saved lists store only that identifier. When a row is shown, the app uses the owner's trip name if one exists or looks the place up online; otherwise it can show **Saved campground**.

Search results and place cards stay in memory for the session. Adding a trip saves the chosen campground name, coordinates, and time zone as the owner's booking record. A trip remains readable if Apple later stops listing its campground.

Manual campground entry uses a `local:<uuid>` identity reused for later trips with the same name, allowing completed trips to appear in **Have been**.

Trip site details come from the owner's reservation or observations. The listing does not automatically fill site number, length, or hookups.

## Privacy, attribution, and provider behavior

Camp Finder's **Near me** requests optional location permission; text search and manual trip entry work without it. Search regions go to Apple Maps through MapKit. Device location is not stored in the library; chosen campground coordinates are stored with a trip.

Apple supplies the map and place card presentation/attribution. The repository's MIT software license does not grant blanket rights to third-party images, narratives, trademarks, or linked materials. Do not treat Maps search results as an owned, redistributable campground dataset.

See the [Camp Finder source guide](campground-sourcing.md) for exact requests, storage rules, throttling behavior, and release checks.

## Offline coverage

Offline maps and region-limited offline campground lists are deferred to v2 (#20). Current core trip records remain available offline; discovery/place details do not become an offline directory just because a place is saved. See the [release plan](integration-plan.md).
