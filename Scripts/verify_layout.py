#!/usr/bin/env python3
"""No guest or helper run: static app assembly contract checks."""
import json
from pathlib import Path
import plistlib
import sys

from kit_artifacts import ROOT
from build_patched_kit import inventory

app = Path(sys.argv[1])
contents = app / "Contents"
info = plistlib.loads((contents / "Info.plist").read_bytes())
assert info["CFBundleExecutable"] == "OmarchyVMManager"
assert info["CFBundleIdentifier"] == "dev.omarchy.vm-manager"
assert info["LSMinimumSystemVersion"] == "15.0"
assert info["CFBundleIconFile"] == "OmarchyVMManager"
for extension in ("icns", "png"):
    name = "OmarchyVMManager." + extension
    assert (contents / "Resources" / name).read_bytes() == (ROOT / "App/Assets" / name).read_bytes()
assert (contents / "Resources/OmarchyVMManager.icns").read_bytes().startswith(b"icns")
assert not (contents / "Library/LaunchDaemons").exists(), "NAT-only app must not register networking"
assert (contents / "Resources/TryOmarchy-THIRD_PARTY_NOTICES.md").is_file()
for name in ("OmarchyVMManager", "OmarchyVMStorageHelper"):
    assert (contents / "MacOS" / name).is_file()
lock = json.loads((ROOT / "Config/TryOmarchyRuntime.lock.json").read_bytes())
embedded_lock = contents / "Resources/TryOmarchyRuntime.lock.json"
assert embedded_lock.read_bytes() == (ROOT / "Config/TryOmarchyRuntime.lock.json").read_bytes()
kit = contents / "Helpers/TryOmarchyKit.bundle"
assert inventory(kit) == lock["files"]
guest = kit / "Contents/Resources/guest"
factory = json.loads((guest / "factory.json").read_bytes())
assert not (guest / factory["compressed"]["path"]).exists()
assert not list(app.rglob("*.img"))
assert not list(app.rglob("*.img.zst*"))
print("app-layout: PASS; exact locked payload, NAT-only, no factory image")
