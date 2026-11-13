"""Real adapter, fake SDK/build/signing processes only; never uses host tools."""
import io
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Scripts"))
import private_provisioning_package as private
import private_provisioning_signer as signer
from test_private_provisioning_package import Fixture, FakeSigner, TEAM, PROFILE, put
from resource_signature_fixtures import SIGNATURE_RECORDS, add_signature_records

MACHO_FIXTURE = b"\xcf\xfa\xed\xfePROCESS_RUNNER_FIXTURE_NOT_EXECUTABLE\n"
PARSER_REVISION = "1" * 40
LITERAL = "Sources/OmarchyVMManagerCore/PrivateM6Acceptance.swift"


def replace(path, data):
    if path.exists(): path.write_bytes(data)
    else: put(path, data)


class CommandFixture(Fixture):
    def __init__(self, root, signed_resources=False):
        super().__init__(root)
        self.source_kit["Contents/MacOS/omarchy-vm-helper"] = MACHO_FIXTURE + b"runtime"
        self.runtime["files"] = {n: private.digest(b) for n, b in self.source_kit.items()}
        for name, data in self.source_kit.items():
            replace(self.app / "Contents/Helpers/TryOmarchyKit.bundle" / name, data)
        replace(self.app / "Contents/Resources/TryOmarchyRuntime.lock.json", private.canonical(self.runtime))
        self.base = {"Config/TouchIDProfile.lock.json": private.canonical({"format": 1, "bundleID": private.BUNDLE_ID,
                      "profileSHA256": private.digest(PROFILE)}),
                     "Config/TryOmarchyClipboardPatch.json": private.canonical({"commit": self.runtime["patchCommit"]}),
                     "Package.resolved": private.canonical({"pins": [{"identity": "tomldecoder",
                       "location": "https://example.invalid/TOMLDecoder.git", "state": {"revision": PARSER_REVISION}}]}),
                     "Sources/OmarchyVMManagerCore/RuntimePin.swift": b"original runtime pin",
                     "Sources/OmarchyVMManagerCore/SignedBuildPin.swift": b"original signed pin",
                     "App/OmarchyVMManager.entitlements": plistlib.dumps({}),
                     "LICENSE": b"fixture license", "THIRD_PARTY_NOTICES.md": b"fixture notices"}
        for stem in ("OmarchyVMManager", "OmarchyGuest"):
            for ext in ("icns", "png"): self.base["App/Assets/" + stem + "." + ext] = b"fixture icon"
        self.overlay = {}
        for name in private.OVERLAY_PATHS:
            if name == LITERAL:
                values = "\n".join(str(self.scope[k]) for k in ("vmID", "root", "device", "inode", "markerSHA256", "scopeSHA256"))
                self.overlay[name] = (values + '\nfatalError("invalid scope")\npublic enum PrivateM6CandidateInspection {\n'
                                      + signer.OLD_INSPECTION + '"productionSigningAdmission": "BLOCKED_EXPECTED_AD_HOC"\n}\n').encode()
            else:
                self.base[name] = b"original fixture source\n"
                self.overlay[name] = b"reviewed fixture overlay\n"
        self.overlay["App/Info.plist"] = private.read(self.app / "Contents/Info.plist")
        archive = io.BytesIO()
        with tarfile.open(fileobj=archive, mode="w:") as tar:
            for name, data in sorted(self.base.items()):
                item = tarfile.TarInfo(name); item.size = len(data); tar.addfile(item, io.BytesIO(data))
        replace(self.candidate / "base-source.tar", archive.getvalue())
        self.source["baseArchiveSHA256"] = private.digest(archive.getvalue())
        self.source["overlayFiles"] = [{"path": n, "beforeSHA256": private.digest(self.base[n]) if n in self.base else None,
                                        "afterSHA256": private.digest(b)} for n, b in sorted(self.overlay.items())]
        replace(self.candidate / "source-evidence.json", private.canonical(self.source))
        if signed_resources:
            add_signature_records(self.app / "Contents/Resources" / private.package.BUNDLE)
        self.manifest.update(source=self.source, appInventory=private.tree(self.app),
                             runtimeLockSHA256=private.digest(private.canonical(self.runtime)))
        replace(self.candidate / "candidate.json", private.canonical(self.manifest))
        self.identity = private.ReviewedIdentity(private.digest(private.read(self.candidate / "candidate.json")), self.scope["scopeSHA256"])
        self.expected = self.prepare()
        material = root / "material"; material.mkdir(mode=0o700)
        put(material / "profile", PROFILE); put(material / "isolated.keychain-db", b"NOT A REAL KEYCHAIN")
        self.runtime_dir = material / "runtime"; self.runtime_dir.mkdir(mode=0o700)
        for name, data in self.source_kit.items():
            put(self.runtime_dir / "TryOmarchyKit.bundle" / name, data + (b"FAKE SIGNATURE" if "MacOS" in name else b""), "MacOS" in name)
        archive = b"FAKE RUNTIME ARCHIVE NOT FOR DISTRIBUTION"
        put(self.runtime_dir / "TryOmarchyKit.zip", archive)
        original_raw = private.read(self.handoff / "inputs/Config/TryOmarchyRuntime.lock.json")
        self.signed_lock = dict(self.runtime, kitSHA256=private.digest(archive), signingTeamID=TEAM,
                                sourceKitSHA256=self.runtime["kitSHA256"], sourceLockSHA256=private.digest(original_raw),
                                artifactTag="v0.0.0-dev.1", files=private.tree(self.runtime_dir / "TryOmarchyKit.bundle"))
        put(self.runtime_dir / "TryOmarchySignedRuntime.lock.json", private.canonical(self.signed_lock))
        self.upstream = material / "client"; self.upstream.mkdir(mode=0o700)
        put(self.upstream / "THIRD_PARTY_NOTICES.md", b"upstream fixture notices")
        self.parser = material / "parser"; self.parser.mkdir(mode=0o700)
        self.material = signer.Material(TEAM, "Developer ID Application: Fixture Only (" + TEAM + ")",
                                       material / "profile", material / "isolated.keychain-db", self.runtime_dir, self.upstream, self.parser)


class FakeCommands:
    test_double = True

    def __init__(self, fixture, fault=None):
        self.fixture, self.fault = fixture, fault
        self.commands = []; self.authorizations = []; self.entitlements = None

    def authorize(self, *bindings): self.authorizations.append(bindings)

    def run(self, command):
        self.commands.append(command)
        stage, args, cwd = command.stage, command.argv, command.cwd
        fixture = self.fixture
        if self.fault == stage: return signer.Result(1, b"", b"synthetic-password-do-not-log")
        if self.fault == "oversize": return signer.Result(0, b"x" * (command.maximum + 1))
        if self.fault == "exception": raise TimeoutError("synthetic-password-do-not-log")
        if stage == "decode-pinned-profile":
            profile_fault = {"profile-team": "wrong-profile-team", "profile-expired": "expired-profile"}.get(self.fault)
            _, _, profile = FakeSigner(profile_fault).profile()
            return signer.Result(stdout=plistlib.dumps(profile))
        if stage == "apply-original-overlay":
            for name, data in fixture.overlay.items(): replace(cwd / name, data + (b"changed" if self.fault == "overlay-bytes" else b""))
        if stage == "check-original-overlay" and self.fault == "handoff-tamper":
            (fixture.handoff / "inputs/scope.json").write_bytes(b"tampered immutable scope")
        if stage.startswith(("check-local-", "verify-local-")):
            revision = PARSER_REVISION if stage.endswith("parser") else fixture.runtime["patchCommit"]
            return signer.Result(stdout=("0" * 40 if self.fault == "revision" else revision).encode())
        if stage.startswith("check-clean-"):
            return signer.Result(stdout=b" M changed" if self.fault == "dirty" else b"")
        if "-revision-" in stage:
            revision = PARSER_REVISION if stage.endswith("parser") else fixture.runtime["patchCommit"]
            return signer.Result(stdout=revision.encode())
        if "-clean-" in stage:
            return signer.Result(stdout=b" M changed" if self.fault == "dependency-drift" and stage.startswith("after-build") else b"")
        if stage.startswith("copy-local-"):
            shutil.copytree(Path(args[-2]), Path(args[-1]))
        if stage == "build-scoped-signed-prerelease":
            assert "-o" in args and "prepare-source" in args and "build-signed" in args
            assert "--disable-automatic-resolution" in args[-1]
            assert TEAM in private.read(cwd / "Sources/OmarchyVMManagerCore/SignedBuildPin.swift").decode()
            assert private.digest(private.canonical(fixture.signed_lock)) in private.read(cwd / "Sources/OmarchyVMManagerCore/RuntimePin.swift").decode()
            assert "#if SIGNED_PRERELEASE" in private.read(cwd / LITERAL).decode()
            if self.fault == "source-drift": (cwd / LITERAL).write_bytes(b"changed")
            if self.fault == "source-addition": put(cwd / "Sources/Injected.swift", b"unexpected source")
            self.binaries = cwd / ".build/products/release"
            self.launcher = cwd / ".build/provisioning-launcher/products/release"
            for name in (private.MAIN, *private.CHILDREN):
                destination = self.launcher if name == "dev-vm-process-host" else self.binaries
                scope = "0" * 64 if self.fault == "missing-scope" else fixture.scope["scopeSHA256"]
                put(destination / name, MACHO_FIXTURE + name.encode() + scope.encode(), True)
            put(self.binaries / "OmarchyVMManager_OmarchyVMManagerCore.bundle/fixture", b"core resource")
            # A fresh resource build emits payload, not the reference app's
            # inherited detached signature. No SDK or signer runs here.
            reference = fixture.handoff / "inputs" / private.package.BUNDLE
            for name in private.tree(reference):
                if name not in SIGNATURE_RECORDS:
                    put(self.binaries / private.package.BUNDLE / name, private.read(reference / name))
        if stage == "locate-built-binaries":
            return signer.Result(stdout=str(fixture.root if self.fault == "foreign-build" else self.binaries).encode())
        if stage == "locate-built-launcher": return signer.Result(stdout=str(self.launcher).encode())
        if stage.startswith("sign-child-"):
            assert "--timestamp" in args and args[args.index("--keychain") + 1] == str(fixture.material.keychain)
            path = Path(args[-1]); path.write_bytes(path.read_bytes() + b" FAKE CHILD SIGNATURE")
        if stage == "sign-outer-app":
            app = Path(args[-1]); contents = app / "Contents"
            private.package.verify(contents, root=fixture.handoff / "inputs")  # Post-child-sign hashes.
            self.entitlements = plistlib.loads(private.read(Path(args[args.index("--entitlements") + 1])))
            binary = contents / "MacOS" / private.MAIN
            binary.write_bytes(binary.read_bytes() + b" FAKE OUTER SIGNATURE")
            put(contents / "_CodeSignature/CodeResources", b"NOT A REAL SIGNATURE")
            if self.fault == "outer-child-tamper":
                path = contents / "MacOS/OmarchyVMProvisioningHelper"; path.write_bytes(path.read_bytes() + b"changed")
            if self.fault == "outer-runtime-tamper":
                (contents / "Helpers/TryOmarchyKit.bundle/Contents/Resources/firmware.fd").write_bytes(b"changed")
            if self.fault == "signed-scope-removed": binary.write_bytes(MACHO_FIXTURE + b"scope removed")
        if "-signature-" in stage:
            target = Path(args[-1]); binary = target / "Contents/MacOS" / private.MAIN if target.is_dir() else target
            team = "ZZZ1234567" if self.fault == "wrong-team" else TEAM
            flags = "none" if self.fault == "no-runtime" else "runtime"
            timestamp = "" if self.fault == "no-timestamp" else "Timestamp=Nov 4, 2026\n"
            signature = "Signature=adhoc\n" if self.fault == "adhoc" else ""
            details = ("Authority=Developer ID Application: Fixture Only\nAuthority=Developer ID Certification Authority\nAuthority=Apple Root CA\n"
                       + "TeamIdentifier=" + team + "\nCodeDirectory v=20500 size=42 flags=0x10000(" + flags + ") hashes=1+1\n"
                       + timestamp + signature + "CDHash=" + private.digest(private.read(binary))[:40] + "\n")
            return signer.Result(stderr=details.encode())
        if "-entitlements-" in stage:
            main = stage.endswith("-app") or stage.endswith("-" + private.MAIN)
            entitlements = self.entitlements if main else {}
            if self.fault == "child-keychain" and not main: entitlements = {"keychain-access-groups": ["wrong"]}
            return signer.Result(stdout=plistlib.dumps(entitlements))
        if stage.endswith("-profile-certificate"):
            prefix = next(a.split("=", 1)[1] for a in args if a.startswith("--extract-certificates="))
            put(Path(prefix + "0"), b"wrong certificate" if self.fault == "certificate" else b"synthetic public certificate")
        if stage.endswith("-offline-bundle-contract"):
            if self.fault == "verification-mutation":
                path = Path(args[0]); path.write_bytes(path.read_bytes() + b"changed by verifier")
            return signer.Result(stdout=private.canonical({"touchIDProtectedStorageAvailable": True,
                     "developmentKeychainCompatibility": False, "hostPreflightPerformed": False,
                     "vmLaunchEnabled": self.fault == "launch-contract"}))
        return signer.Result()


class SignerAdapterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="private-signer-fixture-")
        self.addCleanup(self.temp.cleanup); self.root = Path(self.temp.name).resolve()
        environment = patch.dict(os.environ, {"GITHUB_REF": "", "GITHUB_EVENT_NAME": "", "MACOS_CERTIFICATE_PASSWORD": "do-not-inherit"})
        environment.start(); self.addCleanup(environment.stop)
        self.fixture = CommandFixture(self.root)
        for name in ("subprocess.run", "subprocess.Popen", "subprocess.check_output", "socket.socket"):
            guard = patch(name, side_effect=AssertionError("Real process/network forbidden in signer fixtures"))
            guard.start(); self.addCleanup(guard.stop)

    def run_adapter(self, fault=None, output="result"):
        self.fake = FakeCommands(self.fixture, fault)
        self.adapter = signer.Adapter(self.fake, self.fixture.material)
        return self.adapter.run(self.fixture.handoff, self.root / output, self.fixture.expected)

    def test_complete_command_sequence_preserves_scope_and_private_roundtrip(self):
        result = self.run_adapter()
        self.assertEqual(result["status"], "FAKE_RUNNER_ONLY")
        self.assertFalse(result["productionCryptographyObserved"]); self.assertFalse(result["guestRunAuthorized"])
        self.assertEqual(result["scopeSHA256"], self.fixture.scope["scopeSHA256"])
        self.assertEqual(result["localScopeValidation"], "PENDING_ORIGINAL_MAC")
        self.assertEqual(result["loadedChildAdmission"], "NOT_RUN")
        events = result["events"]
        self.assertLess(events.index("sign-child-OmarchyVMProvisioningHelper"), events.index("seal-post-sign-helper-digests"))
        self.assertLess(events.index("seal-post-sign-helper-digests"), events.index("sign-outer-app"))
        self.assertEqual(private.tree(self.root / "result/Private Candidate.app"), private.tree(self.root / "result/roundtrip/Private Candidate.app"))
        self.assertFalse(Path(self.fixture.scope["root"]).exists())
        for command in self.fake.commands:
            self.assertNotIn("MACOS_CERTIFICATE_PASSWORD", command.environment)
            self.assertNotIn("notarytool", command.argv); self.assertNotIn("ssh", command.argv)
            self.assertEqual(command.requestSHA256, self.fixture.expected)
            self.assertIn(command.effect, {"inspect", "build", "sign-with-timestamp"})
        archive = self.root / "result/PROCESS-RUNNER-TEST-ONLY.zip"
        self.assertEqual(stat.S_IMODE(archive.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(archive.parent.stat().st_mode), 0o700)
        self.assertEqual(private.load_handoff(self.fixture.handoff, self.fixture.expected)["scopeSHA256"], result["scopeSHA256"])

    def test_signed_reference_and_unsigned_fake_build_complete_seal_and_roundtrip(self):
        root = self.root / "signed-reference"; root.mkdir(mode=0o700)
        self.fixture = CommandFixture(root, signed_resources=True)
        before = private.tree(self.fixture.handoff)
        result = self.run_adapter(output="signed-resources-result")
        self.assertEqual(result["status"], "FAKE_RUNNER_ONLY")
        for suffix in ("Private Candidate.app", "roundtrip/Private Candidate.app"):
            contents = self.root / "signed-resources-result" / suffix / "Contents"
            private.package.verify(contents, root=self.fixture.handoff / "inputs")
            self.assertFalse(set(SIGNATURE_RECORDS) & private.tree(contents / "Resources" / private.package.BUNDLE).keys())
        self.assertEqual(private.tree(self.fixture.handoff), before)

    def test_default_system_runner_denies_before_material_or_output(self):
        adapter = signer.Adapter(signer.SystemRunner(), self.fixture.material)
        with patch.object(signer.Adapter, "_validate_material", side_effect=AssertionError("material must not be read")):
            with self.assertRaisesRegex(private.Refused, "legacy-real-signer-disabled"):
                adapter.run(self.fixture.handoff, self.root / "denied", self.fixture.expected)
        self.assertFalse((self.root / "denied").exists())

    def test_effect_and_binding_authorization_cannot_be_read_from_environment(self):
        values = (self.fixture.expected, self.fixture.scope["scopeSHA256"], self.fixture.material.binding())
        runner = signer.SystemRunner(signer.ExecutionAuthorization(*values, frozenset({"inspect"})))
        with self.assertRaises(private.Refused): runner.authorize("0" * 64, *values[1:])
        command = signer.Command("forbidden", "sign-with-timestamp", (signer.TOOLS["codesign"], "--force"), self.root, {}, *values)
        with self.assertRaisesRegex(private.Refused, "legacy-real-signer-disabled"): runner.run(command)
        for argv in ((signer.TOOLS["security"], "unlock-keychain"), ("/usr/bin/ssh", "host")):
            command = signer.Command("forbidden", "inspect", argv, self.root, {}, *values)
            with self.assertRaises(private.Refused): runner.run(command)

    def test_synthetic_request_never_enters_system_execution(self):
        runner = FakeCommands(self.fixture); runner.test_double = False
        with self.assertRaisesRegex(private.Refused, "legacy-real-signer-disabled"):
            signer.Adapter(runner, self.fixture.material).run(self.fixture.handoff, self.root / "denied", self.fixture.expected)
        self.assertEqual(runner.commands, []); self.assertFalse((self.root / "denied").exists())

    def test_legacy_real_dispatch_is_disabled_even_with_old_typed_authority(self):
        values=(self.fixture.expected,self.fixture.scope["scopeSHA256"],self.fixture.material.binding())
        runner=signer.SystemRunner(signer.ExecutionAuthorization(*values,frozenset({"build","inspect","sign-with-timestamp"})))
        command=signer.Command("decode","inspect",(signer.TOOLS["security"],"cms","-D","-i","fixture"),self.root,{},*values)
        with patch("subprocess.Popen",side_effect=AssertionError("Legacy process must not start")):
            with self.assertRaisesRegex(private.Refused,"legacy-real-signer-disabled"):runner.run(command)

    def test_legacy_real_adapter_denies_before_any_material_or_output(self):
        values=(self.fixture.expected,self.fixture.scope["scopeSHA256"],self.fixture.material.binding())
        runner=signer.SystemRunner(signer.ExecutionAuthorization(*values,frozenset({"build","inspect","sign-with-timestamp"})))
        with patch.object(signer.Adapter,"_validate_material",side_effect=AssertionError("No material IO")):
            with self.assertRaises(private.Refused):signer.Adapter(runner,self.fixture.material).run(self.fixture.handoff,self.root/'denied',self.fixture.expected)
        self.assertFalse((self.root/'denied').exists())

    def test_sdk_source_build_signing_and_verification_failures_are_private(self):
        faults = ("decode-pinned-profile", "profile-team", "profile-expired", "check-original-overlay", "apply-original-overlay", "overlay-bytes",
                  "revision", "dirty", "verify-local-runtime-signatures", "prepare-pinned-provisioning-source",
                  "build-scoped-signed-prerelease", "source-drift", "source-addition", "dependency-drift", "missing-scope", "foreign-build",
                  "sign-child-OmarchyVMProvisioningHelper", "sign-outer-app", "outer-child-tamper", "outer-runtime-tamper",
                  "signed-scope-removed", "staged-deep-signatures", "wrong-team", "no-runtime", "no-timestamp", "adhoc",
                  "child-keychain", "certificate", "launch-contract", "verification-mutation", "roundtrip-deep-signatures",
                  "oversize", "exception")
        for i, fault in enumerate(faults):
            with self.subTest(fault=fault):
                name = "failure-" + str(i)
                with self.assertRaisesRegex(private.Refused, "private-signer-adapter-failed"): self.run_adapter(fault, name)
                raw = private.read(self.root / name / "failure.json")
                self.assertNotIn(b"synthetic-password", raw); self.assertNotIn(self.fixture.material.identity.encode(), raw)
                self.assertFalse(private.decode(raw)["automaticRetry"])

    def test_runtime_origin_archive_and_immutable_payload_fail_closed_before_build(self):
        lock_path = self.fixture.runtime_dir / "TryOmarchySignedRuntime.lock.json"
        for i, field in enumerate(("sourceKitSHA256", "managedSSHVersion", "kitSHA256", "files")):
            lock = dict(self.fixture.signed_lock)
            lock[field] = ({**lock["files"], "Contents/Resources/firmware.fd": "0" * 64} if field == "files"
                           else 2 if field == "managedSSHVersion" else "0" * 64)
            lock_path.write_bytes(private.canonical(lock))
            with self.subTest(field=field), self.assertRaises(private.Refused): self.run_adapter(output="runtime-" + str(i))
            self.assertNotIn("build-scoped-signed-prerelease", self.adapter.events)

    def test_handoff_change_during_command_cannot_be_rebound(self):
        with self.assertRaises(private.Refused): self.run_adapter("handoff-tamper")
        self.assertNotIn("apply-original-overlay", self.adapter.events)

    def test_refuses_output_reuse_and_tag_release_context(self):
        self.run_adapter()
        with self.assertRaises(private.Refused): self.run_adapter()
        with patch.dict(os.environ, {"GITHUB_REF": "refs/tags/v0.0.0-dev.1"}):
            with self.assertRaises(private.Refused): self.run_adapter(output="release")
        self.assertFalse((self.root / "release").exists())

    def test_keychain_and_profile_are_explicit_private_and_pinned(self):
        self.fixture.material.keychain.chmod(0o644)
        with self.assertRaises(private.Refused): self.run_adapter(output="keychain")
        self.assertEqual(self.fake.commands, [])
        self.fixture.material.keychain.chmod(0o600)
        self.fixture.material.profile.write_bytes(b"different profile")
        with self.assertRaises(private.Refused): self.run_adapter(output="profile")
        self.assertEqual(self.fake.commands, [])

    def test_redacted_representations_do_not_expose_material_or_commands(self):
        self.run_adapter()
        self.assertEqual(repr(self.fixture.material), "PrivateSigningMaterial(redacted)")
        for command in self.fake.commands: self.assertEqual(repr(command), "PrivateSigningCommand(redacted)")


if __name__ == "__main__": unittest.main()
