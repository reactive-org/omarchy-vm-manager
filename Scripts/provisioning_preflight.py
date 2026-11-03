#!/usr/bin/env python3
"""Offline milestone-6 evidence, never execution admission or a guest/tool probe.

Reads only explicit build inputs and repository metadata. Does not run candidate
binaries, Homebrew, SSH, Ansible, signing tools, or inspect user VM/factory storage.
The report is private developer evidence, not a product Python dependency.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess

import provisioning_package as package


def fingerprint(path, maximum=512 * 1024 * 1024, executable=False):
    """Bounded regular-file observation; not a loaded-code admission proof."""
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        package.require(stat.S_ISREG(before.st_mode) and 0 < before.st_size <= maximum)
        package.require(not executable or before.st_mode & 0o111)
        digest, size = hashlib.sha256(), 0
        while block := os.read(fd, 1024 * 1024):
            size += len(block)
            package.require(size <= maximum)
            digest.update(block)
        after = os.fstat(fd)
        fields = lambda value: (value.st_dev, value.st_ino, value.st_size,
                                value.st_mtime_ns, value.st_ctime_ns, value.st_mode)
        package.require(fields(before) == fields(after) and size == before.st_size)
        package.require(os.stat(path, follow_symlinks=False) == after)
        return {"sha256": digest.hexdigest(), "bytes": size}
    finally:
        os.close(fd)


def repository(root):
    def git(*args):
        result = subprocess.run(["/usr/bin/git", "--no-optional-locks", "-c", "core.fsmonitor=false",
                                 "-c", "core.untrackedCache=false", "-C", str(root), *args],
                                capture_output=True, timeout=10, check=True)
        return result.stdout
    head = git("rev-parse", "--verify", "HEAD").decode("ascii").strip()
    package.require(len(head) in (40, 64) and all(c in "0123456789abcdef" for c in head))
    return {"head": head, "dirty": bool(git("status", "--porcelain=v1", "-z", "--untracked-files=all")),
            "binarySourceBinding": "NOT_PROVEN"}


def collect(root, binaries, launcher_binaries, app=None):
    root, binaries, launcher_binaries = Path(root), Path(binaries), Path(launcher_binaries)
    checks, evidence = [], {}

    def check(name, action):
        try:
            value = action()
            checks.append({"id": name, "status": "PASS"})
            if value is not None:
                evidence[name] = value
        except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
            # Fixed text only: malformed inputs and tools cannot inject paths,
            # identifiers, secrets or captured output into the report.
            checks.append({"id": name, "status": "BLOCKED",
                           "reason": "Missing, changed, unsafe or incompatible local input."})

    def source():
        raw, lock = package.verify_source(root)
        package.require((root / "Sources/OmarchyVMManagerCore/ProvisioningPackagePin.swift").read_text()
                        == package.pin_source(raw, lock))
        return {"lockSHA256": package.sha(raw), "engineSHA256": lock["engineSHA256"],
                "sourceSnapshotSHA256": lock["sourceSnapshotSHA256"], "baseRevision": lock["revision"],
                "patches": lock.get("integrationPatches", [])}

    check("repository", lambda: repository(root))
    check("pinnedSource", source)
    for label, name in (("runtimeLock", "TryOmarchyRuntime.lock.json"),
                        ("reviewedFactoryCatalogue", "../Sources/OmarchyVMManagerCore/Resources/ReviewedFactories.json")):
        check(label, lambda name=name: fingerprint(root / "Config" / name, maximum=4 * 1024 * 1024))
    for name in ("OmarchyVMManager", "omarchy-vm", "OmarchyVMStorageHelper", "OmarchyVMProvisioningHelper"):
        check(name, lambda name=name: fingerprint(binaries / name, executable=True))
    check("dev-vm-process-host", lambda: fingerprint(launcher_binaries / "dev-vm-process-host", executable=True))

    def resources():
        raw, lock = package.read_lock(root)
        actual = package.files(package.resource_directory(binaries / package.BUNDLE))
        package.require(actual == package.resource_files(lock))
        return {"files": len(actual), "lockSHA256": package.sha(raw)}
    check("builtProvisioningResources", resources)

    def assembled():
        contents = Path(app) / "Contents"
        package.verify(contents, root)
        package.require((contents / "Resources/TryOmarchyRuntime.lock.json").read_bytes()
                        == (root / "Config/TryOmarchyRuntime.lock.json").read_bytes())
        result = {}
        for name in ("OmarchyVMManager", "omarchy-vm", "OmarchyVMStorageHelper", *package.EXECUTABLES):
            result[name] = fingerprint(contents / "MacOS" / name, executable=True)
            original = launcher_binaries if name == "dev-vm-process-host" else binaries
            # Signing may change bytes. Record equality without claiming a
            # different signed binary came from this build or stripping it.
            result[name]["matchesSuppliedBuild"] = (result[name] == fingerprint(original / name, executable=True))
        return result
    if app is not None:
        check("assembledProvisioningInventory", assembled)

    blockers = [
        {"id": "disposableScope", "status": "NOT_APPROVED",
         "requirement": "Explicitly authorize new stopped disposable profile preparation, then review original UUID/root/device/inode/marker pins. No existing VM is selected."},
        {"id": "operationalCandidate", "status": "NOT_ASSESSED",
         "requirement": "Review a concrete candidate embedding the same approved scope in manager and helper. Ordinary product execution remains disabled."},
        {"id": "signingAndLoadedCode", "status": "NOT_RUN",
         "requirement": "Verify exact kit provenance, loaded helper/package admission and authorized signing. File hashes alone do not prove these."},
        {"id": "factoryAndTools", "status": "NOT_INSPECTED",
         "requirement": "Review an already available verified factory and fresh Homebrew Ansible evidence. No download, install or tool execution is authorized here."},
        {"id": "guestRun", "status": "NOT_APPROVED",
         "requirement": "Review exact frozen inputs and separately authorize named disposable launches, real SSH/Ansible, guest changes and relevant privileges."},
    ]
    if app is None:
        blockers.insert(0, {"id": "assembledApp", "status": "NOT_PROVIDED",
                            "requirement": "Record the exact assembled candidate separately; build products are not an app or signature proof."})
    if evidence.get("repository", {}).get("dirty", True):
        blockers.insert(0, {"id": "sourceCommit", "status": "UNCOMMITTED",
                            "requirement": "Commit the reviewed source and bind a fresh candidate to that commit before real acceptance."})
    return {"format": 1, "offlineStatus": "PASS" if all(c["status"] == "PASS" for c in checks) else "BLOCKED",
            "guestAcceptance": "NOT_RUN", "executionAuthorized": False,
            "checks": checks, "evidence": evidence, "remaining": blockers,
            "limitations": ["This report cannot enable provisioning or supply trusted approval pins.",
                            "No candidate, signing tool, Homebrew, gh, SSH or Ansible process was run.",
                            "No user VM registry, guest root, factory image, credential store or desktop was inspected.",
                            "These file observations are not atomic launch admission or proof that binaries were built from HEAD."]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binaries", type=Path, required=True)
    parser.add_argument("--launcher-binaries", type=Path, required=True)
    parser.add_argument("--app", type=Path, help="Optional assembled candidate; records file hashes without running it")
    args = parser.parse_args()
    result = collect(package.ROOT, args.binaries, args.launcher_binaries, args.app)
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if result["offlineStatus"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
