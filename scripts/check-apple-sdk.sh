#!/bin/bash
# Full-display Duo layout and its APIs require a 27.1 SDK build, not a higher deployment target.
set -euo pipefail

xcodebuild -version
SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version)"
python3 - "$SDK_VERSION" <<'PY'
import sys

version = sys.argv[1]
parts = tuple(int(part) for part in version.split(".")[:2])
if parts < (27, 1):
    raise SystemExit(f"iOS SDK {version} is too old. Select Xcode 27.1 or newer for iPhone Duo support.")
print(f"iOS SDK: {version} (Duo-capable)")
PY
