#!/usr/bin/env python3
"""No guest or helper run: static app assembly contract checks."""
import json
import argparse
from pathlib import Path
import plistlib
import sys

from kit_artifacts import ROOT
from build_patched_kit import inventory
from bundle_layout import core_resource_directory

parser = argparse.ArgumentParser()
parser.add_argument("app", type=Path)
parser.add_argument("--runtime-lock", type=Path, default=ROOT / "Config/TryOmarchyRuntime.lock.json")
args = parser.parse_args()
app = args.app
contents = app / "Contents"
info = plistlib.loads((contents / "Info.plist").read_bytes())
assert info["CFBundleExecutable"] == "OmarchyVMManager"
resources = core_resource_directory(contents / "Resources/OmarchyVMManager_OmarchyVMManagerCore.bundle")
contract = resources / "OwnerSetupContract.json"
assert contract.read_bytes() == (ROOT / "Sources/OmarchyVMManagerCore/Resources/OwnerSetupContract.json").read_bytes()
assert json.loads(contract.read_bytes())["schemaVersion"] == 1
lean_contract = contract.with_name("LeanOwnerSetupContract.json")
assert lean_contract.read_bytes() == (ROOT / "Sources/OmarchyVMManagerCore/Resources/LeanOwnerSetupContract.json").read_bytes()
assert json.loads(lean_contract.read_bytes())["keyboards"] == json.loads(contract.read_bytes())["keyboards"]
assert (resources / "ReviewedFactories.json").read_bytes() == (ROOT / "Sources/OmarchyVMManagerCore/Resources/ReviewedFactories.json").read_bytes()
assert info["CFBundleIdentifier"] == ("dev.omarchy.vm-manager.layout-preview" if info.get("OmarchyLayoutPreview") is True else "dev.omarchy.vm-manager")
assert info["LSMinimumSystemVersion"] == "15.0"
assert info["CFBundleIconFile"] == "OmarchyVMManager"
for stem in ("OmarchyVMManager", "OmarchyGuest"):
    for extension in ("icns", "png"):
        name = stem + "." + extension
        assert (contents / "Resources" / name).read_bytes() == (ROOT / "App/Assets" / name).read_bytes()
    assert (contents / "Resources" / (stem + ".icns")).read_bytes().startswith(b"icns")
assert not (contents / "Library/LaunchDaemons").exists(), "NAT-only app must not register networking"
assert (contents / "Resources/TryOmarchy-THIRD_PARTY_NOTICES.md").is_file()
for name in ("OmarchyVMManager", "OmarchyVMStorageHelper", "omarchy-vm"):
    assert (contents / "MacOS" / name).is_file()
lock = json.loads(args.runtime_lock.read_bytes())
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
