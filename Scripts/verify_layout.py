#!/usr/bin/env python3
"""No guest or helper run: static app assembly contract checks."""
import json
import argparse
from pathlib import Path
import plistlib
import sys
import subprocess

from kit_artifacts import ROOT
from build_patched_kit import inventory
from bundle_layout import core_resource_directory
from keychain_profile import verify_keychain_profile
import provisioning_package

parser = argparse.ArgumentParser()
parser.add_argument("app", type=Path)
parser.add_argument("--runtime-lock", type=Path, default=ROOT / "Config/TryOmarchyRuntime.lock.json")
args = parser.parse_args()
app = args.app
contents = app / "Contents"
provisioning_package.verify(contents)
info = plistlib.loads((contents / "Info.plist").read_bytes())
assert info["CFBundleExecutable"] == "OmarchyVMManager"
resources = core_resource_directory(contents / "Resources/OmarchyVMManager_OmarchyVMManagerCore.bundle")
contract = resources / "OwnerSetupContract.json"
assert contract.read_bytes() == (ROOT / "Sources/OmarchyVMManagerCore/Resources/OwnerSetupContract.json").read_bytes()
assert json.loads(contract.read_bytes())["schemaVersion"] == 1
official_keyboards = json.loads(contract.read_bytes())["keyboards"]
for lean_name in ("LeanOwnerSetupContract.json", "LeanOwnerSetupContract-a948d8a.json"):
    lean_contract = contract.with_name(lean_name)
    assert lean_contract.read_bytes() == (ROOT / "Sources/OmarchyVMManagerCore/Resources" / lean_name).read_bytes()
    # Every reviewed contract offers the manager's keyboard IDs; console keymaps
    # may differ by Omarchy release (4.5 moved three layouts to latin1 maps).
    assert [k["id"] for k in json.loads(lean_contract.read_bytes())["keyboards"]] == [k["id"] for k in official_keyboards]
assert json.loads(contract.with_name("LeanOwnerSetupContract.json").read_bytes())["keyboards"] == official_keyboards
assert (resources / "ReviewedFactories.json").read_bytes() == (ROOT / "Sources/OmarchyVMManagerCore/Resources/ReviewedFactories.json").read_bytes()
channel = info.get("OmarchyAppChannel", "stable")
assert channel in ("stable", "development"), "unknown app channel"
development = channel == "development"
assert not (development and info.get("OmarchyLayoutPreview") is True)
assert info["CFBundleIdentifier"] == ("dev.omarchy.vm-manager.layout-preview" if info.get("OmarchyLayoutPreview") is True else ("dev.omarchy.vm-manager.dev" if development else "dev.omarchy.vm-manager"))
if development:
    assert info["CFBundleName"] == info["CFBundleDisplayName"] == "Omarchy VM Manager Dev"
assert info["LSMinimumSystemVersion"] == "15.0"
assert info["CFBundleIconFile"] == "OmarchyVMManager"
for stem in ("OmarchyVMManager", "OmarchyGuest"):
    for extension in ("icns", "png"):
        name = stem + "." + extension
        source_stem = "OmarchyVMManagerDev" if development and stem == "OmarchyVMManager" else stem
        assert (contents / "Resources" / name).read_bytes() == (ROOT / "App/Assets" / (source_stem + "." + extension)).read_bytes()
    assert (contents / "Resources" / (stem + ".icns")).read_bytes().startswith(b"icns")
fonts = sorted(path.name for path in (ROOT / "App/Fonts").iterdir())
assert sorted(path.name for path in (contents / "Resources/Fonts").iterdir()) == fonts, "bundled fonts differ"
for name in fonts:
    assert (contents / "Resources/Fonts" / name).read_bytes() == (ROOT / "App/Fonts" / name).read_bytes()
assert not (contents / "Library/LaunchDaemons").exists(), "NAT-only app must not register networking"
assert (contents / "Resources/TryOmarchy-THIRD_PARTY_NOTICES.md").is_file()
cli_name = "omarchy-vm-dev" if development else "omarchy-vm"
for name in ("OmarchyVMManager", "OmarchyVMStorageHelper", cli_name):
    assert (contents / "MacOS" / name).is_file()
for name, argument in (("OmarchyVMManager", "--verify-bundle-json"), (cli_name, "--version"), ("OmarchyVMStorageHelper", "--channel-json")):
    diagnostic = json.loads(subprocess.check_output([str(contents / "MacOS" / name), argument], text=True))
    assert diagnostic["appChannel"] == channel, "mixed app-channel executables refused"
lock = json.loads(args.runtime_lock.read_bytes())
verify_keychain_profile(app, lock.get("signingTeamID", ""))
embedded_lock = contents / "Resources/TryOmarchyRuntime.lock.json"
assert embedded_lock.read_bytes() == args.runtime_lock.read_bytes()
kit = contents / "Helpers/TryOmarchyKit.bundle"
assert inventory(kit) == lock["files"]
guest = kit / "Contents/Resources/guest"
factory = json.loads((guest / "factory.json").read_bytes())
assert not (guest / factory["compressed"]["path"]).exists()
assert not list(app.rglob("*.img"))
assert not list(app.rglob("*.img.zst*"))
print("app-layout: PASS; exact locked payload, NAT-only, no factory image")
