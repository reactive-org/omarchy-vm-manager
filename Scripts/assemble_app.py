#!/usr/bin/env python3
"""Assemble a debug or authorized signed prerelease app with exact kit content."""
import argparse
import json
import os
import plistlib
from pathlib import Path
from ticket_network import run_ticket_checked
import shutil
import subprocess

from kit_artifacts import ROOT, digest
from build_patched_kit import inventory
from keychain_profile import stage_keychain_profile, verify_keychain_profile
from release_metadata import release_info


def run(*args, **kwargs):
    subprocess.run([str(x) for x in args], check=True, **kwargs)


def assemble():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dev", action="store_true", help="Build the isolated Development channel")
    parser.add_argument("--preview", action="store_true", help="Compatibility alias for --dev")
    parser.add_argument("--layout-preview", action="store_true", help="Build an isolated no-VM lifecycle layout gallery")
    parser.add_argument("--output-directory", type=Path, default=ROOT / "dist", help="Separate packaging output from the normal local app")
    parser.add_argument("--preserve-runtime-signatures", action="store_true", help="Reuse the exact upstream-pipeline runtime signatures across app builds")
    parser.add_argument("--runtime-lock", type=Path, default=ROOT / "Config/TryOmarchyRuntime.lock.json")
    parser.add_argument("--runtime-directory", type=Path)
    parser.add_argument("--signed-prerelease", action="store_true")
    parser.add_argument("--keychain-profile", type=Path, help="Explicit Developer ID profile for biometric guest password storage")
    args = parser.parse_args()
    development = args.dev or args.preview
    assert not (development and args.layout_preview), "Dev and layout preview are separate builds"
    assert args.keychain_profile is None or args.signed_prerelease, "a Keychain profile requires authorized Developer ID signing"
    assert not args.signed_prerelease or args.keychain_profile is not None, "signed prereleases require the pinned Touch ID profile"
    channel = "development" if development else "stable"
    requested_channel = os.environ.get("RELEASE_CHANNEL")
    assert requested_channel is None or requested_channel == channel, "release channel and compiled app differ"
    info = release_info(plistlib.loads((ROOT / "App/Info.plist").read_bytes()), os.environ.get("RELEASE_TAG", ""),
                        requested_channel, os.environ.get("RELEASE_VERSION"), os.environ.get("RELEASE_BUILD"))
    assert not args.signed_prerelease or info.get("OmarchyReleaseTag"), "signed prereleases require RELEASE_TAG"
    lock_path = args.runtime_lock
    lock = json.loads(lock_path.read_bytes())
    assert lock["kitVersion"] == "development" and lock["focusAwareClipboard"] is True
    assert digest(lock_path) in (ROOT / "Sources/OmarchyVMManagerCore/RuntimePin.swift").read_text()
    source = args.runtime_directory or ROOT / ("VendorArtifacts/patched-" + lock["patchCommit"][:12])
    assert digest(source / "TryOmarchyKit.zip") == lock["kitSHA256"], "private archive mismatch"
    assert inventory(source / "TryOmarchyKit.bundle") == lock["files"], "private kit content mismatch"
    configuration = "release" if args.signed_prerelease else "debug"
    identity = os.environ["MACOS_SIGNING_IDENTITY"] if args.signed_prerelease else "-"
    if args.signed_prerelease:
        assert args.preserve_runtime_signatures and lock["signingTeamID"] == os.environ["APPLE_TEAM_ID"]
        assert identity.startswith("Developer ID Application:") and identity.endswith("(" + lock["signingTeamID"] + ")")
    build_arguments = ["--scratch-path", str(ROOT / ".build/dev"), "-Xswiftc", "-DDEVELOPMENT_CHANNEL"] if development else []
    binaries = Path(subprocess.check_output(["swift", "build", "--disable-sandbox", "-c", configuration, *build_arguments, "--show-bin-path"], cwd=ROOT, text=True).strip())
    channel = "development" if development else "stable"
    name = "Omarchy VM Manager Layout Preview" if args.layout_preview else ("Omarchy VM Manager Dev" if development else "Omarchy VM Manager")
    cli_name = "omarchy-vm-dev" if development else "omarchy-vm"
    app = args.output_directory / (name + ".app")
    stage = args.output_directory / ("." + name + ".staging.app")
    assert not stage.exists(), "existing assembly stage; inspect before retrying"
    for subdirectory in ("MacOS", "Resources", "Helpers"):
        (stage / "Contents" / subdirectory).mkdir(parents=True, exist_ok=True)
    try:
        for executable in ("OmarchyVMManager", "OmarchyVMStorageHelper", "omarchy-vm"):
            destination_name = cli_name if executable == "omarchy-vm" else executable
            shutil.copy2(binaries / executable, stage / "Contents/MacOS" / destination_name)
        resources = binaries / "OmarchyVMManager_OmarchyVMManagerCore.bundle"
        assert resources.is_dir() and not resources.is_symlink(), "missing core resource bundle"
        assert all(not entry.is_symlink() for entry in resources.rglob("*")), "linked core resource entry"
        shutil.copytree(resources, stage / "Contents/Resources" / resources.name)
        if args.layout_preview:
            info["CFBundleIdentifier"] = "dev.omarchy.vm-manager.layout-preview"
            info["CFBundleName"] = info["CFBundleDisplayName"] = "Omarchy VM Manager Layout Preview"
            info["OmarchyLayoutPreview"] = True
        elif development:
            info["CFBundleIdentifier"] = "dev.omarchy.vm-manager.dev"
            info["CFBundleName"] = info["CFBundleDisplayName"] = name
        info["OmarchyAppChannel"] = channel
        (stage / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        entitlements_path = ROOT / "App/OmarchyVMManager.entitlements"
        if args.keychain_profile:
            entitlements = stage_keychain_profile(args.keychain_profile, stage, lock["signingTeamID"],
                                                 info["CFBundleIdentifier"], plistlib.loads(entitlements_path.read_bytes()))
            # Signing input stays outside the final app's sealed resources.
            entitlements_path = stage.with_suffix(".keychain-entitlements.plist")
            entitlements_path.write_bytes(plistlib.dumps(entitlements))
        for stem in ("OmarchyVMManager", "OmarchyGuest"):
            for extension in ("icns", "png"):
                source_stem = "OmarchyVMManagerDev" if development and stem == "OmarchyVMManager" else stem
                shutil.copy2(ROOT / "App/Assets" / (source_stem + "." + extension), stage / "Contents/Resources" / (stem + "." + extension))
        shutil.copy2(lock_path, stage / "Contents/Resources/TryOmarchyRuntime.lock.json")
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
        if args.signed_prerelease:
            run_ticket_checked("python3", signature, "verify", "--team", lock["signingTeamID"], "--require-notarization", kit)
        else:
            run("python3", signature, "verify", "--signature-only", kit)
        assert inventory(kit) == lock["files"], "embedding changed pinned kit bytes"
        signing = ["codesign", "--force", "--sign", identity]
        if args.signed_prerelease:
            signing += ["--options", "runtime", "--timestamp"]
        run(*signing, "--identifier", info["CFBundleIdentifier"] + ".storage", stage / "Contents/MacOS/OmarchyVMStorageHelper")
        run(*signing, "--identifier", info["CFBundleIdentifier"] + ".cli", stage / "Contents/MacOS" / cli_name)
        run(*signing, "--identifier", info["CFBundleIdentifier"],
            "--entitlements", entitlements_path, stage)
        run("codesign", "--verify", "--deep", "--strict", stage)
        verify_keychain_profile(stage, lock.get("signingTeamID", ""))
        for executable, argument in (("OmarchyVMManager", "--verify-bundle-json"), (cli_name, "--version"), ("OmarchyVMStorageHelper", "--channel-json")):
            diagnostic = json.loads(subprocess.check_output([str(stage / "Contents/MacOS" / executable), argument], text=True))
            assert diagnostic["appChannel"] == channel, "mixed app-channel executables refused"
        if app.exists():
            assert app.is_dir() and not app.is_symlink()
            shutil.rmtree(app)
        stage.rename(app)
    except BaseException:
        if stage.exists():
            shutil.rmtree(stage)
        raise
    finally:
        if args.keychain_profile:
            stage.with_suffix(".keychain-entitlements.plist").unlink(missing_ok=True)
    print(f"Built private debug app: {app}")


if __name__ == "__main__":
    assemble()
