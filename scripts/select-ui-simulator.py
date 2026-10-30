"""Choose each workflow option's exact simulator on its newest compatible iOS 27 runtime."""
import json
import re
import sys


def select_device(devices, family):
    choices = {
        "iPhone": ("iPhone 18 Pro", (27, 0, 0)),
        "iPad": ("iPad Pro 13-inch (M5)", (27, 0, 0)),
        "iPhone Duo": ("iPhone Duo", (27, 1, 0)),
    }
    if family not in choices:
        raise ValueError(f"Unknown simulator family: {family}")
    name, minimum = choices[family]
    candidates = []
    for runtime, items in devices.items():
        match = re.search(r"\.iOS-(\d+)-(\d+)(?:-(\d+))?$", runtime)
        if not match:
            continue
        version = tuple(int(part or 0) for part in match.groups())
        if version < minimum or version[0] != 27:
            continue
        for index, device in enumerate(items):
            if device["name"] == name and device.get("isAvailable", True):
                candidates.append((version, -index, device["udid"]))
    if not candidates:
        raise ValueError(f"No available {name} simulator on iOS {minimum[0]}.{minimum[1]} or a later iOS 27 runtime. Install its runtime in Xcode.")
    return max(candidates)[2]


if __name__ == "__main__":
    try:
        with open(sys.argv[2]) as source:
            print(select_device(json.load(source)["devices"], sys.argv[1]))
    except ValueError as error:
        raise SystemExit(str(error))
