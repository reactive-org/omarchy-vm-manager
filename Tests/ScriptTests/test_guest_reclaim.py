"""No VM/SSH: exercise the shipped Reclaim space guest program with stand-ins."""
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import unittest
import uuid
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[2] / 'Sources/OmarchyVMManagerCore/Resources/GuestReclaim.py'
spec = importlib.util.spec_from_file_location('guest_reclaim', SOURCE)
reclaim = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reclaim)


class FakeChild:
    def __init__(self, status, output=b'', running_polls=0):
        self.status, self.stdout, self.polls = status, io.BytesIO(output), running_polls
        self.terminated = False

    def poll(self):
        if self.terminated:
            return -15
        if self.polls:
            self.polls -= 1
            return None
        return self.status

    def terminate(self):
        self.terminated = True

    def wait(self, timeout=None):
        return self.poll()

    def kill(self):
        self.terminated = True


class GuestReclaimTests(unittest.TestCase):
    def control(self):
        read, write = os.pipe()
        self.addCleanup(os.close, read)
        return read, write

    def test_runs_only_the_fixed_helper_through_noninteractive_sudo(self):
        read, write = self.control()
        calls = []
        def popen(arguments, **options):
            calls.append((arguments, options))
            return FakeChild(0, b'{"filesystems": ["root", "home"]}')
        status, output = reclaim.run_helper(read, popen=popen)
        os.close(write)
        self.assertEqual(calls[0][0], ['/usr/bin/sudo', '-n', '/usr/bin/try-omarchy-reclaim'])
        self.assertEqual(calls[0][1]['stderr'], subprocess.DEVNULL)
        self.assertNotIn('shell', calls[0][1])
        self.assertEqual(reclaim.outcome(status, output), ['root', 'home'])

    def test_closed_control_channel_cancels_and_terminates_sudo(self):
        read, write = self.control()
        os.close(write)
        child = FakeChild(0, running_polls=1000)
        with self.assertRaises(InterruptedError):
            reclaim.run_helper(read, popen=lambda *a, **k: child)
        self.assertTrue(child.terminated)

    def test_unsignalable_root_sudo_does_not_turn_cancellation_into_a_failure(self):
        read, write = self.control()
        os.close(write)
        child = FakeChild(0, running_polls=1000)
        def refuse():
            raise PermissionError(1, 'Operation not permitted')
        child.terminate = child.kill = refuse
        with self.assertRaises(InterruptedError):
            reclaim.run_helper(read, popen=lambda *a, **k: child)

    def test_outcomes_map_to_fixed_stages(self):
        self.assertEqual(reclaim.outcome(0, b'{"filesystems": ["root"]}'), ['root'])
        for status, output in ((0, b'{"filesystems": ["home"]}'), (0, b'{"filesystems": ["root", "/home/owner"]}'),
                               (0, b'{"filesystems": ["root", "root"]}'), (1, b'{"failure": "trim-root"}'),
                               (0, b'{"filesystems": ["root"], "extra": 1}')):
            with self.assertRaises(RuntimeError, msg=output):
                reclaim.outcome(status, output)
        # sudo refused (no rule) or helper missing: nothing on stdout.
        for status, output in ((1, b''), (1, b'not json'), (127, b'')):
            with self.assertRaises(LookupError):
                reclaim.outcome(status, output)

    def report(self, identity, status=0, output=b'{"filesystems": ["root"]}'):
        vm, session, operation = str(uuid.uuid4()), str(uuid.uuid4()), str(uuid.uuid4())
        identity = identity(vm, session)
        printed = io.StringIO()
        with patch.object(reclaim.subprocess, 'check_output', return_value=json.dumps(identity).encode()), \
             patch.object(reclaim.os, 'getuid', return_value=1000), \
             patch.object(reclaim, 'run_helper', return_value=(status, output)), \
             patch.object(reclaim.signal, 'signal'), patch('sys.stdout', printed):
            try:
                reclaim.main(vm, session, 'owner', operation)
                code = 0
            except SystemExit as exit:
                code = exit.code
        return code, json.loads(printed.getvalue()), (vm, session, operation)

    def test_success_echoes_only_ids_and_filesystem_names(self):
        code, report, (vm, session, operation) = self.report(lambda vm, s: {'vmID': vm, 'sessionToken': s, 'user': 'owner', 'uid': 1000})
        self.assertEqual(code, 0)
        self.assertEqual(report, {'vmID': vm, 'sessionID': session, 'operationID': operation, 'filesystems': ['root']})

    def test_identity_mismatch_and_failures_report_only_a_stage(self):
        code, report, _ = self.report(lambda vm, s: {'vmID': str(uuid.uuid4()), 'sessionToken': s, 'user': 'owner', 'uid': 1000})
        self.assertEqual((code, report), (1, {'failure': 'prerequisites'}))
        good = lambda vm, s: {'vmID': vm, 'sessionToken': s, 'user': 'owner', 'uid': 1000}
        self.assertEqual(self.report(good, 1, b'')[:2], (1, {'failure': 'unsupported'}))
        self.assertEqual(self.report(good, 1, b'{"failure": "trim-home", "errno": 5}')[:2], (1, {'failure': 'trim'}))


if __name__ == '__main__':
    unittest.main()
