#!/usr/bin/env python3
"""Acquire a conservative RV identity subset from NHTSA's free products API.

This is NOT vPIC and is NOT a complete RV catalog. Product-year records exist in
NHTSA's safety database; absent records do not mean a model was not manufactured.
Only exact reviewed retail family names with a matching recall vehicle-type
description are admitted. No years, floorplans, specifications or photos are
inferred. Writes separate data/catalog outputs, never the app's bundled catalog.
Uses only the Python standard library. Cached replay makes no network requests.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import sys
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
API = 'https://api.nhtsa.gov/'
DOCS = 'https://www.nhtsa.gov/nhtsa-datasets-and-apis'
# Exact names only. Mixed-type families (Eagle, Reflection, Momentum, Rockwood,
# Cherokee, Wildwood, etc.) deliberately excluded until finer evidence exists.
FAMILIES = {
    'AIRSTREAM': ('Airstream', {
        'CLASSIC': 'travelTrailer', 'CLASSIC LIMITED': 'travelTrailer',
        'FLYING CLOUD': 'travelTrailer', 'INTERNATIONAL': 'travelTrailer',
        'INTERNATIONAL SERENITY': 'travelTrailer', 'BAMBI': 'travelTrailer',
        'BASECAMP': 'travelTrailer', 'CARAVEL': 'travelTrailer',
        'GLOBETROTTER': 'travelTrailer', 'SPORT': 'travelTrailer',
    }),
    'JAYCO': ('Jayco', {
        'REDHAWK': 'motorhome', 'REDHAWK SE': 'motorhome', 'GREYHAWK': 'motorhome',
        'MELBOURNE': 'motorhome', 'ALANTE': 'motorhome', 'SENECA': 'motorhome',
        'PRECEPT': 'motorhome', 'PRECEPT PRESTIGE': 'motorhome', 'EMBARK': 'motorhome',
    }),
    'WINNEBAGO': ('Winnebago', {
        'VIEW': 'motorhome', 'MINNIE WINNIE': 'motorhome', 'EKKO': 'motorhome',
        'VITA': 'motorhome', 'HORIZON': 'motorhome', 'FORZA': 'motorhome',
        'ADVENTURER': 'motorhome', 'VISTA': 'motorhome', 'NAVION': 'motorhome',
        'JOURNEY': 'motorhome', 'ASPECT': 'motorhome', 'OUTLOOK': 'motorhome',
        'SIGHTSEER': 'motorhome', 'TOUR': 'motorhome', 'INTENT': 'motorhome',
    }),
    'GRAND DESIGN': ('Grand Design', {
        'SOLITUDE': 'fifthWheel', 'IMAGINE': 'travelTrailer',
        'IMAGINE XLS': 'travelTrailer', 'TRANSCEND': 'travelTrailer',
        'TRANSCEND XPLOR': 'travelTrailer',
    }),
    'NEWMAR': ('Newmar', {
        'DUTCH STAR': 'motorhome', 'KING AIRE': 'motorhome',
        'VENTANA': 'motorhome', 'VENTANA LE': 'motorhome',
        'LONDON AIRE': 'motorhome', 'NEW AIRE': 'motorhome',
        'BAY STAR': 'motorhome', 'BAY STAR SPORT': 'motorhome',
        'CANYON STAR': 'motorhome', 'ESSEX': 'motorhome',
    }),
    'TIFFIN': ('Tiffin', {
        'ALLEGRO RED': 'motorhome', 'ALLEGRO BUS': 'motorhome',
        'PHAETON': 'motorhome', 'ALLEGRO': 'motorhome', 'WAYFARER': 'motorhome',
    }),
    'FOREST RIVER': ('Forest River', {
        'SUNSEEKER': 'motorhome', 'BERKSHIRE': 'motorhome',
        'GEORGETOWN': 'motorhome', 'FORESTER': 'motorhome', 'FR3': 'motorhome',
    }),
}


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, indent=2, ensure_ascii=False) + '\n')
    temporary.replace(path)


class Client:
    def __init__(self, cache, offline):
        self.cache, self.offline = cache, offline

    def get(self, endpoint, **params):
        url = API + endpoint + '?' + urlencode(params)
        key = hashlib.sha256(url.encode()).hexdigest()
        path = self.cache / (key + '.json')
        if path.exists():
            envelope = json.loads(path.read_text())
            if envelope['sourceURL'] != url:
                raise ValueError('cache source URL mismatch')
            if 'error' in envelope:
                raise RuntimeError(envelope['error'])
            return envelope
        if self.offline:
            raise RuntimeError('uncached URL in offline replay: ' + url)
        request = Request(url, headers={'User-Agent': 'CampCatalogResearch/1.0',
                                       'Accept': 'application/json'})
        # No auth, rotating proxies, challenge bypass, or retries on blocking.
        try:
            with urlopen(request, timeout=30) as response:
                payload = response.read(8 * 1024 * 1024)
        except HTTPError as error:
            # Preserve source inconsistency for deterministic offline replay.
            # Do not retry a rejected or inaccessible request.
            write_json(path, {'sourceURL': url,
                             'retrievedAt': datetime.now(timezone.utc).isoformat(),
                             'error': f'HTTP {error.code}: {error.reason}'})
            raise
        body = json.loads(payload)
        if not isinstance(body.get('results'), list):
            raise ValueError('unexpected API payload for ' + url)
        envelope = {'sourceURL': url, 'retrievedAt': datetime.now(timezone.utc).isoformat(),
                    'payloadSHA256': hashlib.sha256(payload).hexdigest(), 'response': body}
        write_json(path, envelope)
        return envelope


def confirms_type(summary, rig_type):
    text = re.sub(r'[-‐‑–]', ' ', summary.casefold())
    # "Tiffin Motorhomes, Inc." is a manufacturer name, not type evidence.
    # Only examine the description after the manufacturer's recall statement.
    if 'recalling' not in text:
        return False
    text = text.split('recalling', 1)[1]
    has_motorhome = bool(re.search(r'\bmotor\s*homes?\b', text))
    has_travel = bool(re.search(r'\btravel trailers?\b', text))
    has_fifth = bool(re.search(r'\b(?:fifth|5th) wheel\b', text))
    # Reject summaries listing multiple vehicle categories: attribution unclear.
    return {'motorhome': has_motorhome and not has_travel and not has_fifth,
            'travelTrailer': has_travel and not has_motorhome and not has_fifth,
            'fifthWheel': has_fifth and not has_motorhome and not has_travel}[rig_type]


def acquire(client, start, end, workers):
    results, rejected, errors, counts = [], [], [], {}
    jobs = [(make, year) for make in FAMILIES for year in range(start, end + 1)]

    def models(job):
        make, year = job
        try:
            envelope = client.get('products/vehicle/models', modelYear=year, make=make, issueType='r')
            return job, envelope, None
        except (OSError, ValueError, RuntimeError) as error:
            return job, None, str(error)

    candidates = []
    with ThreadPoolExecutor(max_workers=workers) as pool:
        for (make, year), envelope, error in pool.map(models, jobs):
            if error:
                errors.append({'make': make, 'year': year, 'error': error})
                continue
            items = envelope['response']['results']
            counts[f'{make}|{year}'] = len(items)
            for item in items:
                if item.get('make') != make or str(item.get('modelYear')) != str(year):
                    raise ValueError('API returned identity outside requested year/make')
                model = item.get('model', '')
                if model in FAMILIES[make][1]:
                    candidates.append((make, year, model, envelope))
                else:
                    rejected.append({'make': make, 'year': year, 'model': model,
                                     'reason': 'not in exact reviewed family/type allowlist'})
    print(f'Product lookups complete: {len(candidates)} exact-family candidates.', flush=True)

    def corroborate(candidate):
        make, year, model, product = candidate
        try:
            recall = client.get('recalls/recallsByVehicle', make=make, model=model, modelYear=year)
        except (OSError, ValueError, RuntimeError) as error:
            return None, {'make': make, 'year': year, 'model': model, 'error': str(error)}
        rig_type = FAMILIES[make][1][model]
        matches = []
        for item in recall['response']['results']:
            if (str(item.get('ModelYear')) != str(year)
                    or str(item.get('Make', '')).upper() != make
                    or str(item.get('Model', '')).upper() != model):
                continue
            summary = item.get('Summary', '')
            # Product is already exact in recall response; require explicit type.
            if confirms_type(summary, rig_type):
                matches.append(item)
        if not matches:
            return None, {'make': make, 'year': year, 'model': model,
                          'reason': 'no unambiguous vehicle-type statement in exact identity recall'}
        item = matches[0]
        display_make = FAMILIES[make][0]
        display_model = model.title()
        for token in ('XLS', 'SE', 'LE', 'FR3', 'EKKO', 'RED'):
            display_model = re.sub(r'\b' + token.title() + r'\b', token, display_model)
        identity = re.sub(r'[^a-z0-9]+', '-', f'{display_make}-{display_model}-{year}-base'.lower())
        row = {'id': identity, 'make': display_make, 'model': display_model, 'year': year,
               'floorplan': None, 'rigType': rig_type, 'sourceURL': product['sourceURL'],
               'imageURL': None, 'imageRights': 'No image supplied; use user photo or emoji.'}
        proof = {'recordID': identity, 'productSourceURL': product['sourceURL'],
                 'productRetrievedAt': product['retrievedAt'],
                 'productPayloadSHA256': product['payloadSHA256'],
                 'typeSourceURL': recall['sourceURL'],
                 'typeRetrievedAt': recall['retrievedAt'],
                 'campaignNumber': item['NHTSACampaignNumber'],
                 'classificationEvidence': item['Summary'],
                 'identity': {'make': make, 'model': model, 'modelYear': year},
                 'floorplanStatus': 'not provided by source',
                 'sourceLimit': 'presence in safety database, not complete retail catalog'}
        return (row, proof), None

    with ThreadPoolExecutor(max_workers=workers) as pool:
        for result, rejection in pool.map(corroborate, candidates):
            if result:
                results.append(result)
            elif 'error' in rejection:
                errors.append(rejection)
            else:
                rejected.append(rejection)
    return results, rejected, errors, counts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--start-year', type=int, default=2015)
    parser.add_argument('--end-year', type=int, default=2026)
    parser.add_argument('--offline', action='store_true')
    parser.add_argument('--workers', type=int, choices=range(1, 5), default=3)
    parser.add_argument('--output', type=Path, default=ROOT / 'data/catalog/nhtsa-products')
    parser.add_argument('--seed', type=Path,
                        help='also write a deduplicated combined-catalog.json; seed is never modified')
    args = parser.parse_args()
    if not 2000 <= args.start_year <= args.end_year <= 2027:
        parser.error('supported acquisition range: 2000–2027')
    client = Client(args.output / 'raw', args.offline)
    admitted, rejected, errors, counts = acquire(client, args.start_year, args.end_year, args.workers)
    admitted.sort(key=lambda pair: (pair[0]['make'], pair[0]['model'], pair[0]['year']))
    rows = [pair[0] for pair in admitted]
    keys = [(r['make'], r['model'], r['year'], r['floorplan']) for r in rows]
    if len(set(keys)) != len(rows):
        raise ValueError('duplicate admitted identity')
    note = (f'Partial safety-database-derived RV identity catalog: {len(rows)} records, '
            f'{len({r["make"] for r in rows})} makes, queried model years '
            f'{args.start_year}–{args.end_year}. Exact model-year evidence and explicit '
            'vehicle-type corroboration; no floorplans or photos. Not complete manufacturer coverage.')
    write_json(args.output / 'candidate-catalog.json',
               {'schemaVersion': 1, 'coverageNote': note, 'records': rows})
    write_json(args.output / 'provenance.json', [pair[1] for pair in admitted])
    write_json(args.output / 'report.json', {
        'documentationURL': DOCS, 'source': 'NHTSA vehicle products / recalls public APIs',
        'apiKeyRequired': False, 'catalogCompletenessClaim': False,
        'queriedYears': list(range(args.start_year, args.end_year + 1)),
        'lookups': len(counts), 'returnedProductRows': sum(counts.values()),
        'admitted': len(rows), 'byMake': {m: sum(r['make'] == m for r in rows)
                                      for m in sorted({r['make'] for r in rows})},
        'byType': {t: sum(r['rigType'] == t for r in rows)
                   for t in sorted({r['rigType'] for r in rows})},
        'lookupCounts': counts, 'rejected': rejected, 'errors': errors,
    })
    if args.seed:
        seed = json.loads(args.seed.read_text())
        if seed.get('schemaVersion') != 1:
            raise ValueError('seed must use schemaVersion 1')
        def key(row):
            return tuple(value.casefold() if isinstance(value, str) else value
                         for value in (row['make'], row['model'], row['year'], row['floorplan']))
        combined = {key(row): row for row in seed['records']}
        for row in rows:
            previous = combined.get(key(row))
            if previous and previous['rigType'] != row['rigType']:
                raise ValueError('conflicting rig type for ' + row['id'])
            combined.setdefault(key(row), row)  # Keep established profile IDs.
        combined_rows = sorted(combined.values(), key=lambda row:
                               (row['make'], row['model'], row['year'], row['floorplan'] or ''))
        combined_note = (f'Partial offline catalog: {len(combined_rows)} source-backed identities '
                         f'across {len({r["make"] for r in combined_rows})} makes; '
                         'selected manufacturer floorplans plus federal safety-database model-year '
                         'identities with unspecified floorplans. Coverage is incomplete. '
                         'Use manual entry for missing rigs. No manufacturer images are bundled.')
        write_json(args.output / 'combined-catalog.json', {
            'schemaVersion': 1, 'coverageNote': combined_note, 'records': combined_rows})
        print(f'Combined export: {len(combined_rows)} records; seed file unchanged.')
    print(note)
    print(f'{len(rejected)} excluded; {len(errors)} acquisition errors. Output: {args.output}')
    return bool(errors)


if __name__ == '__main__':
    sys.exit(main())
