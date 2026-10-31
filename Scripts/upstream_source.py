#!/usr/bin/env python3
"""Reconstruct the exact reviewed patch commit in a space-free build checkout."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

if sys.flags.optimize:
    raise RuntimeError("Optimized Python execution is refused; source validation assertions are required")

ROOT = Path(__file__).resolve().parent.parent
BASE = "13d63df8da2947f833c04025ff5ade187d39ba81"


def git(folder, *args, **kwargs):
    return subprocess.check_output(["git", "-C", str(folder), *args], text=True, **kwargs).strip()


def prepare():
    source = ROOT / "Vendor/try-omarchy"
    assert git(source, "rev-parse", "HEAD") == BASE, "vendor must remain at stock v1.3.0"
    assert git(source, "describe", "--tags", "--exact-match") == "v1.3.0"
    assert not git(source, "status", "--porcelain"), "dirty stock source"
    metadata = json.loads((ROOT / "Config/TryOmarchyClipboardPatch.json").read_bytes())
    patch = ROOT / "Patches/0001-focus-aware-clipboard.patch"
    assert hashlib.sha256(patch.read_bytes()).hexdigest() == metadata["patchSHA256"]
    build_root = Path("/private/tmp") if sys.platform == "darwin" else Path(tempfile.gettempdir())
    destination = build_root / ("omarchy-vm-manager-source-" + metadata["commit"][:12])
    if destination.exists():
        assert not destination.is_symlink() and destination.stat().st_uid == os.getuid()
        assert git(destination, "rev-parse", "HEAD") == metadata["commit"], "unexpected build source"
        assert not git(destination, "status", "--porcelain"), "dirty build source"
        return destination
    subprocess.run(["git", "clone", "--no-hardlinks", "--no-checkout", str(source), str(destination)],
                   check=True, stdout=sys.stderr)
    subprocess.run(["git", "-C", str(destination), "checkout", "--detach", BASE], check=True, stdout=sys.stderr)
    subprocess.run(["git", "-C", str(destination), "apply", "--index", str(patch)], check=True)
    env = dict(os.environ)
    for role in ("AUTHOR", "COMMITTER"):
        key = role.lower()
        env[f"GIT_{role}_NAME"] = metadata[key + "Name"]
        env[f"GIT_{role}_EMAIL"] = metadata[key + "Email"]
        env[f"GIT_{role}_DATE"] = metadata[key + "Date"]
    subprocess.run(["git", "-C", str(destination), "-c", "commit.gpgsign=false", "commit", "-m", metadata["subject"]],
                   check=True, env=env, stdout=sys.stderr)
    assert git(destination, "rev-parse", "HEAD") == metadata["commit"], "reconstructed patch commit mismatch"
    assert git(destination, "rev-parse", "HEAD^") == BASE
    return destination


if __name__ == "__main__":
    try:
        print(prepare())
    except Exception as error:
        sys.exit(f"upstream-source: {error}")
