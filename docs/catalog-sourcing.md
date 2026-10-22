# RV catalog sourcing and release plan

Research date: 2026-10-18; independent source audit: 2026-10-19. Initial geographic scope: North American RV products. This is an explicit implementation assumption, not worldwide coverage. No vendors were contacted, accounts created, feeds purchased, or image licenses obtained.

## Result

> **Status (v1):** the app no longer bundles or queries a rig catalog; owners enter year, make, model, length, and optional details. This report and `data/catalog/` are retained as research for a possible future lookup.

The original app seed contained **82 source-backed starter records across three makes**, model year **2025**. Every record has a primary-source URL. It covers travel trailers, fifth wheels, Class A and Class C motorhomes, Class B camper vans, and truck campers. Folding camping trailers remain a sourcing gap after the audit below. Car camping, tents, conversions, and missing models use manual entry rather than invented manufacturer records. No manufacturer photographs or floorplan drawings are included.

This is **not** the complete curated database requested for the finished product. The source discovery and acquisition strategy below identify how to build that database; a production license, systematic extraction, and independent editorial verification remain outstanding. No public source investigated establishes complete make/model/year/floorplan coverage or blanket offline redistribution rights.

The best commercial lead is **J.D. Power Specialty Industry Web Services**, whose official product page explicitly offers RV year/make/model/trim data for application integration. Ask for a coverage sample and an offline distribution agreement. Do not confuse it with their general automotive APIs. Supplement any licensed feed with manufacturer archives and an editorial exception queue. [Specialty Web Services](https://www.jdpowervalues.com/get-values/web-services)

## Source inventory

“Observed” means an official source was inspected or located in primary-site search results during this research. A year span describes visible archive entries, **not a guarantee that every intervening model, year, or floorplan exists**. “Gap” means coverage or extraction remains to be established. Current product pages can silently advance to a new model year; prefer dated brochures and year-specific pages.

### THOR-associated manufacturers and brands

Corporate ownership is useful for outreach, but must not replace the consumer-facing make. THOR's official [company directory](https://www.thorindustries.com/thor-companies) is a discovery source. Brand ownership and operations change: their [2025 Heartland realignment announcement](https://ir.thorindustries.com/investor-resources/press-releases/press-release-details/2025/THOR-Announces-Strategic-Realignment-of-Heartland-Recreational-Vehicle-Company/default.aspx) describes private-label transfers. Preserve historical make names and effective dates.

| Manufacturer / group | Primary source | Observed coverage and acquisition work |
| --- | --- | --- |
| Airstream | [Document archive](https://www.airstream.com/owners/document-archive/), [current brochures](https://www.airstream.com/support-tools/explore-compare/request-a-brochure/) | Official support directs vintage research to the archive. Travel trailers and touring coaches. Enumerate archive years and model documents; no complete year span validated. Seed uses dated official 2025 press release facts; re-fetched and checked on 2026-10-19. A previously indexed Classic brochure URL returned 404, demonstrating the need for source monitoring. |
| Jayco | [Product archives](https://www.jayco.com/rvs/archives/) | Visible archive selector: 2023–2026; current navigation includes 2027. Travel trailers, fifth wheels, toy haulers, camping trailers, and Class A/B/C. Older documents may exist outside the current selector. Regional suffixes such as `W` must remain distinct. |
| Entegra Coach | [Previous model years](https://www.entegracoach.com/models/previous-model-years/) | Official archive endpoint located. Some old product URLs now redirect to this index. Re-enumerate documents instead of trusting old page slugs. Full historic span not established. |
| Highland Ridge | [2020 travel-trailer archive](https://www.highlandridgerv.com/rvs/archives/2020/travel-trailers/), [2021 archive](https://www.highlandridgerv.com/rvs/archives/2021/travel-trailers/) | Older official category pages remain indexed. Current and historic Open Range lineage needs normalization; complete archive extraction pending. |
| Keystone | [Brochures](https://www.keystonerv.com/brochures), [marketing resources](https://www.keystonerv.com/marketing-resources) | Current models and marketing assets. Historical east/west versions need separate sourcing. Marketing availability is not permission for a consumer app to redistribute files. No official complete historical span verified. |
| Dutchmen | [Brochures](https://www.dutchmen.com/en/brochures), [manuals](https://www.dutchmen.com/en/owners-manuals) | Current brochure hub located. Older brochures require additional manufacturer/dealer archival research. Preserve model-family and private-label lineage, including licensed brand names. |
| Heartland | [Brochure archive](https://heartlandrvs.com/brochures/), [model lineup](https://heartlandrvs.com/all-brands/) | Official archive and older dated PDFs found. Model lines and manufacturing assignments have changed. Capture source-era identity; do not relabel old rigs with current ownership. |
| CrossRoads / Redwood | [Manufacturer entry point](https://www.crossroadsrv.com/) | Official historical archive not validated in this pass. Third-party copies exist, but their existence does not establish reuse rights. Request manufacturer/licensor backfill; keep gap explicit. |
| KZ / Venture | [Official 2007 KZ brochure example](https://www.kz-rv.com/brochures/2007/2007-KZ-RV-Outdoorsmen-Brochure.pdf), [2018 example](https://www.kz-rv.com/brochures/2018/2018-KZ-RV-Connect-Lightweight-Travel-Trailers-Flyer.pdf), [Venture brochure archive](https://www.venture-rv.com/brochures/), [Venture product archive](https://www.venture-rv.com/product-archive.html) | Dated KZ files provide historical evidence. Do not assume a year directory is exhaustive. Venture has separate archive pages. |
| Thor Motor Coach | [Brochures and archive](https://www.thormotorcoach.com/brochures) | Current and archived motorized brochures; official dated 2025 PDFs located. Legacy Damon/Four Winds identities require alias and historical-manufacturer rules. Exact earliest year not established. |
| Tiffin | [Brochures](https://tiffinmotorhomes.com/brochures/) | Allegro Bus entries observed as far back as 2005 and through 2027, with gaps; Allegro Bay 2022–2027 visible. Other model families have different spans. Class A/C and camper-van lines require separate classification. |

### Forest River ecosystem

The [Forest River product directory](https://www.forestriverinc.com/rvs) is a starting point across towable and motorized products. Its current categories are not historical coverage. Regional variants, renamed divisions, discontinued product families, and dealer-exclusive products need explicit reconciliation.

| Make / division | Primary source | Observed coverage and acquisition work |
| --- | --- | --- |
| Forest River | [Motorhomes](https://www.forestriverinc.com/rvs/motorhomes), [Surveyor Camp Series](https://www.forestriverinc.com/rvs/surveyor-camp-series), [manuals](https://www.forestriverinc.com/owners-manuals) | Examples have 2025/2026 selectors; some current pages now show 2027. Inventory Rockwood, Flagstaff, Cherokee, Wildwood, Salem, R-Pod, Surveyor, No Boundaries, Cedar Creek, Sabre, Sierra, Sandpiper, Vengeance, XLR, FR3, Georgetown, Berkshire, Forester, and Sunseeker as separate model-family discovery tasks. Enumeration and year coverage for these families remain unverified. |
| Coachmen / Shasta | [Travel-trailer directory](https://www.coachmenrv.com/travel-trailers), [2023 Clipper camping-trailer brochure](https://coachmenrv.com/brochures/2023/2023clipperbrochure.pdf) | Official 2019 and 2023 folding-camper documents found. Current Clipper travel trailers are not interchangeable with the older folding-camper line. Apex, Catalina, Freedom Express and motorized line coverage must be extracted separately. |
| Palomino | [Backpack](https://palominorv.com/Backpack), [Puma](https://palominorv.com/puma), [Columbus](https://palominorv.com/fifth-wheels/columbus) | Dated 2025 content and older dated PDF examples found; host/path redirects toward Forest River require canonical URL tracking. Truck campers must retain hard-side versus pop-up roof equipment distinction. |
| East to West | [Official site](https://www.easttowestrv.com/), [2025 Bravado brochure](https://www.easttowestrv.com/files/brochures/2025/2025bravadobrochure.pdf) | Dated official documents found; all travel-trailer/fifth-wheel/Class C family coverage still needs enumeration. |
| Dynamax, Prime Time | Manufacturer/licensor follow-up queue | Significant discovery gaps in this pass. Do not infer their model/year catalog from the parent directory. |

### Winnebago Industries ecosystem

| Make | Primary source | Observed coverage and acquisition work |
| --- | --- | --- |
| Winnebago | [Brochures, View example](https://www.winnebago.com/brochure?model=View), [official asset library](https://assets.winnebagoind.com/) | View archive lists entries from 2006 through 2025 with gaps. Other lines have their own histories. Asset metadata gives model/year clues, but photography and document downloads carry usage terms. Winnebago and historic Itasca require consumer aliases and separate lineage. |
| Newmar | [Historical brochure archive](https://www.newmarcorp.com/owners/brochure-archive), [current library](https://www.newmarcorp.com/owners/brochure-video-library) | Observed historical entries down to 1983 Kountry Aire. Includes retired fifth wheels as well as motorhomes. Archive presence is not complete coverage. |
| Grand Design | [Brochures](https://www.granddesignrv.com/content/granddesignrv/us/en/shopping-tools/brochures/brochure-download.html), [Reflection archive](https://www.granddesignrv.com/fifth-wheels/reflection/archive), [official specification directory](https://pdf.granddesignrv.com/SpecSheet/) | Current and model-family archive endpoints located. Travel trailers, fifth wheels, toy haulers, and newer motorized products need model-year-specific evidence; no complete historic span validated. |

### Other major and specialty sources

| Make / source | Primary source | Observed coverage and acquisition work |
| --- | --- | --- |
| Fleetwood | [Brochures](https://www.fleetwoodrv.com/shopping-tools-research-brochures/), [build and price](https://www.fleetwoodrv.com/build-price/) | Official archived brochures; build selector currently exposes multiple years, including 2024–2027. Legacy towables need a different historical backfill than current motorized products. |
| Renegade | [Brochures](https://www.renegaderv.com/shopping-tools/rv-brochure/) | Current motorized brochures located. Historic coverage not measured. |
| Holiday Rambler, American Coach, Monaco, Safari | Manufacturer/licensor follow-up queue | Brands/legacy identities requiring separate source audits. Do not assume Fleetwood coverage includes them. |
| Lance | [Owner-support archive](https://www.lancecamper.com/owner-support/) | Observed annual truck-camper documents 2000–2026; travel-trailer documents 2009 onward and selected toy-hauler documents. The 2025 truck-camper and travel-trailer PDFs were fetched and text-inspected for the seed. |
| Northwood | [Brochure archive](https://northwoodmfg.com/brochure-archive/), [2025 Arctic Fox document](https://northwoodmfg.com/wp-content/uploads/2025/01/2025-Arctic-Fox-Brochure.pdf) | Dated Arctic Fox travel trailer/fifth wheel and truck-camper brochures located. Nash, Wolf Creek, Desert Fox and renamed families need separate extraction. One PDF is image-based in web extraction, so OCR/visual review is required. |
| Outdoors RV | [Brochures](https://outdoorsrvmfg.com/brochures/), [official older buyer guide](https://outdoorsrvmfg.com/wp-content/uploads/2015/09/outdoors_buyers_guide.pdf) | Current and older PDFs found. File upload path date does not establish model year; use the document itself. |
| Alliance | [Brochures](https://www.alliancerv.com/brochures/brochures) | Visible 2026 and 2027 documents for Paradigm, Avenue, Valor, Delta, Benchmark. Earlier-year archive completeness unverified. |
| Brinkley | [Product download library](https://www.brinkleyrv.com/product-downloads/), [2024 brochure](https://www.brinkleyrv.com/wp-content/uploads/Docs/Literature/2024/2024-Brinkley-RV-Brochure-Fall-2023.pdf) | Library has year/version fields. Use the document's model year rather than its publishing season. |
| Gulf Stream | [Download center](https://www.gulfstreamcoach.com/downloads), [motorhome brochure archives](https://www.gulfstreamcoach.com/brochure-archives) | Official current brochures and historical motorhome collection. Historical towable coverage remains separate. |
| nuCamp | [Preceding models](https://nucamprv.com/preceding-models/), [documents](https://nucamprv.com/documents-new/) | Teardrops and truck campers. Prior-model index located; original T@B/T@G naming, later TAB/TAG names, and manufacturing lineage need aliases. |
| Aliner | [Camper directory](https://aliner.com/all-campers/) | 2025 and 2026 catalogs were indexed, but direct PDF URLs returned 404 during verification. **No Aliner seed rows admitted.** Reacquire canonical files before importing; folding hard-side campers need tailored equipment questions. |
| Four Wheel Campers | [Hawk family](https://fourwheelcampers.com/model-category/hawk/), [factory inventory](https://fourwheelcampers.com/location/four-wheel-campers/campers-for-sale/) | Model/layout information and dated factory inventory found. A launch date alone does not establish a marketed model year. Avoid fabricated year ranges for custom builds. |
| Pleasure-Way | [Brochure archive](https://pleasureway.com/brochure-archive/) | Official Class B historical archive located; full year span still to enumerate. |
| Roadtrek | [Brochures](https://roadtrek.com/brochures/) | Historic documents include chassis-model-year labels, including 1985–1986 and 2001 examples. Distinguish chassis year from coach year. |
| Leisure Travel Vans / Triple E | [Brochures](https://leisurevans.com/brochures/) | Official archive explicitly includes both brands. Marketed Class B+/small Class C vehicles should not automatically become camper vans. |

Additional backlog, not verified source coverage: Escape, Casita, Scamp, Oliver, inTech, ATC, Ember, Cruiser RV, Black Series, A-Liner/Somerset legacy lines, Northern Lite, Bigfoot, Adventurer, Host, Scout, Capri, Travel Lite, Phoenix, Hallmark, Outfitter, popup-roof conversion builders, custom van builders, and extinct manufacturers. Remove duplicate aliases during ingestion. Europe, Australia/New Zealand, and other markets require separate source and rights programs; do not label the current work global.

## Commercial and public data options

| Provider | Confirmed offering / role | Unresolved contract and coverage questions |
| --- | --- | --- |
| [J.D. Power Specialty Web Services](https://www.jdpowervalues.com/get-values/web-services) | Explicit RV year/make/model/trim integration offering. Best first licensing candidate. | Floorplan granularity, earliest years, discontinued brands, market coverage, incremental feed, stable IDs, rights to bundle/cache on unlimited devices, post-termination retention, photo rights and pricing. No quote obtained. |
| [RVUSA / NetSource Media](https://www.rvusa.com/plan-comparison) | Dealer plans advertise a model-specification/photo/floorplan database. | A dealer subscription is not proven to license external consumer-app redistribution. Request a separate OEM/data contract and sample. Public guide access is not a license. |
| [Black Book](https://www.blackbook.com/automotive-solutions/), [API offering](https://www.blackbook.com/api/) | Official product list explicitly includes **Recreational Vehicles Web API** and an RV Value Guide covering travel trailers, motorhomes, park models, truck campers and camping trailers, with monthly updates. Rechecked 2026-10-19. A second direct licensing candidate alongside J.D. Power. | Exact year/make/model/floorplan coverage, stable identity export, image rights, consumer-app use and offline redistribution remain unverified. No quote or sample obtained. |
| [DataOne Software](https://www.dataonesoftware.com/faqs) | Licenses proprietary vehicle data with API/flat-file delivery options. | RV coach/floorplan coverage is **not confirmed** by the reviewed FAQ; do not substitute chassis VIN data for an RV catalog. |
| [MarketCheck](https://www.marketcheck.com/apis/) | Advertises RV inventory-search and dealer APIs. | Listing inventory is not a complete historical reference catalog; identity, completeness, photo rights and long-term caching need verification. Secondary acquisition candidate only. |
| [NHTSA vPIC](https://vpic.nhtsa.dot.gov/api/Home/Index), [scope](https://vpic.nhtsa.dot.gov/About), [FAQ](https://vpic.nhtsa.dot.gov/api/Home/Index/FAQ) | Public manufacturer/VIN data, intended for 1981 onward; API is free. Useful for make normalization, chassis identification and optional VIN assistance. | Built from manufacturer VIN submissions. It does not establish retail floorplan, trim, optional equipment or photograph completeness. A motorhome VIN may identify chassis rather than the completed coach. Evaluate a server-side snapshot/export workflow before choosing on-device data. |
| [RVIA directory](https://www.rvia.org/membership/membership-directory) | Industry manufacturer/supplier discovery; directory access requires a member portal. | Not a demonstrated make/model/year/floorplan feed. No membership, dataset access or redistribution right acquired. Shipment reports cannot populate a rig selector. |

Third-party brochure collections such as [RecreationalVehicles.info](https://recreationalvehicles.info/) and [RV Roundtable](https://www.rvroundtable.com/rv-brochure/) are gap-finding aids. Validate the original issuer and obtain necessary redistribution rights; do not assume the archive operator owns the manufacturer photos. Dealer listings can provide corroborating evidence, but mislabeling, mutable inventory, and copied images make them unsuitable as the sole curated authority.

## Seed provenance and audit rules

| Rows | Evidence |
| --- | --- |
| Jayco Jay Flight SLX 2025 — 41 floorplans | [Official brochure](https://www.jayco.com/uploads/rvs/brochures/873-Jay-Flight-SLX-Brochure-2025.pdf), PDF page 5 floorplan/specification column. Keep east/west suffixes intact. `334RTS` and `380DQS` appear elsewhere in extracted text and were not admitted from this column. |
| Jayco Eagle Fifth Wheels 2025 — 7 | [Year-specific floorplan page](https://www.jayco.com/rvs/fifth-wheels/2025-eagle-fifth-wheels/floorplans/). Marketing badges such as “Redesigned” and “Dealer Stock Only” are removed from identity. |
| Jayco Swift 2025 — 4 | [Year-specific floorplans](https://www.jayco.com/rvs/class-b-motorhomes/2025-swift/floorplans/). `camperVan` maps to the manufacturer's Class B classification. |
| Jayco Precept 2025 — 5; Redhawk 2025 — 4 | [Precept](https://www.jayco.com/rvs/class-a-motorhomes/2025-precept/floorplans/) is Class A; [Redhawk](https://www.jayco.com/rvs/class-c-motorhomes/2025-Redhawk/floorplans/) is Class C. Both map to `motorhome` in the v1 app enum. URL case is significant for Redhawk. |
| Lance 2025 — 9 truck campers, 10 travel trailers | [Truck-camper PDF](https://lance-camper.s3-us-west-1.amazonaws.com/docs/brochure/LANCE_Camper_2025.pdf) and [travel-trailer PDF](https://lance-camper.s3-us-west-1.amazonaws.com/docs/brochure/LANCE_Trailer_2025.pdf). Model numbers are the model, with null floorplan. References to 1475/1575 survive in generic footnotes but are not admitted as 2025 models without dedicated current-model evidence. |
| Coachmen Clipper — **6 quarantined, not bundled** | [Official dated PDF](https://coachmenrv.com/brochures/2023/2023clipperbrochure.pdf), page 10 model table confirms 806XLS, 107LS, 128LS, 860LS, 108ST and 1285SST. However, its 2023 path, copyright and 2/23 publication date do not explicitly establish model year. Obtain a year-specific official product/archive statement before admitting these as 2023 rigs. |
| Airstream Classic 2025 — 2 | [Official 2025 model-year announcement](https://media.airstream.com/press-release/airstream-unveils-2025-model-year-travel-trailer-updates/), 30RB and 33FB. Does not exhaust that year's lineup or twin-bed options. |
| Winnebago Revel — **1 quarantined, not bundled** | [Official 2025 Revel-series brochure metadata](https://assets.winnebagoind.com/content/assets-winnebago-ind/public-assets/details/document.html/content/dam/winnebago/products/brochure/Brochure-Revel-Series-25-0425.pdf) lists model year 2025, combined series `Revel,Revel Sport`, and combined floorplans `44E,44N,44C`. It does **not** establish which code belongs to which series. Original PDF rendition returned HTTP 403 in this audit. The prior inventory corroboration had no saved source URL. Obtain the original or a year-specific official Revel/44E page before admission. |

The seed records establish identity only. They do **not** assert installed equipment, legal towing compatibility, actual dimensions, weights, electrical service, slideout sequence or manufacturer-approved setup procedures. Those require separate, versioned evidence and user confirmation. A brochure can change mid-year; preserve editions and production distinctions.

## Independent audit — 2026-10-19

All ten original source URLs were fetched again. Four were PDFs extracted with `pdftotext -layout`; six were HTML pages inspected as text and markup. All 89 original codes appear somewhere in those sources, but a code appearing in a document is insufficient when the year or model association is ambiguous. Seven rows were therefore removed from the selectable export and retained as the two quarantine entries above. No records were added by interpolation or inference.

The retained **82 records = Airstream 2 + Jayco 61 + Lance 19**. Eight source URLs support these records. The eight source families were checked as follows:

| Source family | Explicit year/identity evidence checked | Retained count |
| --- | --- | --- |
| Airstream Classic | Announcement title and `2025 Classic` section explicitly join Classic with 30RB and 33FB. | 2 |
| Jayco Jay Flight SLX | Cover says `2025 JAY FLIGHT SLX`; PDF page 5 floorplan specification column explicitly lists all 41 retained codes, including 160LK / 160LKW and 280FKS. Some specifications are TBD; no specifications are imported. The later table contains additional valid codes not yet imported, so this is a subset. | 41 |
| Jayco Eagle Fifth Wheels | Page title and `2025 Eagle Fifth Wheels Floorplans` heading; all seven retained floorplan cards present, including 317RLOK and 370FBTS. | 7 |
| Jayco Swift | `2025 Swift Floorplans` heading joins 20A, 20E, 20T and 20Y to that model year. | 4 |
| Jayco Precept | `2025 Precept Floorplans` heading and cards join 31UL, 34B, 34G, 36A and 36C to that year. | 5 |
| Jayco Redhawk | `2025 Redhawk Floorplans` heading and cards join 24B, 26M, 29XK and 31F to that year. | 4 |
| Lance Truck Campers | Cover says `2025 | TRUCK CAMPERS`; dedicated model sections and pages 26–27 specification columns include all nine codes. Final page explicitly says information applies to all 2025 model-year products. Representative 1062 has a dedicated page 5 section, not merely the customer story about a 2017 rig. | 9 |
| Lance Travel Trailers | Cover says `2025 | TRAVEL TRAILERS`; dedicated sections and pages 26–27 include all ten retained models. Representative 1685 has a dedicated page 18 section; 2565 appears on page 3. Final legal paragraph explicitly states 2025 model-year applicability. The PDF footer mistakenly calls it a truck-camper brochure, so classification follows the cover and dedicated contents. | 10 |

For Jayco HTML sources, current navigation includes 2027 links. Verification uses the **2025 page heading and its floorplan cards**, never current global navigation. For Lance, generic footnotes can mention retired models and are not admission evidence. These checks validate a starter identity subset, not complete manufacturer coverage or installed equipment.

PDF SHA-256 fingerprints from this audit (sources remain external; no brochure assets are bundled):

- Jayco SLX: `51d80358b4372921b01283ceed26f0e336e3bf4e4a32cc8707bb3df66678fec9`.
- Lance campers: `18cab1756c138909c148068e62da4b63b06bfdd5061111afa246a513df4900ca`.
- Lance trailers: `842c115a56e5c6d9847a71144c530cee55d2a24958b2e1f489a6f77cdcfa9abb`.
- Quarantined Clipper document: `0e3a49b65fa90b0da13a6694df59c57004e00ef7bcb64a58301a72b4e9c91182`.

Run `python3 scripts/validate_catalog.py` to enforce the export contract, unique IDs and normalized make/model/year/floorplan tuples, RigType enum, reviewed manufacturer provenance hosts over HTTPS, and explicit offline-image approval. It is stdlib-only and makes no network calls. A structural pass does not independently verify source claims or confer legal rights. Factual sourcing and rights review remain separate release gates.

## Rights and procurement evidence

Rechecked primary commercial/public pages on 2026-10-19: J.D. Power explicitly advertises RV year/make/model/trim data; Black Book explicitly advertises an RV API; RVUSA dealer plans explicitly include a model-specification/photo/floorplan database; MarketCheck explicitly advertises RV listing and dealer APIs; DataOne describes API and flat-file delivery without confirmed RV coach/floorplan coverage; vPIC states model-year coverage intended for 1981 onward from manufacturer VIN submissions. These establish candidates, not a purchasable complete catalog with agreed terms.

**No investigated public offering establishes permission to bundle a complete catalog, cache it indefinitely on user devices, or redistribute manufacturer photography.** Public brochure access and factual identity evidence are separate from rights to reproduce expressive descriptions, drawings and images. The Winnebago asset page explicitly displays download usage terms; Lance PDFs say all rights reserved. The current export contains only minimal identity facts, source links, and null images, pending production data-rights review.

Request each licensor's sample with: minimum/maximum years per make and rig class; retail model/floorplan versus chassis/trim distinctions; obsolete and private-label brands; regional variants; stable IDs; correction/deletion feeds; manufacturer provenance; and missing-value rates. Request contract language for bundled mobile exports, background updates, offline caching, device/user limits, territory, attribution, derived normalization, disaster recovery, data retained in old trip profiles, and retention after termination. Image rights must separately cover app display, crops/thumbnails, downloads, offline use, attribution and revocation. No vendors have been contacted.

Acquisition priorities are (1) J.D. Power and Black Book samples plus offline terms; (2) RVUSA/NetSource OEM data licensing rather than dealer access; (3) manufacturer permission and dated archive backfills across the source inventory; (4) vPIC for make/chassis normalization only; (5) inventory feeds for corroboration, never historical completeness. The initial North American scope, target historical years and coverage thresholds need a product decision before claiming the full catalog is complete.

## Data and offline delivery design

The v1 seed contract is intentionally small: `schemaVersion`, `coverageNote`, and `records` with `id`, `make`, `model`, integer `year`, nullable `floorplan`, `rigType`, `sourceURL`, nullable `imageURL`, and `imageRights`. An image-bearing row additionally requires an `imageLicense` object with `approvalStatus: "approved"`, `permitsOfflineRedistribution: true`, named `rightsHolder`, and HTTPS `licenseURL`; no current row has imagery or this approval. IDs are stable within this seed. A correction should retain the existing ID; do not regenerate IDs when fixing spelling.

Before production ingestion, extend the authoring database with manufacturer ID, consumer make ID, model-family ID, aliases, market, class A/B/C, trailer subtype, coach versus chassis year, first/last supported year, document edition, extraction/review status, source observation time, reviewer, evidence page/section, content hash, license record, and field-level provenance. Keep this richer authoring data separate from the compact on-device export.

Do not manufacture year ranges from a single brochure. Do not infer floorplan presence across neighboring years. Do not collapse `265BHS` and `265BHSW`, rename all historic products to their current owner, or treat a 2024 upload date as a 2024 model year. Use null for unknown floorplan; allow users to save a manually described rig without a catalog match. Car campers can optionally identify their passenger vehicle, but setup equipment remains user-described.

Ship a complete approved text snapshot in the app bundle. Online updates should download a signed/versioned manifest, validate schema/hash/duplicate identities, stage the new snapshot, then replace atomically while retaining the last known-good version. A failed update must never break offline onboarding. Existing profiles retain a snapshot of their chosen identity and equipment so a catalog correction cannot silently modify their setup flow. Offer corrections separately.

An optional official-image pack needs separate distribution rights. Fetch only images whose license permits mobile display, downloads, thumbnails/crops, regional use and offline retention. Save attribution and license expiry/revocation rules per asset; serve through controlled storage rather than hotlinking brochure images. Emoji and locally imported photos remain functional when no licensed image exists.

## Concrete acquisition sequence

1. Define the launch coverage promise: North America, supported rig classes, target model years, and treatment of vintage/custom rigs. Keep “My rig isn't listed” always available.
2. Obtain J.D. Power, Black Book RV API, and RVUSA sample exports and proposed consumer-app/offline terms. This document prepares those requests; it does not send them. Request a year-by-make-by-class coverage matrix and missing-data report, not just total record counts.
3. Build a manufacturer source register with per-source permissions, immutable document editions, status, canonical URLs and review ownership. Enumerate the major groups above before claiming coverage.
4. Import licensed structured data first; extract permitted dated manufacturer documents for gaps. Use OCR only as a draft, then compare each admitted tuple against the source. Record conflicts rather than choosing silently.
5. Reconcile duplicate names, private labels, regional versions, obsolete manufacturers, and coach/chassis years. Run a second-person review for first imports and all safety-relevant equipment metadata.
6. Release a measured snapshot with exact coverage, quality metrics, and a changelog. Audit a representative sample from every rig class and manufacturer before shipping. Verify unknown rigs can finish onboarding offline.
7. Refresh current-year data on a scheduled basis and when manufacturer revisions are detected. Preserve old versions and alias mappings; never erase historical profiles when a source disappears.

Release blockers for a “fully curated database” claim: contracted offline data rights; agreed geographic/year scope; quantified manufacturer coverage; historic and custom-rig fallback; source-backed normalization; ongoing update ownership. Official brochure imagery has its own unresolved rights dependency and is not implied by obtaining text data.

## Free API investigation and acquired expansion — 2026-10-19

**A usable free API exists, with limited coverage:** NHTSA's vehicle-products API supplies explicit retail make/model/model-year identities in its safety database. This is a separate system from vPIC. It is publicly documented, requires no API key in the tested requests, and provides a practical factual backfill without scraping blocked commercial finder pages. It does not provide a complete retail catalog, floorplan coverage, brochure photographs, or installed equipment. [Official dataset/API documentation](https://www.nhtsa.gov/nhtsa-datasets-and-apis)

`scripts/catalog_nhtsa.py` acquired **249 additional source-backed identities across seven makes and model years 2015–2026**. The acquisition made 84 make/year product lookups. Only exact reviewed family names are considered; each admitted identity is then corroborated against an exact make/model/year recall response containing an explicit, unambiguous vehicle-type statement. The parser ignores the manufacturer-name prefix so “Tiffin Motorhomes, Inc.” alone cannot count as motorhome classification evidence. Mixed-type families such as Eagle, Reflection, Momentum, Rockwood and Cherokee are excluded rather than guessed. All acquired floorplans are null, and all image URLs are null.

| Make | Admitted identities |
| --- | ---: |
| Airstream | 18 |
| Forest River | 42 |
| Grand Design | 18 |
| Jayco | 37 |
| Newmar | 49 |
| Tiffin | 31 |
| Winnebago | 54 |
| **Total** | **249** |

The type breakdown is 213 motorhomes, 29 travel trailers and 7 fifth wheels. The importer excluded 417 unreviewed or insufficiently corroborated product rows. Fourteen exact products appeared in the products endpoint but their recall endpoint returned HTTP 400; these inconsistencies are recorded as errors and **none are admitted**. A missing result is not proof that a model did not exist. Source inclusion is not a statement about whether an individual owner's VIN has an unrepaired recall.

Files are deliberately separated from the shipped resource:

- `data/catalog/nhtsa-products/candidate-catalog.json`: 249 additional identities in the app's exact v1 schema.
- `data/catalog/nhtsa-products/combined-catalog.json`: 331 identities when merged with the audited 82-record manufacturer seed, spanning eight makes. Existing IDs and source-backed floorplans are preserved. This is a merge-ready artifact; generating it does not change the app bundle.
- `data/catalog/nhtsa-products/provenance.json`: identity, product evidence URL, retrieval time/hash, type evidence URL, campaign ID and classification evidence for each admitted record.
- `data/catalog/nhtsa-products/raw/`: cached API responses, including rejected requests for deterministic offline replay.
- `data/catalog/nhtsa-products/report.json`: per-make/year lookup counts, admitted counts, exclusions, and acquisition errors.

Reproduce acquisition with `python3 scripts/catalog_nhtsa.py --start-year 2015 --end-year 2026`. Replay exclusively from disk and prepare a combined artifact with `python3 scripts/catalog_nhtsa.py --offline --seed data/catalog/nhtsa-products/combined-catalog.json`. The command exits nonzero if source errors exist, while still writing the explicitly partial validated output and error report. It never retries rejected access, supplies credentials, uses rotating proxies, or bypasses a challenge. `python3 scripts/validate_catalog.py data/catalog/nhtsa-products/combined-catalog.json` validates the export. The validator accepts only the reviewed federal products endpoint with exact make/year query parameters; vPIC URLs remain excluded as retail catalog provenance.

### Other free candidates and scrape access review

| Source | Live result / restriction | Decision |
| --- | --- | --- |
| NHTSA vPIC | Free public API; returned zero models for Jayco make ID 4516 in 2025. Name search `jayco` instead matched a different “JAYCO TRAILER COMPANY.” Winnebago returned generic classifications such as “Class C” and incomplete vehicles; Forest River mixed RV and cargo products. | Useful for manufacturer/VIN reconciliation, **not** an unreviewed onboarding import. [API FAQ](https://vpic.nhtsa.dot.gov/api/Home/Index/FAQ) |
| NHTSA vehicle-products / recalls API | Exact retail make/model/year evidence; coverage is constrained by the safety database. | Used for the conservative acquisition above. No imagery, manuals or recall prose are placed in the app catalog. |
| RVUSA | `robots.txt` returned `Allow: /`; guide and terms requests returned HTTP 403. A permissive robots file does not grant data/image redistribution rights. | No bulk scrape attempted and no block bypassed. Evaluate an explicit data agreement if broader coverage is required. [Robots](https://www.rvusa.com/robots.txt) |
| Newmar / Winnebago / Grand Design | Newmar robots allows crawling, but the shared Winnebago Industries terms expressly restrict scraping/extraction/copying. A subsequent content request also returned HTTP 403. | No scalable manufacturer-site scrape implemented. [Terms](https://www.newmarcorp.com/terms-of-use), [Winnebago terms](https://www.winnebago.com/terms-of-use) |
| Lance | `robots.txt` has broad disallow rules, including the site root and document paths. | No automated site crawl. The earlier manually verified seed remains separate from any proposal for bulk acquisition. [Robots](https://www.lancecamper.com/robots.txt) |
| RV Fuel Vault Find My Fit | Offers a free-to-start dealer fitment API, but its published data-use license prohibits bulk download, database reconstruction and competing catalog use. | Unsuitable for this app's offline catalog. [Developer offering](https://thervfuelvault.com/developers), [data-use terms](https://thervfuelvault.com/developers/register) |
| Generic free VIN/automotive databases | Search surfaced vPIC wrappers and car-oriented catalogs. No reviewed offering established complete RV coach/floorplan coverage and unrestricted offline catalog redistribution. | Do not present these as a complete free RV database. Use official vPIC directly for its documented scope. |

Government API availability supports the factual acquisition above; it does not confer rights to manufacturer brochure photos or third-party marketing copy. The source inventory earlier in this document is **not** a declaration that every listed site is scrape-permitted. Access, factual verification, coverage, and redistribution rights remain separate questions.

## Measurable production coverage targets

These are proposed acceptance criteria for the product team, not claims already met:

1. **Scope:** North American retail RVs, model years 2000 through the currently released model year, across all six RV categories; manual car/tent/custom entry always available offline.
2. **Manufacturer baseline:** Publish an explicit make/year/type matrix for every manufacturer in the agreed launch inventory. Every matrix cell must say verified, partial, unavailable or not applicable. No implied continuous year ranges.
3. **Source completeness:** For each approved, accessible source edition, import and review 100% of its relevant identity rows or publish an exception list. Measure licensed-feed coverage against its supplied manifest rather than an invented market-total denominator.
4. **Accuracy:** Every admitted tuple has explicit year evidence, a source URL, reviewed class evidence, and a recorded source edition or response hash. No unmatched duplicates; no unsupported floorplans. Independently review at least 10% of each new make/year/type cohort, and 100% of conflicts before release.
5. **User coverage:** In a representative pilot of at least 500 rigs spanning all six RV categories, target at least 95% exact make/model/year matching and report floorplan-match rate separately. This does not establish 95% of the entire RV market. Track the reason for every manual fallback.
6. **Offline freshness:** Ship the approved snapshot in the bundle, keep old profiles stable, publish a coverage/version date, and verify atomic update rollback. Track current-year additions monthly and validate changed source records before release.

Acquisition priority for a zero-data-license-cost path is: (1) retain and expand the documented federal subset with conservative review; (2) add independently verified manufacturer facts where access and reuse permit; (3) obtain missing manufacturer permissions and donated datasets without assuming consent; (4) quantify remaining gaps. If the free path misses the agreed coverage target, compare contracted J.D. Power, Black Book and RVUSA samples against that measured gap before purchasing. No outreach or purchase has been performed.
