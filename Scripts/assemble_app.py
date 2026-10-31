#!/usr/bin/env python3
"""Assemble only a private debug app with exact kit content and ad-hoc signing."""
import json
from pathlib import Path
import shutil
import subprocess

from kit_artifacts import ROOT, digest
from build_patched_kit import inventory


def run(*args, **kwargs):
    subprocess.run([str(x) for x in args], check=True, **kwargs)


def assemble():
    lock_path = ROOT / "Config/TryOmarchyRuntime.lock.json"
    lock = json.loads(lock_path.read_bytes())
    assert lock["kitVersion"] == "development" and lock["focusAwareClipboard"] is True
    assert digest(lock_path) in (ROOT / "Sources/OmarchyVMManagerCore/RuntimePin.swift").read_text()
    source = ROOT / ("VendorArtifacts/patched-" + lock["patchCommit"][:12])
    assert digest(source / "TryOmarchyKit.zip") == lock["kitSHA256"], "private archive mismatch"
    assert inventory(source / "TryOmarchyKit.bundle") == lock["files"], "private kit content mismatch"
    binaries = Path(subprocess.check_output(["swift", "build", "--disable-sandbox", "--show-bin-path"], cwd=ROOT, text=True).strip())
    app = ROOT / "dist/Omarchy VM Manager.app"
    stage = ROOT / "dist/.Omarchy VM Manager.staging.app"
    assert not stage.exists(), "existing assembly stage; inspect before retrying"
    for name in ("MacOS", "Resources", "Helpers"):
        (stage / "Contents" / name).mkdir(parents=True, exist_ok=True)
    try:
        for executable in ("OmarchyVMManager", "OmarchyVMStorageHelper"):
            shutil.copy2(binaries / executable, stage / "Contents/MacOS" / executable)
        shutil.copy2(ROOT / "App/Info.plist", stage / "Contents/Info.plist")
        shutil.copy2(lock_path, stage / "Contents/Resources" / lock_path.name)
        for name in ("LICENSE", "THIRD_PARTY_NOTICES.md"):
            shutil.copy2(ROOT / name, stage / "Contents/Resources" / name)
        shutil.copy2(ROOT / "Vendor/try-omarchy/THIRD_PARTY_NOTICES.md",
                     stage / "Contents/Resources/TryOmarchy-THIRD_PARTY_NOTICES.md")
        kit = stage / "Contents/Helpers/TryOmarchyKit.bundle"
        run("ditto", source / "TryOmarchyKit.bundle", kit)
        signature = ROOT / "Vendor/try-omarchy/scripts/kit_signature.py"
        run("python3", signature, "sign", "--identity", "-", kit)
        run("python3", signature, "verify", "--signature-only", kit)
        assert inventory(kit) == lock["files"], "embedding changed pinned kit bytes"
        run("codesign", "--force", "--sign", "-", "--identifier", "dev.omarchy.vm-manager.storage", stage / "Contents/MacOS/OmarchyVMStorageHelper")
        run("codesign", "--force", "--sign", "-", "--identifier", "dev.omarchy.vm-manager",
            "--entitlements", ROOT / "App/OmarchyVMManager.entitlements", stage)
        run("codesign", "--verify", "--deep", "--strict", stage)
        run(stage / "Contents/MacOS/OmarchyVMManager", "--diagnostics-json")
        if app.exists():
            assert app.is_dir() and not app.is_symlink()
            shutil.rmtree(app)
        stage.rename(app)
    except BaseException:
        if stage.exists():
            shutil.rmtree(stage)
        raise
    print(f"Built private debug app: {app}")


if __name__ == "__main__":
    assemble()
