"""CI check: local signing overrides must reach both app configurations; never signs a build."""
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
LOCAL = ROOT / "Config/Local.xcconfig"
DEFAULTS = {
    "PRODUCT_BUNDLE_IDENTIFIER": "com.tannerdev.roamready",
    "DEVELOPMENT_TEAM": "CCW6X88UZ6",
    "ROAMREADY_MIRRORING_CONTAINER": "",
    "CODE_SIGN_ENTITLEMENTS": "Camp/Camp.entitlements",
}
OVERRIDES = {
    "PRODUCT_BUNDLE_IDENTIFIER": "com.roamready.configurationtest",
    "DEVELOPMENT_TEAM": "TESTTEAM01",
    "ROAMREADY_MIRRORING_CONTAINER": "iCloud.com.roamready.configurationtest",
    "CODE_SIGN_ENTITLEMENTS": "Config/Cloud.entitlements",
}


def verify(expected):
    for configuration in ("Debug", "Release"):
        output = subprocess.check_output([
            "xcodebuild", "-project", "RoamReady.xcodeproj", "-scheme", "RoamReady",
            "-configuration", configuration, "-destination", "generic/platform=iOS Simulator",
            "-showBuildSettings", "-json",
        ], cwd=ROOT)
        targets = json.loads(output)
        settings = next(target["buildSettings"] for target in targets if target["target"] == "Camp")
        for key, value in expected.items():
            assert settings.get(key, "") == value, f"{configuration}: {key} did not resolve correctly"
        print(f"{configuration} configuration resolves correctly")


if __name__ == "__main__":
    if LOCAL.exists():
        raise SystemExit("Run only in a clean CI checkout; will not overwrite Config/Local.xcconfig")
    verify(DEFAULTS)
    created = False
    try:
        # Exclusive creation protects a developer file even if one appears during the first check.
        with LOCAL.open("x") as fixture:
            created = True
            fixture.write("\n".join(f"{key} = {value}" for key, value in OVERRIDES.items()) + "\n")
        verify(OVERRIDES)
    finally:
        if created:
            LOCAL.unlink()
