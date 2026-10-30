"""Choose the newest available iOS runtime, keeping ordinary iPhone and Duo runs separate."""
import json
import re
import sys


def select_device(devices, family):
    if family not in ("iPhone", "iPad", "iPhone Duo"):
        raise ValueError(f"Unknown simulator family: {family}")
    candidates = []
    for runtime, items in devices.items():
        match = re.search(r"\.iOS-(\d+)-(\d+)(?:-(\d+))?$", runtime)
        if not match:
            continue
        version = tuple(int(part or 0) for part in match.groups())
        minimum = (27, 1, 0) if family == "iPhone Duo" else (27, 0, 0)
        if version < minimum:
            continue
        for index, device in enumerate(items):
            name = device["name"]
            matches = name == "iPhone Duo" if family == "iPhone Duo" else name.startswith(family) and "Duo" not in name
            if matches and device.get("isAvailable", True):
                candidates.append((version, -index, device["udid"]))
    if not candidates:
        raise ValueError(f"No available {family} simulator with iOS {'27.1' if family == 'iPhone Duo' else '27'} or newer. Install its runtime in Xcode.")
    return max(candidates)[2]


if __name__ == "__main__":
    try:
        with open(sys.argv[2]) as source:
            print(select_device(json.load(source)["devices"], sys.argv[1]))
    except ValueError as error:
        raise SystemExit(str(error))
