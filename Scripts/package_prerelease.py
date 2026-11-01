#!/usr/bin/env python3
"""Package an already verified ad-hoc debug app for a versioned prerelease."""
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile

from kit_artifacts import ROOT, digest


def validate_tag(tag, version):
    if not re.fullmatch(re.escape("v" + version) + r"-dev\.[1-9][0-9]*", tag):
        raise ValueError(f"Use v{version}-dev.N (N >= 1); only development prereleases are supported")
    return tag


def package():
    info = plistlib.loads((ROOT / "App/Info.plist").read_bytes())
    tag = validate_tag(os.environ.get("RELEASE_TAG", ""), info["CFBundleShortVersionString"])
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    app = ROOT / "dist/prerelease-staging/Omarchy VM Manager.app"
    folder = ROOT / "dist/prerelease"
    folder.mkdir(parents=True, exist_ok=True)
    archive = folder / f"Omarchy-VM-Manager-{tag}-macOS-arm64-development.zip"
    if archive.exists():
        raise ValueError("Existing prerelease archive was preserved; inspect it before retrying")
    subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive)], check=True)
    with tempfile.TemporaryDirectory(prefix="prerelease-check-", dir=ROOT / ".build") as temp:
        subprocess.run(["ditto", "-x", "-k", str(archive), temp], check=True)
        subprocess.run([str(ROOT / "Scripts/verify-app.sh"), "--bundle-only", str(Path(temp) / app.name)], check=True)
    (folder / (archive.name + ".sha256")).write_text(digest(archive) + "  " + archive.name + "\n")
    lock = json.loads((ROOT / "Config/TryOmarchyRuntime.lock.json").read_bytes())
    (folder / "release-notes.md").write_text(
        f"Development build {tag}, source `{commit}`, macOS 15+ on Apple Silicon.\n\n"
        "Download the app ZIP and matching SHA-256 checksum below. The app includes the CLI and storage helper. "
        "This experimental development fork uses ad-hoc signing; it is not Developer ID signed or notarized. "
        "macOS Gatekeeper may block opening a downloaded copy. Trusted distribution remains a separate release milestone.\n\n"
        f"Embedded runtime source: `{lock['patchCommit']}`; runtime archive SHA-256: `{lock['kitSHA256']}`. "
        "The exact existing runtime pin is preserved. The upstream runtime is provided by Try Omarchy, with the "
        "manager's reviewed development patches; licenses and notices are included in the app.\n\n"
        "CI verifies signatures, exact payload provenance, bundle layout and macOS compatibility without starting a guest. "
        "Host hypervisor readiness and real guest behavior are not established by CI. No factory image is included; "
        "the official image downloads only when you explicitly launch a new guest.\n")
    print(archive)


if __name__ == "__main__":
    package()
