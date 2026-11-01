#!/usr/bin/env python3
"""Acquire the exact existing development kit without rebuilding or re-pinning it."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import stat
import subprocess
import sys
import tempfile
import urllib.request
import zipfile

from kit_artifacts import ROOT, digest, manifest
from build_patched_kit import inventory

MAX_ARCHIVE_BYTES = 50_000_000
MAX_EXPANDED_BYTES = 256_000_000


def archive_manifest(archive, lock):
    assert archive.is_file() and not archive.is_symlink()
    assert archive.stat().st_size <= MAX_ARCHIVE_BYTES
    assert digest(archive) == lock["kitSHA256"], "runtime archive digest mismatch"
    files, names = {}, set()
    with zipfile.ZipFile(archive) as z:
        assert sum(item.file_size for item in z.infolist()) <= MAX_EXPANDED_BYTES
        for item in z.infolist():
            path = PurePosixPath(item.filename)
            assert not path.is_absolute() and ".." not in path.parts
            assert path.parts and path.parts[0] == "TryOmarchyKit.bundle"
            assert path.as_posix() == item.filename.rstrip("/") and item.filename not in names
            names.add(item.filename)
            mode = stat.S_IFMT(item.external_attr >> 16)
            assert mode in (0, stat.S_IFREG, stat.S_IFDIR), "special runtime archive entry"
            if not item.is_dir() and not path.name.startswith("._"):
                files[path.relative_to("TryOmarchyKit.bundle").as_posix()] = hashlib.sha256(z.read(item)).hexdigest()
        assert files == lock["files"], "runtime archive inventory mismatch"
        value = json.loads(z.read("TryOmarchyKit.bundle/Contents/Resources/kit.json"))
    assert value == {"format": 1, "version": lock["kitVersion"],
                     "runProtocolVersion": lock["runProtocolVersion"], "buildDate": lock["buildDate"]}
    return value


def verify(folder, lock):
    value = archive_manifest(folder / "TryOmarchyKit.zip", lock)
    bundle = folder / "TryOmarchyKit.bundle"
    assert bundle.is_dir() and not bundle.is_symlink()
    assert inventory(bundle) == lock["files"], "extracted runtime inventory mismatch"
    assert manifest(bundle / "Contents/Resources/kit.json", "development") == value
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)], check=True)


def fetch():
    lock_path = ROOT / "Config/TryOmarchyRuntime.lock.json"
    lock = json.loads(lock_path.read_bytes())
    assert digest(lock_path) in (ROOT / "Sources/OmarchyVMManagerCore/RuntimePin.swift").read_text()
    patch = json.loads((ROOT / "Config/TryOmarchyClipboardPatch.json").read_bytes())
    assert lock["patchCommit"] == patch["commit"] and lock["patchSHA256"] == patch["patchSHA256"]
    assert digest(ROOT / "Patches/0001-focus-aware-clipboard.patch") == lock["patchSHA256"]
    assert lock["kitVersion"] == "development" and lock["runProtocolVersion"] == 1
    destination = ROOT / ("VendorArtifacts/patched-" + lock["patchCommit"][:12])
    if destination.exists() or destination.is_symlink():
        verify(destination, lock)
        print("Verified existing locked runtime kit")
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    tag = "runtime-kit-" + lock["kitSHA256"]
    url = "https://github.com/reactive-org/omarchy-vm-manager/releases/download/" + tag + "/TryOmarchyKit.zip"
    with tempfile.TemporaryDirectory(prefix="runtime-", dir=destination.parent) as temp:
        staging = Path(temp)
        archive = staging / "TryOmarchyKit.zip"
        with urllib.request.urlopen(url, timeout=60) as source, archive.open("wb") as output:
            received = 0
            while chunk := source.read(1024 * 1024):
                received += len(chunk)
                if received > MAX_ARCHIVE_BYTES:
                    raise ValueError("Runtime archive exceeds its size limit")
                output.write(chunk)
        value = archive_manifest(archive, lock)
        subprocess.run(["ditto", "-x", "-k", str(archive), str(staging)], check=True)
        (staging / "TryOmarchyKit.json").write_text(json.dumps(value, indent=2) + "\n")
        (staging / "TryOmarchyKit.zip.sha256").write_text(lock["kitSHA256"] + "  TryOmarchyKit.zip\n")
        verify(staging, lock)
        staging.rename(destination)
    print("Fetched and verified the exact locked runtime; no factory image or guest started")


if __name__ == "__main__":
    try:
        fetch()
    except Exception as error:
        sys.exit(f"runtime-kit: {error}")
