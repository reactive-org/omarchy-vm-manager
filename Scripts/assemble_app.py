#!/usr/bin/env python3
"""Assemble only a private debug app with exact kit content and ad-hoc signing."""
import argparse
import json
import plistlib
from pathlib import Path
import shutil
import subprocess

from kit_artifacts import ROOT, digest
from build_patched_kit import inventory


def run(*args, **kwargs):
    subprocess.run([str(x) for x in args], check=True, **kwargs)


def assemble():
    parser = argparse.ArgumentParser()
    parser.add_argument("--preview", action="store_true", help="Build a sibling app without replacing the running manager")
    parser.add_argument("--layout-preview", action="store_true", help="Build an isolated no-VM lifecycle layout gallery")
    parser.add_argument("--output-directory", type=Path, default=ROOT / "dist", help="Separate packaging output from the normal local app")
    parser.add_argument("--preserve-runtime-signatures", action="store_true", help="Reuse the exact upstream-pipeline ad-hoc signatures across macOS builder versions")
    args = parser.parse_args()
    assert not (args.preview and args.layout_preview)
    lock_path = ROOT / "Config/TryOmarchyRuntime.lock.json"
    lock = json.loads(lock_path.read_bytes())
    assert lock["kitVersion"] == "development" and lock["focusAwareClipboard"] is True
    assert digest(lock_path) in (ROOT / "Sources/OmarchyVMManagerCore/RuntimePin.swift").read_text()
    source = ROOT / ("VendorArtifacts/patched-" + lock["patchCommit"][:12])
    assert digest(source / "TryOmarchyKit.zip") == lock["kitSHA256"], "private archive mismatch"
    assert inventory(source / "TryOmarchyKit.bundle") == lock["files"], "private kit content mismatch"
    binaries = Path(subprocess.check_output(["swift", "build", "--disable-sandbox", "--show-bin-path"], cwd=ROOT, text=True).strip())
    name = "Omarchy VM Manager Layout Preview" if args.layout_preview else ("Omarchy VM Manager Preview" if args.preview else "Omarchy VM Manager")
    app = args.output_directory / (name + ".app")
    stage = args.output_directory / ("." + name + ".staging.app")
    assert not stage.exists(), "existing assembly stage; inspect before retrying"
    for name in ("MacOS", "Resources", "Helpers"):
        (stage / "Contents" / name).mkdir(parents=True, exist_ok=True)
    try:
        for executable in ("OmarchyVMManager", "OmarchyVMStorageHelper", "omarchy-vm"):
            shutil.copy2(binaries / executable, stage / "Contents/MacOS" / executable)
        resources = binaries / "OmarchyVMManager_OmarchyVMManagerCore.bundle"
        assert resources.is_dir() and not resources.is_symlink(), "missing core resource bundle"
        assert all(not entry.is_symlink() for entry in resources.rglob("*")), "linked core resource entry"
        shutil.copytree(resources, stage / "Contents/Resources" / resources.name)
        info = plistlib.loads((ROOT / "App/Info.plist").read_bytes())
        if args.layout_preview:
            info["CFBundleIdentifier"] = "dev.omarchy.vm-manager.layout-preview"
            info["CFBundleName"] = info["CFBundleDisplayName"] = "Omarchy VM Manager Layout Preview"
            info["OmarchyLayoutPreview"] = True
        (stage / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        for stem in ("OmarchyVMManager", "OmarchyGuest"):
            for extension in ("icns", "png"):
                shutil.copy2(ROOT / "App/Assets" / (stem + "." + extension), stage / "Contents/Resources" / (stem + "." + extension))
        shutil.copy2(lock_path, stage / "Contents/Resources" / lock_path.name)
        for name in ("LICENSE", "THIRD_PARTY_NOTICES.md"):
            shutil.copy2(ROOT / name, stage / "Contents/Resources" / name)
        shutil.copy2(ROOT / "Vendor/try-omarchy/THIRD_PARTY_NOTICES.md",
                     stage / "Contents/Resources/TryOmarchy-THIRD_PARTY_NOTICES.md")
        kit = stage / "Contents/Helpers/TryOmarchyKit.bundle"
        run("ditto", source / "TryOmarchyKit.bundle", kit)
        assert inventory(kit) == lock["files"], "copying changed pinned kit bytes"
        signature = ROOT / "Vendor/try-omarchy/scripts/kit_signature.py"
        if not args.preserve_runtime_signatures:
            run("python3", signature, "sign", "--identity", "-", kit)
        run("python3", signature, "verify", "--signature-only", kit)
        assert inventory(kit) == lock["files"], "embedding changed pinned kit bytes"
        run("codesign", "--force", "--sign", "-", "--identifier", "dev.omarchy.vm-manager.storage", stage / "Contents/MacOS/OmarchyVMStorageHelper")
        run("codesign", "--force", "--sign", "-", "--identifier", "dev.omarchy.vm-manager.cli", stage / "Contents/MacOS/omarchy-vm")
        run("codesign", "--force", "--sign", "-", "--identifier", info["CFBundleIdentifier"],
            "--entitlements", ROOT / "App/OmarchyVMManager.entitlements", stage)
        run("codesign", "--verify", "--deep", "--strict", stage)
        run(stage / "Contents/MacOS/OmarchyVMManager", "--verify-bundle-json")
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
