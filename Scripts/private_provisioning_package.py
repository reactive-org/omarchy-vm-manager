#!/usr/bin/env python3
"""Private developer packaging handoff; never a product approval loader.

The CLI freezes reviewed inputs only. The packaging runner accepts synthetic
fixtures and an injected simulation backend only. No real signer, credentials,
subprocess, network, publishing or VM adapter is provided here.
"""
import argparse
from dataclasses import dataclass
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
import sys
import tarfile
import unicodedata
import uuid
import zipfile

import keychain_profile
import provisioning_package as package
from signed_prerelease import validate_payload, validate_signed_lock

if sys.flags.optimize:
    raise RuntimeError("Private packaging requires validation assertions")

BUNDLE_ID = "dev.omarchy.vm-manager"
MAIN = "OmarchyVMManager"
CHILDREN = ("OmarchyVMStorageHelper", "omarchy-vm", *package.EXECUTABLES)
LIMIT = 1024 * 1024 * 1024
OVERLAY_PATHS = {
    "App/Info.plist", "Scripts/provisioning_package.py",
    "Sources/OmarchyVMManagerApp/OmarchyVMManagerApp.swift",
    "Sources/OmarchyVMProvisioningHelper/main.swift",
    "Sources/OmarchyVMManagerCore/ProvisioningOperationalBackends.swift",
    "Sources/OmarchyVMManagerCore/PrivateM6Acceptance.swift",
}
SCOPE_KEYS = {"vmID", "root", "device", "inode", "markerSHA256", "approvalID",
              "sourceCommit", "purpose", "receiptSHA256", "scopeSHA256"}


class Refused(ValueError):
    """Fixed diagnostics only; never echo paths, source text or signer errors."""


def require(value, code="private-packaging-invalid"):
    if not value:
        raise Refused(code)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def sha256(value):
    return isinstance(value, str) and re.fullmatch("[0-9a-f]{64}", value) is not None


def decode(raw):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result)
            result[key] = value
        return result
    try:
        return json.loads(raw, object_pairs_hook=pairs,
                          parse_constant=lambda _: (_ for _ in ()).throw(Refused("private-packaging-invalid")))
    except (ValueError, TypeError, RecursionError):
        raise Refused("private-packaging-invalid") from None


def relative(name):
    require(isinstance(name, str) and 0 < len(name) <= 512 and "\\" not in name)
    path = PurePosixPath(name)
    require(not path.is_absolute() and str(path) == name and all(p not in (".", "..") for p in path.parts))
    require(not any(unicodedata.category(c) in ("Cc", "Cs") for c in name) and len(path.parts) <= 32)
    require(not name.casefold().endswith((".img", ".img.zst", ".img.zst.download", ".qcow2", ".vmdk", ".dmg")),
            "private-disk-image-refused")
    return path


def private_directory(path):
    path = Path(path)
    info = path.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid()
            and stat.S_IMODE(info.st_mode) == 0o700 and path.resolve() == path,
            "private-directory-required")
    return path


def new_directory(path, source=None):
    path = Path(path)
    require(path.is_absolute() and path.name not in ("", ".", ".."))
    private_directory(path.parent)
    # Packaging must never write into a manager UUID namespace, even if a caller
    # accidentally supplies the approved guest root as its output directory.
    parts = tuple(p.casefold() for p in path.parts)
    require(not any(parts[i:i+2] == ("omarchy vm manager", "vms") for i in range(len(parts)-1)),
            "guest-storage-output-refused")
    published = {("dist", "prerelease"), ("dist", "prerelease-staging"),
                 (".build", "signed-release"), (".build", "notarization")}
    require(not any(parts[i:i+2] in published for i in range(len(parts)-1)),
            "publishing-output-refused")
    if source is not None:
        source = Path(source)
        require(path != source and source not in path.parents and path not in source.parents,
                "source-output-overlap")
    require(not os.path.lexists(path), "existing-output-preserved")
    os.mkdir(path, 0o700)
    return private_directory(path)


def read(path, maximum=LIMIT):
    path = Path(path)
    require(path.parent.resolve() == path.parent, "linked-input-refused")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1
                and not before.st_mode & 0o022 and 0 <= before.st_size <= maximum,
                "unsafe-packaging-input")
        blocks, total = [], 0
        while block := os.read(fd, 1024 * 1024):
            total += len(block); require(total <= maximum)
            blocks.append(block)
        after, current = os.fstat(fd), path.lstat()
        fields = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns, s.st_mode)
        require(fields(before) == fields(after) == fields(current) and total == before.st_size,
                "packaging-input-changed")
        return b"".join(blocks)
    finally:
        os.close(fd)


def write(path, data, executable=False):
    path = Path(path)
    require(path.parent.resolve() == path.parent)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                 0o700 if executable else 0o600)
    try:
        with os.fdopen(fd, "wb", closefd=False) as stream:
            stream.write(data); stream.flush(); os.fsync(fd)
    finally:
        os.close(fd)


def write_json(path, value):
    write(path, canonical(value) + b"\n")


def tree(folder):
    folder = Path(folder)
    require(folder.is_dir() and folder.resolve() == folder)
    result, total = {}, 0
    for directory, dirs, files in os.walk(folder, followlinks=False):
        for name in dirs:
            path = Path(directory) / name
            require(not path.is_symlink() and not path.stat().st_mode & 0o022)
        for name in files:
            path = Path(directory) / name
            key = path.relative_to(folder).as_posix(); relative(key)
            data = read(path); total += len(data)
            require(len(result) < 4096 and total <= LIMIT)
            result[key] = digest(data)
    return result


def copy_tree(source, target, expected):
    require(tree(source) == expected, "input-inventory-changed")
    target.mkdir(mode=0o700)
    for name, sha in expected.items():
        relative(name); src, dst = source / name, target / name
        dst.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        data = read(src); require(digest(data) == sha, "input-inventory-changed")
        write(dst, data, executable=bool(src.stat().st_mode & 0o111))
    require(tree(target) == expected and tree(source) == expected, "input-inventory-changed")


def validate_scope(scope):
    require(isinstance(scope, dict) and set(scope) == SCOPE_KEYS)
    for key in ("vmID", "approvalID"):
        require(str(uuid.UUID(scope[key])).upper() == scope[key])
    root = scope["root"]
    require(isinstance(root, str) and root.startswith("/") and len(root) <= 4096
            and not any(unicodedata.category(c) in ("Cc", "Cs") for c in root) and str(PurePosixPath(root)) == root
            and ".." not in PurePosixPath(root).parts
            and root.endswith("/Omarchy VM Manager/VMs/" + scope["vmID"]))
    require(scope["vmID"] not in {"C7C2B381-E43C-4A5A-8246-4314596B4C0A", "89F88CC2-BD11-44B5-9C1B-31EDB2DE6B0B"})
    require(type(scope["device"]) is int and 0 <= scope["device"] < 2**63)
    require(type(scope["inode"]) is int and 0 < scope["inode"] < 2**64)
    require(isinstance(scope["sourceCommit"], str) and re.fullmatch("[0-9a-f]{40}", scope["sourceCommit"]))
    require(all(sha256(scope[k]) for k in ("markerSHA256", "receiptSHA256", "scopeSHA256")))
    require(scope["purpose"] == "Candidate preparation only; no guest execution authorized")
    body = {k: v for k, v in scope.items() if k not in ("receiptSHA256", "scopeSHA256")}
    require(digest(canonical(body)) == scope["scopeSHA256"], "scope-binding-changed")


@dataclass(frozen=True, repr=False)
class ReviewedIdentity:
    candidateSHA256: str
    scopeSHA256: str

    def __post_init__(self):
        require(sha256(self.candidateSHA256) and sha256(self.scopeSHA256))

    def __repr__(self):
        return "ReviewedIdentity(redacted)"


def archive_profile_pin(raw):
    names, total, profile = set(), 0, None
    with tarfile.open(fileobj=io.BytesIO(raw), mode="r:") as archive:
        for item in archive:
            name = item.name.rstrip("/"); relative(name)
            require(name not in names and (item.isdir() or item.isfile()), "unsafe-source-archive")
            names.add(name); total += item.size
            require(len(names) <= 8192 and total <= LIMIT, "oversize-source-archive")
            if name == "Config/TouchIDProfile.lock.json":
                require(item.isfile() and item.size <= 65536)
                profile = decode(archive.extractfile(item).read())
    require(profile is not None and profile.get("format") == 1
            and profile.get("bundleID") == BUNDLE_ID and sha256(profile.get("profileSHA256")))
    return profile


def prepare_handoff(candidate, output, reviewed):
    """Freeze an explicitly reviewed build identity; never observe guest roots."""
    private_context()
    candidate = private_directory(candidate)
    raw = read(candidate / "candidate.json", 512 * 1024)
    require(digest(raw) == reviewed.candidateSHA256, "candidate-binding-changed")
    manifest = decode(raw)
    scope_raw, source_raw = read(candidate / "scope.json", 65536), read(candidate / "source-evidence.json", 65536)
    scope, source = decode(scope_raw), decode(source_raw)
    require(type(manifest.get("format")) is int and manifest["format"] == 1
            and type(source.get("format")) is int and source["format"] == 1,
            "unsupported-private-candidate-format")
    validate_scope(scope)
    require(scope["scopeSHA256"] == reviewed.scopeSHA256 and manifest["scope"] == scope
            and manifest["source"] == source and source["scopeSHA256"] == reviewed.scopeSHA256,
            "scope-binding-changed")
    require(source["baseCommit"] == scope["sourceCommit"] and source["ordinaryGateUnchanged"] is True
            and source["productionSigningPolicyUnchanged"] is True)
    require(manifest["status"] == "PREPARED_OFFLINE_NOT_AUTHORIZED_FOR_GUEST_RUN"
            and manifest["guestAcceptance"] == "NOT_RUN")
    require({r["path"] for r in source["overlayFiles"]} == OVERLAY_PATHS
            and len(source["overlayFiles"]) == len(OVERLAY_PATHS))
    require(all(set(item) == {"path", "beforeSHA256", "afterSHA256"}
                and sha256(item["afterSHA256"])
                and (item["beforeSHA256"] is None or sha256(item["beforeSHA256"]))
                for item in source["overlayFiles"]))
    archive, patch = read(candidate / "base-source.tar"), read(candidate / "candidate-overlay.patch", 1024*1024)
    require(digest(archive) == source["baseArchiveSHA256"] and digest(patch) == source["overlaySHA256"],
            "source-binding-changed")
    profile_pin = archive_profile_pin(archive)
    receipt = read(candidate / "root-preparation-receipt.json", 256*1024)
    require(digest(receipt) == scope["receiptSHA256"], "original-receipt-changed")
    recorded = decode(receipt)
    require(all(recorded[k] == scope[k] for k in ("vmID", "root", "device", "inode", "markerSHA256")))
    app = candidate / "Omarchy VM Manager.app"
    require(tree(app) == manifest["appInventory"], "candidate-inventory-changed")
    resources = app / "Contents/Resources"
    lock_raw = read(resources / "DevVMProvisioning.lock.json", 65536)
    runtime_raw = read(resources / "TryOmarchyRuntime.lock.json", 65536)
    lock, runtime = decode(lock_raw), decode(runtime_raw)
    require(digest(lock_raw) == manifest["packageLockSHA256"]
            and digest(runtime_raw) == manifest["runtimeLockSHA256"]
            and lock["engineSHA256"] == manifest["engineSHA256"])
    require(sha256(runtime["kitSHA256"]) and runtime["kitSHA256"] == manifest["runtimeKitSHA256"])
    bundle = resources / package.BUNDLE
    bundle_inventory = tree(bundle)
    require(package.files(package.resource_directory(bundle)) == package.resource_files(lock))
    kit = app / "Contents/Helpers/TryOmarchyKit.bundle"
    require(tree(kit) == runtime["files"], "runtime-source-changed")
    out = new_directory(output, candidate)
    try:
        inputs = out / "inputs"; inputs.mkdir(mode=0o700)
        (inputs / "Config").mkdir(mode=0o700)
        frozen = {"candidate.json": raw, "scope.json": scope_raw, "source-evidence.json": source_raw,
                  "base-source.tar": archive, "candidate-overlay.patch": patch,
                  "root-preparation-receipt.json": receipt,
                  "Config/DevVMProvisioning.lock.json": lock_raw,
                  "Config/TryOmarchyRuntime.lock.json": runtime_raw,
                  "Config/TouchIDProfile.lock.json": canonical(profile_pin)}
        for name, data in frozen.items(): write(inputs / name, data)
        copy_tree(bundle, inputs / package.BUNDLE, bundle_inventory)
        copy_tree(kit, inputs / "TryOmarchyKit.bundle", runtime["files"])
        require(tree(app) == manifest["appInventory"], "candidate-changed-during-freeze")
        request = {"format": 1, "status": "PRIVATE_REQUEST_ONLY_NOT_SIGNED", "publication": "forbidden",
                   "reviewedCandidateSHA256": reviewed.candidateSHA256, "scopeSHA256": reviewed.scopeSHA256,
                   "sourceCommit": source["baseCommit"], "overlaySHA256": source["overlaySHA256"],
                   "profileSHA256": profile_pin["profileSHA256"], "inputs": tree(inputs),
                   "simulationFixture": manifest.get("simulationFixture") is True,
                   "localScopeValidation": "deferred-to-original-Mac", "guestRunAuthorized": False}
        request_raw = canonical(request) + b"\n"
        write(out / "request.json", request_raw)
        write_json(out / "request.sha256.json", {"sha256": digest(request_raw)})
        return digest(request_raw)
    except Exception:
        try:
            write_json(out / "failure.json", {"status": "PRIVATE_CAPTURE_FAILED_OUTPUT_PRESERVED",
                                             "publication": "forbidden", "guestRunAuthorized": False})
        except OSError:
            pass
        raise Refused("private-handoff-capture-failed") from None


def load_handoff(folder, expected):
    folder = private_directory(folder)
    require(not os.path.lexists(folder / "failure.json"), "failed-handoff-refused")
    raw = read(folder / "request.json", 1024*1024)
    require(sha256(expected) and digest(raw) == expected, "handoff-binding-changed")
    require(decode(read(folder / "request.sha256.json", 4096)) == {"sha256": expected},
            "handoff-checksum-changed")
    value = decode(raw)
    require(value["format"] == 1 and value["publication"] == "forbidden"
            and value["guestRunAuthorized"] is False and value["status"] == "PRIVATE_REQUEST_ONLY_NOT_SIGNED")
    require(tree(folder / "inputs") == value["inputs"], "frozen-inputs-changed")
    manifest = decode(read(folder / "inputs/candidate.json", 512*1024))
    scope = decode(read(folder / "inputs/scope.json", 65536)); validate_scope(scope)
    require(scope["scopeSHA256"] == value["scopeSHA256"] == manifest["scope"]["scopeSHA256"])
    require(digest(read(folder / "inputs/candidate.json")) == value["reviewedCandidateSHA256"])
    require(manifest["source"]["overlaySHA256"] == value["overlaySHA256"])
    return value


def verify_built_app(app, handoff, request, build, runtime, original_raw, team, profile=None):
    require(build == {"mode": "SIGNED_PRERELEASE", "sourceCommit": request["sourceCommit"],
                      "overlaySHA256": request["overlaySHA256"],
                      "managerScopeSHA256": request["scopeSHA256"], "helperScopeSHA256": request["scopeSHA256"]},
            "compiled-scope-or-build-mode-changed")
    contents = app / "Contents"
    info = plistlib.loads(read(contents / "Info.plist", 65536))
    require(info.get("CFBundleIdentifier") == BUNDLE_ID and info.get("CFBundleExecutable") == MAIN)
    require((contents / "Resources/DevVMProvisioning.lock.json").read_bytes()
            == read(handoff / "inputs/Config/DevVMProvisioning.lock.json"))
    for name in (MAIN, *CHILDREN):
        executable = contents / "MacOS" / name
        binary = read(executable)
        require(executable.stat().st_mode & 0o111 and binary.startswith(b"SIMULATION_ONLY_NOT_MACHO\n"),
                "real-binary-in-simulation-refused")
        if name in (MAIN, "OmarchyVMProvisioningHelper"):
            body = decode(binary.split(b"\n", 2)[1])
            require(body == {"role": name, "scopeSHA256": request["scopeSHA256"], "mode": "SIGNED_PRERELEASE"},
                    "simulated-compiled-scope-changed")
    require(tree(contents / "Resources" / package.BUNDLE)
            == tree(handoff / "inputs" / package.BUNDLE), "provisioning-resources-changed")
    require(tree(contents / "Helpers/TryOmarchyKit.bundle") == runtime["files"], "signed-kit-changed")
    runtime_raw = read(contents / "Resources/TryOmarchyRuntime.lock.json", 65536)
    require(decode(runtime_raw) == runtime, "signed-runtime-lock-changed")
    pins = decode(read(contents / "Resources/PrivateSigningBuildPins.json", 65536))
    require(pins == {"runtimeLockSHA256": digest(runtime_raw), "team": team,
                     "sourceKitSHA256": decode(original_raw)["kitSHA256"],
                     "sourceLockSHA256": digest(original_raw)}, "signed-build-pins-changed")
    if profile is not None:
        require(read(contents / "embedded.provisionprofile", 65536) == profile, "embedded-profile-changed")


def verify_simulated_signatures(evidence, team, entitlements):
    require(set(evidence) == {"app", *CHILDREN}, "signature-evidence-incomplete")
    for name, item in evidence.items():
        expected = entitlements if name == "app" else {}
        require(item == {"mode": "SIMULATED_NOT_A_CODE_SIGNATURE", "team": team,
                         "hardenedRuntime": True, "timestamp": True, "entitlements": expected},
                "signature-contract-refused")


def archive_local(app, output):
    fd = os.open(output, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    with os.fdopen(fd, "w+b") as stream:
        with zipfile.ZipFile(stream, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for name in sorted(tree(app)):
                path = app / name
                entry = zipfile.ZipInfo(app.name + "/" + name)
                entry.external_attr = (stat.S_IFREG | (0o700 if path.stat().st_mode & 0o111 else 0o600)) << 16
                archive.writestr(entry, read(path))
        stream.flush(); os.fsync(stream.fileno())


def extract_local(archive, destination):
    destination.mkdir(mode=0o700)
    names, total = set(), 0
    with zipfile.ZipFile(archive) as package_zip:
        for entry in package_zip.infolist():
            name = entry.filename; path = relative(name)
            mode = entry.external_attr >> 16
            require(name not in names and stat.S_ISREG(mode), "unsafe-private-archive")
            names.add(name); total += entry.file_size
            require(len(names) <= 4096 and total <= LIMIT)
            target = destination.joinpath(*path.parts)
            target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            write(target, package_zip.read(entry), executable=bool(mode & 0o111))


def package_simulation(handoff, output, expected, backend):
    """Exercise complete ordering with synthetic data. No real backend exists."""
    private_context()
    handoff = Path(handoff)
    request = load_handoff(handoff, expected)
    require(request["simulationFixture"] is True and backend.mode == "SIMULATION_ONLY",
            "real-signing-unavailable")
    out = new_directory(output, handoff)
    events, phase = [], "validate-profile"
    def checkpoint(name):
        nonlocal phase
        phase = name; events.append(name)
    try:
        team, raw_profile, decoded_profile = backend.profile()
        require(re.fullmatch("[A-Z0-9]{10}", team) and digest(raw_profile) == request["profileSHA256"],
                "profile-binding-changed")
        entitlements = keychain_profile.profile_entitlements(decoded_profile, team, BUNDLE_ID)
        load_handoff(handoff, expected)
        original_raw = read(handoff / "inputs/Config/TryOmarchyRuntime.lock.json", 65536)
        original = decode(original_raw)
        # A fake signer cannot declare guest scripts/firmware to be signable code.
        # Synthetic runtime code has an explicit non-Mach-O marker; actual runtime
        # code is never accepted by this simulation runner.
        source_code = set()
        for name in original["files"]:
            data = read(handoff / "inputs/TryOmarchyKit.bundle" / name)
            require(data[:4] not in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe",
                                     b"\xbe\xba\xfe\xca", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xce",
                                     b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"),
                    "real-runtime-in-simulation-refused")
            if data.startswith(b"SIMULATION_ONLY_NOT_MACHO\n"): source_code.add(name)
        require(source_code, "synthetic-runtime-required")
        checkpoint("prepare-signed-runtime")
        runtime, code_paths = backend.runtime(out, handoff, team)
        load_handoff(handoff, expected)
        require(code_paths == source_code, "signable-runtime-code-changed")
        validate_signed_lock(runtime, original, digest(original_raw), team)
        validate_payload(original["files"], runtime["files"], code_paths)
        checkpoint("rebuild-signed-prerelease-with-original-scope")
        app, build = backend.rebuild(out, handoff, request, runtime, team)
        load_handoff(handoff, expected)
        require(app == out / "Simulation.app", "unexpected-build-output")
        verify_built_app(app, handoff, request, build, runtime, original_raw, team)
        write(app / "Contents/embedded.provisionprofile", raw_profile)
        checkpoint("sign-children")
        backend.sign_children(app, team)
        load_handoff(handoff, expected)
        verify_built_app(app, handoff, request, build, runtime, original_raw, team, raw_profile)
        checkpoint("seal-post-sign-helper-digests")
        package.seal(app / "Contents", root=handoff / "inputs")
        package.verify(app / "Contents", root=handoff / "inputs")
        before_outer = tree(app)
        checkpoint("sign-outer-app")
        backend.sign_app(app, team, entitlements)
        load_handoff(handoff, expected)
        after_outer = tree(app)
        changed = {n for n in before_outer.keys() | after_outer.keys() if before_outer.get(n) != after_outer.get(n)}
        require(changed <= {"Contents/MacOS/OmarchyVMManager", "Contents/_CodeSignature/CodeResources"},
                "outer-signing-changed-sealed-payload")
        checkpoint("verify-private-package")
        verify_built_app(app, handoff, request, build, runtime, original_raw, team, raw_profile)
        package.verify(app / "Contents", root=handoff / "inputs")
        signed_inventory = tree(app)
        verify_simulated_signatures(backend.verify(app, team), team, entitlements)
        require(tree(app) == signed_inventory, "verification-mutated-app")
        require(read(app / "Contents/embedded.provisionprofile") == raw_profile)
        checkpoint("archive-private-only")
        archive = out / "SIMULATION-ONLY-NOT-SIGNED.zip"
        archive_local(app, archive)
        archive_sha = digest(read(archive))
        checkpoint("extract-and-reverify")
        extract_local(archive, out / "roundtrip")
        extracted = out / "roundtrip/Simulation.app"
        require(tree(extracted) == tree(app), "archive-roundtrip-changed")
        verify_built_app(extracted, handoff, request, build, runtime, original_raw, team, raw_profile)
        package.verify(extracted / "Contents", root=handoff / "inputs")
        verify_simulated_signatures(backend.verify(extracted, team), team, entitlements)
        require(tree(extracted) == signed_inventory and tree(app) == signed_inventory
                and digest(read(archive)) == archive_sha, "verification-mutated-package")
        load_handoff(handoff, expected)
        result = {"format": 1, "status": "SIMULATION_ONLY_NOT_SIGNED_OR_LAUNCH_READY",
                  "scopeSHA256": request["scopeSHA256"], "handoffSHA256": expected,
                  "archiveSHA256": archive_sha, "events": events,
                  "productionSigningVerified": False, "publication": "forbidden",
                  "localScopeValidation": "deferred-to-original-Mac", "guestRunAuthorized": False,
                  "realSigningOperations": 0, "credentialOperations": 0, "guestLaunches": 0}
        write_json(out / "simulation.json", result)
        return result
    except Exception:
        write_json(out / "failure.json", {"format": 1, "status": "FAILED_PRIVATE_OUTPUT_PRESERVED",
                                         "phase": phase, "realSigningOperations": 0,
                                         "publication": "forbidden", "guestRunAuthorized": False})
        raise Refused("private-simulation-failed") from None


def private_context():
    require(not os.environ.get("GITHUB_REF", "").startswith("refs/tags/")
            and os.environ.get("GITHUB_EVENT_NAME") != "release", "publishing-context-refused")


class PrivateArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        raise Refused("invalid-private-packaging-command")


def main():
    parser = PrivateArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="operation", required=True)
    prepare = sub.add_parser("prepare", help="Freeze reviewed private inputs; no signing")
    prepare.add_argument("--candidate", type=Path, required=True)
    prepare.add_argument("--output", type=Path, required=True)
    prepare.add_argument("--reviewed-identity", type=Path, required=True)
    try:
        args = parser.parse_args()
        private_context()
        private_directory(args.reviewed_identity.parent)
        require(stat.S_IMODE(args.reviewed_identity.lstat().st_mode) == 0o600,
                "private-reviewed-identity-required")
        identity = decode(read(args.reviewed_identity, 4096))
        require(set(identity) == {"candidateSHA256", "scopeSHA256"})
        # Publishing workflows cannot accidentally turn this command into their
        # private source/artifact intake. There is no release/sign/upload command.
        prepare_handoff(args.candidate, args.output, ReviewedIdentity(**identity))
        print('{"status":"PRIVATE_REQUEST_PREPARED_NOT_SIGNED","publication":"forbidden","guestRunAuthorized":false}')
        return 0
    except Exception:
        print('{"status":"PRIVATE_HANDOFF_REFUSED","guestRunAuthorized":false}', file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
