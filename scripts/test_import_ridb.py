#!/usr/bin/env python3
import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
import zipfile
from import_ridb import build, email_address, https_url, phone_number, records, shard_for

class RIDBImportTests(unittest.TestCase):
    def test_stream_parser_handles_unicode_and_empty_arrays(self):
        text = {'RECDATA': [{'text': 'é' * 40000}, {'text': '尾'}]}
        self.assertEqual(list(records(io.BytesIO(json.dumps(text, ensure_ascii=False).encode()))), text['RECDATA'])
        self.assertEqual(list(records(io.BytesIO(b'{"RECDATA":[]}'))), [])

    def test_import_excludes_management_unknowns_and_does_not_confuse_vehicle_access_with_ada(self):
        with tempfile.TemporaryDirectory() as temp:
            temp = Path(temp)
            rows = {
                'Facilities': [{'FacilityID': '1', 'FacilityName': 'Pines', 'Enabled': True, 'FacilityTypeDescription': 'Campground', 'FacilityLatitude': 37, 'FacilityLongitude': -119},
                               {'FacilityID': '2', 'FacilityName': 'Bad coords', 'Enabled': True, 'FacilityTypeDescription': 'Campground', 'FacilityLatitude': 0, 'FacilityLongitude': 0}],
                'FacilityAddresses': [],
                'Campsites': [{'CampsiteID': 'A', 'FacilityID': '1', 'CampsiteName': '01', 'TypeOfUse': 'Overnight', 'CampsiteType': 'RV ELECTRIC', 'CampsiteAccessible': True},
                              {'CampsiteID': 'B', 'FacilityID': '1', 'TypeOfUse': 'Overnight', 'CampsiteType': 'MANAGEMENT'}],
                'CampsiteAttributes': [{'EntityID': 'A', 'EntityType': 'Campsite', 'AttributeName': 'Electricity Hookup', 'AttributeValue': '30/50'},
                                       {'EntityID': 'A', 'EntityType': 'Campsite', 'AttributeName': 'Sewer Hookup', 'AttributeValue': ''}],
                'PermittedEquipment': [{'CampsiteID': 'A', 'EquipmentName': 'RV', 'MaxLength': 35}, {'CampsiteID': 'A', 'EquipmentName': 'Trailer', 'MaxLength': 0}],
            }
            archive = temp / 'export.zip'
            with zipfile.ZipFile(archive, 'w') as z:
                for name, values in rows.items(): z.writestr(name + '_API_v1.json', json.dumps({'RECDATA': values}))
            out = temp / 'result'
            with contextlib.redirect_stdout(io.StringIO()): build(archive, out)
            index = json.loads((out / 'index.json').read_text())
            self.assertEqual(len(index['campgrounds']), 1)
            campground = index['campgrounds'][0]
            self.assertEqual(campground['amenities'], {'electricHookup': True, 'amp30': True, 'amp50': True})
            self.assertNotIn('maximumTrailerFeet', campground)
            shard = json.loads((out / f'sites-{shard_for("1"):02d}.json').read_text())
            self.assertEqual(len(shard['sitesByFacility']['1']), 1)
            self.assertTrue(shard['sitesByFacility']['1'][0]['vehicleAccessible'])
            manifest = json.loads((out / 'manifest.json').read_text())
            self.assertNotIn('manifest.json', manifest['files'])

    def test_contact_fields_are_copied_as_published_and_malformed_values_are_dropped(self):
        with tempfile.TemporaryDirectory() as temp:
            temp = Path(temp)
            facility = lambda fid, **extra: dict({'FacilityID': fid, 'FacilityName': 'Camp ' + fid, 'Enabled': True,
                                                  'FacilityTypeDescription': 'Campground', 'FacilityLatitude': 37, 'FacilityLongitude': -119}, **extra)
            rows = {
                'Facilities': [facility('1', FacilityPhone='(530) 543-2600 ext 2', FacilityEmail='pines@example.gov',
                                        FacilityReservationURL='https://www.recreation.gov/camping/campgrounds/1'),
                               facility('2', FacilityPhone='TBD', FacilityEmail='not an email', FacilityReservationURL='http://insecure.example'),
                               facility('3')],
                'FacilityAddresses': [], 'Campsites': [], 'CampsiteAttributes': [], 'PermittedEquipment': [],
                'Links': [{'EntityID': '1', 'EntityType': 'Facility', 'LinkType': 'Official Web Site', 'URL': 'https://www.fs.usda.gov/pines'},
                          {'EntityID': '1', 'EntityType': 'Facility', 'LinkType': 'Other', 'URL': 'https://example.com/other'},
                          {'EntityID': '2', 'EntityType': 'Facility', 'LinkType': 'Official Web Site', 'URL': 'javascript:alert(1)'}],
            }
            archive = temp / 'export.zip'
            with zipfile.ZipFile(archive, 'w') as z:
                for name, values in rows.items(): z.writestr(name + '_API_v1.json', json.dumps({'RECDATA': values}))
            out = temp / 'result'
            with contextlib.redirect_stdout(io.StringIO()): build(archive, out)
            index = json.loads((out / 'index.json').read_text())
            self.assertEqual(index['schemaVersion'], 2)
            by_id = {c['id']: c for c in index['campgrounds']}
            self.assertEqual(by_id['ridb-1']['phone'], '(530) 543-2600 ext 2')
            self.assertEqual(by_id['ridb-1']['email'], 'pines@example.gov')
            self.assertEqual(by_id['ridb-1']['reservationURL'], 'https://www.recreation.gov/camping/campgrounds/1')
            self.assertEqual(by_id['ridb-1']['websiteURL'], 'https://www.fs.usda.gov/pines')
            for missing in ('ridb-2', 'ridb-3'):
                for key in ('phone', 'email', 'reservationURL', 'websiteURL'):
                    self.assertNotIn(key, by_id[missing], (missing, key))

    def test_contact_validators(self):
        self.assertIsNone(https_url('http://example.com'))
        self.assertIsNone(https_url('https://'))
        self.assertIsNone(https_url('https://exa mple.com'))
        self.assertIsNone(https_url(None))
        self.assertEqual(https_url(' https://example.com/a '), 'https://example.com/a')
        self.assertIsNone(phone_number('123'))
        self.assertIsNone(phone_number('call the office'))
        self.assertEqual(phone_number('  801-555-0100  '), '801-555-0100')
        self.assertIsNone(email_address('a@b'))
        self.assertIsNone(email_address('<a@b.com>'))
        self.assertEqual(email_address(' a@b.com '), 'a@b.com')

if __name__ == '__main__': unittest.main()
