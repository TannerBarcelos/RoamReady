# Campground and individual-site sources

Research checked 2026-10-19. Scope: North America initially, with the implemented federal snapshot limited to the United States. No accounts were created, keys obtained, or paid services purchased. No endpoint access controls were bypassed.

## Recommendation and actual acquisition

Use **RIDB federal campground + individual-campsite data** as the first substantial source, supplement NPS structured campground details, and evaluate OpenStreetMap for broader campground discovery and selected mapped pitches. None is a complete source of private/state/local campgrounds, real-time occupancy, bookable dates, or trustworthy equipment compatibility for every numbered site.

The official RIDB [download page](https://ridb.recreation.gov/download) offers “all the RIDB recreation area, facility, and site level data” in CSV/JSON, marked **Updated Daily**. Exact publicly offered compressed exports:

- [JSON ZIP](https://ridb.recreation.gov/downloads/RIDBFullExport_V1_JSON.zip)
- [CSV ZIP](https://ridb.recreation.gov/downloads/RIDBFullExport_V1_CSV.zip)

A keyless HEAD request to the JSON archive returned HTTP 200, `application/zip`, **572,761,198 bytes** (about 546 MiB), last modified 2026-10-18 18:46:40 GMT. The root implementation downloaded and inspected it, finding **15,432 facilities**, **5,803 explicitly classified Campground**, and **130,856 campsite records** attached to 4,965 facilities. These are export counts, not complete national coverage.

The app import subsequently retains **5,260 enabled Campground facilities with valid coordinates** and **111,647 overnight, non-management sites**, using a campground index plus 64 site shards. See the importer and generated manifest for the authoritative build counts. The snapshot excludes photographs and long narrative descriptions. This is actual published site-level data, not a fabricated example database. Its date must remain visible: downloading an export does not make it live reservation inventory.

## Source comparison

| Source | Access/cost evidence | Useful details and limits | Reuse/offline implications |
| --- | --- | --- | --- |
| **RIDB / Recreation.gov** | Public daily bulk ZIP requires no key. API requires registered key; unauthenticated `/api/v1/facilities?limit=1` returned 401. Public portal/docs inspected; no paid subscription was required for bulk access. API spec documents 50 requests/second and 50 records maximum per page; actual enforced quotas can differ. | Federal facilities and individual sites: stable FacilityID/CampsiteID, name/number, loop, site type, overnight/day use, coordinates, attributes, permitted equipment and maximum lengths where present, source update date. Agencies supply data and may omit or misstate fields. Federal scope does not mean every federal campsite is represented. | Preserve RIDB/agency attribution and source IDs. Portal terms distinguish API/documentation/key (“API Vendor Materials”) from government-provided responses; do not redistribute keys or expose a general substitute API. Public bulk export is intentionally downloadable. No blanket photo/image license was established; omit images and expressive descriptions from the app snapshot. Commercial release should retain the export provenance and review applicable provider/agency terms rather than claim all content is unrestricted. |
| **NPS API** | [Get started](https://www.nps.gov/subjects/developer/get-started.htm) explicitly says API key acquisition is “free and easy.” [Guides](https://www.nps.gov/subjects/developer/guides.htm) and [API docs](https://www.nps.gov/subjects/developer/api-documentation.htm). Keyless test returned HTTP 403, so no authenticated live response was verified here. | `/api/v1/campgrounds` gives campground descriptions, coordinates, fees, reservation links, aggregate site counts by accommodation type, amenities and accessibility information. It is **not** a directory of every numbered pitch or site-level availability. National Park Service scope only. | [NPS disclaimer/copyright](https://www.nps.gov/aboutus/disclaimer.htm): much NPS-created material is public domain but third-party contributions can be protected; government marks and photographs require per-asset review. Retain attribution and refresh dates. Do not infer individual-site attributes from campground-wide summaries. |
| **OpenStreetMap** | Free ODbL map database; no key on common community Overpass endpoints, whose capacity is shared. [Overpass API](https://wiki.openstreetmap.org/wiki/Overpass_API) documents appropriate use and individual instance policies. | `tourism=camp_site`, `tourism=caravan_site` locate campgrounds/RV parks; `tourism=camp_pitch` can identify individual sites with `ref`, equipment and power-supply tags. Global coverage and varying completeness. Pitch polygons/nodes may lack a reliable parent relation or official site number. Do not equate unmapped with nonexistent. | [Copyright/ODbL](https://www.openstreetmap.org/copyright) requires OpenStreetMap contributor attribution and license obligations; derived databases may trigger share-alike. Keep provenance/layer separable and evaluate release obligations before merging into a proprietary catalog. Do not use public Overpass servers as every user's unbounded live backend; generate regional packs or use suitable hosting/extracts. Tile use has separate terms and is not permission to bulk-download standard map tiles. |
| **US Forest Service** | Official [Interactive Visitor Map](https://www.fs.usda.gov/ivm/) and [USFS geospatial data entrypoint](https://data.fs.usda.gov/geodata/) are discovery candidates. IVM and tested USFS pages returned HTTP 403 in this environment; no access controls were bypassed and no independent USFS endpoint schema/throughput guarantee is asserted here. | Strong recreation-site/trail/facility information, generally campground/recreation-facility scale. No verified nationwide API for every numbered campsite in this pass. Many USFS reservable sites are already represented in RIDB. | Use RIDB USFS records first to avoid duplicate providers/IDs. Audit each USFS layer's metadata, currency, license and coordinates before adding it; do not assume one agency-wide data standard or that facility features are individual sites. |

## RIDB endpoints and documented schema

Primary source: current [OpenAPI YAML](https://ridb.recreation.gov/shared/swagger/ridb.yaml), linked by the official [API docs](https://ridb.recreation.gov/docs). Inspected the real specification, not inferred endpoint names.

- `GET https://ridb.recreation.gov/api/v1/facilities` — `query`, `state`, `latitude`, `longitude`, `radius` (miles, maximum 25), `limit` (1–50), `offset`, `full`, activity and update filters.
- `GET .../facilities/{facilityId}` — one facility; `full=true` for related information.
- `GET .../facilities/{facilityId}/campsites` — individual sites for that campground; paginated `limit` / `offset`.
- `GET .../campsites/{campsiteId}` — one site's current descriptive record.
- `GET .../campsites/{campsiteId}/attributes` — attributes; also present in site records as `ATTRIBUTES`.

Header authentication is `apikey: <registered key>`. Collection responses contain `RECDATA` and `METADATA.RESULTS.CURRENT_COUNT/TOTAL_COUNT`, with paging parameters under `METADATA.PARAMETERS`. Single-record endpoints return an object rather than the collection envelope.

Site fields include `CampsiteID`, `FacilityID`, `CampsiteName`, `CampsiteType`, `TypeOfUse`, `Loop`, `CampsiteAccessible`, latitude/longitude, `LastUpdatedDate`, `ATTRIBUTES` (`AttributeName`/`AttributeValue`) and `PERMITTEDEQUIPMENT` (`EquipmentName`/`MaxLength`). Source casing/types must be preserved at the adapter boundary. Raw attribute strings are not an enumerated stable amenity contract.

**Critical interpretation:** the current spec describes `CampsiteAccessible` as **“Is the campsite accessible by vehicle.”** It must not automatically be shown as wheelchair/ADA accessibility. Use specifically identified accessibility attributes, descriptive text and operator verification. A campground may have accessible restrooms while its individual sites do not meet a user's access needs.

Zero/absent equipment lengths mean unknown, not unlimited or unsuitable. Do not replace trailer limits with motorhome limits. Treat an omitted electrical/water/pet field as unknown. Raw attributes and equipment names need a reviewed normalization dictionary, and a site with multiple attribute records should retain conflicting values for review rather than silently claim certainty.

## Availability and booking are separate

RIDB's ordinary campsite endpoints describe sites; `Reservable` and a reservation URL are not current availability. The current portal exposes a separate [Availability API specification](https://ridb.recreation.gov/shared/swagger/availability.yaml), but its documentation tab is gated by tier1/admin access in the public app code. Public visibility of the YAML does not establish eligibility or authorization to call that service. Do not scrape or rely on undocumented Recreation.gov reservation inventory endpoints.

For this build, show site details with snapshot dates and open the official booking page when online. Do not mark dates available or promise a booking from the federal snapshot. A site can be seasonal, closed, reserved, offline-only, first-come or restricted even if present in the export.

## Live refresh (post-v1, #18)

No live provider client ships. The bundled and downloaded RIDB snapshots need no key. A future live refresh needs a bounded backend that owns the RIDB key (allowlisted routes, geographic bounds, size and rate limits, caching); never ship provider keys in the app. The client prototyped earlier is in git history.
