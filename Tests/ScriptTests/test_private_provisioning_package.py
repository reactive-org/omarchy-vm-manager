import contextlib
import datetime
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Scripts"))
import private_provisioning_package as private

MAGIC = b"SIMULATION_ONLY_NOT_MACHO\n"
TEAM = "ABC1234567"
PROFILE = b"SIMULATION_ONLY_NOT_AN_APPLE_PROFILE"


def put(path, data, executable=False):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    private.write(path, data, executable)


class Fixture:
    def __init__(self, root):
        self.root = root
        self.candidate = root / "candidate"; self.candidate.mkdir(mode=0o700)
        self.app = self.candidate / "Omarchy VM Manager.app"
        self.source_kit = {
            "Contents/MacOS/omarchy-vm-helper": MAGIC + b"synthetic runtime\n",
            "Contents/Resources/firmware.fd": b"synthetic immutable firmware",
        }
        self.runtime = {"format": 1, "kitSHA256": private.digest(b"synthetic source archive"),
                        "patchCommit": "b" * 40, "focusAwareClipboard": True, "managedSSHVersion": 1,
                        "buildDate": "2026-11-01T00:00:00Z", "composition": "synthetic source",
                        "files": {n: private.digest(b) for n, b in self.source_kit.items()}}
        self.engine = b'{"api":1,"synthetic":true}\n'
        resource = "Sources/DevVMProvisioningCore/Resources/"
        self.lock = {"format": 1, "setupAPI": 1, "package": "Vendor/dev-vm",
                     "resourceBundle": private.package.BUNDLE, "launcher": private.package.EXECUTABLES[1],
                     "engineSHA256": private.digest(self.engine),
                     "files": {resource + "engine-identity.json": private.digest(self.engine),
                               resource + "Provisioning/example.txt": private.digest(b"fixed resource")}}
        resources = self.app / "Contents/Resources"
        put(resources / "DevVMProvisioning.lock.json", private.canonical(self.lock))
        put(resources / "TryOmarchyRuntime.lock.json", private.canonical(self.runtime))
        bundle = resources / private.package.BUNDLE / "Resources"
        put(bundle / "engine-identity.json", self.engine)
        put(bundle / "Provisioning/example.txt", b"fixed resource")
        for name, data in self.source_kit.items():
            put(self.app / "Contents/Helpers/TryOmarchyKit.bundle" / name, data, "MacOS" in name)
        for name in (private.MAIN, *private.CHILDREN):
            put(self.app / "Contents/MacOS" / name, MAGIC + name.encode() + b" unsigned\n", True)
        put(self.app / "Contents/Info.plist", plistlib.dumps({"CFBundleIdentifier": private.BUNDLE_ID,
                                                           "CFBundleExecutable": private.MAIN}))
        self.scope = {"vmID": "11111111-2222-4333-8444-555555555555",
                      "root": "/private/tmp/synthetic-never-created/Omarchy VM Manager/VMs/11111111-2222-4333-8444-555555555555",
                      "device": 1, "inode": 2, "markerSHA256": "c" * 64,
                      "approvalID": "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE", "sourceCommit": "a" * 40,
                      "purpose": "Candidate preparation only; no guest execution authorized"}
        self.scope["scopeSHA256"] = private.digest(private.canonical(self.scope))
        receipt = {k: self.scope[k] for k in ("vmID", "root", "device", "inode", "markerSHA256")}
        receipt_raw = private.canonical(receipt)
        self.scope["receiptSHA256"] = private.digest(receipt_raw)
        put(self.candidate / "root-preparation-receipt.json", receipt_raw)
        put(self.candidate / "scope.json", private.canonical(self.scope))
        profile_pin = private.canonical({"format": 1, "bundleID": private.BUNDLE_ID,
                                         "profileSHA256": private.digest(PROFILE)})
        archive = io.BytesIO()
        with tarfile.open(fileobj=archive, mode="w:") as tar:
            entry = tarfile.TarInfo("Config/TouchIDProfile.lock.json"); entry.size = len(profile_pin)
            tar.addfile(entry, io.BytesIO(profile_pin))
        put(self.candidate / "base-source.tar", archive.getvalue())
        overlay = b"synthetic reviewed overlay; no source is executed in this fixture\n"
        put(self.candidate / "candidate-overlay.patch", overlay)
        self.source = {"format": 1, "baseCommit": self.scope["sourceCommit"], "scopeSHA256": self.scope["scopeSHA256"],
                       "baseArchiveSHA256": private.digest(archive.getvalue()), "overlaySHA256": private.digest(overlay),
                       "ordinaryGateUnchanged": True, "productionSigningPolicyUnchanged": True,
                       "overlayFiles": [{"path": n, "beforeSHA256": "d" * 64, "afterSHA256": "e" * 64}
                                        for n in sorted(private.OVERLAY_PATHS)]}
        put(self.candidate / "source-evidence.json", private.canonical(self.source))
        self.manifest = {"format": 1, "scope": self.scope, "source": self.source, "simulationFixture": True,
                         "status": "PREPARED_OFFLINE_NOT_AUTHORIZED_FOR_GUEST_RUN", "guestAcceptance": "NOT_RUN",
                         "appInventory": private.tree(self.app),
                         "packageLockSHA256": private.digest(private.canonical(self.lock)),
                         "runtimeLockSHA256": private.digest(private.canonical(self.runtime)),
                         "runtimeKitSHA256": self.runtime["kitSHA256"], "engineSHA256": private.digest(self.engine)}
        put(self.candidate / "candidate.json", private.canonical(self.manifest))
        self.identity = private.ReviewedIdentity(private.digest(private.read(self.candidate / "candidate.json")),
                                                 self.scope["scopeSHA256"])
        self.handoff = root / "handoff"

    def prepare(self):
        return private.prepare_handoff(self.candidate, self.handoff, self.identity)


class FakeSigner:
    """Text fixture signatures only. No subprocess, credentials or publishing API."""
    mode = "SIMULATION_ONLY"

    def __init__(self, fault=None):
        self.fault = fault; self.calls = []; self.signed = set(); self.entitlements = None

    def profile(self):
        self.calls.append("profile")
        if self.fault == "exception": raise RuntimeError("synthetic-password-must-never-be-logged")
        profile = {"TeamIdentifier": [TEAM], "Platform": ["OSX"], "ProvisionsAllDevices": True,
                   "DeveloperCertificates": [b"synthetic public certificate"],
                   "ExpirationDate": datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=90),
                   "Entitlements": {"com.apple.application-identifier": TEAM + "." + private.BUNDLE_ID,
                                    "com.apple.developer.team-identifier": TEAM}}
        if self.fault == "wrong-profile-team": profile["TeamIdentifier"] = ["ZZZ1234567"]
        if self.fault == "expired-profile": profile["ExpirationDate"] = datetime.datetime(2000, 1, 1)
        return TEAM, b"changed-profile" if self.fault == "profile-hash" else PROFILE, profile

    def runtime(self, output, handoff, team):
        self.calls.append("runtime")
        original_raw = private.read(handoff / "inputs/Config/TryOmarchyRuntime.lock.json")
        original = private.decode(original_raw)
        source = handoff / "inputs/TryOmarchyKit.bundle"
        target = output / "signed-runtime.bundle"
        private.copy_tree(source, target, original["files"])
        code = target / "Contents/MacOS/omarchy-vm-helper"
        code.write_bytes(code.read_bytes() + b"SIMULATED signature\n")
        if self.fault == "firmware": (target / "Contents/Resources/firmware.fd").write_bytes(b"tampered")
        lock = dict(original, kitSHA256="f" * 64, signingTeamID=team, sourceKitSHA256=original["kitSHA256"],
                    sourceLockSHA256=private.digest(original_raw), artifactTag="v0.0.0-dev.1", files=private.tree(target))
        if self.fault == "runtime-origin": lock["sourceKitSHA256"] = "0" * 64
        if self.fault == "runtime-capability": lock["managedSSHVersion"] = 2
        code = {"Contents/MacOS/omarchy-vm-helper"}
        if self.fault == "firmware-as-code": code.add("Contents/Resources/firmware.fd")
        if self.fault == "runtime-input-tamper":
            (handoff / "inputs/Config/TryOmarchyRuntime.lock.json").write_bytes(b"changed frozen lock")
        return lock, code

    def rebuild(self, output, handoff, request, runtime, team):
        self.calls.append("rebuild")
        app = output / "Simulation.app"
        resources = app / "Contents/Resources"; resources.mkdir(parents=True, mode=0o700)
        put(app / "Contents/Info.plist", plistlib.dumps({"CFBundleIdentifier": private.BUNDLE_ID,
                                                       "CFBundleExecutable": private.MAIN}))
        for name in (private.MAIN, *private.CHILDREN):
            body = private.canonical({"role": name, "scopeSHA256": request["scopeSHA256"], "mode": "SIGNED_PRERELEASE"})
            put(app / "Contents/MacOS" / name, MAGIC + body + b"\n", True)
        private.copy_tree(handoff / "inputs" / private.package.BUNDLE, resources / private.package.BUNDLE,
                          private.tree(handoff / "inputs" / private.package.BUNDLE))
        put(resources / "DevVMProvisioning.lock.json", private.read(handoff / "inputs/Config/DevVMProvisioning.lock.json"))
        put(resources / "TryOmarchyRuntime.lock.json", private.canonical(runtime))
        original_raw = private.read(handoff / "inputs/Config/TryOmarchyRuntime.lock.json")
        pins = {"runtimeLockSHA256": private.digest(private.canonical(runtime)), "team": team,
                "sourceKitSHA256": private.decode(original_raw)["kitSHA256"], "sourceLockSHA256": private.digest(original_raw)}
        if self.fault == "build-pins": pins["team"] = "ZZZ1234567"
        put(resources / "PrivateSigningBuildPins.json", private.canonical(pins))
        (app / "Contents/Helpers").mkdir(mode=0o700)
        private.copy_tree(output / "signed-runtime.bundle", app / "Contents/Helpers/TryOmarchyKit.bundle", runtime["files"])
        build = {"mode": "SIGNED_PRERELEASE", "sourceCommit": request["sourceCommit"], "overlaySHA256": request["overlaySHA256"],
                 "managerScopeSHA256": request["scopeSHA256"], "helperScopeSHA256": request["scopeSHA256"]}
        if self.fault in ("managerScopeSHA256", "helperScopeSHA256", "mode", "overlaySHA256"):
            build[self.fault] = "changed"
        if self.fault == "real-binary": (app / "Contents/MacOS" / private.MAIN).write_bytes(b"\xcf\xfa\xed\xfe")
        return app, build

    def sign_children(self, app, team):
        self.calls.append("sign_children")
        for name in private.CHILDREN:
            path = app / "Contents/MacOS" / name
            path.write_bytes(path.read_bytes() + b"SIMULATED child signature\n")
            self.signed.add(name)
        if self.fault == "sign-children": raise RuntimeError("synthetic-password-must-never-be-logged")
        if self.fault == "late-runtime-tamper":
            (app / "Contents/Helpers/TryOmarchyKit.bundle/Contents/Resources/firmware.fd").write_bytes(b"late tamper")
        if self.fault == "late-profile-tamper":
            (app / "Contents/embedded.provisionprofile").write_bytes(b"late tamper")
        if self.fault == "late-compiled-scope":
            path = app / "Contents/MacOS/OmarchyVMProvisioningHelper"
            data = path.read_bytes(); body = private.decode(data.split(b"\n", 2)[1])
            body["scopeSHA256"] = "0" * 64
            path.write_bytes(MAGIC + private.canonical(body) + b"\n")

    def sign_app(self, app, team, entitlements):
        self.calls.append("sign_app"); self.entitlements = entitlements
        seal = private.decode(private.read(app / "Contents/Resources/ProvisioningDistribution.json"))
        for name in private.package.EXECUTABLES:
            assert seal["executables"][name] == private.digest(private.read(app / "Contents/MacOS" / name))
        code = app / "Contents/MacOS" / private.MAIN
        code.write_bytes(code.read_bytes() + b"SIMULATED outer signature\n")
        put(app / "Contents/_CodeSignature/CodeResources", b"SIMULATION ONLY outer signature")
        if self.fault == "late-child-tamper":
            child = app / "Contents/MacOS/OmarchyVMProvisioningHelper"
            child.write_bytes(child.read_bytes() + b"late tamper")
        if self.fault == "late-resource-tamper":
            (app / "Contents/Resources" / private.package.BUNDLE / "Resources/Provisioning/example.txt").write_bytes(b"changed")

    def verify(self, app, team):
        self.calls.append("verify")
        if self.fault == "verification-mutation":
            path = app / "Contents/MacOS/OmarchyVMProvisioningHelper"
            path.write_bytes(path.read_bytes() + b"verification changed signed bytes")
        evidence = {name: {"mode": "SIMULATED_NOT_A_CODE_SIGNATURE", "team": team,
                           "hardenedRuntime": True, "timestamp": True,
                           "entitlements": self.entitlements if name == "app" else {}}
                    for name in ("app", *private.CHILDREN)}
        if self.fault == "signature-team": evidence["OmarchyVMProvisioningHelper"]["team"] = "ZZZ1234567"
        if self.fault == "signature-timestamp": evidence["app"]["timestamp"] = False
        if self.fault == "child-keychain": evidence["omarchy-vm"]["entitlements"] = {"keychain-access-groups": ["wrong"]}
        if self.fault == "second-verify" and self.calls.count("verify") == 2:
            raise RuntimeError("synthetic-password-must-never-be-logged")
        return evidence


class PrivateProvisioningTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="private-packaging-fixture-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        environment = patch.dict(os.environ, {"GITHUB_REF": "", "GITHUB_EVENT_NAME": ""})
        environment.start(); self.addCleanup(environment.stop)
        self.fixture = Fixture(self.root)
        # A regression must fail rather than touch any real signer, tool, network,
        # credentials or release process. The fake pipeline uses file IO only.
        for name in ("subprocess.run", "subprocess.check_output", "socket.socket"):
            guard = patch(name, side_effect=AssertionError("External operation prohibited in private fixtures"))
            guard.start(); self.addCleanup(guard.stop)

    def run_pipeline(self, signer=None, output="result"):
        if not self.fixture.handoff.exists(): self.expected = self.fixture.prepare()
        return private.package_simulation(self.fixture.handoff, self.root / output, self.expected, signer or FakeSigner())

    def test_complete_sequence_retains_scope_uses_post_sign_seal_and_private_roundtrip(self):
        signer = FakeSigner(); result = self.run_pipeline(signer)
        self.assertEqual(signer.calls, ["profile", "runtime", "rebuild", "sign_children", "sign_app", "verify", "verify"])
        self.assertEqual(result["scopeSHA256"], self.fixture.scope["scopeSHA256"])
        self.assertEqual(result["status"], "SIMULATION_ONLY_NOT_SIGNED_OR_LAUNCH_READY")
        self.assertFalse(result["productionSigningVerified"]); self.assertFalse(result["guestRunAuthorized"])
        self.assertEqual(result["publication"], "forbidden")
        self.assertEqual(private.tree(self.root / "result/Simulation.app"), private.tree(self.root / "result/roundtrip/Simulation.app"))
        self.assertFalse(Path(self.fixture.scope["root"]).exists())
        self.assertEqual(stat.S_IMODE((self.root / "result").stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((self.root / "result/SIMULATION-ONLY-NOT-SIGNED.zip").stat().st_mode), 0o600)
        self.assertLess(result["events"].index("sign-children"), result["events"].index("seal-post-sign-helper-digests"))
        self.assertLess(result["events"].index("seal-post-sign-helper-digests"), result["events"].index("sign-outer-app"))

    def test_frozen_inputs_survive_source_edits_without_rebinding(self):
        self.expected = self.fixture.prepare()
        (self.fixture.candidate / "scope.json").write_bytes(b"changed original")
        result = self.run_pipeline()
        self.assertEqual(result["scopeSHA256"], self.fixture.scope["scopeSHA256"])

    def test_reviewed_binding_and_tampered_candidate_are_refused_before_output(self):
        wrong = private.ReviewedIdentity("0" * 64, self.fixture.scope["scopeSHA256"])
        with self.assertRaises(private.Refused): private.prepare_handoff(self.fixture.candidate, self.fixture.handoff, wrong)
        self.assertFalse(self.fixture.handoff.exists())
        (self.fixture.app / "Contents/MacOS" / private.MAIN).write_bytes(b"tamper")
        with self.assertRaises(private.Refused): self.fixture.prepare()
        self.assertFalse(self.fixture.handoff.exists())

    def test_frozen_input_tamper_or_changed_request_is_not_a_new_approval(self):
        self.expected = self.fixture.prepare(); signer = FakeSigner()
        (self.fixture.handoff / "inputs/scope.json").write_bytes(b"changed")
        with self.assertRaises(private.Refused): self.run_pipeline(signer)
        self.assertEqual(signer.calls, []); self.assertFalse((self.root / "result").exists())
        request = self.fixture.handoff / "request.json"
        request.write_bytes(request.read_bytes() + b" ")
        with self.assertRaises(private.Refused): private.load_handoff(self.fixture.handoff, self.expected)

    def test_failure_marker_and_changed_checksum_prevent_use_of_complete_handoff(self):
        self.expected = self.fixture.prepare()
        private.write_json(self.fixture.handoff / "failure.json", {"status": "interrupted capture"})
        with self.assertRaisesRegex(private.Refused, "failed-handoff-refused"):
            private.load_handoff(self.fixture.handoff, self.expected)
        (self.fixture.handoff / "failure.json").unlink()
        (self.fixture.handoff / "request.sha256.json").write_bytes(private.canonical({"sha256": "0" * 64}))
        with self.assertRaisesRegex(private.Refused, "handoff-checksum-changed"):
            private.load_handoff(self.fixture.handoff, self.expected)

    def test_real_candidate_cannot_enter_simulated_signing(self):
        self.fixture.manifest.pop("simulationFixture")
        (self.fixture.candidate / "candidate.json").write_bytes(private.canonical(self.fixture.manifest))
        self.fixture.identity = private.ReviewedIdentity(private.digest(private.read(self.fixture.candidate / "candidate.json")), self.fixture.scope["scopeSHA256"])
        self.expected = self.fixture.prepare(); signer = FakeSigner()
        with self.assertRaisesRegex(private.Refused, "real-signing-unavailable"): self.run_pipeline(signer)
        self.assertEqual(signer.calls, []); self.assertFalse((self.root / "result").exists())

    def test_scope_rebuild_profile_runtime_and_signature_failures_are_closed(self):
        self.expected = self.fixture.prepare()
        faults = ["wrong-profile-team", "expired-profile", "profile-hash", "runtime-origin", "runtime-capability", "firmware", "firmware-as-code",
                  "managerScopeSHA256", "helperScopeSHA256", "mode", "overlaySHA256", "build-pins", "real-binary",
                  "late-child-tamper", "late-resource-tamper", "late-runtime-tamper", "late-profile-tamper", "late-compiled-scope", "verification-mutation",
                  "signature-team", "signature-timestamp", "child-keychain"]
        for index, fault in enumerate(faults):
            with self.subTest(fault=fault), self.assertRaisesRegex(private.Refused, "private-simulation-failed"):
                self.run_pipeline(FakeSigner(fault), "failure-" + str(index))
            folder = self.root / ("failure-" + str(index))
            self.assertTrue((folder / "failure.json").exists())
            self.assertFalse((folder / "simulation.json").exists())

    def test_failures_preserve_private_output_redact_backend_errors_and_do_not_resume(self):
        self.expected = self.fixture.prepare()
        for index, fault in enumerate(("exception", "sign-children", "second-verify")):
            output = "interrupted-" + str(index)
            with self.assertRaises(private.Refused) as error: self.run_pipeline(FakeSigner(fault), output)
            folder = self.root / output
            self.assertNotIn("synthetic-password", str(error.exception))
            self.assertNotIn("synthetic-password", (folder / "failure.json").read_text())
            signer = FakeSigner()
            with self.assertRaisesRegex(private.Refused, "existing-output-preserved"): self.run_pipeline(signer, output)
            self.assertEqual(signer.calls, [])

    def test_private_output_symlink_existing_and_source_overlap_are_refused(self):
        public = self.root / "public"; public.mkdir(mode=0o755)
        with self.assertRaises(private.Refused): private.prepare_handoff(self.fixture.candidate, public / "out", self.fixture.identity)
        (self.root / "link").symlink_to(self.fixture.candidate, target_is_directory=True)
        with self.assertRaises(private.Refused): private.prepare_handoff(self.root / "link", self.fixture.handoff, self.fixture.identity)
        with self.assertRaises(private.Refused): private.prepare_handoff(self.fixture.candidate, self.fixture.candidate / "out", self.fixture.identity)

    def test_guest_namespace_release_outputs_and_publication_context_are_refused(self):
        for components in (("Omarchy VM Manager", "VMs"), ("dist", "prerelease"),
                           ("dist", "prerelease-staging"), (".build", "signed-release"), (".build", "notarization"),
                           ("OMARCHY VM MANAGER", "vms"), ("DIST", "PRERELEASE")):
            parent = self.root.joinpath(*components)
            parent.mkdir(parents=True, mode=0o700, exist_ok=True)
            with self.assertRaises(private.Refused): private.new_directory(parent / "private-output")
            self.assertFalse((parent / "private-output").exists())
        with patch.dict(os.environ, {"GITHUB_EVENT_NAME": "release"}), self.assertRaisesRegex(private.Refused, "publishing-context-refused"):
            self.fixture.prepare()
        self.assertFalse(self.fixture.handoff.exists())

    def test_interrupted_capture_preserves_private_failure_without_secret_diagnostics(self):
        with patch.object(private, "copy_tree", side_effect=OSError("synthetic-secret-do-not-print")):
            with self.assertRaisesRegex(private.Refused, "private-handoff-capture-failed"):
                self.fixture.prepare()
        failure = self.fixture.handoff / "failure.json"
        self.assertTrue(failure.exists()); self.assertNotIn("synthetic-secret", failure.read_text())
        self.assertEqual(stat.S_IMODE(failure.stat().st_mode), 0o600)
        with self.assertRaisesRegex(private.Refused, "existing-output-preserved"):
            self.fixture.prepare()

    def test_runtime_input_tamper_is_caught_before_rebuild(self):
        signer = FakeSigner("runtime-input-tamper")
        with self.assertRaises(private.Refused): self.run_pipeline(signer)
        self.assertEqual(signer.calls, ["profile", "runtime"])

    def test_archive_reverification_detects_tampered_extraction(self):
        extract = private.extract_local
        def altered(archive, destination):
            extract(archive, destination)
            code = destination / "Simulation.app/Contents/MacOS/OmarchyVMProvisioningHelper"
            code.write_bytes(code.read_bytes() + b"tampered extraction")
        signer = FakeSigner()
        with patch.object(private, "extract_local", side_effect=altered), self.assertRaises(private.Refused):
            self.run_pipeline(signer)
        self.assertEqual(signer.calls.count("verify"), 1)

    def test_invalid_cli_does_not_echo_unrecognized_signing_or_secret_arguments(self):
        output = io.StringIO()
        with patch.object(sys, "argv", ["private-package", "sign", "synthetic-secret-do-not-print"]), contextlib.redirect_stderr(output):
            self.assertEqual(private.main(), 1)
        self.assertNotIn("synthetic-secret", output.getvalue())

    def test_tar_links_traversal_duplicates_and_disk_images_are_refused(self):
        for kind in ("link", "traversal", "duplicate", "disk", "uppercase-disk", "partial-disk"):
            output = io.BytesIO()
            with tarfile.open(fileobj=output, mode="w:") as tar:
                name = {"traversal": "../escape", "disk": "disk.img", "uppercase-disk": "DISK.IMG",
                        "partial-disk": "factory.img.zst.download"}.get(kind, "Config/TouchIDProfile.lock.json")
                entry = tarfile.TarInfo(name)
                if kind == "link": entry.type = tarfile.SYMTYPE; entry.linkname = "/etc/passwd"
                tar.addfile(entry)
                if kind == "duplicate": tar.addfile(entry)
            with self.subTest(kind=kind), self.assertRaises((private.Refused, ValueError)):
                private.archive_profile_pin(output.getvalue())

    def test_archive_traversal_symlink_and_duplicates_are_refused(self):
        for index, name in enumerate(("../escape", "Simulation.app/link", "Simulation.app/duplicate")):
            archive = self.root / (str(index) + ".zip")
            with zipfile.ZipFile(archive, "w") as package:
                entry = zipfile.ZipInfo(name); entry.external_attr = (stat.S_IFLNK | 0o777) << 16
                if index != 1: entry.external_attr = (stat.S_IFREG | 0o600) << 16
                package.writestr(entry, b"fixture")
                if index == 2:
                    import warnings
                    with warnings.catch_warnings():
                        warnings.simplefilter("ignore"); package.writestr(entry, b"duplicate")
            with self.assertRaises(private.Refused): private.extract_local(archive, self.root / ("extract-" + str(index)))
        self.assertFalse((self.root / "escape").exists())

    def test_duplicate_scope_fields_and_invalid_or_retained_scope_are_refused(self):
        with self.assertRaises(private.Refused): private.decode(b'{"inode":1,"inode":2}')
        for key, value in (("inode", True), ("root", "/private/tmp/../escape"), ("vmID", "C7C2B381-E43C-4A5A-8246-4314596B4C0A")):
            with self.subTest(key=key), self.assertRaises((private.Refused, ValueError)):
                private.validate_scope(dict(self.fixture.scope, **{key: value}))

    def test_cli_prepares_only_and_refuses_publishing_context_without_logs_or_keys(self):
        identity = self.root / "reviewed.json"
        private.write_json(identity, {"candidateSHA256": self.fixture.identity.candidateSHA256,
                                      "scopeSHA256": self.fixture.identity.scopeSHA256})
        args = ["private-package", "prepare", "--candidate", str(self.fixture.candidate), "--output", str(self.fixture.handoff), "--reviewed-identity", str(identity)]
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.object(sys, "argv", args), patch.dict(os.environ, {"GITHUB_REF": "refs/tags/v0.0.0-dev.1"}), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            self.assertEqual(private.main(), 1)
        self.assertFalse(self.fixture.handoff.exists())
        self.assertNotIn(str(self.root), stderr.getvalue())
        with patch.object(sys, "argv", args), patch.dict(os.environ, {"GITHUB_REF": "", "GITHUB_EVENT_NAME": ""}), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            self.assertEqual(private.main(), 0)
        self.assertIn("PRIVATE_REQUEST_PREPARED_NOT_SIGNED", stdout.getvalue())
        self.assertNotIn(self.fixture.scope["scopeSHA256"], stdout.getvalue())
        self.assertNotIn("publish", dir(FakeSigner()))


if __name__ == "__main__":
    unittest.main()
