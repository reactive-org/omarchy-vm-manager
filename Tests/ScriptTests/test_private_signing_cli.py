"""Reusable operator CLI: disposable public inputs, virtual workers and fake FFI."""
from dataclasses import asdict
import io
import os
from pathlib import Path
import sys
from unittest.mock import patch
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]/'Scripts'))
import private_signing as cli
import private_provisioning_package as p
import private_provisioning_offline as offline
import receipt_bound_signing as signing
import bounded_signing_process as bounded
import test_receipt_bound_signing as signing_tests
from test_receipt_bound_signing import Commands, Factory, Tasks


class OperatorTests(unittest.TestCase):
    def setUp(self):
        self.seed = signing_tests.ReceiptSigningTests('test_end_to_end_private_roundtrip_is_fake_and_avoids_all_legacy_verifiers')
        self.seed.setUp(); self.addCleanup(self.seed.doCleanups)
        self.root = self.seed.root; self.plan = self.root/'operator-plan'
        historical = asdict(self.seed.historical); historical['output'] = str(historical['output'])
        self.selection = {'format': 1, 'kind': 'PRIVATE_SIGNING_SELECTION',
            'sourceInputPacket': str(self.seed.fixture.packet), 'sourceReview': asdict(self.seed.fixture.review),
            'historicalOfflineReview': historical,
            'stagedMaterial': {k: str(v) for k, v in vars(self.seed.material).items()}}
        self.input = self.root/'selection.json'; p.write_json(self.input, self.selection)
        self.backends = []
        test = self

        class FakeBackend:
            def __init__(self, source, historical, material, review, authorization):
                test.backends.append(self); self.review = review; self.authorization = authorization
                self.ops = Commands(test.seed.fixture)
                self.factory = Factory(review, material, self.ops)
                self.runner = bounded.SigningRunner(review, material, self.factory, authorization, clock=self.ops.clock)
                self.tasks = Tasks(test.seed.fixture)
                self.caller = signing.ReceiptBoundCaller(source, historical, material, review, self.runner, signing.CandidateVerifier(self.tasks))
                self.retained = False
            def run(self, packet, cancel): return self.caller.run(packet, cancel=cancel)
            def evidence(self):
                return {'commandEvidence': self.runner.worker_records, 'nativeEvidence': self.tasks.records,
                        'unresolvedHandles': len(self.factory.pending_cleanup), 'commandCleanupConfirmed': self.runner.cleanup_confirmed}
            def retain(self): self.retained = True

        self.backend = FakeBackend

    def prepare(self): return cli.prepare(self.input, self.plan)

    def rewrite(self, file, value): file.write_bytes(p.canonical(value)+b'\n')

    def test_prepare_and_check_are_public_data_only_and_keep_private_modes(self):
        before = p.tree(self.seed.fixture.packet)
        with patch('private_provisioning_materials._stamp_keychain', side_effect=AssertionError('No keychain stat')):
            summary = self.prepare(); self.assertEqual(summary, cli.check(self.plan))
        self.assertFalse(summary['executionAuthorized']); self.assertEqual(summary['keyAvailability'], 'NOT_QUERIED')
        self.assertEqual(self.plan.stat().st_mode & 0o777, 0o700)
        self.assertTrue(all(f.stat().st_mode & 0o777 == 0o600 for f in self.plan.iterdir()))
        self.assertEqual(p.read(self.plan/'.gitignore'), b'*\n')
        self.assertFalse((self.plan/'candidate').exists()); self.assertFalse(self.backends)
        self.assertEqual(before, p.tree(self.seed.fixture.packet))

    def test_import_previous_review_copies_data_and_discards_approval_fields(self):
        record = dict(self.selection, kind='RECEIPT_BOUND_SIGNED_CANDIDATE_REVIEW', reviewOnly=True,
                      allApprovals='GRANTED', signingExecuted=True, proposedOutput='/never-use-old-output')
        self.rewrite(self.input, record); self.prepare()
        self.assertEqual(p.decode(p.read(self.plan/'selection.json')), self.selection)
        self.assertNotIn(b'GRANTED', p.read(self.plan/'plan.json'))

    def test_denied_confirmation_constructs_no_backend_and_does_not_consume(self):
        self.prepare()
        with self.assertRaises(p.Refused): cli.execute(self.plan, lambda _: False, backend=self.backend)
        self.assertFalse(self.backends); self.assertFalse((self.plan/'consumed.json').exists())

    def test_fixture_never_selects_native_backend_even_with_confirmation(self):
        self.prepare()
        with patch.object(cli, 'terminal_confirmation', side_effect=AssertionError('No prompt')):
            with self.assertRaisesRegex(p.Refused, 'fixture-cannot-sign'): cli.execute(self.plan, cli.terminal_confirmation)
        self.assertFalse((self.plan/'consumed.json').exists())

    def test_explicit_fake_run_completes_roundtrip_and_retains_evidence_once(self):
        summary = self.prepare(); before = p.tree(self.seed.fixture.packet)
        result = cli.execute(self.plan, lambda s: s == summary, backend=self.backend)
        self.assertEqual(result['status'], 'FAKE_RECEIPT_BOUND_SIGNER_ONLY')
        self.assertEqual(self.backends[0].authorization.effects, bounded.EFFECTS)
        self.assertTrue(self.backends[0].retained)
        evidence = p.decode(p.read(self.plan/'attempt.json'))
        self.assertEqual(evidence['evidence']['unresolvedHandles'], 0)
        self.assertTrue(evidence['evidence']['commandCleanupConfirmed'])
        self.assertEqual(cli.check(self.plan)['status'], 'CONSUMED_NO_RETRY')
        with self.assertRaisesRegex(p.Refused, 'consumed'): cli.execute(self.plan, lambda _: True, backend=self.backend)
        self.assertEqual(len(self.backends), 1); self.assertEqual(before, p.tree(self.seed.fixture.packet))

    def test_failed_backend_is_consumed_without_exception_text_or_retry(self):
        self.prepare()
        def failing(*_): raise RuntimeError('private keychain path/password must not be logged')
        with self.assertRaises(RuntimeError): cli.execute(self.plan, lambda _: True, backend=failing)
        evidence = p.read(self.plan/'attempt.json')
        self.assertNotIn(b'password', evidence); self.assertNotIn(b'keychain path', evidence)
        self.assertEqual(p.decode(evidence)['status'], 'STOPPED_NO_RETRY')
        with self.assertRaisesRegex(p.Refused, 'consumed'): cli.execute(self.plan, lambda _: True, backend=failing)

    def test_mutation_while_confirming_refuses_before_consumption_or_backend(self):
        self.prepare()
        def confirm(_):
            record = p.decode(p.read(self.plan/'plan.json')); record['requestSHA256'] = '0'*64
            self.rewrite(self.plan/'plan.json', record); return True
        with self.assertRaises(p.Refused): cli.execute(self.plan, confirm, backend=self.backend)
        self.assertFalse(self.backends); self.assertFalse((self.plan/'consumed.json').exists())

    def test_changed_wrapper_or_engine_binding_requires_new_plan(self):
        self.prepare(); impl = cli.implementation()
        with patch.object(cli, 'implementation', return_value=dict(impl, operatorFiles={'private_signing.py': '0'*64})):
            with self.assertRaisesRegex(p.Refused, 'implementation-changed'): cli.check(self.plan)
        record = p.decode(p.read(self.plan/'plan.json')); record['implementation']['engineSHA256'] = '0'*64
        self.rewrite(self.plan/'plan.json', record)
        with self.assertRaisesRegex(p.Refused, 'implementation-changed'): cli.check(self.plan)

    def test_injected_saved_approval_and_unknown_selection_fields_refuse(self):
        self.prepare()
        record = p.decode(p.read(self.plan/'plan.json')); record['executionAuthorized'] = True
        self.rewrite(self.plan/'plan.json', record)
        with self.assertRaisesRegex(p.Refused, 'schema'): cli.check(self.plan)
        with self.assertRaisesRegex(p.Refused, 'schema'): cli._selection(dict(self.selection, password='never-used'))

    def test_changed_profile_and_historical_receipt_are_refused_without_native_work(self):
        self.prepare(); profile = self.seed.material.profile; original = p.read(profile)
        profile.write_bytes(b'changed public fixture')
        with self.assertRaisesRegex(p.Refused, 'public-input-changed'): cli.check(self.plan)
        profile.write_bytes(original)
        receipt = p.decode(p.read(self.seed.receipt_path)); receipt['cleanupConfirmed'] = False
        self.rewrite(self.seed.receipt_path, receipt)
        with self.assertRaisesRegex(p.Refused, 'historical-receipt'): cli.check(self.plan)
        self.assertFalse(self.backends)

    def test_incomplete_historical_worker_cleanup_is_refused(self):
        receipt = p.decode(p.read(self.seed.receipt_path)); receipt['workerEvidence'][0]['handle']['rootReaped'] = False
        self.rewrite(self.seed.receipt_path, receipt)
        with self.assertRaisesRegex(p.Refused, 'historical-cleanup'): self.prepare()
        self.assertFalse(self.plan.exists())

    def test_existing_output_and_overlapping_plan_are_preserved(self):
        self.prepare(); sentinel = self.plan/'candidate'; sentinel.mkdir(mode=0o700)
        p.write(sentinel/'keep', b'keep')
        with self.assertRaisesRegex(p.Refused, 'existing-output'): cli.check(self.plan)
        self.assertEqual(p.read(sentinel/'keep'), b'keep')
        with self.assertRaises(p.Refused): cli.prepare(self.input, self.seed.fixture.packet/'new-plan')
        with self.assertRaises(p.Refused): cli.prepare(self.input, self.plan)

    def test_vm_namespace_and_linked_plan_and_credential_reads_refuse(self):
        with self.assertRaisesRegex(p.Refused, 'vm-path'): cli._path('/fixture/Omarchy VM Manager/vms/fixture')
        with self.assertRaisesRegex(p.Refused, 'credential-content'): cli._read(self.seed.material.keychain)
        self.prepare(); link = self.root/'linked-plan'; link.symlink_to(self.plan, target_is_directory=True)
        with self.assertRaises(p.Refused): cli.check(link)

    def test_permissions_and_duplicate_json_keys_refuse(self):
        self.input.chmod(0o644)
        with self.assertRaisesRegex(p.Refused, 'private-file'): self.prepare()
        self.input.chmod(0o600); self.input.write_bytes(b'{"format":1,"format":1}')
        with self.assertRaises(p.Refused): self.prepare()

    def test_consumption_creation_is_exclusive_and_fences_competing_run(self):
        self.prepare(); write = p.write_json
        def write_once(path, value):
            if Path(path).name == 'consumed.json': write(path, {'otherAttempt': True})
            return write(path, value)
        with patch.object(p, 'write_json', side_effect=write_once):
            with self.assertRaises(FileExistsError): cli.execute(self.plan, lambda _: True, backend=self.backend)
        self.assertFalse(self.backends)

    def test_operator_binding_does_not_change_running_engine_digest(self):
        before = offline.implementation_digest(); self.prepare(); cli.check(self.plan)
        self.assertEqual(offline.implementation_digest(), before)
        self.assertNotIn('private_signing.py', offline.IMPLEMENTATION_FILES)

    def test_noninteractive_run_and_yes_flag_cannot_authorize(self):
        with patch.object(sys.stdin, 'isatty', return_value=False), patch('builtins.open', side_effect=AssertionError('No tty open')):
            with self.assertRaisesRegex(p.Refused, 'terminal-required'): cli.terminal_confirmation({})
        with patch('sys.stderr', new_callable=io.StringIO) as errors:
            self.assertEqual(cli.main(['run', '--plan', str(self.plan), '--yes']), 1)
        self.assertNotIn(str(self.plan), errors.getvalue()); self.assertFalse(self.backends)

    def test_cancellation_after_consent_does_not_consume_or_create_backend(self):
        self.prepare()
        with self.assertRaisesRegex(p.Refused, 'cancelled'):
            cli.execute(self.plan, lambda _: True, backend=self.backend, cancel=lambda: True)
        self.assertFalse(self.backends); self.assertFalse((self.plan/'consumed.json').exists())

    def test_cli_prepare_check_and_fixed_errors_do_not_echo_private_paths(self):
        with patch('sys.stdout', new_callable=io.StringIO) as output:
            self.assertEqual(cli.main(['prepare', '--selection', str(self.input), '--plan', str(self.plan)]), 0)
        self.assertNotIn(str(self.root), output.getvalue())
        self.assertFalse(p.decode(output.getvalue())['executionAuthorized'])
        with patch('sys.stdout', new_callable=io.StringIO) as output:
            self.assertEqual(cli.main(['check', '--plan', str(self.plan)]), 0)
        self.assertEqual(p.decode(output.getvalue())['keyAvailability'], 'NOT_QUERIED')
        with patch.object(cli, 'check', side_effect=p.Refused('operator-secret-private-path')), \
             patch('sys.stderr', new_callable=io.StringIO) as errors:
            self.assertEqual(cli.main(['check', '--plan', str(self.plan)]), 1)
        self.assertNotIn('secret', errors.getvalue()); self.assertIn('operator-stopped', errors.getvalue())

    def test_native_composition_passes_only_exact_typed_context_without_activation(self):
        from dataclasses import replace
        review = replace(self.seed.review, fixture=False)
        auth = signing.SigningAuthorization(review.request_digest(), bounded.EFFECTS)
        with patch.object(cli, 'CommandFactory') as factory, patch.object(cli, 'SigningRunner') as runner, \
             patch.object(cli, 'NativeTasks') as tasks, patch.object(cli, 'CandidateVerifier') as verifier, \
             patch.object(cli, 'ReceiptBoundCaller') as caller:
            cli.NativeBackend(self.seed.fixture.review, self.seed.historical, self.seed.material, review, auth)
        factory.assert_called_once_with(review, self.seed.material)
        runner.assert_called_once_with(review, self.seed.material, factory.return_value, auth)
        tasks.assert_called_once_with(review, self.seed.historical)
        verifier.assert_called_once_with(tasks.return_value)
        caller.assert_called_once_with(self.seed.fixture.review, self.seed.historical, self.seed.material,
                                       review, runner.return_value, verifier.return_value)
        caller.return_value.run.assert_not_called()

    def test_terminal_requires_exact_full_plan_phrase_and_uses_only_tty(self):
        summary = {'planSHA256': 'a'*64, 'sourceCommit': 'b'*40, 'scopeSHA256': 'c'*64}
        for answer, expected in [('yes\n', False), ('SIGN '+('a'*64)+'\n', True), ('SIGN '+('a'*63)+'\n', False)]:
            reader = io.StringIO(answer); writer = io.StringIO()
            with patch.object(sys.stdin, 'isatty', return_value=True), patch.object(sys.stdout, 'isatty', return_value=True), \
                 patch('builtins.open', side_effect=[reader, writer]) as opened:
                self.assertIs(cli.terminal_confirmation(summary), expected)
                self.assertEqual([call.args[0] for call in opened.call_args_list], ['/dev/tty', '/dev/tty'])


if __name__ == '__main__': unittest.main()
