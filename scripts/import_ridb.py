#!/usr/bin/env python3
"""Build text/factual campground + site snapshots from the official daily RIDB ZIP.

No media, authored descriptions, prices, or availability data are copied. Published contact details
(phone, email, reservation page, official website) are copied as published; only https links are kept.
Usage: python3 scripts/import_ridb.py --archive /path/RIDBFullExport_V1_JSON.zip
"""
import argparse
import collections
import datetime
import hashlib
import json
import io
import re
from pathlib import Path
import zipfile

SOURCE = 'https://ridb.recreation.gov/downloads/RIDBFullExport_V1_JSON.zip'
SHARDS = 64
FACTS = {'Electricity Hookup', 'Water Hookup', 'Sewer Hookup', 'Pets Allowed',
         'Driveway Entry', 'Driveway Length', 'Max Vehicle Length', 'Max Num of People',
         'Max Num of Vehicles', 'Site Access', 'Checkin Time', 'Checkout Time'}
EQUIPMENT = {'RV': 'motorhome', 'TRAILER': 'travelTrailer', 'FIFTH WHEEL': 'fifthWheel',
             'POP UP': 'popUp', 'PICKUP CAMPER': 'truckCamper', 'CARAVAN/CAMPER VAN': 'camperVan',
             'TENT': 'tent', 'CAR': 'carCamping'}


def records(stream):
    """Stream RECDATA without allocating the 291MB source attribute array."""
    stream = io.TextIOWrapper(stream, encoding="utf-8")
    decoder = json.JSONDecoder()
    buffer = ''; started = False; eof = False
    while True:
        if not eof and len(buffer) < 65536:
            piece = stream.read(65536)
            if piece:
                buffer += piece
            else:
                eof = True
        if not started:
            start = buffer.find('[')
            if start < 0:
                if eof: raise ValueError('Missing RECDATA array')
                continue
            buffer = buffer[start + 1:]; started = True
        buffer = buffer.lstrip(' \r\n\t,')
        if buffer.startswith(']'): return
        if not buffer:
            if eof: raise ValueError('Truncated RECDATA')
            continue
        try:
            obj, end = decoder.raw_decode(buffer)
        except json.JSONDecodeError:
            if eof: raise
            piece = stream.read(65536)
            if piece: buffer += piece
            else: eof = True
            continue
        yield obj
        buffer = buffer[end:]


SCHEMA_VERSION = 2
EMAIL = re.compile(r'^[^@\s<>,]+@[^@\s<>,]+\.[^@\s<>,.]+$')


def https_url(value):
    """The URL as published if it is an absolute https link; anything else is dropped."""
    value = str(value or '').strip()
    if not value.lower().startswith('https://') or len(value) <= len('https://') or any(c.isspace() for c in value):
        return None
    return value


def phone_number(value):
    """The number as published if it has enough digits to dial (7 to 15, ignoring an extension)."""
    value = ' '.join(str(value or '').split())
    main = re.split(r'(?i)\s*(?:x|ext)', value)[0]
    return value if 7 <= sum(c.isdigit() for c in main) <= 15 else None


def email_address(value):
    value = str(value or '').strip()
    return value if EMAIL.match(value) else None


def contact(row, website):
    fields = {'phone': phone_number(row.get('FacilityPhone')), 'email': email_address(row.get('FacilityEmail')),
              'reservationURL': https_url(row.get('FacilityReservationURL')), 'websiteURL': website}
    return {key: value for key, value in fields.items() if value}


def shard_for(facility_id):
    return sum(facility_id.encode('utf-8')) % SHARDS


def coordinates(row, prefix):
    try:
        lat, lon = float(row[prefix + 'Latitude']), float(row[prefix + 'Longitude'])
        if not (-90 <= lat <= 90 and -180 <= lon <= 180) or (lat == 0 and lon == 0): return None
        return lat, lon
    except (KeyError, TypeError, ValueError): return None


def build(archive, output):
    output.mkdir(parents=True, exist_ok=True)
    today = datetime.datetime.now(datetime.timezone.utc).date().isoformat()
    with zipfile.ZipFile(archive) as source:
        read = lambda name: records(source.open(name + '_API_v1.json'))
        facilities = {r['FacilityID']: r for r in read('Facilities')
                      if r.get('Enabled') is True and r.get('FacilityTypeDescription') == 'Campground' and coordinates(r, 'Facility')}
        websites = {}
        if 'Links_API_v1.json' in source.namelist():
            for row in read('Links'):
                if row.get('EntityType') == 'Facility' and row.get('EntityID') in facilities \
                        and str(row.get('LinkType', '')).strip().casefold() == 'official web site':
                    url = https_url(row.get('URL'))
                    if url: websites.setdefault(row['EntityID'], url)
        regions = {}
        for row in read('FacilityAddresses'):
            if row['FacilityID'] in facilities:
                parts = [row.get('City', '').strip(), row.get('AddressStateCode', '').strip()]
                regions.setdefault(row['FacilityID'], ', '.join(p for p in parts if p))
        sites = {}; by_facility = collections.defaultdict(list)
        raw_count = 0
        for row in read('Campsites'):
            raw_count += 1
            if row['FacilityID'] not in facilities or row.get('TypeOfUse') != 'Overnight' or 'MANAGEMENT' in row.get('CampsiteType', '').upper(): continue
            site = {'id': row['CampsiteID'], 'name': row.get('CampsiteName', ''), 'kind': row.get('CampsiteType', ''),
                    'loop': row.get('Loop', '').strip(), 'vehicleAccessible': row.get('CampsiteAccessible'),
                    'attributes': {}, 'equipment': {}, 'updatedAt': row.get('LastUpdatedDate', '')}
            coord = coordinates(row, 'Campsite')
            if coord: site.update(latitude=coord[0], longitude=coord[1])
            sites[row['CampsiteID']] = site; by_facility[row['FacilityID']].append(site)
        for row in read('CampsiteAttributes'):
            if row.get('EntityType') != 'Campsite' or row.get('AttributeName') not in FACTS: continue
            site = sites.get(row['EntityID']); value = str(row.get('AttributeValue', '')).strip()
            if site is not None and value: site['attributes'][row['AttributeName']] = value
        for row in read('PermittedEquipment'):
            site = sites.get(row['CampsiteID']); kind = EQUIPMENT.get(row.get('EquipmentName', '').upper())
            if site is None or kind is None: continue
            try: length = max(0, float(row.get('MaxLength') or 0))
            except (ValueError, TypeError): length = 0
            site['equipment'][kind] = max(site['equipment'].get(kind, 0), length)
        campgrounds = []
        for fid, row in sorted(facilities.items()):
            amenities = {}; rig_types = set(); limits = collections.defaultdict(list)
            for site in by_facility[fid]:
                rig_types.update(site['equipment'])
                for kind, length in site['equipment'].items():
                    if length > 0: limits[kind].append(length)
                attrs = site['attributes']
                for key, amenity in [('Water Hookup', 'waterHookup'), ('Sewer Hookup', 'sewerHookup'), ('Pets Allowed', 'pets')]:
                    if attrs.get(key, '').casefold() in ('yes', 'true', 'y'): amenities[amenity] = True
                entry = attrs.get('Driveway Entry', '').lower().replace('-', '').replace(' ', '')
                if entry == 'pullthrough': amenities['pullThrough'] = True
                electric = attrs.get('Electricity Hookup', '').strip().lower()
                amps = set(re.findall(r'\d+', electric))
                if electric in ('yes', 'true') or amps.intersection({'15', '20', '30', '50', '100'}):
                    amenities['electricHookup'] = True
                    if '30' in amps: amenities['amp30'] = True
                    if '50' in amps: amenities['amp50'] = True
            lat, lon = coordinates(row, 'Facility')
            campground = {'id': 'ridb-' + fid, 'name': row['FacilityName'], 'region': regions.get(fid) or 'United States · federal campground',
                          'latitude': lat, 'longitude': lon, 'amenities': amenities,
                          'notes': 'Federal directory snapshot. Site-specific restrictions apply; verify with the operator. ' + str(len(by_facility[fid])) + ' overnight site records in this snapshot.',
                          'sourceURL': 'https://www.recreation.gov/camping/campgrounds/' + fid,
                          'checkedAt': today}
            campground.update(contact(row, websites.get(fid)))
            if rig_types: campground['supportedRigTypes'] = sorted(rig_types)
            if limits['motorhome']: campground['maximumMotorhomeFeet'] = max(limits['motorhome'])
            if limits['travelTrailer']: campground['maximumTrailerFeet'] = max(limits['travelTrailer'])
            campgrounds.append(campground)
        index = {'schemaVersion': SCHEMA_VERSION, 'coverageNote': str(len(campgrounds)) + ' federal campground records from the RIDB daily export, retrieved ' + today + '. Not all US campgrounds. Snapshot facts, not live booking availability. Unknown facts remain unknown.', 'campgrounds': campgrounds}
        dump = lambda path, obj: path.write_text(json.dumps(obj, separators=(',', ':'), ensure_ascii=False) + '\n')
        dump(output / 'index.json', index)
        for shard in range(SHARDS):
            groups = {fid: by_facility[fid] for fid in sorted(facilities) if shard_for(fid) == shard and by_facility[fid]}
            dump(output / f'sites-{shard:02d}.json', {'schemaVersion': 1, 'sitesByFacility': groups})
        with archive.open('rb') as source_file:
            source_hash = hashlib.file_digest(source_file, 'sha256').hexdigest()
        manifest = {'retrievedAt': today, 'sourceURL': SOURCE, 'sourceSHA256': source_hash,
                    'campgrounds': len(campgrounds), 'rawSiteRecords': raw_count, 'includedOvernightSites': len(sites), 'facilitiesWithSites': sum(bool(by_facility[fid]) for fid in facilities),
                    'excluded': 'Disabled/non-Campground facilities, invalid/zero facility coordinates, management and non-overnight inventory, non-https links, undialable phone numbers and malformed emails. No images, narratives, prices or live availability.',
                    'shardCount': SHARDS, 'files': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(output.glob('*.json')) if p.name != 'manifest.json'}}
        dump(output / 'manifest.json', manifest)
        print(json.dumps({k: v for k, v in manifest.items() if k != 'files'}, indent=2))

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=Path('data/campgrounds'))
    args = parser.parse_args()
    build(args.archive, args.output)
