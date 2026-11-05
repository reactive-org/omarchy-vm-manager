#!/usr/bin/env python3
"""Exercise packaged channel guards without a manager session or VM storage."""
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

if sys.flags.optimize:
    raise RuntimeError("Optimized Python execution is refused")

for argument in sys.argv[1:]:
    app = Path(argument).resolve()
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    channel = info["OmarchyAppChannel"]
    cli = "omarchy-vm-dev" if channel == "development" else "omarchy-vm"
    other_id = "dev.omarchy.vm-manager" if channel == "development" else "dev.omarchy.vm-manager.dev"
    for name, option in ((cli, "--version"), ("OmarchyVMStorageHelper", "--channel-json")):
        result = subprocess.run([str(app / "Contents/MacOS" / name), option], check=True, capture_output=True, text=True)
        assert json.loads(result.stdout)["appChannel"] == channel
    with tempfile.TemporaryDirectory(prefix="omarchy-channel-bundle-") as scratch:
        fixture = Path(scratch) / "Mismatched.app/Contents"
        (fixture / "MacOS").mkdir(parents=True)
        (fixture / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": other_id,
            "CFBundleExecutable": "OmarchyVMManager",
            "CFBundlePackageType": "APPL",
        }))
        # There is deliberately no manager binary. If the CLI identity guard
        # regresses, its missing-app guard still prevents a real command.
        for name, arguments in ((cli, ["list"]), ("OmarchyVMStorageHelper", [])):
            target = fixture / "MacOS" / name
            shutil.copy2(app / "Contents/MacOS" / name, target)
            result = subprocess.run([str(target), *arguments], capture_output=True, text=True)
            assert result.returncode != 0
            reply = json.loads(result.stdout)
            code = reply.get("error", {}).get("code", reply.get("code"))
            assert code == "app-channel-mismatch", (channel, name, code)
    print(f"{channel}: packaged executable identity and mismatched-app refusal PASS; no manager or VM started")
