"""Fixed Reclaim space request. Runs the guest's argument-less trim helper.

Only the fixed stage, a numeric errno and the trimmed filesystem names leave
the guest; never paths, fstrim output or sudo's stderr.
"""
import json
import os
import select
import signal
import subprocess
import sys
import time
import uuid

IDENTITY = '/usr/lib/try-omarchy/managed-ssh-identity'
SUDO = '/usr/bin/sudo'
HELPER = '/usr/bin/try-omarchy-reclaim'
FILESYSTEMS = ('root', 'home')


def verify(identity, vm, session, user):
    assert uuid.UUID(identity['vmID']) == uuid.UUID(vm)
    assert uuid.UUID(identity['sessionToken']) == uuid.UUID(session)
    assert identity['user'] == user and identity['uid'] == os.getuid()
    assert 1000 <= os.getuid() < 60000


def run_helper(control_fd, timeout=1800, popen=subprocess.Popen):
    """Run the helper through its fixed sudo rule; EOF on control cancels it."""
    # -n never prompts: a guest without the rule fails instead of waiting.
    child = popen([SUDO, '-n', HELPER], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                  stderr=subprocess.DEVNULL, env={'PATH': '/usr/bin:/bin', 'LC_ALL': 'C'})
    deadline = time.monotonic() + timeout
    try:
        while True:
            if select.select([control_fd], [], [], 0.2)[0] and not os.read(control_fd, 1):
                raise InterruptedError('cancelled')
            status = child.poll()
            if status is not None:
                return status, child.stdout.read(4097)
            if time.monotonic() >= deadline:
                raise TimeoutError('timeout')
    finally:
        if child.poll() is None:
            # sudo runs as root, so the owner usually may not signal it (EPERM).
            # Stop waiting instead: the trim may finish in the guest, which is
            # harmless, and the host never reports it as complete.
            try:
                child.terminate()
                child.wait(timeout=5)
            except (OSError, subprocess.TimeoutExpired):
                try:
                    child.kill()
                except OSError:
                    pass


def outcome(status, output):
    """Map the helper's exit to trimmed filesystems or a fixed stage."""
    try:
        report = json.loads(output) if output and len(output) <= 4096 else None
    except ValueError:
        report = None
    if status == 0:
        # The helper ran; anything but its exact report is an unconfirmed trim.
        names = report.get('filesystems') if isinstance(report, dict) and set(report) == {'filesystems'} else None
        if (isinstance(names, list) and names[:1] == ['root'] and len(set(names)) == len(names)
                and all(name in FILESYSTEMS for name in names)):
            return names
        raise RuntimeError('trim')
    if isinstance(report, dict) and isinstance(report.get('failure'), str):
        # The helper ran and reported its own failure.
        raise RuntimeError('trim')
    # No helper report: sudo refused (no rule) or the helper is missing.
    raise LookupError('unsupported')


def main(vm, session, user, operation):
    def interrupted(signum, frame):
        raise InterruptedError('cancelled')
    for signum in (signal.SIGHUP, signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, interrupted)
    stage = 'prerequisites'
    try:
        identity = json.loads(subprocess.check_output([IDENTITY], timeout=3, stderr=subprocess.DEVNULL))
        verify(identity, vm, session, user)
        uuid.UUID(operation)
        stage = 'trim'
        status, output = run_helper(sys.stdin.fileno())
        try:
            names = outcome(status, output)
        except LookupError:
            stage = 'unsupported'
            raise
        print(json.dumps({'vmID': vm, 'sessionID': session, 'operationID': operation, 'filesystems': names}))
    except BaseException as failure:
        report = {'failure': stage}
        code = getattr(failure, 'errno', None) if isinstance(failure, OSError) else None
        if type(code) is int and 1 <= code <= 4095:
            report['errno'] = code
        print(json.dumps(report))
        sys.exit(1)
