# Remaining production integrations

## Established account, then offline trips

Initial Sign in with Apple and rig/profile onboarding require internet. Existing device sessions reopen planned trips offline; local Core Data writes never wait for cloud delivery. Camp Finder, profile/rig changes, account changes, and fresh weather need connectivity. Camera capture, imported photos, checklist edits, site notes, ratings, and manual trip creation from known details remain local. See [account/offline contract](account-and-offline-contract.md).

Native Apple credential authentication, Keychain storage, pinned local ownership, online revocation checks, and signout persistence teardown are implemented. There is no server account/session service. Account deletion and complete local/cloud erase remain release work; no fake server validation/deletion is claimed. Multiple app-account libraries are not implemented.

## Managed iCloud

`NSPersistentCloudKitContainer` owns SQLite, private CloudKit mirroring, retries, history, and external binary transfers. There is no raw SQLite usage or custom record transport. Provision a new dedicated cloud container and deploy its generated schema. Approval pins the separate device iCloud identity; unavailable or mismatched identity leaves authenticated local trip access intact.

Two-device/account/attachment acceptance and actual iOS 27 runtime remain required. See [storage architecture](offline-storage.md).

## Apple Foundation Models only

Remove hosted AI from the roadmap. The only generative route is Apple's on-device Foundation Models, gated to iPhone 16 or newer product eligibility and Apple's independent runtime availability. Saved checklist guidance remains the fallback. No provider/model choice or remote question transfer is exposed. Initial Apple model download/readiness is an online prerequisite.

## Campground data

The RIDB public bulk export supports a real federal campground and site snapshot without an API key. `scripts/import_ridb.py` builds dated factual index/site shards, and the app downloads them over HTTPS from configurable public snapshot hosting. Development hosting points to this repository branch through Info.plist; production should use an owned CDN/versioned snapshot endpoint with an update owner and measured traffic budget. Static directory facts are not live booking availability.

A tested RIDB-shaped proxy client is ready for future live provider refresh. A deployed bounded backend and registered RIDB API key are still needed for that path; never ship provider keys in the app. NPS, state/local/private coverage, broader regional datasets, and any reservation availability require separate integrations/agreements. See [source report](campground-sourcing.md).

## Rig catalog

Keep sourced brochure records and explicit make/model/year government evidence with per-record provenance. The importer must not treat regulatory vPIC chassis/trailer labels as comprehensive retail RV models. Exact model-year tuples and explicitly evidenced rig categories are required. No guessed year ranges or unsupported floorplans should enter onboarding. Official images/manual redistribution need separate rights. See [catalog sourcing](catalog-sourcing.md).

## Native release gate

Provision real Apple identifiers and test on iPhone. Run iOS 27 build/runtime, airplane-mode return access, multi-device cloud transfers, signup/revocation/recovery, camera permissions, large datasets, VoiceOver, Dynamic Type, reduced transparency/motion, WeatherKit attribution, storage exhaustion, and Foundation Models eligibility. Portable tests and SDK 26.5 simulator builds do not establish iOS 27 or production readiness.
