"""Material preflight uses synthetic files, fake SDK and fake public X509 only."""
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
import os
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Scripts"))
import private_provisioning_package as private
import private_provisioning_materials as materials
import private_provisioning_signer as signer
from test_private_provisioning_inputs import SourceFixture, SourceCommands
from test_private_provisioning_package import FakeSigner, put

CERT = b"synthetic public certificate"


def certificate_details(identity):
    return {"subject": ((("commonName", identity),),), "notBefore": "Nov  1 00:00:00 2020 GMT",
            "notAfter": "Nov  1 00:00:00 2040 GMT"}


class MaterialCommands(SourceCommands):
    def __init__(self, fixture, fault=None, callback=None):
        super().__init__(fixture, fault); self.callback = callback

    def run(self, command):
        if self.callback: self.callback(command)
        if command.stage == "decode-selected-profile":
            self.commands.append(command)
            if self.fault == command.stage: return signer.Result(1, b"", b"private-diagnostic-do-not-log")
            _, _, profile = FakeSigner().profile()
            if self.fault == "profile-team": profile["TeamIdentifier"] = ["ZZZ1234567"]
            if self.fault == "profile-certificate": profile["DeveloperCertificates"] = [b"other public certificate"]
            if self.fault == "profile-app": profile["Entitlements"]["com.apple.application-identifier"] = "wrong.app"
            if self.fault == "profile-expiry":
                from datetime import datetime
                profile["ExpirationDate"] = datetime(2000, 1, 1)
            return signer.Result(stdout=plistlib.dumps(profile))
        if self.fault == "revision" and "-revision-" in command.stage:
            self.commands.append(command); return signer.Result(stdout=b"0" * 40)
        if self.fault == "dirty" and "-clean-" in command.stage:
            self.commands.append(command); return signer.Result(stdout=b" M dirty")
        return super().run(command)


class MaterialInspectionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="material-inspection-fixture-")
        self.addCleanup(self.temp.cleanup); self.root = Path(self.temp.name).resolve()
        env = patch.dict(os.environ, {"GITHUB_REF": "", "GITHUB_EVENT_NAME": ""})
        env.start(); self.addCleanup(env.stop)
        self.fixture = SourceFixture(self.root)
        self.cert = self.root / "material/public.der"; put(self.cert, CERT)
        self.inspector = self.fixture.material.upstream / "scripts/kit_signature.py"
        put(self.inspector, b"# Synthetic inspector, never executed\n")
        self.selection = materials.MaterialSelection(self.fixture.material, self.cert)
        self.output = self.root / "inspection"
        self.review = materials.ReviewedMaterialInspection(self.fixture.review.request_digest(), self.selection.binding(),
            private.digest(CERT), private.digest(private.read(self.inspector)), self.output)
        self.details = certificate_details(self.fixture.material.identity)
        for name in ("subprocess.run", "subprocess.Popen", "subprocess.check_output", "socket.socket"):
            guard = patch(name, side_effect=AssertionError("Real process/network prohibited in material fixtures"))
            guard.start(); self.addCleanup(guard.stop)

    def caller(self, fault=None, callback=None, review=None, selection=None):
        self.runner = MaterialCommands(self.fixture, fault, callback)
        return materials.MaterialInspectionCaller(self.fixture.review, selection or self.selection, review or self.review,
                                                  self.runner, lambda _: self.details)

    def test_stages_only_reviewed_profile_and_public_certificate_without_keychain_reads(self):
        before = private.tree(self.fixture.packet); original = private.tree(self.root / "material")
        caller = self.caller(); read = private.read
        def guarded_read(path, *args):
            self.assertNotEqual(Path(path), self.fixture.material.keychain, "Keychain contents must never be opened")
            return read(path, *args)
        with patch.object(private, "read", side_effect=guarded_read): result = caller.run(self.fixture.packet)
        self.assertEqual(before, private.tree(self.fixture.packet)); self.assertEqual(original, private.tree(self.root / "material"))
        self.assertEqual(result.material.profile, self.output / "manager.provisionprofile")
        self.assertEqual(read(result.material.profile), read(self.fixture.material.profile))
        self.assertEqual(result.material.profile.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.output.stat().st_mode & 0o777, 0o700)
        self.assertEqual(result.material.keychain, self.fixture.material.keychain)
        receipt = private.decode(read(self.output / "material-inspection.json"))
        self.assertEqual(receipt["status"], "FAKE_MATERIAL_INSPECTION_ONLY")
        self.assertEqual(receipt["privateKeyAvailability"], "NOT_QUERIED")
        self.assertEqual(receipt["keychainUnlocked"], "NOT_CHECKED")
        self.assertFalse(receipt["signingAuthorized"]); self.assertFalse(receipt["guestRunAuthorized"])
        self.assertFalse(receipt["nativeRuntimeVerifierObserved"])
        self.assertNotEqual(result.material.binding(), self.fixture.material.binding())
        self.assertNotEqual(self.review.request_digest(), self.fixture.review.request_digest())
        self.assertEqual(self.runner.authorizations, [(self.review.request_digest(), self.fixture.review.scopeSHA256, self.selection.binding())])
        self.assertTrue(all(c.effect == "inspect" and c.requestSHA256 == self.review.request_digest() for c in self.runner.commands))
        self.assertTrue(all(c.environment["GIT_TERMINAL_PROMPT"] == "0" for c in self.runner.commands))
        self.assertFalse(Path(self.fixture.scope["root"]).exists())
        self.assertNotIn(str(self.cert), repr(self.selection) + repr(self.review) + repr(result) + repr(caller))

    def test_default_runner_denies_before_material_io_and_output(self):
        put(self.fixture.packet / "gate.json", b'{"executionAuthorized":true,"approvals":["GRANTED"]}')
        caller = materials.MaterialInspectionCaller(self.fixture.review, self.selection, self.review)
        with patch.object(materials, "_stamp_keychain", side_effect=AssertionError("No metadata")), \
             patch.dict(os.environ, {"PRIVATE_SIGNING_APPROVED": "yes"}):
            with self.assertRaisesRegex(private.Refused, "not-authorized"): caller.run(self.fixture.packet)
        self.assertFalse(self.output.exists())

    def test_source_signing_authorization_cannot_authorize_material_inspection(self):
        auth = signer.ExecutionAuthorization(self.fixture.review.request_digest(), self.fixture.review.scopeSHA256,
                                              self.fixture.material.binding(), frozenset({"inspect", "build", "sign-with-timestamp"}))
        caller = materials.MaterialInspectionCaller(self.fixture.review, self.selection, self.review, signer.SystemRunner(auth))
        with patch.object(materials, "_stamp_keychain", side_effect=AssertionError("No metadata")):
            with self.assertRaisesRegex(private.Refused, "not-authorized"): caller.run(self.fixture.packet)
        self.assertFalse(self.output.exists())

    def test_inspection_authorization_cannot_authorize_app_signing_caller(self):
        auth = signer.ExecutionAuthorization(self.review.request_digest(), self.fixture.review.scopeSHA256,
                                              self.selection.binding(), frozenset({"inspect"}))
        caller = signer.SourceInputCaller(self.fixture.review, self.fixture.material, signer.SystemRunner(auth))
        with self.assertRaisesRegex(private.Refused, "legacy-real-signer-disabled"): caller.run(self.fixture.packet, self.output)
        self.assertFalse(self.output.exists())

    def test_fixture_cannot_run_native_inspector_even_with_matching_authorization(self):
        auth = signer.ExecutionAuthorization(self.review.request_digest(), self.fixture.review.scopeSHA256,
                                              self.selection.binding(), frozenset({"inspect"}))
        caller = materials.MaterialInspectionCaller(self.fixture.review, self.selection, self.review, signer.SystemRunner(auth))
        with patch.object(materials, "_stamp_keychain", side_effect=AssertionError("No metadata")):
            with self.assertRaisesRegex(private.Refused, "fixture-inspection"): caller.run(self.fixture.packet)
        self.assertFalse(self.output.exists())

    def test_native_authorization_requires_inspect_only_before_material_io(self):
        for effects in (frozenset(), frozenset({"sign-with-timestamp"}), frozenset({"inspect", "build"})):
            auth = signer.ExecutionAuthorization(self.review.request_digest(), self.fixture.review.scopeSHA256,
                                                  self.selection.binding(), effects)
            caller = materials.MaterialInspectionCaller(self.fixture.review, self.selection, self.review, signer.SystemRunner(auth))
            with self.subTest(effects=effects), patch.object(materials, "_stamp_keychain", side_effect=AssertionError("No metadata")):
                with self.assertRaisesRegex(private.Refused, "inspection-only-authorization"): caller.run(self.fixture.packet)
        self.assertFalse(self.output.exists())

    def test_independent_inspection_bindings_are_required_before_material_io(self):
        for key in ("sourceRequestSHA256", "selectionSHA256"):
            with self.subTest(key=key), patch.object(materials, "_stamp_keychain", side_effect=AssertionError("No metadata")):
                caller = self.caller(review=replace(self.review, **{key: "0" * 64}))
                with self.assertRaisesRegex(private.Refused, "binding-changed"): caller.run(self.fixture.packet)
                self.assertEqual(self.runner.authorizations, [])

    def test_profile_certificate_and_inspector_bytes_must_match_review(self):
        for path in (self.fixture.material.profile, self.cert, self.inspector):
            original = path.read_bytes()
            with self.subTest(file=path.name):
                path.write_bytes(b"changed")
                with self.assertRaisesRegex(private.Refused, "material-changed"): self.caller().run(self.fixture.packet)
                self.assertFalse(self.output.exists()); self.assertEqual(self.runner.commands, [])
            path.write_bytes(original)

    def test_unsafe_keychain_is_refused_without_opening(self):
        keychain = self.fixture.material.keychain
        keychain.chmod(0o644)
        with self.assertRaisesRegex(private.Refused, "unsafe-named-keychain"): self.caller().run(self.fixture.packet)
        keychain.chmod(0o600)
        link = keychain.with_name("hardlink"); os.link(keychain, link)
        with self.assertRaisesRegex(private.Refused, "unsafe-named-keychain"): self.caller().run(self.fixture.packet)
        link.unlink(); keychain.unlink(); keychain.symlink_to(self.cert)
        with self.assertRaisesRegex(private.Refused, "linked-inspection"): self.caller().run(self.fixture.packet)
        self.assertFalse(self.output.exists())

    def test_missing_material_error_is_fixed_and_does_not_expose_selector(self):
        self.cert.unlink()
        with self.assertRaisesRegex(private.Refused, "^material-inspection-refused$") as context: self.caller().run(self.fixture.packet)
        self.assertNotIn(str(self.cert), str(context.exception)); self.assertFalse(self.output.exists())

    def test_wrong_runtime_or_identity_selector_refuses_before_material_io(self):
        for material in (replace(self.fixture.material, signed_runtime=self.root),
                         replace(self.fixture.material, identity="wrong identity"),
                         replace(self.fixture.material, identity=self.fixture.material.identity + "\n")):
            selection = materials.MaterialSelection(material, self.cert)
            review = replace(self.review, selectionSHA256=selection.binding())
            with self.subTest(material=repr(material)), patch.object(materials, "_stamp_keychain", side_effect=AssertionError("No metadata")):
                with self.assertRaisesRegex(private.Refused, "selector-mismatch"): self.caller(selection=selection, review=review).run(self.fixture.packet)

    def test_profile_validation_failure_preserves_private_fixed_diagnostics(self):
        for fault in ("profile-team", "profile-certificate", "profile-app", "profile-expiry"):
            output = self.root / fault
            with self.subTest(fault=fault), self.assertRaisesRegex(private.Refused, "^material-inspection-failed$"):
                self.caller(fault, review=replace(self.review, output=output)).run(self.fixture.packet)
            report = (output / "failure.json").read_bytes()
            self.assertNotIn(b"private-diagnostic", report); self.assertFalse((output / "material-inspection.json").exists())
            self.assertFalse(private.decode(report)["automaticRetry"])

    def test_public_certificate_cn_and_validity_are_checked(self):
        variants = [dict(self.details, subject=((("commonName", "Wrong identity"),),)),
                    dict(self.details, notAfter="Nov  1 00:00:00 2000 GMT"),
                    dict(self.details, notBefore="Nov  1 00:00:00 2099 GMT")]
        for i, details in enumerate(variants):
            self.details = details; output = self.root / ("cert-invalid-" + str(i))
            with self.subTest(i=i), self.assertRaisesRegex(private.Refused, "inspection-failed"):
                self.caller(review=replace(self.review, output=output)).run(self.fixture.packet)
            self.assertFalse(any(c.stage == "verify-selected-runtime-signatures" for c in self.runner.commands))

    def test_command_failures_bounds_and_dependency_drift_fail_closed(self):
        for fault in ("decode-selected-profile", "verify-selected-runtime-signatures", "oversize", "exception", "revision", "dirty"):
            output = self.root / ("failed-" + fault)
            with self.subTest(fault=fault), self.assertRaisesRegex(private.Refused, "inspection-failed"):
                self.caller(fault, review=replace(self.review, output=output)).run(self.fixture.packet)
            self.assertNotIn(b"do-not-log", (output / "failure.json").read_bytes())
            self.assertFalse((output / "material-inspection.json").exists())

    def test_callback_rechecks_sources_staging_and_keychain_metadata(self):
        targets = [("source-profile", self.fixture.material.profile), ("public-certificate", self.cert),
                   ("runtime-inspector", self.inspector), ("named-keychain", self.fixture.material.keychain),
                   ("staged-profile", None), ("frozen-runtime", self.fixture.packet / "runtime/TryOmarchySignedRuntime.lock.json")]
        for label, target in targets:
            output = self.root / ("changed-" + label)
            selected = target or output / "manager.provisionprofile"
            original = target.read_bytes() if target else None
            def mutate(command):
                if command.stage == "decode-selected-profile": selected.write_bytes(b"changed-during-callback")
            with self.subTest(target=label), self.assertRaisesRegex(private.Refused, "inspection-failed"):
                self.caller(callback=mutate, review=replace(self.review, output=output)).run(self.fixture.packet)
            self.assertFalse((output / "material-inspection.json").exists())
            if target: target.write_bytes(original)

    def test_staged_public_certificate_and_parser_drift_are_rechecked(self):
        for name in ("public-certificate.der", "public-certificate.pem", "parser"):
            output = self.root / ("changed-" + name)
            def mutate(command):
                if command.stage == "verify-selected-runtime-signatures" and name != "parser":
                    (output / name).write_bytes(b"changed-during-inspection")
                if command.stage == "after-inspection-clean-parser" and name == "parser":
                    self.runner.fault = "dirty"
            with self.subTest(name=name), self.assertRaisesRegex(private.Refused, "inspection-failed"):
                self.caller(callback=mutate, review=replace(self.review, output=output)).run(self.fixture.packet)
            self.assertFalse((output / "material-inspection.json").exists())

    def test_consumed_before_failed_admission_and_concurrent_replay(self):
        caller = self.caller()
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(caller.run, self.fixture.packet) for _ in range(2)]
        self.assertEqual(sum(f.exception() is None for f in futures), 1)
        errors = [f.exception() for f in futures if f.exception() is not None]
        self.assertEqual(str(errors[0]), "material-inspection-caller-already-used")
        with self.assertRaisesRegex(private.Refused, "already-used"): caller.run(self.fixture.packet)
        caller = self.caller()
        with self.assertRaises(private.Refused): caller.run(self.root / "missing-packet")
        with self.assertRaisesRegex(private.Refused, "already-used"): caller.run(self.fixture.packet)

    def test_existing_output_vm_namespace_release_context_and_overlap_are_refused(self):
        outputs = [self.fixture.packet, self.root / "dist/prerelease/result", self.root / "Omarchy VM Manager/VMs/result"]
        for output in outputs:
            if not output.parent.exists(): output.parent.mkdir(mode=0o700, parents=True)
            with self.subTest(output=output.name), self.assertRaises(private.Refused):
                self.caller(review=replace(self.review, output=output)).run(self.fixture.packet)
        with patch.dict(os.environ, {"GITHUB_REF": "refs/tags/v1.0.0"}):
            with self.assertRaises(private.Refused): self.caller().run(self.fixture.packet)
        self.assertFalse(self.output.exists())

    def test_review_and_selection_are_typed_and_domain_bound(self):
        with self.assertRaises(private.Refused): materials.MaterialInspectionCaller({}, self.selection, self.review)
        with self.assertRaises(private.Refused): materials.ReviewedMaterialInspection("invalid", "0" * 64, "0" * 64, "0" * 64, self.output)
        with self.assertRaises(private.Refused): materials.ReviewedMaterialInspection("0" * 64, "0" * 64, "0" * 64, "0" * 64, Path("relative"))
        self.assertNotEqual(self.review.request_digest(), replace(self.review, output=self.root / "other").request_digest())
        self.assertNotEqual(self.selection.binding(), materials.MaterialSelection(self.fixture.material, self.root / "other.der").binding())


if __name__ == "__main__": unittest.main()
