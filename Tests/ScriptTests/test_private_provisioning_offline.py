"""Complete offline policy against synthetic CMS, fake APIs/processes and clocks."""
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
import private_provisioning_offline as offline
import offline_inspection_worker as worker
import offline_inspection_runner as supervisor
from private_provisioning_materials import MaterialSelection
from private_provisioning_signer import ExecutionAuthorization
from test_private_provisioning_inputs import SourceFixture
from test_private_provisioning_package import FakeSigner, put, TEAM
from test_private_provisioning_signer import PARSER_REVISION

CERT = b"synthetic public certificate"


def der(tag, value):
    size = len(value)
    length = bytes([size]) if size < 128 else bytes([128 + (size.bit_length() + 7) // 8]) + size.to_bytes((size.bit_length() + 7) // 8, "big")
    return bytes([tag]) + length + value


def cms(payload, kind=worker.DATA_OID, outer=worker.SIGNED_OID, detached=False):
    # Synthetic envelope/signers only. No key, certificate or CMS signature made.
    encapsulated = der(6, kind) + (b"" if detached else der(0xA0, der(4, payload)))
    signed = der(2, b"\x01") + der(0x31, der(0x30, der(6, b"\x2a\x03"))) + der(0x30, encapsulated)
    signed += der(0x31, der(0x30, der(2, b"\x01")))
    return der(0x30, der(6, outer) + der(0xA0, der(0x30, signed)))


class Clock:
    def __init__(self): self.now = 0
    def __call__(self): return self.now


class FakeAPI:
    test_double = True

    def __init__(self, fixture):
        self.fixture = fixture; self.calls = []; self.references = set(); self.infos = {}; self.fault = None

    def disable_interaction(self): self.calls.append(("interaction", False)); return self.fault != "interaction"
    def dependency_status(self, path):
        self.calls.append(("dependency", path))
        return {"revision": PARSER_REVISION if path == self.fixture.material.parser_checkout else self.fixture.runtime["patchCommit"],
                "clean": self.fault != "dirty"}
    def keychain_open(self, path):
        self.calls.append(("keychain_open", path)); ref = ("keychain", len(self.calls)); self.references.add(ref); return ref
    def keychain_status(self, ref):
        self.calls.append(("keychain_status", ref))
        if self.fault == "keychain-exception": raise RuntimeError("synthetic-secret-do-not-log")
        return 7 if self.fault == "unlocked" else 6
    def release(self, ref): self.calls.append(("release", ref)); self.references.remove(ref)
    def cms_content(self, raw):
        self.calls.append(("cms_content",))
        if self.fault == "cms-exception": raise RuntimeError("synthetic-secret-do-not-log")
        return b"different content" if self.fault == "cms-content" else worker.signed_content(raw)
    def certificate_info(self, raw):
        self.calls.append(("certificate",))
        return {"commonName": "wrong" if self.fault == "certificate-name" else self.fixture.material.identity,
                "notBefore": 0, "notAfter": 1 if self.fault == "certificate-expired" else 4_000_000_000}
    def static_open(self, path):
        self.calls.append(("static_open", path)); ref = ("static", path); self.references.add(ref); return ref
    def static_validate(self, ref, flags, requirement):
        self.calls.append(("static_validate", flags, requirement))
        assert flags in (worker.STATIC_FLAGS, worker.STATIC_FLAGS | worker.CHECK_NESTED)
        assert flags & worker.NO_NETWORK and 'subject.OU' in requirement and TEAM in requirement
        if self.fault == "static-exception": raise RuntimeError("synthetic-secret-do-not-log")
        return self.fault != "static-invalid"
    def static_info(self, ref):
        self.calls.append(("static_info", ref)); path = ref[1]
        expected = {"com.apple.security.hypervisor": True} if path.name in ("TryOmarchyKit.bundle", "omarchy-vm-helper") else {}
        info = {"identifier": "dev.tryomarchy.kit", "team": TEAM, "flags": worker.RUNTIME,
                "timestamp": 1_700_000_000, "entitlements": expected}
        variants = {"wrong-team": {"team": "ZZZ1234567"}, "wrong-identifier": {"identifier": "wrong"},
                    "adhoc": {"flags": worker.RUNTIME | worker.ADHOC}, "no-runtime": {"flags": 0},
                    "no-timestamp": {"timestamp": None}, "nan-timestamp": {"timestamp": float("nan")},
                    "wrong-entitlements": {"entitlements": {"unexpected": True}}}
        info.update(variants.get(self.fault, {})); return info


class FakeProcess:
    def __init__(self, factory, spec):
        self.factory, self.spec = factory, spec; self.killed = self.reaped = self.closed = self.exited = False
        self.status = 0; self.descendants = factory.mode == "descendants"; self.chunks = []
        self.wait_timeout = None
        if factory.mode in ("hang", "stage-timeout", "job-timeout", "stdout-overflow", "stderr-overflow"):
            if factory.mode.endswith("overflow"):
                stream = factory.mode.split("-")[0]
                self.chunks = [(stream, b"x" * 65536)] * 32 + [(stream, b"x")]
            return
        try:
            if factory.callback: factory.callback(spec, factory)
            value = worker.perform(spec, factory.api)
            raw = private.canonical(value)
            if factory.mode == "invalid-json": raw = b'{"a":1,"a":2}'
            self.chunks = [("stdout", raw[i:i + 65536]) for i in range(0, len(raw), 65536)]
        except BaseException:
            self.status = 1; self.chunks = [("stderr", b"synthetic-secret-do-not-log")]

    def read_ready(self, maximum, timeout):
        assert maximum == 65536 and 0 <= timeout <= 0.05
        self.factory.clock.now += {"hang": 1, "stage-timeout": 121, "job-timeout": 101}.get(self.factory.mode, 0.001)
        if self.factory.on_read: self.factory.on_read(self)
        if self.factory.mode in ("hang", "stage-timeout", "job-timeout"): return []
        return [self.chunks.pop(0)] if self.chunks else []
    def poll(self):
        if self.factory.mode in ("hang", "stage-timeout", "job-timeout"): return None
        if not self.chunks: self.exited = True; return self.status
        return None
    def group_alive(self): return not self.exited or self.descendants
    def streams_closed(self): return not self.chunks
    def kill_group(self): self.killed = self.exited = True; self.descendants = False
    def wait(self, timeout):
        self.wait_timeout = timeout; self.reaped = True
        if self.factory.mode == "wait-failure": raise TimeoutError("private-diagnostic")
        return self.status
    def close(self): self.closed = True


class Factory:
    test_double = True

    @property
    def api_test_double(self): return self.api.test_double

    def __init__(self, fixture, clock):
        self.clock = clock; self.api = FakeAPI(fixture); self.processes = []
        self.implementationSHA256 = offline.implementation_digest()
        self.mode = None; self.callback = None; self.on_read = None
    def spawn(self, spec):
        process = FakeProcess(self, spec); self.processes.append(process); return process


class OfflineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="offline-inspection-fixture-")
        self.addCleanup(self.temp.cleanup); self.root = Path(self.temp.name).resolve()
        env = patch.dict(os.environ, {"GITHUB_REF": "", "GITHUB_EVENT_NAME": ""}); env.start(); self.addCleanup(env.stop)
        self.profile = FakeSigner().profile()[2]; self.profile_content = plistlib.dumps(self.profile); self.der = cms(self.profile_content)
        with patch("test_private_provisioning_package.PROFILE", self.der), patch("test_private_provisioning_signer.PROFILE", self.der):
            self.fixture = SourceFixture(self.root)
        put(self.root / "material/public.der", CERT)
        put(self.fixture.material.upstream / offline.HELPER_ENTITLEMENTS, plistlib.dumps({"com.apple.security.hypervisor": True}))
        put(self.fixture.material.upstream / offline.QEMU_ENTITLEMENTS, plistlib.dumps({}))
        self.selection = MaterialSelection(self.fixture.material, self.root / "material/public.der")
        self.review = offline.OfflineReview(self.fixture.review.request_digest(), self.selection.binding(), private.digest(CERT),
            offline.implementation_digest(), private.digest(private.read(self.fixture.material.upstream / offline.HELPER_ENTITLEMENTS)),
            private.digest(private.read(self.fixture.material.upstream / offline.QEMU_ENTITLEMENTS)), self.root / "inspection")
        self.clock = Clock(); self.factory = Factory(self.fixture, self.clock)
        for name in ("subprocess.run", "subprocess.Popen", "subprocess.check_output", "socket.socket", "ctypes.CDLL"):
            guard = patch(name, side_effect=AssertionError("No real processes, network or native libraries in offline tests"))
            guard.start(); self.addCleanup(guard.stop)

    def caller(self, review=None, authorization=True):
        review = review or self.review
        auth = supervisor.OfflineAuthorization(review.request_digest(), self.fixture.review.scopeSHA256,
            self.selection.binding(), review.implementationSHA256, frozenset({"offline-native-inspect"})) if authorization is True else authorization
        self.runner = supervisor.Runner(self.factory, auth, self.clock)
        return offline.OfflineInspectionCaller(self.fixture.review, self.selection, review, self.runner, wall_clock=lambda: 1_800_000_000)

    def fail(self, caller=None):
        with self.assertRaisesRegex(private.Refused, "^offline-inspection-refused$"): (caller or self.caller()).run(self.fixture.packet)
        self.assertFalse((self.review.output / "offline-inspection.json").exists())

    def test_full_fake_adapter_preserves_inputs_and_explicitly_leaves_proofs_unestablished(self):
        before = private.tree(self.fixture.packet); originals = private.tree(self.root / "material")
        caller = self.caller(); read = private.read
        def guarded(path, *args):
            self.assertNotEqual(Path(path), self.fixture.material.keychain)
            return read(path, *args)
        with patch.object(private, "read", side_effect=guarded): receipt = caller.run(self.fixture.packet)
        self.assertEqual(before, private.tree(self.fixture.packet)); self.assertEqual(originals, private.tree(self.root / "material"))
        self.assertEqual(receipt["status"], "FAKE_OFFLINE_INSPECTION_ONLY"); self.assertFalse(receipt["nativeValidationObserved"])
        self.assertEqual(receipt["daemonCheck"], "NOT_RUN"); self.assertEqual(receipt["privateKeyAvailability"], "NOT_QUERIED")
        self.assertEqual(receipt["profileSignerAuthenticity"], "NOT_ESTABLISHED"); self.assertEqual(receipt["certificateTrust"], "NOT_EVALUATED")
        self.assertFalse(receipt["signingAuthorized"]); self.assertFalse(receipt["guestRunAuthorized"])
        self.assertTrue(receipt["cleanupConfirmed"]); self.assertEqual(self.factory.api.references, set())
        self.assertNotEqual(receipt["stagedMaterialSHA256"], self.fixture.material.binding())
        self.assertEqual(self.review.output.stat().st_mode & 0o777, 0o700)
        self.assertEqual((self.review.output / "manager.provisionprofile").stat().st_mode & 0o777, 0o600)
        self.assertTrue(all(p.reaped and p.closed and not p.killed for p in self.factory.processes))
        checks = [c for c in self.factory.api.calls if c[0] == "static_validate"]
        self.assertEqual(len(checks), receipt["staticCodeChecks"])
        self.assertTrue(all(c[1] & worker.NO_NETWORK for c in checks))
        self.assertFalse(Path(self.fixture.scope["root"]).exists())

    def test_default_denial_precedes_all_source_and_material_io(self):
        caller = offline.OfflineInspectionCaller(self.fixture.review, self.selection, self.review)
        with patch.object(offline.SourceInputAdmission, "open", side_effect=AssertionError("No input IO")), \
             patch.object(offline, "_stamp_keychain", side_effect=AssertionError("No keychain IO")), \
             patch.dict(os.environ, {"OFFLINE_INSPECTION_APPROVED": "yes"}): self.fail(caller)
        self.assertFalse(self.review.output.exists())

    def test_old_signing_authority_and_wrong_effects_cannot_authorize_offline_work(self):
        old = ExecutionAuthorization(self.review.request_digest(), self.fixture.review.scopeSHA256, self.selection.binding(), frozenset({"inspect"}))
        self.fail(self.caller(authorization=old))
        auth = self.caller().runner.authorization
        for field, value in (("effects", frozenset({"inspect"})), ("effects", frozenset({"offline-native-inspect", "build"})),
                             ("requestSHA256", "0" * 64), ("scopeSHA256", "0" * 64),
                             ("selectionSHA256", "0" * 64), ("implementationSHA256", "0" * 64)):
            with self.subTest(field=field): self.fail(self.caller(authorization=replace(auth, **{field: value})))
        self.assertEqual(self.factory.processes, [])

    def test_fixture_cannot_dispatch_to_nonfake_factory(self):
        self.factory.test_double = False
        with patch.object(offline, "_stamp_keychain", side_effect=AssertionError("No metadata")): self.fail()
        self.assertFalse(self.review.output.exists()); self.assertEqual(self.factory.processes, [])

    def test_review_domains_and_output_and_implementation_are_bound(self):
        self.assertNotEqual(self.review.request_digest(), self.fixture.review.request_digest())
        self.assertNotEqual(self.review.request_digest(), replace(self.review, output=self.root / "other").request_digest())
        for field in ("sourceRequestSHA256", "selectionSHA256", "implementationSHA256"):
            with self.subTest(field=field): self.fail(self.caller(review=replace(self.review, **{field: "0" * 64})))
        with self.assertRaises(private.Refused): offline.OfflineReview("invalid", *(["0" * 64] * 5), self.review.output)
        with self.assertRaises(private.Refused): offline.OfflineInspectionCaller({}, self.selection, self.review)
        self.assertNotIn(str(self.selection.public_certificate), repr(self.review) + repr(self.caller()) + repr(worker.task("locked", path="/synthetic")))

    def test_profile_certificate_entitlements_and_implementation_changes_refuse_before_workers(self):
        for path in (self.fixture.material.profile, self.selection.public_certificate,
                     self.fixture.material.upstream / offline.HELPER_ENTITLEMENTS, self.fixture.material.upstream / offline.QEMU_ENTITLEMENTS):
            before = path.read_bytes(); path.write_bytes(b"changed")
            with self.subTest(path=path.name): self.fail()
            path.write_bytes(before)
        with patch.object(offline, "implementation_digest", return_value="0" * 64): self.fail()
        self.assertEqual(self.factory.processes, [])

    def test_keychain_locked_and_interaction_disabled_and_references_always_released(self):
        for fault in ("unlocked", "keychain-exception", "interaction"):
            self.factory.api.fault = fault
            with self.subTest(fault=fault), self.assertRaises(private.Refused): worker.perform(worker.task("locked", path=str(self.fixture.material.keychain)), self.factory.api)
            self.assertEqual(self.factory.api.references, set())
        self.assertTrue(all(c == ("interaction", False) for c in self.factory.api.calls if c[0] == "interaction"))

    def test_static_code_policy_failures_never_fallback_to_network_or_leak_references(self):
        for fault in ("static-invalid", "static-exception", "wrong-team", "wrong-identifier", "adhoc", "no-runtime", "no-timestamp", "nan-timestamp", "wrong-entitlements"):
            self.factory.api.fault = fault
            with self.subTest(fault=fault), self.assertRaises((private.Refused, RuntimeError)):
                worker.perform(worker.task("static", path=str(self.fixture.material.upstream), team=TEAM, nested=False, entitlements={}), self.factory.api)
            self.assertEqual(self.factory.api.references, set())
        validates = [c for c in self.factory.api.calls if c[0] == "static_validate"]
        self.assertEqual(len(validates), 9); self.assertTrue(all(c[1] == worker.STATIC_FLAGS for c in validates))

    def test_cms_rejects_encryption_nested_content_and_detached_before_any_api(self):
        for raw in (cms(self.profile_content, outer=bytes.fromhex("2a864886f70d010703")),
                    cms(self.profile_content, kind=worker.SIGNED_OID), cms(cms(self.profile_content)), cms(self.profile_content, detached=True),
                    b"\x30\x80\x00\x00", self.der + b"trailing", self.der[:-1], b"\x30\x84\xff\xff\xff\xff"):
            with self.subTest(length=len(raw)), self.assertRaises(private.Refused): worker.perform(worker.task("profile", content=worker.blob(raw)), self.factory.api)
        self.assertEqual(self.factory.api.calls, [])

    def test_cms_requires_native_decoder_to_return_the_guarded_content(self):
        self.assertEqual(worker.signed_content(self.der), self.profile_content)
        self.factory.api.fault = "cms-content"
        with self.assertRaises(private.Refused): worker.perform(worker.task("profile", content=worker.blob(self.der)), self.factory.api)
        self.assertEqual([c[0] for c in self.factory.api.calls], ["interaction", "cms_content"])

    def test_der_depth_and_size_and_noncanonical_lengths_are_bounded(self):
        raw = der(2, b"\x01")
        for _ in range(34): raw = der(0x30, raw)
        for invalid in (raw, b"\x30\x81\x01\x00", b"x" * (worker.LIMIT + 1)):
            with self.assertRaises(private.Refused): worker.signed_content(invalid)

    def test_unknown_tasks_fields_and_vm_namespaces_refuse_before_api(self):
        values = [worker.Task("daemon-check", b"{}"), worker.task("locked", path="/synthetic", unlock=True),
                  worker.task("locked", path="/synthetic/Omarchy VM Manager/VMs/disposable"),
                  worker.task("static", path="/synthetic", team=TEAM, nested=True, entitlements={}, flags=0)]
        for spec in values:
            with self.assertRaises(private.Refused): worker.perform(spec, self.factory.api)
        self.assertEqual(self.factory.api.calls, [])

    def test_live_stdout_and_stderr_caps_kill_group_reap_close_without_success(self):
        for mode in ("stdout-overflow", "stderr-overflow"):
            factory = Factory(self.fixture, Clock()); factory.mode = mode
            caller = self.caller(); self.runner.factory = factory; self.runner.clock = factory.clock
            self.fail(caller); process = factory.processes[-1]
            self.assertTrue(process.killed and process.reaped and process.closed)
            self.assertEqual(process.wait_timeout, 5)
            if self.review.output.exists():
                self.assertNotIn(b"synthetic-secret", (self.review.output / "failure.json").read_bytes())
                # Each caller needs a fresh output; retain the failed one.
                self.review = replace(self.review, output=self.root / (mode + "-next"))

    def test_stage_timeout_kills_group_and_reaps(self):
        self.factory.mode = "stage-timeout"; self.fail()
        process = self.factory.processes[-1]
        self.assertTrue(process.killed and process.reaped and process.closed)

    def test_whole_job_deadline_does_not_reset_per_stage(self):
        caller = self.caller(); count = [0]
        def elapsed(process):
            count[0] += 1; self.clock.now += 100
        self.factory.on_read = elapsed
        self.fail(caller)
        self.assertGreaterEqual(len(self.factory.processes), 3)
        self.assertTrue(self.factory.processes[-1].killed)

    def test_whole_job_budget_includes_initial_source_admission(self):
        original = offline.SourceInputAdmission.open
        def delayed(*args):
            self.clock.now += 301
            return original(*args)
        with patch.object(offline.SourceInputAdmission, "open", side_effect=delayed): self.fail()
        self.assertEqual(self.factory.processes, []); self.assertFalse(self.review.output.exists())

    def test_reentrant_worker_dispatch_cannot_overlap_owned_groups(self):
        caller = self.caller(); refused = []
        def reenter(spec, factory):
            try: self.runner.run(spec, lambda: None)
            except private.Refused as error: refused.append(str(error))
        self.factory.callback = reenter
        receipt = caller.run(self.fixture.packet)
        self.assertEqual(len(refused), len(self.factory.processes))
        self.assertTrue(all(error == "offline-worker-overlap" for error in refused))
        self.assertTrue(receipt["cleanupConfirmed"])

    def test_cancellation_and_interrupt_kill_reap_and_consume_caller(self):
        caller = self.caller(); cancel = [False]
        self.factory.on_read = lambda _: cancel.__setitem__(0, True)
        with self.assertRaises(private.Refused): caller.run(self.fixture.packet, cancel=lambda: cancel[0])
        self.assertTrue(self.factory.processes[-1].killed and self.factory.processes[-1].reaped)
        with self.assertRaisesRegex(private.Refused, "already-used"): caller.run(self.fixture.packet)

    def test_root_exit_does_not_release_live_descendants(self):
        self.factory.mode = "descendants"; self.fail()
        process = self.factory.processes[-1]
        self.assertTrue(process.killed and process.reaped and process.closed)
        self.assertFalse(process.group_alive())

    def test_cleanup_failure_is_actionable_and_never_a_success(self):
        self.factory.mode = "wait-failure"; self.fail()
        report = private.decode(private.read(self.review.output / "failure.json"))
        self.assertFalse(report["cleanupConfirmed"]); self.assertFalse(report["automaticRetry"])
        self.assertTrue(self.factory.processes[-1].closed)

    def test_callback_mutation_of_frozen_input_aborts_and_reaps(self):
        def mutate(spec, factory):
            self.fixture.material.profile.write_bytes(b"changed-during-worker")
        self.factory.callback = mutate; self.fail()
        process = self.factory.processes[-1]
        self.assertTrue(process.killed and process.reaped and process.closed)
        self.assertFalse(private.decode(private.read(self.review.output / "failure.json"))["automaticRetry"])

    def test_staged_files_runtime_inventory_and_keychain_metadata_are_revalidated(self):
        targets = [self.review.output / "manager.provisionprofile", self.fixture.material.keychain,
                   self.fixture.material.upstream / offline.HELPER_ENTITLEMENTS,
                   self.fixture.packet / "runtime/TryOmarchySignedRuntime.lock.json"]
        for i, target in enumerate(targets):
            review = replace(self.review, output=self.root / ("mutation-" + str(i)))
            selected = review.output / target.name if target.parent == self.review.output else target
            original = target.read_bytes() if target.exists() else None
            self.factory = Factory(self.fixture, self.clock)
            self.factory.on_read = lambda process: selected.write_bytes(b"changed-after-worker")
            with self.subTest(i=i): self.fail(self.caller(review=review))
            self.assertTrue(self.factory.processes[-1].killed and self.factory.processes[-1].reaped)
            if original is not None: target.write_bytes(original)

    def test_api_exception_causes_fixed_private_failure_and_releases_native_references(self):
        self.factory.api.fault = "static-exception"; self.fail()
        self.assertEqual(self.factory.api.references, set())
        process = self.factory.processes[-1]
        self.assertTrue(process.reaped and process.closed); self.assertFalse(process.killed)
        self.assertFalse(process.group_alive())
        self.assertNotIn(b"synthetic-secret", (self.review.output / "failure.json").read_bytes())

    def test_keyboard_interrupt_from_progress_check_kills_reaps_and_closes(self):
        def interrupted(process): raise KeyboardInterrupt()
        self.factory.on_read = interrupted; self.fail()
        process = self.factory.processes[-1]
        self.assertTrue(process.killed and process.reaped and process.closed)

    def test_failed_atomic_spawn_is_not_misreported_as_confirmed_cleanup(self):
        self.factory.spawn = lambda _: (_ for _ in ()).throw(RuntimeError("private-launch-error"))
        self.fail()
        report = private.decode(private.read(self.review.output / "failure.json"))
        self.assertFalse(report["cleanupConfirmed"])

    def test_fake_api_cannot_be_mislabeled_as_a_native_validation(self):
        self.factory.test_double = False
        self.fail(); self.assertEqual(self.factory.processes, [])
        with self.assertRaises(private.Refused): worker.perform(worker.task("locked", path=str(self.fixture.material.keychain)), self.factory.api, expected_test_double=False)
        self.assertEqual(self.factory.api.calls, [])

    def test_caller_and_runner_replay_after_failure_are_consumed(self):
        self.factory.api.fault = "dirty"; caller = self.caller(); self.fail(caller)
        with self.assertRaisesRegex(private.Refused, "already-used"): caller.run(self.fixture.packet)
        with self.assertRaisesRegex(private.Refused, "already-used"): self.runner.start(self.runner.bindings)

    def test_typed_task_payload_cannot_exceed_worker_input_bound(self):
        with self.assertRaises(private.Refused): worker.Task("profile", b"x" * (2 * worker.LIMIT + 1)).decode()
        with self.assertRaises(private.Refused): worker.unblob("!not-base64!")

    def test_invalid_worker_json_is_private_fixed_failure(self):
        self.factory.mode = "invalid-json"; self.fail()
        process = self.factory.processes[-1]
        self.assertTrue(process.reaped and process.closed); self.assertFalse(process.killed)
        self.assertFalse(process.group_alive())
        self.assertNotIn(b"synthetic-secret", (self.review.output / "failure.json").read_bytes())

    def test_concurrent_caller_use_is_one_shot(self):
        caller = self.caller()
        with ThreadPoolExecutor(max_workers=2) as pool: results = [pool.submit(caller.run, self.fixture.packet) for _ in range(2)]
        self.assertEqual(sum(f.exception() is None for f in results), 1)
        self.assertEqual(len([f for f in results if str(f.exception()) == "offline-caller-already-used"]), 1)

    def test_unsafe_outputs_and_keychain_links_refuse_without_workers(self):
        for output in (self.fixture.packet, self.root / "Omarchy VM Manager/VMs/result"):
            output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            self.fail(self.caller(review=replace(self.review, output=output)))
        self.fixture.material.keychain.chmod(0o644); self.fail()
        self.assertEqual(self.factory.processes, [])

    def test_every_macho_is_enumerated_even_in_nonstandard_resource_paths(self):
        root = self.root / "enumeration"; root.mkdir(mode=0o700)
        put(root / "Resources/custom/tools/unusual", b"\xcf\xfa\xed\xfeNOT EXECUTABLE", True)
        put(root / "plain", b"plain data")
        self.assertEqual(offline.static_targets(root), [root / "Resources/custom/tools/unusual"])


if __name__ == "__main__": unittest.main()
