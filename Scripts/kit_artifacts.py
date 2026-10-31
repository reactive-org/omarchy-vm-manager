#!/usr/bin/env python3
"""Pinned reference acquisition and content verification; never fetches an image."""
import hashlib
from datetime import datetime
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import urllib.request
import zipfile

if sys.flags.optimize:
    raise RuntimeError("Optimized Python execution is refused; validation assertions are required")

ROOT = Path(__file__).resolve().parent.parent
BASE = "13d63df8da2947f833c04025ff5ade187d39ba81"


def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def manifest(path, version):
    value = json.loads(path.read_bytes())
    assert type(value["format"]) is int and value["format"] == 1 and value["version"] == version
    assert type(value["runProtocolVersion"]) is int and value["runProtocolVersion"] == 1
    assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", value["buildDate"])
    datetime.strptime(value["buildDate"], "%Y-%m-%dT%H:%M:%SZ")
    return value


def verify_reference(folder):
    lock = json.loads((ROOT / "Config/TryOmarchyUpstream.lock.json").read_bytes())
    archive = folder / "TryOmarchyKit.zip"
    assert not archive.is_symlink() and archive.is_file()
    assert digest(archive) == lock["kitSHA256"], "committed kit digest mismatch"
    sidecar = (folder / "TryOmarchyKit.zip.sha256").read_text().split()
    assert sidecar == [lock["kitSHA256"], "TryOmarchyKit.zip"], "sidecar mismatch"
    published = manifest(folder / "TryOmarchyKit.json", lock["tag"])
    with zipfile.ZipFile(archive) as z:
        for item in z.infolist():
            p = Path(item.filename)
            assert not p.is_absolute() and ".." not in p.parts and p.parts[0] == "TryOmarchyKit.bundle"
        assert json.loads(z.read("TryOmarchyKit.bundle/Contents/Resources/kit.json")) == published
    bundle = folder / "TryOmarchyKit.bundle"
    if bundle.exists():
        assert not bundle.is_symlink()
        assert manifest(bundle / "Contents/Resources/kit.json", lock["tag"]) == published
        with zipfile.ZipFile(archive) as z:
            expected = {item.filename.removeprefix("TryOmarchyKit.bundle/"): hashlib.sha256(z.read(item)).hexdigest()
                        for item in z.infolist() if not item.is_dir() and not Path(item.filename).name.startswith("._")}
        actual = {}
        for path in bundle.rglob("*"):
            assert not path.is_symlink(), "unsafe extracted reference entry"
            if path.is_file():
                actual[path.relative_to(bundle).as_posix()] = digest(path)
            else:
                assert path.is_dir(), "special reference entry"
        assert actual == expected, "extracted reference differs from the pinned archive"
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)], check=True)
    return lock


def fetch():
    destination = ROOT / "VendorArtifacts/stock-v1.3.0"
    if destination.exists():
        verify_reference(destination)
        assert (destination / "TryOmarchyKit.bundle").is_dir(), "incomplete artifact; inspect it manually"
        print("Verified existing stock v1.3.0 reference kit")
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="stock-", dir=destination.parent) as temp:
        staging = Path(temp)
        for name in ["TryOmarchyKit.zip", "TryOmarchyKit.zip.sha256", "TryOmarchyKit.json"]:
            url = "https://github.com/omacom/try-omarchy/releases/download/v1.3.0/" + name
            maximum = 20_000_000 if name.endswith(".zip") else 65_536
            with urllib.request.urlopen(url, timeout=60) as source, open(staging / name, "wb") as output:
                received = 0
                while chunk := source.read(1024 * 1024):
                    received += len(chunk)
                    if received > maximum:
                        raise ValueError(f"{name} exceeds the allowed small-asset size")
                    output.write(chunk)
        verify_reference(staging)
        subprocess.run(["ditto", "-x", "-k", str(staging / "TryOmarchyKit.zip"), str(staging)], check=True)
        verify_reference(staging)
        staging.rename(destination)
    print("Verified and unpacked stock v1.3.0 reference kit; no factory image downloaded")


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["fetch"]:
            fetch()
        else:
            raise ValueError("usage: kit_artifacts.py fetch")
    except Exception as error:
        sys.exit(f"kit-artifacts: {error}")
