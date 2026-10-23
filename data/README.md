# Sourced development data

`campgrounds/` contains a factual RIDB federal directory snapshot retrieved 2026-10-19: an index and 64 lazily downloaded individual-site shards. The manifest records the original public ZIP URL/SHA-256, retrieval date, counts, exclusions, and generated file hashes. It excludes photographs, authored descriptions, prices, and live reservation availability. Index schema 2 adds the facility phone, email, reservation page, and official website as RIDB publishes them (non-https links, undialable numbers, and malformed emails are dropped). The app reads schema 1 and 2; the committed snapshot stays schema 1 until the importer is rerun against a fresh export. Rebuild with `scripts/import_ridb.py` and verify with `scripts/validate_campgrounds.py`.


The repository's software license is not a blanket license to third-party images, narratives, trademarks, or linked materials. Preserve source attribution, retrieval evidence, and coverage limitations. Source-specific access/reuse findings are documented in `docs/campground-sourcing.md`. No images or brochure redistribution rights are implied.

The native app's development campground URL points to the `main` branch's public raw files. Production should use an owned, versioned CDN/snapshot endpoint with an explicit refresh owner; this repository is not a live reservation API.
