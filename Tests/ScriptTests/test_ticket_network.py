import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'Scripts'))
import ticket_network


class TicketVerificationTests(unittest.TestCase):
    def test_nested_verifier_network_error_retries_identical_read_only_arguments(self):
        arguments = ['python3', 'kit_signature.py', 'verify', '--require-notarization', '/fixture/kit']
        failure = subprocess.CalledProcessError(1, arguments, output='', stderr='NSURLErrorDomain Code=-1005')
        result = SimpleNamespace(stdout='verified\n', stderr='')
        with patch.object(ticket_network.subprocess, 'run', side_effect=[failure,result]) as run, patch.object(ticket_network.time,'sleep') as wait:
            self.assertIs(ticket_network.run_ticket_checked(*arguments),result)
            self.assertEqual([item.args[0] for item in run.call_args_list],[arguments,arguments])
            self.assertTrue(all(item.kwargs['check'] for item in run.call_args_list))
            wait.assert_called_once_with(5)

    def test_policy_failure_is_immediate_and_persistent_network_failure_stays_bounded(self):
        for detail,count in [('invalid signature',1),('NSURLErrorDomain Code=-1005',3)]:
            with self.subTest(detail=detail), patch.object(ticket_network.subprocess,'run',side_effect=subprocess.CalledProcessError(1,['fixture'],stderr=detail)) as run, patch.object(ticket_network.time,'sleep'):
                with self.assertRaises(subprocess.CalledProcessError):
                    ticket_network.run_ticket_checked('fixture')
                self.assertEqual(run.call_count,count)

    def test_assembly_and_final_validation_use_the_ticket_retry_without_weakening_flags(self):
        import assemble_app
        import verify_signed_app
        result=SimpleNamespace(stdout='verified',stderr='')
        with patch.object(verify_signed_app,'run_ticket_checked',return_value=result) as command:
            self.assertIs(verify_signed_app.run('python3','kit_signature.py','verify','--require-notarization','/fixture'),result)
            self.assertIs(verify_signed_app.run('codesign','--verify','--check-notarization','-R=notarized','/fixture'),result)
            self.assertIs(verify_signed_app.run('xcrun','stapler','validate','/fixture'),result)
            self.assertEqual(command.call_count,3)
        self.assertIs(assemble_app.run_ticket_checked,ticket_network.run_ticket_checked)
