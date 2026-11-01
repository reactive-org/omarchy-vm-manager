#!/usr/bin/env python3
"""Verify a signed/notarized package without launching the app or any guest."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys

from kit_artifacts import ROOT
from keychain_profile import verify_keychain_profile


def run(*arguments):
    result = subprocess.run([str(value) for value in arguments], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f"Signed-package verification failed: {Path(str(arguments[0])).name}: {result.stderr[-3000:]}")
    return result


def verify(app):
    lock = json.loads((app / "Contents/Resources/TryOmarchyRuntime.lock.json").read_bytes())
    team = lock.get("signingTeamID", "")
    assert re.fullmatch(r"[A-Z0-9]{10}", team), "missing signed runtime team"
    assert not os.environ.get("APPLE_TEAM_ID") or os.environ["APPLE_TEAM_ID"] == team
    assert verify_keychain_profile(app, team), "signed release is missing its Touch ID provisioning profile"
    kit = app / "Contents/Helpers/TryOmarchyKit.bundle"
    run("python3", ROOT / "Vendor/try-omarchy/scripts/kit_signature.py", "verify", "--team", team, "--require-notarization", kit)
    for name in ("OmarchyVMManager", "OmarchyVMStorageHelper", "omarchy-vm"):
        executable = app / "Contents/MacOS" / name
        details = run("codesign", "-dv", "--verbose=4", executable).stderr
        assert "Authority=Developer ID Application: " in details
        assert f"TeamIdentifier={team}\n" in details
        assert re.search(r"flags=0x[0-9a-f]+\([^)]*runtime", details)
        assert "\nTimestamp=" in details
        run("codesign", "--verify", "--strict", "--check-notarization", "-R=notarized", executable)
        if name != "OmarchyVMManager":
            entitlement_data = run("codesign", "-d", "--entitlements", ":-", executable).stdout.strip()
            import plistlib
            entitlements = plistlib.loads(entitlement_data.encode()) if entitlement_data else {}
            assert not any(key in entitlements for key in ("com.apple.application-identifier", "keychain-access-groups")), "child executable gained Keychain access"
    diagnostics = json.loads(run(app / "Contents/MacOS/OmarchyVMManager", "--verify-bundle-json").stdout)
    assert diagnostics["touchIDProtectedStorageAvailable"] is True, "the signed process cannot see its Touch ID entitlement"
    assert diagnostics["developmentKeychainCompatibility"] is False, "a signed release selected the development Keychain store"
    assert diagnostics["hostPreflightPerformed"] is False and diagnostics["vmLaunchEnabled"] is False
    run("codesign", "--verify", "--deep", "--strict", app)
    run("xcrun", "stapler", "validate", app)
    run("spctl", "--assess", "--type", "execute", "--verbose=2", app)
    print("signed-package: PASS; provisioned Touch ID capability, Developer ID, hardened runtime, timestamps, notarization, stapling and Gatekeeper")


if __name__ == "__main__":
    try:
        verify(Path(sys.argv[1]))
    except Exception as error:
        sys.exit(str(error))
