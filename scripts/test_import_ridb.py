#!/usr/bin/env python3
import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
import zipfile
from import_ridb import build, records, shard_for

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

if __name__ == '__main__': unittest.main()
