#!/usr/bin/env python3
"""Package an already verified ad-hoc debug app for a versioned prerelease."""
import json
import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

from kit_artifacts import ROOT, digest
from release_metadata import validate_tag, verify_release_info, channel_spec, release_info


def package():
    parser = argparse.ArgumentParser()
    parser.add_argument("--signed", action="store_true")
    parser.add_argument("--runtime-lock", type=Path, default=ROOT / "Config/TryOmarchyRuntime.lock.json")
    args = parser.parse_args()
    channel = os.environ.get("RELEASE_CHANNEL")
    _, app_name, _, archive_name = channel_spec(channel or "stable")
    info = release_info(plistlib.loads((ROOT / "App/Info.plist").read_bytes()), os.environ.get("RELEASE_TAG", ""),
                        channel, os.environ.get("RELEASE_VERSION"), os.environ.get("RELEASE_BUILD"))
    tag = validate_tag(os.environ.get("RELEASE_TAG", ""), info["CFBundleShortVersionString"], channel)
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    app = ROOT / "dist/prerelease-staging" / (app_name + ".app")
    verify_release_info(plistlib.loads((app / "Contents/Info.plist").read_bytes()), tag, info["CFBundleShortVersionString"], channel)
    folder = ROOT / "dist/prerelease"
    folder.mkdir(parents=True, exist_ok=True)
    flavor = "notarized" if args.signed else "development"
    archive = folder / f"{archive_name}-{tag}-macOS-arm64-{flavor}.zip"
    if archive.exists():
        raise ValueError("Existing prerelease archive was preserved; inspect it before retrying")
    subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive)], check=True)
    with tempfile.TemporaryDirectory(prefix="prerelease-check-", dir=ROOT / ".build") as temp:
        subprocess.run(["ditto", "-x", "-k", str(archive), temp], check=True)
        extracted = Path(temp) / app.name
        verify_release_info(plistlib.loads((extracted / "Contents/Info.plist").read_bytes()), tag, info["CFBundleShortVersionString"], channel)
        subprocess.run([str(ROOT / "Scripts/verify-app.sh"), "--bundle-only", str(extracted), str(args.runtime_lock)], check=True)
        if args.signed:
            subprocess.run(["python3", str(ROOT / "Scripts/verify_signed_app.py"), str(extracted)], check=True)
    (folder / (archive.name + ".sha256")).write_text(digest(archive) + "  " + archive.name + "\n")
    lock = json.loads(args.runtime_lock.read_bytes())
    distribution = (
        "This experimental development fork is Developer ID signed, notarized by Apple, and carries a stapled ticket. "
        "It uses the explicit signed-prerelease build mode; it is not an official upstream runtime release.\n\n"
        if args.signed else
        "This experimental development fork uses ad-hoc signing; it is not Developer ID signed or notarized. "
        "macOS Gatekeeper may block opening a downloaded copy. Trusted distribution remains a separate release milestone.\n\n")
    (folder / "release-notes.md").write_text(
        f"{app_name} {tag}, source `{commit}`, macOS 15+ on Apple Silicon.\n\n"
        "Download the app ZIP and matching SHA-256 checksum below. The app includes the CLI and storage helper. "
        + distribution +
        ("Guest setup passwords use a provisioned private Keychain item with Touch ID and Mac login password fallback. "
         "Use Guest Defaults to explicitly upgrade an older saved password before creating a new unattended guest. "
         "Native biometric prompts and real guest behavior still require user validation.\n\n" if args.signed else "") +
        ("Guest sudo Touch ID is now off by default and opt-in per VM through Allow Touch ID inside this VM. "
         "Stop the guest before changing it, then pair explicitly inside the guest through Setup → Security → Touch ID for sudo. "
         "Host bridge configuration does not prove guest pairing. Denial or contention falls back to the Linux guest password. "
         "Manager UUIDs isolate pairing keys; one manager guest prompt is allowed at a time. "
         "Native success, focus, cancellation and multi-VM behavior still require validation. "
         "Guest 1Password unlock remains disabled in this sudo milestone.\n\n"
         if lock.get("managedAuthenticationVersion") == 1 else "") +
        f"Embedded runtime source: `{lock['patchCommit']}`; runtime archive SHA-256: `{lock['kitSHA256']}`. " +
        ("The original development runtime is unchanged; this build uses separate signed-runtime provenance. "
         "Custom factories bound to the ad-hoc runtime remain preserved but need a bundle compatible with this signed runtime. "
         if args.signed else "The exact existing runtime pin is preserved. ") +
        "The upstream runtime is provided by Try Omarchy, with the "
        "manager's reviewed development patches; licenses and notices are included in the app.\n\n"
        "CI verifies signatures, exact payload provenance, bundle layout and macOS compatibility without starting a guest. "
        "Host hypervisor readiness and real guest behavior are not established by CI. No factory image is included; "
        "the official image downloads only when you explicitly launch a new guest.\n")
    print(archive)


if __name__ == "__main__":
    package()
