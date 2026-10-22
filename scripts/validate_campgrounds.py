#!/usr/bin/env python3
"""Validate generated factual directory snapshots, hashes, IDs and equipment semantics."""
import hashlib
import json
from pathlib import Path
from import_ridb import SHARDS, shard_for

root = Path(__file__).resolve().parents[1] / 'data/campgrounds'
manifest = json.loads((root / 'manifest.json').read_text())
for name, expected in manifest['files'].items():
    assert Path(name).name == name and name.endswith('.json')
    assert hashlib.sha256((root / name).read_bytes()).hexdigest() == expected, name
index = json.loads((root / 'index.json').read_text())
assert index['schemaVersion'] in (1, 2)
for campground in index['campgrounds']:
    for key in ('reservationURL', 'websiteURL'):
        assert key not in campground or campground[key].startswith('https://'), (campground['id'], key)
facilities = {r['id'].removeprefix('ridb-') for r in index['campgrounds']}
assert len(facilities) == len(index['campgrounds']) == manifest['campgrounds']
ids = set(); with_sites = set()
for shard in range(SHARDS):
    data = json.loads((root / f'sites-{shard:02d}.json').read_text())
    assert data['schemaVersion'] == 1
    for facility, sites in data['sitesByFacility'].items():
        assert facility in facilities and shard_for(facility) == shard
        with_sites.add(facility)
        for site in sites:
            assert site['id'] not in ids
            ids.add(site['id'])
            assert 'MANAGEMENT' not in site['kind']
            assert all(type(v) in (int, float) and v >= 0 for v in site['equipment'].values())
            assert 'accessible' not in site, 'Vehicle access must not be mislabeled ADA access'
assert len(ids) == manifest['includedOvernightSites']
assert len(with_sites) == manifest['facilitiesWithSites']
print(f'PASS: {len(facilities):,} campgrounds, {len(ids):,} overnight sites, {SHARDS} verified shards; snapshot {manifest["retrievedAt"]}.')
