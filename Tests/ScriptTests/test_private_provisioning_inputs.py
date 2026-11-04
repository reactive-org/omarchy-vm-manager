"""Source-only admission/caller: synthetic files and fake commands exclusively."""
import copy
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace as update
import io
import os
from pathlib import Path
import sys
import tarfile
import tempfile
import threading
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Scripts"))
import private_provisioning_package as private
import private_provisioning_inputs as source
import private_provisioning_signer as signer
from test_private_provisioning_package import put
from test_private_provisioning_signer import CommandFixture, FakeCommands, TEAM, LITERAL


class SourceFixture(CommandFixture):
    def __init__(self, root):
        super().__init__(root)
        self.lock["sourceSnapshotSHA256"] = private.digest(private.canonical(self.lock["files"]))
        self.packet = root / "source-packet"; self.packet.mkdir(mode=0o700)
        inputs = self.packet / "inputs"; inputs.mkdir(mode=0o700)
        new_base = dict(self.base)
        # Independent new source identity, while the original scope/definition and
        # legacy request stay untouched. No copied scope.sourceCommit rewrite.
        new_commit = "7" * 40
        dev = copy.deepcopy(self.runtime)
        dev.update(kitVersion="development", runProtocolVersion=1)
        source_kit = dict(self.source_kit)
        source_kit["Contents/Resources/kit.json"] = private.canonical({"format": 1, "version": "development",
            "runProtocolVersion": 1, "buildDate": dev["buildDate"]})
        dev["files"] = {n: private.digest(b) for n, b in source_kit.items()}
        dev_raw = private.canonical(dev)
        new_base["Config/TryOmarchyRuntime.lock.json"] = dev_raw
        new_base["Config/DevVMProvisioning.lock.json"] = private.canonical(self.lock)
        resources = private.package.resource_files(self.lock)
        resource_data = {n: private.read(self.handoff / "inputs" / private.package.BUNDLE / "Resources" / n) for n in resources}
        for name in self.lock["files"]:
            suffix = name.removeprefix("Sources/DevVMProvisioningCore/Resources/")
            new_base["Vendor/dev-vm/" + name] = resource_data[suffix]
        archive = io.BytesIO()
        with tarfile.open(fileobj=archive, mode="w:") as tar:
            for name, data in sorted(new_base.items()):
                entry = tarfile.TarInfo(name); entry.size = len(data); tar.addfile(entry, io.BytesIO(data))
        raw_archive = archive.getvalue()
        for name, data in {"base-source.tar": raw_archive,
                           "candidate-overlay.patch": private.read(self.handoff / "inputs/candidate-overlay.patch"),
                           "scope.json": private.read(self.handoff / "inputs/scope.json"),
                           "root-preparation-receipt.json": private.read(self.handoff / "inputs/root-preparation-receipt.json")}.items():
            put(inputs / name, data)
        for name in ("DevVMProvisioning.lock.json", "TryOmarchyRuntime.lock.json", "TouchIDProfile.lock.json"):
            put(inputs / "Config" / name, new_base["Config/" + name])
        for name, data in source_kit.items(): put(inputs / "TryOmarchyKit.bundle" / name, data, "MacOS" in name)
        private.copy_tree(self.handoff / "inputs" / private.package.BUNDLE, inputs / private.package.BUNDLE,
                          private.tree(self.handoff / "inputs" / private.package.BUNDLE))
        runtime = self.packet / "runtime"; runtime.mkdir(mode=0o700)
        signed_files = {}
        for name, data in source_kit.items():
            signed_data = data + (b" FAKE SIGNATURE" if "MacOS" in name else b"")
            put(runtime / "TryOmarchyKit.bundle" / name, signed_data, "MacOS" in name)
            signed_files[name] = signed_data
        signed_zip = io.BytesIO()
        with zipfile.ZipFile(signed_zip, "w") as zipped:
            for name, data in signed_files.items(): zipped.writestr("TryOmarchyKit.bundle/" + name, data)
        signed = dict(dev, files=private.tree(runtime / "TryOmarchyKit.bundle"), signingTeamID=TEAM,
                      sourceLockSHA256=private.digest(dev_raw), sourceKitSHA256=dev["kitSHA256"],
                      artifactTag="v0.0.0-dev.1", kitSHA256=private.digest(signed_zip.getvalue()))
        put(runtime / "TryOmarchyKit.zip", signed_zip.getvalue())
        put(runtime / "TryOmarchySignedRuntime.lock.json", private.canonical(signed))
        self.signed_lock, self.runtime = signed, dev
        self.material = update(self.material, signed_runtime=runtime)
        scope_raw = private.read(inputs / "scope.json")
        base_inventory = {n: private.digest(b) for n, b in new_base.items()}
        scoped = dict(base_inventory, **{n: private.digest(b) for n, b in self.overlay.items()})
        evidence = {"format": 1, "baseCommit": new_commit, "baseArchiveSHA256": private.digest(raw_archive),
                    "overlaySHA256": private.digest(private.read(inputs / "candidate-overlay.patch")),
                    "originalScopeSourceCommit": self.scope["sourceCommit"], "scopeSHA256": self.scope["scopeSHA256"],
                    "scopeBytesSHA256": private.digest(scope_raw), "scopeDefinitionCopiedVerbatim": True,
                    "ordinaryGateUnchanged": True, "productionSigningPolicyUnchanged": True, "applicationBuilt": False,
                    "overlayFiles": [{"path": n, "beforeSHA256": base_inventory.get(n), "afterSHA256": private.digest(b)}
                                     for n, b in sorted(self.overlay.items())]}
        put(inputs / "source-evidence.json", private.canonical(evidence))
        put(self.packet / "lineage/previous-request.json", private.read(self.handoff / "request.json"))
        self.record = {"format": 1, "kind": "PRIVATE_INTEGRATED_CANDIDATE_INPUTS", "status": "PREPARED_INPUTS_ONLY_NOT_AUTHORIZED",
                       "sourceCommit": new_commit, "scopeSHA256": self.scope["scopeSHA256"], "scopeBytesSHA256": private.digest(scope_raw),
                       "originalScopeSourceCommit": self.scope["sourceCommit"], "priorRequestSHA256": self.expected,
                       "applicationBuilt": False, "applicationSigned": False, "guestRunAuthorized": False, "executionAuthorized": False,
                       "legacyAdapterCompatible": False, "publication": "forbidden", "inputs": private.tree(inputs),
                       "runtime": private.tree(runtime), "lineage": private.tree(self.packet / "lineage"),
                       "sourceArchiveSHA256": private.digest(raw_archive), "overlaySHA256": evidence["overlaySHA256"],
                       "developmentLockSHA256": private.digest(dev_raw), "signedRuntimeLockSHA256": private.digest(private.canonical(signed)),
                       "signedRuntimeArchiveSHA256": signed["kitSHA256"], "runtimeArtifactTag": signed["artifactTag"],
                       "artifactContainer": "fake-existing-release", "signedRuntimeSource": "/never-read/metadata-hint",
                       "scopedSourceSHA256": private.digest(private.canonical(scoped))}
        put(self.packet / "candidate-inputs.json", private.canonical(self.record))
        self.review = source.ReviewedSourceInputs(private.digest(private.read(self.packet / "candidate-inputs.json")),
            new_commit, self.scope["scopeSHA256"], private.digest(scope_raw), self.expected,
            private.digest(self.overlay[LITERAL]), private.digest(raw_archive), evidence["overlaySHA256"], TEAM, fixture=True)

    def reseal(self):
        self.record.update(inputs=private.tree(self.packet / "inputs"), runtime=private.tree(self.packet / "runtime"),
                           lineage=private.tree(self.packet / "lineage"))
        (self.packet / "candidate-inputs.json").write_bytes(private.canonical(self.record))
        self.review = update(self.review, candidateInputsSHA256=private.digest(private.read(self.packet / "candidate-inputs.json")))


class SourceCommands(FakeCommands):
    def __init__(self, fixture, fault=None):
        # The fake SDK verifies against the current source packet, while tests
        # retain the original legacy directory for independent immutability checks.
        current = copy.copy(fixture); current.handoff = fixture.packet
        super().__init__(current, fault)


class SourceInputTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="source-admission-fixture-")
        self.addCleanup(self.temp.cleanup); self.root = Path(self.temp.name).resolve()
        environment = patch.dict(os.environ, {"GITHUB_REF": "", "GITHUB_EVENT_NAME": ""})
        environment.start(); self.addCleanup(environment.stop)
        self.fixture = SourceFixture(self.root)
        for name in ("subprocess.run", "subprocess.Popen", "subprocess.check_output", "socket.socket"):
            guard = patch(name, side_effect=AssertionError("Real process/network prohibited in source fixtures"))
            guard.start(); self.addCleanup(guard.stop)

    def admit(self): return source.SourceInputAdmission.open(self.fixture.packet, self.fixture.review)

    def caller(self, fault=None, material=None):
        self.runner = SourceCommands(self.fixture, fault)
        return signer.SourceInputCaller(self.fixture.review, material or self.fixture.material, self.runner)

    def test_typed_admission_keeps_new_source_and_original_scope_distinct(self):
        admission = self.admit(); request = admission.revalidate()
        self.assertEqual(request["format"], 2)
        self.assertEqual(request["sourceCommit"], self.fixture.review.sourceCommit)
        scope = private.decode(private.read(self.fixture.packet / "inputs/scope.json"))
        self.assertNotEqual(request["sourceCommit"], scope["sourceCommit"])
        self.assertEqual(private.read(self.fixture.packet / "inputs/scope.json"), private.read(self.fixture.handoff / "inputs/scope.json"))
        self.assertNotEqual(admission.requestSHA256, self.fixture.review.candidateInputsSHA256)
        self.assertNotEqual(admission.requestSHA256, update(self.fixture.review, fixture=False).request_digest())
        self.assertEqual(repr(admission), "SourceInputAdmissionV2(redacted)")
        self.assertEqual(repr(self.fixture.review), "ReviewedSourceInputs(redacted)")

    def test_fake_caller_runs_full_adapter_roundtrip_and_preserves_frozen_inputs(self):
        before = private.tree(self.fixture.packet); old = private.tree(self.fixture.handoff)
        caller = self.caller(); result = caller.run(self.fixture.packet, self.root / "result")
        self.assertEqual(result["inputAdmissionVersion"], 2)
        self.assertEqual(result["sourceCommit"], self.fixture.review.sourceCommit)
        self.assertEqual(result["scopeBytesSHA256"], self.fixture.review.scopeBytesSHA256)
        self.assertEqual(result["status"], "FAKE_RUNNER_ONLY")
        self.assertFalse(result["productionCryptographyObserved"]); self.assertFalse(result["guestRunAuthorized"])
        self.assertEqual(result["notarization"], "NOT_REQUESTED_NOT_ESTABLISHED")
        self.assertEqual(before, private.tree(self.fixture.packet)); self.assertEqual(old, private.tree(self.fixture.handoff))
        self.assertTrue(all(c.requestSHA256 == self.fixture.review.request_digest() for c in self.runner.commands))
        self.assertFalse(Path(self.fixture.scope["root"]).exists())
        with self.assertRaisesRegex(private.Refused, "already-used"): caller.run(self.fixture.packet, self.root / "replay")
        self.assertFalse((self.root / "replay").exists())

    def test_default_runner_refuses_before_material_io_or_output_even_if_gate_claims_authority(self):
        put(self.fixture.packet / "gate.json", b'{"executionAuthorized":true,"approvals":[{"status":"GRANTED"}]}')
        caller = signer.SourceInputCaller(self.fixture.review, self.fixture.material)
        with patch.object(signer.Adapter, "_validate_material", side_effect=AssertionError("No material IO")):
            with self.assertRaisesRegex(private.Refused, "legacy-real-signer-disabled"): caller.run(self.fixture.packet, self.root / "denied")
        self.assertFalse((self.root / "denied").exists())
        with self.assertRaisesRegex(private.Refused, "already-used"): caller.run(self.fixture.packet, self.root / "again")

    def test_legacy_path_does_not_auto_detect_or_accept_source_packets(self):
        with self.assertRaises((private.Refused, OSError)):
            signer.Adapter(SourceCommands(self.fixture), self.fixture.material).run(self.fixture.packet, self.root / "legacy", self.fixture.review.candidateInputsSHA256)
        self.assertFalse((self.root / "legacy").exists())
        with self.assertRaises(private.Refused): source.SourceInputAdmission.open(self.fixture.packet, {})

    def test_independent_review_bindings_cannot_be_replaced_by_sidecar_or_gate(self):
        path = self.fixture.packet / "candidate-inputs.json"
        changed = dict(self.fixture.record, sourceCommit="0" * 40)
        path.write_bytes(private.canonical(changed))
        put(self.fixture.packet / "checksums.json", private.canonical({"candidateInputsSHA256": private.digest(private.read(path))}))
        caller = self.caller()
        with self.assertRaisesRegex(private.Refused, "source-input-admission-refused"): caller.run(self.fixture.packet, self.root / "tampered")
        self.assertEqual(self.runner.commands, []); self.assertEqual(self.runner.authorizations, [])
        self.assertFalse((self.root / "tampered").exists())

    def test_resealed_header_cannot_retarget_historical_scope_or_claim_authority(self):
        original = copy.deepcopy(self.fixture.record)
        mutations = [("format", 2), ("format", True), ("kind", "PRIVATE_REQUEST_ONLY_NOT_SIGNED"),
                     ("sourceCommit", "0" * 40), ("scopeSHA256", "0" * 64),
                     ("scopeBytesSHA256", "0" * 64), ("priorRequestSHA256", "0" * 64),
                     ("originalScopeSourceCommit", self.fixture.review.sourceCommit),
                     ("applicationBuilt", True), ("applicationSigned", True), ("executionAuthorized", True),
                     ("guestRunAuthorized", True), ("legacyAdapterCompatible", True), ("publication", "allowed"),
                     ("sourceArchiveSHA256", "0" * 64), ("overlaySHA256", "0" * 64),
                     ("scopedSourceSHA256", "0" * 64), ("signedRuntimeLockSHA256", "0" * 64),
                     ("signedRuntimeArchiveSHA256", "0" * 64), ("unknown", True)]
        for key, value in mutations:
            with self.subTest(field=key, value=value):
                self.fixture.record = dict(original, **{key: value}); self.fixture.reseal()
                with self.assertRaises(private.Refused): self.admit()

    def test_scope_definition_and_lineage_remain_independently_reviewed_after_reseal(self):
        for field in ("preservedScopeSourceSHA256", "priorRequestSHA256", "scopeBytesSHA256", "sourceArchiveSHA256", "overlaySHA256"):
            with self.subTest(field=field), self.assertRaises(private.Refused):
                source.SourceInputAdmission.open(self.fixture.packet, update(self.fixture.review, **{field: "0" * 64}))

    def test_duplicate_json_unsafe_links_and_legacy_alias_are_refused(self):
        path = self.fixture.packet / "candidate-inputs.json"; original = private.read(path)
        duplicate = original[:-1] + b',"format":1}'
        path.write_bytes(duplicate); self.fixture.review = update(self.fixture.review, candidateInputsSHA256=private.digest(duplicate))
        with self.assertRaises(private.Refused): self.admit()
        path.write_bytes(original); self.fixture.review = update(self.fixture.review, candidateInputsSHA256=private.digest(original))
        put(self.fixture.packet / "request.json", b'{}')
        with self.assertRaises(private.Refused): self.admit()
        (self.fixture.packet / "request.json").unlink()
        target = self.fixture.packet / "inputs/candidate-overlay.patch"; raw = target.read_bytes(); target.unlink(); target.symlink_to(self.fixture.handoff / "inputs/candidate-overlay.patch")
        with self.assertRaises(private.Refused): self.admit()
        target.unlink(); put(target, raw)

    def test_runtime_config_payload_and_archive_tamper_fail_before_materials(self):
        paths = ["inputs/Config/TryOmarchyRuntime.lock.json", "inputs/TryOmarchyKit.bundle/Contents/Resources/firmware.fd",
                 "runtime/TryOmarchySignedRuntime.lock.json", "runtime/TryOmarchyKit.zip",
                 "runtime/TryOmarchyKit.bundle/Contents/Resources/firmware.fd", "lineage/previous-request.json"]
        for name in paths:
            with self.subTest(path=name):
                path = self.fixture.packet / name; original = path.read_bytes(); path.write_bytes(b"changed")
                caller = self.caller()
                with self.assertRaises(private.Refused): caller.run(self.fixture.packet, self.root / "must-not-exist")
                self.assertEqual(self.runner.commands, []); self.assertFalse((self.root / "must-not-exist").exists())
                path.write_bytes(original)

    def test_fixture_review_cannot_enter_a_production_runner_or_swap_runtime_selector(self):
        self.runner = SourceCommands(self.fixture); self.runner.test_double = False
        with self.assertRaisesRegex(private.Refused, "legacy-real-signer-disabled"):
            signer.SourceInputCaller(self.fixture.review, self.fixture.material, self.runner).run(self.fixture.packet, self.root / "production")
        self.assertEqual(self.runner.commands, [])
        caller = self.caller(material=update(self.fixture.material, signed_runtime=self.fixture.runtime_dir))
        with self.assertRaisesRegex(private.Refused, "reviewed-runtime-directory"): caller.run(self.fixture.packet, self.root / "swapped")
        self.assertEqual(self.runner.commands, []); self.assertEqual(self.runner.authorizations, [])

    def test_input_change_across_fake_process_is_refused_and_failure_is_private(self):
        runner = SourceCommands(self.fixture); original = runner.run
        def command(spec):
            result = original(spec)
            if spec.stage == "check-original-overlay":
                (self.fixture.packet / "inputs/scope.json").write_bytes(b"changed historical scope")
            return result
        runner.run = command
        caller = signer.SourceInputCaller(self.fixture.review, self.fixture.material, runner)
        with self.assertRaisesRegex(private.Refused, "private-signer-adapter-failed"): caller.run(self.fixture.packet, self.root / "failed")
        self.assertNotIn("apply-original-overlay", [c.stage for c in runner.commands])
        failure = private.read(self.root / "failed/failure.json")
        self.assertNotIn(self.fixture.material.identity.encode(), failure)
        self.assertFalse(private.decode(failure)["automaticRetry"])

    def test_scoped_source_inventory_refuses_extra_file_from_fake_overlay(self):
        runner = SourceCommands(self.fixture); original = runner.run
        def command(spec):
            result = original(spec)
            if spec.stage == "apply-original-overlay": put(spec.cwd / "Sources/Unexpected.swift", b"injected")
            return result
        runner.run = command
        with self.assertRaises(private.Refused):
            signer.SourceInputCaller(self.fixture.review, self.fixture.material, runner).run(self.fixture.packet, self.root / "extra")
        self.assertNotIn("build-scoped-signed-prerelease", [c.stage for c in runner.commands])

    def test_source_namespace_is_refused_before_looking_at_a_vm_directory(self):
        path = self.root / "Omarchy VM Manager/VMs" / self.fixture.scope["vmID"]
        with patch.object(private, "private_directory", side_effect=AssertionError("No VM root observation")):
            with self.assertRaises(private.Refused): source.SourceInputAdmission.open(path, self.fixture.review)
        self.assertFalse(path.exists())

    def test_resealed_foreign_runtime_origin_or_capability_is_refused(self):
        path = self.fixture.packet / "runtime/TryOmarchySignedRuntime.lock.json"
        original = path.read_bytes()
        for field, value in (("sourceLockSHA256", "0" * 64), ("sourceKitSHA256", "0" * 64),
                             ("managedSSHVersion", 2), ("signingTeamID", "ZZZ1234567")):
            with self.subTest(field=field):
                lock = private.decode(original); lock[field] = value
                raw = private.canonical(lock); path.write_bytes(raw)
                self.fixture.record["signedRuntimeLockSHA256"] = private.digest(raw)
                self.fixture.reseal()
                with self.assertRaises(private.Refused): self.admit()
        path.write_bytes(original)

    def test_resealed_unsafe_archive_is_refused_without_extracting(self):
        path = self.fixture.packet / "inputs/base-source.tar"
        original = path.read_bytes()
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode="w:") as output:
            with tarfile.open(fileobj=io.BytesIO(original)) as archive:
                for entry in archive: output.addfile(entry, archive.extractfile(entry) if entry.isfile() else None)
            entry = tarfile.TarInfo("../escape"); entry.size = 3; output.addfile(entry, io.BytesIO(b"bad"))
        raw = stream.getvalue(); path.write_bytes(raw)
        self.fixture.record["sourceArchiveSHA256"] = private.digest(raw)
        self.fixture.reseal(); self.fixture.review = update(self.fixture.review, sourceArchiveSHA256=private.digest(raw))
        with self.assertRaises(private.Refused): self.admit()
        self.assertFalse((self.root / "escape").exists())

    def test_packet_or_legacy_authorization_cannot_authorize_version_2_dispatch(self):
        for digest in (self.fixture.expected, self.fixture.review.candidateInputsSHA256):
            auth = signer.ExecutionAuthorization(digest, self.fixture.review.scopeSHA256,
                self.fixture.material.binding(), frozenset({"build", "inspect", "sign-with-timestamp"}))
            caller = signer.SourceInputCaller(self.fixture.review, self.fixture.material, signer.SystemRunner(auth))
            with self.assertRaisesRegex(private.Refused, "legacy-real-signer-disabled"): caller.run(self.fixture.packet, self.root / "wrong-domain")
            self.assertFalse((self.root / "wrong-domain").exists())

    def test_two_callers_cannot_race_the_same_one_shot_instance(self):
        entered, release = threading.Event(), threading.Event()
        runner = SourceCommands(self.fixture); original = runner.authorize
        def authorize(*bindings):
            entered.set()
            if not release.wait(10): raise AssertionError("Fake authorization gate timed out")
            original(*bindings)
        runner.authorize = authorize
        caller = signer.SourceInputCaller(self.fixture.review, self.fixture.material, runner)
        with ThreadPoolExecutor(max_workers=1) as pool:
            future = pool.submit(caller.run, self.fixture.packet, self.root / "first")
            try:
                self.assertTrue(entered.wait(5))
                with self.assertRaisesRegex(private.Refused, "already-used"):
                    caller.run(self.fixture.packet, self.root / "second")
            finally: release.set()
            self.assertEqual(future.result(timeout=10)["inputAdmissionVersion"], 2)
        self.assertEqual(len(runner.authorizations), 1)
        self.assertFalse((self.root / "second").exists())

    def test_untyped_caller_arguments_are_refused_without_inspection(self):
        with patch.object(private, "read", side_effect=AssertionError("No input or credential IO")):
            with self.assertRaises(private.Refused): signer.SourceInputCaller({}, self.fixture.material)
            with self.assertRaises(private.Refused): signer.SourceInputCaller(self.fixture.review, {})


if __name__ == "__main__": unittest.main()
