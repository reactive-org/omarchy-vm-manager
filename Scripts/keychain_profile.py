"""Optional provisioned Keychain capability; never reads a signing private key."""
import datetime
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile


def profile_pin():
    path = Path(__file__).resolve().parents[1] / "Config/TouchIDProfile.lock.json"
    value = json.loads(path.read_bytes())
    assert value["format"] == 1 and value["bundleID"] == "dev.omarchy.vm-manager", "unsupported Keychain profile pin"
    assert re.fullmatch(r"[0-9a-f]{64}", value["profileSHA256"]), "invalid Keychain profile digest"
    return value


def verify_profile_bytes(raw):
    assert hashlib.sha256(raw).hexdigest() == profile_pin()["profileSHA256"], "Keychain profile digest mismatch"


def signing_certificate(app):
    with tempfile.TemporaryDirectory(prefix="omarchy-public-cert-") as temp:
        prefix = Path(temp) / "certificate"
        subprocess.run(["codesign", "-d", "--extract-certificates=" + str(prefix), str(app)], check=True, capture_output=True)
        return Path(str(prefix) + "0").read_bytes()


def profile_entitlements(profile, team, bundle_id, now=None):
    """Validate decoded profile scope before requesting restricted entitlements.

    macOS remains responsible for validating the Apple-signed profile and the
    app's signing certificate at launch. Unit tests supply synthetic dictionaries.
    """
    assert re.fullmatch(r"[A-Z0-9]{10}", team), "invalid signing team"
    assert bundle_id == "dev.omarchy.vm-manager", "Keychain profile is only for the manager"
    app_id = team + "." + bundle_id
    assert profile.get("TeamIdentifier") == [team], "Keychain profile team mismatch"
    assert "OSX" in profile.get("Platform", []), "not a macOS Keychain profile"
    assert profile.get("ProvisionsAllDevices") is True, "a Developer ID distribution profile is required"
    assert profile.get("DeveloperCertificates"), "profile has no authorized signing certificates"
    expiry = profile.get("ExpirationDate")
    assert isinstance(expiry, datetime.datetime), "profile has no expiration"
    expiry = expiry.replace(tzinfo=datetime.timezone.utc) if expiry.tzinfo is None else expiry
    now = now or datetime.datetime.now(datetime.timezone.utc)
    assert expiry > now, "Keychain provisioning profile expired"
    allowed = profile.get("Entitlements", {})
    assert allowed.get("com.apple.application-identifier") == app_id, "Keychain profile must have this exact App ID"
    assert allowed.get("com.apple.developer.team-identifier") == team, "Keychain profile entitlement team mismatch"
    assert not any(allowed.get(key, False) for key in ("get-task-allow", "com.apple.security.get-task-allow")), "debug distribution profile refused"
    # The App ID is itself the default Keychain access group. Do not grant any
    # shared groups, or give the CLI/storage helper access to guest passwords.
    return {"com.apple.application-identifier": app_id,
            "com.apple.developer.team-identifier": team}


def decode_profile(path):
    result = subprocess.run(["security", "cms", "-D", "-i", str(path)], check=True, capture_output=True)
    return plistlib.loads(result.stdout)


def stage_keychain_profile(profile_path, stage, team, bundle_id, base_entitlements):
    profile_bytes = Path(profile_path).read_bytes()
    verify_profile_bytes(profile_bytes)
    # Decode the same bytes that will be embedded, avoiding a source-file race.
    embedded = stage / "Contents/embedded.provisionprofile"
    embedded.write_bytes(profile_bytes)
    granted = profile_entitlements(decode_profile(embedded), team, bundle_id)
    entitlements = dict(base_entitlements, **granted)
    return entitlements


def verify_keychain_profile(app, team):
    embedded = app / "Contents/embedded.provisionprofile"
    result = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(app)], check=True, capture_output=True)
    actual = plistlib.loads(result.stdout) if result.stdout.strip() else {}
    restricted = {key: value for key, value in actual.items()
                  if key in {"com.apple.application-identifier", "com.apple.developer.team-identifier", "keychain-access-groups"}}
    if not embedded.exists():
        assert not restricted, "Keychain entitlements require an embedded profile"
        return False
    bundle_id = plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"]
    verify_profile_bytes(embedded.read_bytes())
    profile = decode_profile(embedded)
    expected = profile_entitlements(profile, team, bundle_id)
    assert restricted == expected, "packaged Keychain entitlement scope mismatch"
    assert signing_certificate(app) in profile["DeveloperCertificates"], "Keychain profile does not authorize the app's signing certificate"
    return True
