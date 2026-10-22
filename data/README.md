# Sourced development data

`campgrounds/` contains a factual RIDB federal directory snapshot retrieved 2026-10-19: an index and 64 lazily downloaded individual-site shards. The manifest records the original public ZIP URL/SHA-256, retrieval date, counts, exclusions, and generated file hashes. It excludes photographs, authored descriptions, prices, and live reservation availability. Rebuild with `scripts/import_ridb.py` and verify with `scripts/validate_campgrounds.py`.

`catalog/nhtsa-products/` records a partial retail RV identity acquisition, source response cache, exclusions/errors, per-record provenance, candidate export, and combined catalog. Rebuild with `scripts/catalog_nhtsa.py`; inspect its help before network acquisition. `catalog/research/vpic-all-makes.json` is identification research and is not treated as a complete retail/floorplan catalog.

The repository's software license is not a blanket license to third-party images, narratives, trademarks, or linked materials. Preserve source attribution, retrieval evidence, and coverage limitations. Source-specific access/reuse findings are documented in `docs/campground-sourcing.md` and `docs/catalog-sourcing.md`. No images or brochure redistribution rights are implied.

The native app's development campground URL points to this branch's public raw files. Production should use an owned, versioned CDN/snapshot endpoint with an explicit refresh owner; this repository is not a live reservation API.
