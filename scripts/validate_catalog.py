#!/usr/bin/env python3
"""Validate Camp's offline rig export using Python's standard library.

This checks the export contract, not factual source accuracy or legal clearance.
Run from any directory: python3 scripts/validate_catalog.py [catalog.json]
New manufacturer hosts require an explicit provenance review below.
"""
import argparse
import json
from pathlib import Path
import re
import sys
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
RIG_TYPES = {
    'travelTrailer', 'fifthWheel', 'motorhome', 'camperVan',
    'truckCamper', 'popUp', 'carCamping', 'tent',
}
SOURCE_HOSTS = {
    'Airstream': {'media.airstream.com', 'www.airstream.com'},
    'Jayco': {'www.jayco.com'},
    # This exact manufacturer-controlled bucket is linked by Lance support.
    'Lance': {'lance-camper.s3-us-west-1.amazonaws.com', 'www.lancecamper.com'},
}
REQUIRED = {
    'id', 'make', 'model', 'year', 'floorplan', 'rigType',
    'sourceURL', 'imageURL', 'imageRights',
}


def https_url(value):
    if not isinstance(value, str) or any(c.isspace() for c in value):
        return False
    try:
        u = urlsplit(value)
        return (u.scheme == 'https' and bool(u.hostname) and not u.username
                and not u.password and u.port in (None, 443))
    except ValueError:
        return False


def nonempty(value):
    return isinstance(value, str) and bool(value.strip()) and value == value.strip()


def validate(data):
    errors = []
    if not isinstance(data, dict):
        return ['catalog must be an object']
    if set(data) != {'schemaVersion', 'coverageNote', 'records'}:
        errors.append('catalog fields must be schemaVersion, coverageNote, records')
    if type(data.get('schemaVersion')) is not int or data['schemaVersion'] != 1:
        errors.append('schemaVersion must be integer 1')
    if not nonempty(data.get('coverageNote')):
        errors.append('coverageNote must be nonempty trimmed text')
    records = data.get('records')
    if not isinstance(records, list) or not records:
        return errors + ['records must be a nonempty array']
    ids, tuples = set(), set()
    for index, r in enumerate(records):
        label = f'record[{index}]'
        if not isinstance(r, dict):
            errors.append(f'{label}: must be an object')
            continue
        if REQUIRED - r.keys():
            errors.append(f'{label}: missing {sorted(REQUIRED - r.keys())}')
        if r.keys() - (REQUIRED | {'imageLicense'}):
            errors.append(f'{label}: unknown fields {sorted(r.keys() - (REQUIRED | {"imageLicense"}))}')
        for field in ('id', 'make', 'model', 'sourceURL', 'imageRights'):
            if not nonempty(r.get(field)):
                errors.append(f'{label}: {field} must be nonempty trimmed text')
        identity = r.get('id')
        if isinstance(identity, str):
            if not re.fullmatch(r'[a-z0-9]+(?:-[a-z0-9]+)*', identity):
                errors.append(f'{label}: id must use lowercase hyphenated ASCII')
            if identity in ids:
                errors.append(f'{label}: duplicate id {identity}')
            ids.add(identity)
        if type(r.get('year')) is not int or not 1900 <= r['year'] <= 2100:
            errors.append(f'{label}: year must be integer 1900...2100')
        if r.get('floorplan') is not None and not nonempty(r['floorplan']):
            errors.append(f'{label}: floorplan must be null or nonempty trimmed text')
        if not isinstance(r.get('rigType'), str) or r['rigType'] not in RIG_TYPES:
            errors.append(f'{label}: invalid RigType {r.get("rigType")!r}')
        fields = [r.get(k) for k in ('make', 'model', 'year', 'floorplan')]
        if all(v is None or isinstance(v, (str, int)) for v in fields):
            key = tuple(v.casefold().strip() if isinstance(v, str) else v for v in fields)
            if key in tuples:
                errors.append(f'{label}: duplicate make/model/year/floorplan tuple {key}')
            tuples.add(key)
        source = r.get('sourceURL')
        if not https_url(source):
            errors.append(f'{label}: sourceURL must be an HTTPS provenance URL')
        elif (not isinstance(r.get('make'), str)
              or urlsplit(source).hostname not in SOURCE_HOSTS.get(r['make'], set())):
            errors.append(f'{label}: sourceURL host is not reviewed for this make')
        image = r.get('imageURL')
        if image is not None:
            if not https_url(image):
                errors.append(f'{label}: imageURL must be null or HTTPS')
            license_info = r.get('imageLicense')
            if not isinstance(license_info, dict):
                errors.append(f'{label}: imagery requires an explicit imageLicense approval')
            else:
                expected = {'approvalStatus', 'licenseURL', 'rightsHolder', 'permitsOfflineRedistribution'}
                if (set(license_info) != expected
                        or license_info.get('approvalStatus') != 'approved'
                        or license_info.get('permitsOfflineRedistribution') is not True
                        or not nonempty(license_info.get('rightsHolder'))
                        or not https_url(license_info.get('licenseURL'))):
                    errors.append(f'{label}: imageLicense must document approved offline rights and license URL')
        elif 'imageLicense' in r:
            errors.append(f'{label}: imageLicense requires an imageURL')
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('catalog', nargs='?', type=Path,
                        default=ROOT / 'Camp/Resources/rig-catalog.json')
    args = parser.parse_args()
    try:
        data = json.loads(args.catalog.read_text(encoding='utf-8'))
    except (OSError, ValueError) as error:
        print(f'FAIL: {error}', file=sys.stderr)
        return 1
    errors = validate(data)
    if errors:
        print('\n'.join('FAIL: ' + e for e in errors), file=sys.stderr)
        return 1
    records = data['records']
    print(f'PASS: {len(records)} records, {len({r["make"] for r in records})} makes, '
          f'years {sorted({r["year"] for r in records})}; '
          f'{len({r["sourceURL"] for r in records})} reviewed source URLs; '
          f'{sum(r["imageURL"] is not None for r in records)} licensed images.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
