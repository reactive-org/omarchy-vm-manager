#!/usr/bin/env python3
"""Rebuild the helper and complete signed kit, reusing verified release resources."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess

from kit_artifacts import ROOT, digest, manifest, verify_reference
from upstream_source import prepare


def run(*args, **kwargs):
    subprocess.run([str(x) for x in args], check=True, **kwargs)


def inventory(bundle):
    files = {}
    for path in sorted(bundle.rglob("*")):
        assert not path.is_symlink(), f"unsafe kit entry {path}"
        if path.is_file():
            files[path.relative_to(bundle).as_posix()] = digest(path)
        else:
            assert path.is_dir()
    return files


def reuse_guest_package(source, bundle, lock):
    assert inventory(bundle) == lock['files'], 'reuse kit must match the complete previous runtime inventory'
    run('codesign', '--verify', '--deep', '--strict', bundle)
    previous_source = source.parent / ('omarchy-vm-manager-source-' + lock['patchCommit'][:12])
    def git(folder, *args):
        return subprocess.check_output(['git', '-C', str(folder), *args], text=True).strip()
    assert git(previous_source, 'rev-parse', 'HEAD') == lock['patchCommit'], 'previous source must have its locked commit'
    assert not git(previous_source, 'status', '--porcelain'), 'previous source must be clean'
    for path in ('guest/package', 'LICENSE'):
        assert git(source, 'rev-parse', 'HEAD:' + path) == git(previous_source, 'rev-parse', 'HEAD:' + path), 'guest package sources changed; rebuild instead of reusing'

    package = 'try-omarchy-0.1.0-47-aarch64.pkg.tar.zst'
    target = source / 'dist/guest/packages'
    assert not target.exists(), 'existing package output preserved'
    target.mkdir(parents=True)
    shutil.copy2(bundle / 'Contents/Resources/guest-packages' / package, target / package)
    assert digest(target / package) == lock['files']['Contents/Resources/guest-packages/' + package], 'guest package changed while copying'
    lean_name = 'try-omarchy-0.1.0-47.1-aarch64.pkg.tar.zst'
    lean_target = source / 'dist/guest/packages-lean'
    lean_target.mkdir(parents=True, exist_ok=False)
    shutil.copy2(bundle / 'Contents/Resources/guest-packages' / lean_name, lean_target / lean_name)
    assert digest(lean_target / lean_name) == lock['files']['Contents/Resources/guest-packages/' + lean_name]


def build(reuse_guest_package_from=None, reviewed_guest_package=None, reviewed_lean_guest_package=None):
    stock = ROOT / "VendorArtifacts/stock-v1.3.0"
    verify_reference(stock)
    source = prepare()
    patch = json.loads((ROOT / "Config/TryOmarchyClipboardPatch.json").read_bytes())
    destination = ROOT / ("VendorArtifacts/patched-" + patch["commit"][:12])
    if destination.exists():
        lock_path = ROOT / "Config/TryOmarchyRuntime.lock.json"
        assert lock_path.is_file(), "existing unrecorded artifact; inspect before rebuilding"
        lock = json.loads(lock_path.read_bytes())
        assert lock["patchCommit"] == patch["commit"]
        assert digest(destination / "TryOmarchyKit.zip") == lock["kitSHA256"]
        assert inventory(destination / "TryOmarchyKit.bundle") == lock["files"]
        run("make", "-C", source, "test-kit", f"KIT_DIR={destination}")
        print("Verified existing locked private kit")
        return
    run("make", "-C", source, "test-swift")
    env = dict(os.environ, MACOSX_DEPLOYMENT_TARGET="15.0")
    if reviewed_guest_package is not None:
        review = json.loads((ROOT / 'Config/ReviewedGuestPackageSource.json').read_bytes())
        assert digest(reviewed_guest_package) == review['packageSHA256']
        assert review['packageSHA256'] == json.loads((ROOT / 'Config/GuestIntegrationCompatibility.json').read_bytes())['runtimePackageSHA256']
        for path, tree in review['sourceTrees'].items():
            actual = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD:' + path], text=True).strip()
            assert actual == tree, 'reviewed package source tree differs'
        target = source / 'dist/guest/packages'
        target.mkdir(parents=True, exist_ok=True)
        archive = target / 'try-omarchy-0.1.0-47-aarch64.pkg.tar.zst'
        if archive.exists():
            assert list(target.iterdir()) == [archive] and digest(archive) == review['packageSHA256'], 'existing package output was preserved; inspect it'
        else:
            assert not list(target.iterdir()), 'unexpected package output was preserved'
            shutil.copy2(reviewed_guest_package, archive)
        assert reviewed_lean_guest_package is not None, 'the reviewed native-rendering variant is required'
        assert digest(reviewed_lean_guest_package) == review['leanPackageSHA256']
        lean = source / 'dist/guest/packages-lean'
        lean.mkdir(parents=True, exist_ok=True)
        lean_archive = lean / 'try-omarchy-0.1.0-47.1-aarch64.pkg.tar.zst'
        if lean_archive.exists():
            assert list(lean.iterdir()) == [lean_archive] and digest(lean_archive) == review['leanPackageSHA256']
        else:
            assert not list(lean.iterdir())
            shutil.copy2(reviewed_lean_guest_package, lean_archive)
    elif reuse_guest_package_from is None:
        run("make", "-C", source, "guest-package", env=env)
        run(source / 'guest/package/build.sh', '--native-rendering', '--output', source / 'dist/guest/packages-lean', env=env)
    else:
        previous_path = ROOT / 'Config/TryOmarchyRuntime.lock.json'
        assert digest(previous_path) in (ROOT / 'Sources/OmarchyVMManagerCore/RuntimePin.swift').read_text(), 'previous runtime lock must match its compiled pin'
        previous = json.loads(previous_path.read_bytes())
        reuse_guest_package(source, reuse_guest_package_from, previous)
    run("swift", "build", "--disable-sandbox", "--package-path", source / "macos", "-c", "release",
        "-debug-info-format", "none", env=env)
    stage = source / "dist/manager-staging/Try Omarchy.app"
    assert not stage.exists(), "existing build stage; inspect before rebuilding"
    stage.parent.mkdir(parents=True, exist_ok=True)
    run("ditto", stock / "TryOmarchyKit.bundle", stage)
    contents = stage / "Contents"
    shutil.rmtree(contents / "_CodeSignature")
    shutil.copy2(source / "macos/.build/release/omarchy-vm-helper", contents / "MacOS/omarchy-vm-helper")
    assert (source / "guest/package/try-omarchy/files/usr/share/try-omarchy/owner-setup-contract.json").read_bytes() == (ROOT / "Sources/OmarchyVMManagerCore/Resources/OwnerSetupContract.json").read_bytes(), "owner setup contracts differ"
    assert (source / "guest/package/try-omarchy/files/usr/share/try-omarchy/lean-owner-setup-contract.json").read_bytes() == (ROOT / "Sources/OmarchyVMManagerCore/Resources/LeanOwnerSetupContract.json").read_bytes(), "lean owner contracts differ"
    client_contract = (source / 'macos/Sources/TryOmarchyKitClient/VMGuestIntegrationContract.swift').read_text()
    assert (ROOT / 'Config/GuestIntegrationCompatibility.json').read_text().rstrip() in client_contract, 'client compatibility policy differs'
    owner_provenance = {"version": 1, "reportVersion": 1, "sourceCommit": patch["commit"], "contracts": {
        "official": digest(ROOT / "Sources/OmarchyVMManagerCore/Resources/OwnerSetupContract.json"),
        "lean-e4fffc6": digest(ROOT / "Sources/OmarchyVMManagerCore/Resources/LeanOwnerSetupContract.json")}}
    (contents / "Resources/owner-setup-provenance.json").write_text(json.dumps(owner_provenance, indent=2, sort_keys=True) + "\n")
    packages = list((source / "dist/guest/packages").glob("try-omarchy-*.pkg.tar.zst"))
    assert len(packages) == 1 and packages[0].name == "try-omarchy-0.1.0-47-aarch64.pkg.tar.zst"
    assert digest(packages[0]) == json.loads((ROOT / 'Config/GuestIntegrationCompatibility.json').read_bytes())['runtimePackageSHA256'], 'runtime guest archive changed; review and support its complete identity before building the compatibility-capable kit'
    for old in (contents / "Resources/guest-packages").iterdir():
        assert old.is_file() and not old.is_symlink()
        old.unlink()
    shutil.copy2(packages[0], contents / "Resources/guest-packages" / packages[0].name)
    lean_package = source / 'dist/guest/packages-lean/try-omarchy-0.1.0-47.1-aarch64.pkg.tar.zst'
    lean_review = json.loads((ROOT / 'Config/ReviewedGuestPackageSource.json').read_bytes())
    assert digest(lean_package) == lean_review['leanPackageSHA256']
    assert lean_review['leanPackageSHA256'] in client_contract, 'compiled native-rendering archive identity differs'
    shutil.copy2(lean_package, contents / 'Resources/guest-packages' / lean_package.name)
    info = plistlib.loads((source / "macos/Info.plist").read_bytes())
    info["TryOmarchyBuildDescribe"] = "development"
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    for name in ("run-qemu-gpu.sh", "qemu-port-forwarding.sh", "qemu-networking.sh", "network-identity.py"):
        shutil.copy2(source / "macos" / name, contents / "Resources/scripts" / name)
    guest_units = source / 'guest/package/try-omarchy/files/usr/lib/systemd/system'
    shutil.copy2(guest_units / 'try-omarchy-home.service', contents / 'Resources/managed-home.service')
    shutil.copy2(guest_units / 'display-manager.service.d/60-try-omarchy-home.conf', contents / 'Resources/managed-home-login.conf')
    run(source / "macos/build-kit.sh", "--app", stage, "--output", destination, "--sign-identity", "-")
    run("make", "-C", source, "test-kit", f"KIT_DIR={destination}")
    value = manifest(destination / "TryOmarchyKit.json", "development")
    baseline = json.loads((ROOT / "Config/TryOmarchyUpstream.lock.json").read_bytes())
    lock = {
        "format": 1, "upstreamBase": baseline["commit"], "patchCommit": patch["commit"],
        "patchSHA256": patch["patchSHA256"], "referenceKitSHA256": baseline["kitSHA256"],
        "kitSHA256": digest(destination / "TryOmarchyKit.zip"),
        "kitVersion": value["version"], "runProtocolVersion": value["runProtocolVersion"],
        "buildDate": value["buildDate"], "focusAwareClipboard": True, "managedAuthenticationVersion": 1, "managedSSHVersion": 1, "managedSetupVersion": 1, "manualPauseVersion": 1, "launchIntentVersion": 1, "customFactoryVersion": 1, "factoryCompatibilityVersion": 1, "ownerSetupContractsVersion": 1, "ownerSetupReportVersion": 1,
        "guestPackageVersion": "0.1.0-47", "homeDiskVersion": 1, "leanGuestPackageVersion": "0.1.0-47.1", "managerChannelsVersion": 1,
        "composition": "Source-built helper with UUID-scoped guest sudo authentication, responsive main-run-loop focus checks, fixed non-secret denial diagnostics and nonblocking prompt lease, and guest adapter with explicit launch intent and exact display-process reporting, reviewed official/lean owner contracts, verified factory selection, manual Pause/Resume and manager Downloads cache, guest integration packages 0.1.0-47 and native-rendering 47.1, optional persistent home disks and networking; verified v1.3.0 QEMU, firmware and factory download metadata; upstream build-kit.sh ad-hoc signing",
        "files": inventory(destination / "TryOmarchyKit.bundle")
    }
    lock_path = ROOT / "Config/TryOmarchyRuntime.lock.json"
    lock_path.write_text(json.dumps(lock, indent=2, sort_keys=True) + "\n")
    (ROOT / "Sources/OmarchyVMManagerCore/RuntimePin.swift").write_text(
        '// Generated by Scripts/build-patched-try-omarchy-kit.sh from the verified runtime lock.\n'
        'public enum RuntimePin {\n'
        f'    public static let lockSHA256 = "{digest(lock_path)}"\n'
        '}\n')
    print(f"Private kit locked: {lock['patchCommit']} {lock['kitSHA256']}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reuse-guest-package-from', type=Path, help='Verify a previous complete locked kit and reuse its unchanged guest package without Docker or downloads')
    parser.add_argument('--reviewed-guest-package', type=Path, help='Use an exact reviewed archive bound to the current guest recipe and license trees')
    parser.add_argument('--reviewed-lean-guest-package', type=Path, help='Exact reviewed native-rendering variant archive')
    args = parser.parse_args()
    assert args.reuse_guest_package_from is None or args.reviewed_guest_package is None
    build(args.reuse_guest_package_from, args.reviewed_guest_package, args.reviewed_lean_guest_package)
