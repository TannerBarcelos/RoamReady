#!/usr/bin/env bash
set -euo pipefail

TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$TASK_ROOT"

if [[ "${1:-}" != "" && "${1:-}" != "--native" ]]; then
  echo "Usage: scripts/check.sh [--native]" >&2
  exit 2
fi

SWIFT_BIN="${SWIFT_BIN:-swift}"
if ! command -v "$SWIFT_BIN" >/dev/null 2>&1; then
  echo "Swift 6 or newer is required. Set SWIFT_BIN to the toolchain's swift executable." >&2
  exit 1
fi
SWIFTC_BIN="${SWIFTC_BIN:-$(dirname "$(command -v "$SWIFT_BIN")")/swiftc}"
export SWIFTC_BIN

"$SWIFT_BIN" test
python3 scripts/validate_catalog.py

"$SWIFT_BIN" -e '
import Foundation
let url = URL(fileURLWithPath: "RoamReady.xcodeproj/project.pbxproj")
var format = PropertyListSerialization.PropertyListFormat.openStep
let project = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: &format)
guard let dictionary = project as? [String: Any], let objects = dictionary["objects"] as? [String: Any],
      let rootID = dictionary["rootObject"] as? String, objects[rootID] != nil else {
    fatalError("Invalid Xcode project object graph")
}
print("Parsed Xcode OpenStep property list (\(objects.count) objects).")
'

python3 - <<'PY'
import json
import os
import pathlib
import plistlib
import re
import subprocess
import xml.etree.ElementTree as ET

root = pathlib.Path.cwd()
for path in list((root / "Camp").rglob("*.plist")) + list((root / "Camp").rglob("*.xcprivacy")):
    with path.open("rb") as stream:
        plistlib.load(stream)
with (root / "Camp/Camp.entitlements").open("rb") as stream:
    entitlements = plistlib.load(stream)
assert entitlements == {}, "Default build should not request unconfigured Apple capabilities"

json_files = list((root / "Camp").rglob("*.json"))
for path in json_files:
    json.loads(path.read_text())
directory = json.loads((root / "Camp/Resources/campgrounds.json").read_text())
assert directory["schemaVersion"] == 1
campground_ids = set()
for place in directory["campgrounds"]:
    assert place["id"] not in campground_ids
    campground_ids.add(place["id"])
    assert -90 <= place["latitude"] <= 90 and -180 <= place["longitude"] <= 180
    assert place["sourceURL"].startswith("https://")
    assert all(type(value) is bool for value in place["amenities"].values())
    assert place["checkedAt"] and place["name"] and place["region"]
catalog = json.loads((root / "Camp/Resources/rig-catalog.json").read_text())
assert catalog["schemaVersion"] == 1
assert isinstance(catalog["coverageNote"], str) and catalog["coverageNote"].strip()
rig_types = {"travelTrailer", "fifthWheel", "motorhome", "camperVan", "truckCamper", "popUp", "carCamping", "tent"}
record_ids = set()
for record in catalog["records"]:
    assert record["id"] not in record_ids, f'Duplicate catalog record: {record["id"]}'
    record_ids.add(record["id"])
    assert record["rigType"] in rig_types
    assert type(record["year"]) is int
    assert record["sourceURL"].startswith("https://")
    for key in ("id", "make", "model", "imageRights"):
        assert isinstance(record[key], str) and record[key].strip(), f"Empty {key}"

project = (root / "RoamReady.xcodeproj/project.pbxproj").read_text()
definitions = set(re.findall(r"\b([A-F0-9]{24})\s*(?:/\*.*?\*/\s*)?=", project))
references = set(re.findall(r"\b[A-F0-9]{24}\b", project))
assert not (references - definitions), f"Undefined project references: {references - definitions}"
assert "PBXFileSystemSynchronizedRootGroup" in project
assert "XCLocalSwiftPackageReference" in project
assert "relativePath = .;" in project
assert "IPHONEOS_DEPLOYMENT_TARGET = 27.0;" in project
assert "SWIFT_DEFAULT_ACTOR_ISOLATION" not in project, "Do not implicitly isolate all app declarations"
assert (root / "Package.swift").is_file()
scheme = ET.parse(root / "RoamReady.xcodeproj/xcshareddata/xcschemes/RoamReady.xcscheme")
for reference in scheme.iter("BuildableReference"):
    assert reference.attrib["BlueprintIdentifier"] in definitions
    assert reference.attrib["BuildableName"] == "RoamReady.app"
    assert reference.attrib["ReferencedContainer"] == "container:RoamReady.xcodeproj"

sources = sorted((root / "Camp").rglob("*.swift"))
assert sources, "No native app source files found"
for source in sources:
    subprocess.run([os.environ["SWIFTC_BIN"], "-frontend", "-parse", str(source)], check=True)
print(f"Validated plists, {len(json_files)} JSON files, {len(record_ids)} catalog records, project references, shared scheme.")
print(f"Parsed syntax of {len(sources)} native Swift source files. Apple SDK APIs were NOT type-checked.")
PY

if [[ "${1:-}" == "--native" ]]; then
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Native validation requires macOS and Xcode with the iOS 27 SDK." >&2
    exit 1
  fi
  SDK_VERSION="$(xcrun --sdk iphonesimulator --show-sdk-version)"
  if [[ "${SDK_VERSION%%.*}" -lt 27 ]]; then
    echo "iOS 27 SDK required; selected Xcode provides simulator SDK $SDK_VERSION." >&2
    exit 1
  fi
  plutil -lint RoamReady.xcodeproj/project.pbxproj Camp/Info.plist Camp/Camp.entitlements
  xcodebuild -project RoamReady.xcodeproj -scheme "RoamReady" -configuration Debug \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$TASK_ROOT/.derivedData" \
    CODE_SIGNING_ALLOWED=NO build
else
  echo "Native iOS compilation and simulator/device validation remain required on macOS."
fi
