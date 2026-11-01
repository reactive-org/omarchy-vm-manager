#!/usr/bin/env python3
"""CI-only signing/notarization orchestration; never starts a VM or installs an app."""
import base64
import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request

from kit_artifacts import ROOT, digest
from build_patched_kit import inventory
from fetch_runtime_kit import archive_manifest, verify, MAX_ARCHIVE_BYTES
from package_prerelease import validate_tag
from upstream_source import prepare
from keychain_profile import decode_profile, profile_entitlements, verify_profile_bytes

REQUIRED_SECRETS = ("MACOS_CERTIFICATE_P12_BASE64", "MACOS_CERTIFICATE_PASSWORD",
                    "MACOS_SIGNING_IDENTITY", "APPLE_TEAM_ID", "APPLE_API_KEY_P8",
                    "APPLE_API_KEY_ID", "APPLE_API_ISSUER_ID", "MACOS_KEYCHAIN_PROFILE_BASE64")
REDACTIONS = []


@contextmanager
def provisioning_profile():
    if os.environ.get("GITHUB_ACTIONS") != "true" or not os.environ.get("RUNNER_TEMP"):
        raise RuntimeError("Provisioned signing is restricted to the authorized GitHub release job")
    encoded = os.environ.get("MACOS_KEYCHAIN_PROFILE_BASE64", "")
    if not encoded.strip():
        raise ValueError("Missing GitHub secret: MACOS_KEYCHAIN_PROFILE_BASE64")
    REDACTIONS.extend((encoded, encoded.strip()))
    raw = base64.b64decode(re.sub(r"\s", "", encoded), validate=True)
    verify_profile_bytes(raw)
    with tempfile.TemporaryDirectory(prefix="omarchy-profile-", dir=os.environ["RUNNER_TEMP"]) as temp:
        path = Path(temp) / "manager.provisionprofile"
        path.write_bytes(raw)
        path.chmod(0o600)
        profile_entitlements(decode_profile(path), os.environ.get("APPLE_TEAM_ID", "").strip(), "dev.omarchy.vm-manager")
        try:
            yield path
        finally:
            print("Temporary provisioning profile cleaned up", flush=True)


def redact(value):
    for secret in sorted(REDACTIONS, key=len, reverse=True):
        if secret:
            value = value.replace(secret, "[redacted]")
    return value


def run(label, *arguments):
    print(label, flush=True)
    result = subprocess.run([str(value) for value in arguments], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(label + ": " + redact((result.stderr + result.stdout)[-6000:]))
    return result


def check_submission(identifier):
    """Read an existing submission in CI without importing a signing identity."""
    if os.environ.get("GITHUB_ACTIONS") != "true" or not os.environ.get("RUNNER_TEMP"):
        raise RuntimeError("Notarization credentials are restricted to the authorized GitHub release job")
    if not re.fullmatch(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", identifier):
        raise ValueError("Invalid Apple submission ID")
    for name in ("APPLE_API_KEY_P8", "APPLE_API_KEY_ID", "APPLE_API_ISSUER_ID"):
        if not os.environ.get(name, "").strip():
            raise ValueError("Missing GitHub secret: " + name)
        REDACTIONS.extend((os.environ[name], os.environ[name].strip()))
    with tempfile.TemporaryDirectory(prefix="omarchy-notary-status-", dir=os.environ["RUNNER_TEMP"]) as temp:
        key = Path(temp) / "notary.p8"
        key.write_text(os.environ["APPLE_API_KEY_P8"].strip() + "\n")
        key.chmod(0o600)
        authentication = ["--key", key, "--key-id", os.environ["APPLE_API_KEY_ID"].strip(),
                          "--issuer", os.environ["APPLE_API_ISSUER_ID"].strip()]
        result = run("Read existing Apple submission (no upload)", "xcrun", "notarytool", "info", identifier,
                     *authentication, "--output-format", "json")
        status = json.loads(result.stdout)
        assert status["id"].lower() == identifier.lower(), "Apple returned a different submission"
        assert status.get("status") in {"Accepted", "In Progress", "InProgress", "Invalid", "Rejected"}
        folder = ROOT / ".build/notarization"
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "existing-submission.json").write_text(json.dumps(status, indent=2) + "\n")
        if status["status"] in {"Invalid", "Rejected"}:
            run("Read Apple rejection details", "xcrun", "notarytool", "log", identifier,
                *authentication, folder / "existing-submission-log.json")
        print(f"::notice title=Existing Apple submission::{identifier}: {status['status']}", flush=True)
        if os.environ.get("GITHUB_OUTPUT"):
            with open(os.environ["GITHUB_OUTPUT"], "a") as output:
                output.write("status=" + status["status"] + "\n")
        return status


def validate_signed_lock(lock, source, source_sha, team):
    assert re.fullmatch(r"[A-Z0-9]{10}", team)
    assert lock["signingTeamID"] == team
    assert lock["sourceLockSHA256"] == source_sha
    assert lock["sourceKitSHA256"] == source["kitSHA256"]
    assert re.fullmatch(r"[0-9a-f]{64}", lock["kitSHA256"]) and lock["kitSHA256"] != source["kitSHA256"]
    assert re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+-dev\.[1-9][0-9]*", lock["artifactTag"])
    for key, value in source.items():
        if key not in {"files", "kitSHA256", "buildDate", "composition"}:
            assert lock[key] == value, "signed runtime changed source provenance/capability: " + key


def validate_payload(source_files, signed_files, code_paths):
    # Only the upstream signer, metadata writer, stapler and networking builder
    # may change these entries. All guest/scripts/firmware/config payloads stay exact.
    allowed = set(code_paths) | {"Contents/CodeResources", "Contents/_CodeSignature/CodeResources",
                                "Contents/Resources/kit.json"}
    assert set(signed_files) - set(source_files) <= {"Contents/CodeResources"}
    assert set(source_files) <= set(signed_files)
    for name, value in source_files.items():
        if name not in allowed:
            assert signed_files[name] == value, "unsigned runtime payload changed: " + name


def compatible_certificate(certificate, directory):
    # Recent Keychain Access exports can use PKCS#12 algorithms the older
    # runner's SecKeychainItemImport cannot decode. Verify/decrypt with OpenSSL
    # first, then rewrap the same cert/key using a random ASCII transfer password.
    openssl = Path("/opt/homebrew/opt/openssl@3/bin/openssl")
    if not openssl.is_file():
        raise RuntimeError("The release runner needs its bundled Homebrew OpenSSL 3")
    pem, normalized = directory / "identity.pem", directory / "compatible.p12"
    transfer_password = secrets.token_urlsafe(32)
    REDACTIONS.append(transfer_password)
    previous = os.environ.get("OMARCHY_P12_TRANSFER_PASSWORD")
    os.environ["OMARCHY_P12_TRANSFER_PASSWORD"] = transfer_password
    try:
        try:
            run("Validate PKCS12 password and decode certificate container", openssl, "pkcs12", "-legacy", "-in", certificate,
                "-passin", "env:MACOS_CERTIFICATE_PASSWORD", "-noenc", "-out", pem)
        except RuntimeError as error:
            raise RuntimeError("The configured PKCS12 could not be decrypted. Re-export the certificate/private key and update both "
                               "MACOS_CERTIFICATE_P12_BASE64 and MACOS_CERTIFICATE_PASSWORD. " + str(error)) from None
        pem.chmod(0o600)
        run("Rewrap the same certificate/key for macOS importer compatibility", openssl, "pkcs12", "-export", "-in", pem,
            "-out", normalized, "-passout", "env:OMARCHY_P12_TRANSFER_PASSWORD",
            "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1")
        normalized.chmod(0o600)
        print("::notice title=Signing certificate::PKCS12 password validated; identity container normalized for runner compatibility", flush=True)
        return normalized, transfer_password
    finally:
        pem.unlink(missing_ok=True)
        if previous is None:
            os.environ.pop("OMARCHY_P12_TRANSFER_PASSWORD", None)
        else:
            os.environ["OMARCHY_P12_TRANSFER_PASSWORD"] = previous


@contextmanager
def credentials():
    if os.environ.get("GITHUB_ACTIONS") != "true" or not os.environ.get("RUNNER_TEMP"):
        raise RuntimeError("Real signing is restricted to the explicitly authorized GitHub release job")
    for name in REQUIRED_SECRETS:
        if not os.environ.get(name, "").strip():
            raise ValueError("Missing GitHub secret: " + name)
        REDACTIONS.append(os.environ[name])
        REDACTIONS.append(os.environ[name].strip())
    team = os.environ["APPLE_TEAM_ID"].strip()
    identity = os.environ["MACOS_SIGNING_IDENTITY"].strip()
    assert re.fullmatch(r"[A-Z0-9]{10}", team), "invalid Apple Team ID"
    assert identity.startswith("Developer ID Application:") and identity.endswith("(" + team + ")"), "certificate identity/team mismatch"
    os.environ["APPLE_TEAM_ID"], os.environ["MACOS_SIGNING_IDENTITY"] = team, identity
    password = secrets.token_urlsafe(32)
    REDACTIONS.append(password)
    original = shlex.split(run("Read temporary runner keychain search list", "security", "list-keychains", "-d", "user").stdout)
    with tempfile.TemporaryDirectory(prefix="omarchy-signing-", dir=os.environ["RUNNER_TEMP"]) as temp:
        directory = Path(temp)
        certificate, key, keychain = directory / "certificate.p12", directory / "notary.p8", directory / "signing.keychain-db"
        certificate.write_bytes(base64.b64decode(re.sub(r"\s", "", os.environ["MACOS_CERTIFICATE_P12_BASE64"]), validate=True))
        key.write_text(os.environ["APPLE_API_KEY_P8"].strip() + "\n")
        certificate.chmod(0o600); key.chmod(0o600)
        created = False
        try:
            run("Create isolated release keychain", "security", "create-keychain", "-p", password, keychain)
            created = True
            run("Configure release keychain", "security", "set-keychain-settings", "-lut", "21600", keychain)
            run("Unlock release keychain", "security", "unlock-keychain", "-p", password, keychain)
            compatible, transfer_password = compatible_certificate(certificate, directory)
            run("Import Developer ID certificate", "security", "import", compatible, "-P", transfer_password,
                "-k", keychain, "-T", "/usr/bin/codesign", "-T", "/usr/bin/security")
            run("Allow noninteractive signing in isolated runner", "security", "set-key-partition-list", "-S", "apple-tool:,apple:", "-s", "-k", password, keychain)
            run("Select release keychain", "security", "list-keychains", "-d", "user", "-s", keychain, *original)
            identities = run("Validate installed signing identity", "security", "find-identity", "-v", "-p", "codesigning", keychain).stdout
            assert identity in identities, "requested Developer ID identity was not imported"
            profile = "omarchy-release-notary"
            run("Validate and store notarization API credentials", "xcrun", "notarytool", "store-credentials", profile,
                "--key", key, "--key-id", os.environ["APPLE_API_KEY_ID"].strip(),
                "--issuer", os.environ["APPLE_API_ISSUER_ID"].strip(), "--keychain", keychain)
            yield ["--keychain-profile", profile, "--keychain", str(keychain)], team, identity
        finally:
            subprocess.run(["security", "list-keychains", "-d", "user", "-s", *original], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if created:
                subprocess.run(["security", "delete-keychain", str(keychain)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            print("Release credential files and temporary keychain cleaned up", flush=True)


def notarize(archive, profile, label):
    folder = ROOT / ".build/notarization"
    folder.mkdir(parents=True, exist_ok=True)
    submission = json.loads(run("Submit " + label + " to Apple", "xcrun", "notarytool", "submit", archive,
                                *profile, "--output-format", "json").stdout)
    identifier = submission["id"]
    assert re.fullmatch(r"[0-9a-fA-F-]{36}", identifier)
    deadline = time.monotonic() + 45 * 60
    previous_status = None
    while True:
        status = json.loads(run("Check Apple notarization status for " + label, "xcrun", "notarytool", "info", identifier,
                                *profile, "--output-format", "json").stdout)
        (folder / (label + "-submission.json")).write_text(json.dumps(status, indent=2) + "\n")
        print(f"{label}: Apple status {status.get('status')} (submission {identifier})", flush=True)
        if status.get("status") != previous_status:
            print(f"::notice title=Apple notarization::{label}: {status.get('status')} (submission {identifier})", flush=True)
            previous_status = status.get("status")
        if status.get("status") == "Accepted":
            return status
        if status.get("status") not in {"In Progress", "InProgress"}:
            run("Retrieve Apple rejection details", "xcrun", "notarytool", "log", identifier,
                *profile, folder / (label + "-log.json"))
            raise RuntimeError(label + " notarization was not accepted; see the notarization diagnostic artifact")
        if time.monotonic() >= deadline:
            raise RuntimeError(label + " is still pending at Apple; submission ID is retained in the diagnostic artifact")
        time.sleep(30)


def download(archive, url):
    with urllib.request.urlopen(url, timeout=60) as source, archive.open("wb") as target:
        total = 0
        while data := source.read(1024 * 1024):
            total += len(data)
            assert total <= MAX_ARCHIVE_BYTES
            target.write(data)


def prepare_runtime(source, source_bytes, profile, team, identity, tag, work):
    upstream = prepare()
    folder = work / "kit"
    assert not folder.exists(), "existing signed runtime staging was preserved"
    source_sha = hashlib.sha256(source_bytes).hexdigest()
    pinned = ROOT / "Config/TryOmarchySignedRuntime.lock.json"
    signature = upstream / "scripts/kit_signature.py"
    if pinned.exists():
        lock = json.loads(pinned.read_bytes())
        validate_signed_lock(lock, source, source_sha, team)
        folder.mkdir()
        download(folder / "TryOmarchyKit.zip", "https://github.com/reactive-org/omarchy-vm-manager/releases/download/" + lock["artifactTag"] + "/TryOmarchySignedKit.zip")
        archive_manifest(folder / "TryOmarchyKit.zip", lock)
        run("Extract pinned signed runtime", "ditto", "-x", "-k", folder / "TryOmarchyKit.zip", folder)
        verify(folder, lock)
    else:
        original = ROOT / ("VendorArtifacts/patched-" + source["patchCommit"][:12]) / "TryOmarchyKit.bundle"
        run("Build signed runtime through upstream kit pipeline", upstream / "macos/build-kit.sh", "--app", original,
            "--output", folder, "--sign-identity", identity)
        notarize(folder / "TryOmarchyKit.zip", profile, "runtime")
        run("Staple runtime ticket through upstream pipeline", "python3", signature, "staple", folder / "TryOmarchyKit.bundle")
        (folder / "TryOmarchyKit.zip").unlink()
        run("Archive notarized runtime", "ditto", "-c", "-k", "--keepParent", folder / "TryOmarchyKit.bundle", folder / "TryOmarchyKit.zip")
        signed_files = inventory(folder / "TryOmarchyKit.bundle")
        sys.path.insert(0, str(upstream / "scripts"))
        import kit_signature
        code_paths = {path.relative_to(original).as_posix() for path in kit_signature.code_files(kit_signature.layout(original))}
        validate_payload(source["files"], signed_files, code_paths)
        value = json.loads((folder / "TryOmarchyKit.json").read_bytes())
        lock = dict(source, kitSHA256=digest(folder / "TryOmarchyKit.zip"), files=signed_files,
                    buildDate=value["buildDate"], signingTeamID=team, sourceKitSHA256=source["kitSHA256"],
                    sourceLockSHA256=source_sha, artifactTag=tag,
                    composition=source["composition"] + "; Developer ID signed/notarized variant through upstream kit pipeline")
        validate_signed_lock(lock, source, source_sha, team)
        archive_manifest(folder / "TryOmarchyKit.zip", lock)
    run("Verify every runtime signature, entitlement, network pin and notarization", "python3", signature,
        "verify", "--team", team, "--require-notarization", folder / "TryOmarchyKit.bundle")
    lock_path = work / "TryOmarchySignedRuntime.lock.json"
    lock_path.write_text(json.dumps(lock, indent=2, sort_keys=True) + "\n")
    return lock, lock_path, folder


def release():
    import plistlib
    version = plistlib.loads((ROOT / "App/Info.plist").read_bytes())["CFBundleShortVersionString"]
    tag = validate_tag(os.environ.get("RELEASE_TAG", ""), version)
    source_bytes = (ROOT / "Config/TryOmarchyRuntime.lock.json").read_bytes()
    source = json.loads(source_bytes)
    work = ROOT / ".build/signed-release"
    work.mkdir(parents=True, exist_ok=True)
    with provisioning_profile() as keychain_profile, credentials() as (profile, team, identity):
        lock, lock_path, folder = prepare_runtime(source, source_bytes, profile, team, identity, tag, work)
        pin = ROOT / "Sources/OmarchyVMManagerCore/RuntimePin.swift"
        signed_pin = ROOT / "Sources/OmarchyVMManagerCore/SignedBuildPin.swift"
        original_pin = pin.read_bytes()
        original_signed_pin = signed_pin.read_bytes()
        try:
            pin.write_text("// CI-generated signed-prerelease provenance; development pin is restored after packaging.\npublic enum RuntimePin {\n" +
                           f'    public static let lockSHA256 = "{digest(lock_path)}"\n}}\n')
            signed_pin.write_text("// CI-generated signed-prerelease origin.\nenum SignedBuildPin {\n" +
                                  "\n".join(f'    static let {key} = "{value}"' for key, value in {
                                      "signingTeamID": team, "sourceKitSHA256": source["kitSHA256"],
                                      "sourceLockSHA256": digest(ROOT / "Config/TryOmarchyRuntime.lock.json")}.items()) + "\n}\n")
            run("Compile optimized signed-prerelease executables", "make", "build-signed")
            run("Assemble and sign app inside out", "python3", ROOT / "Scripts/assemble_app.py", "--signed-prerelease",
                "--preserve-runtime-signatures", "--runtime-lock", lock_path, "--runtime-directory", folder,
                "--output-directory", ROOT / "dist/prerelease-staging", "--keychain-profile", keychain_profile)
            app = ROOT / "dist/prerelease-staging/Omarchy VM Manager.app"
            run("Verify signed bundle without host/guest launch", ROOT / "Scripts/verify-app.sh", "--bundle-only", app, lock_path)
            submission_archive = work / "notary-app.zip"
            run("Archive app for Apple submission", "ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, submission_archive)
            status = notarize(submission_archive, profile, "app")
            run("Staple app ticket", "xcrun", "stapler", "staple", app)
            run("Verify notarized app and Gatekeeper acceptance", "python3", ROOT / "Scripts/verify_signed_app.py", app)
            run("Package and verify the final notarized ZIP", "python3", ROOT / "Scripts/package_prerelease.py", "--signed", "--runtime-lock", lock_path)
            output = ROOT / "dist/prerelease"
            archive = output / "TryOmarchySignedKit.zip"
            shutil.copy2(folder / "TryOmarchyKit.zip", archive)
            archive.with_suffix(".zip.sha256").write_text(digest(archive) + "  " + archive.name + "\n")
            shutil.copy2(lock_path, output / lock_path.name)
            (output / "SourceRuntime.lock.json").write_bytes(source_bytes)
            (output / "Notarization.json").write_text(json.dumps({"app": status, "runtimeArchiveSHA256": lock["kitSHA256"],
                "sourceLockSHA256": lock["sourceLockSHA256"], "sourceKitSHA256": lock["sourceKitSHA256"]}, indent=2) + "\n")
        finally:
            pin.write_bytes(original_pin)
            signed_pin.write_bytes(original_signed_pin)
    assert (ROOT / "Config/TryOmarchyRuntime.lock.json").read_bytes() == source_bytes
    print("Signed prerelease verified and ready to publish; development runtime/pin preserved", flush=True)


if __name__ == "__main__":
    try:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument("--check-submission", help="Read an existing Apple submission in CI without uploading or signing")
        args = parser.parse_args()
        if args.check_submission:
            check_submission(args.check_submission)
        else:
            release()
    except Exception as error:
        sys.exit(redact(str(error)))
