"""Fixed owner-home backup operation. No file names, archive data or stderr on SSH."""
import ctypes
import json
import os
import pwd
import re
import select
import signal
import stat
import subprocess
import sys
import time
import uuid


def verify(identity, mount, vm, session, user):
    assert uuid.UUID(identity['vmID']) == uuid.UUID(vm)
    assert uuid.UUID(identity['sessionToken']) == uuid.UUID(session)
    assert identity['user'] == user and identity['uid'] == os.getuid()
    assert 1000 <= os.getuid() < 60000
    mounts = mount['filesystems']
    assert len(mounts) == 1
    entry = mounts[0]
    assert (entry['source'], entry['target'], entry['fstype']) == ('mac', '/mnt/mac', '9p')
    options = set(entry['options'].split(','))
    assert {'rw', 'trans=virtio'} <= options and 'ro' not in options
    assert {v for v in options if v.startswith('cache=')} in ({'cache=readahead'}, {'cache=0x1'})
    assert {v for v in options if v.startswith('version=')} <= {'version=9p2000.L'}


def run_child(arguments, output, control_fd, timeout=86400):
    child = subprocess.Popen(arguments, stdin=subprocess.DEVNULL, stdout=output,
                             stderr=subprocess.DEVNULL, start_new_session=True,
                             env={'PATH': '/usr/bin:/bin', 'LC_ALL': 'C'})
    deadline = time.monotonic() + timeout
    try:
        while True:
            # The host keeps this channel open. EOF (including SSH disconnect)
            # cancels the whole tar/compressor process group, not the VM.
            if select.select([control_fd], [], [], 0.2)[0] and not os.read(control_fd, 1):
                raise InterruptedError('cancelled')
            status = child.poll()
            if status is not None:
                if status != 0:
                    raise RuntimeError('archive-failed')
                return
            if time.monotonic() >= deadline:
                raise TimeoutError('timeout')
    finally:
        # gzip can outlive tar on an interrupted connection. Reap/kill the
        # private group even if its leader has already exited.
        try:
            os.killpg(child.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            child.wait(timeout=3)
        except subprocess.TimeoutExpired:
            pass
        finally:
            # The leader may have exited before a compressor that ignored TERM.
            # Reaping the leader alone does not finish the private process group.
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait()


def publish(directory):
    # Linux atomic no-replace rename, including paths created during the backup.
    libc = ctypes.CDLL(None, use_errno=True)
    libc.renameat2.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    libc.renameat2.restype = ctypes.c_int
    if libc.renameat2(directory, b'home.tgz.partial', directory, b'home.tgz', 1) != 0:
        raise OSError(ctypes.get_errno(), 'publish-failed')


def archive(home, share, folder, control_fd, runner=run_child, publisher=publish):
    assert re.fullmatch(r'home-backup-[0-9a-f-]{36}', folder)
    home_fd = os.open(home, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        share_fd = os.open(share, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except BaseException:
        os.close(home_fd)
        raise
    try:
        info = os.fstat(home_fd)
        assert info.st_uid == os.getuid() and os.path.realpath(home) == home and home != '/'
        assert os.path.commonpath([home, os.path.realpath(share)]) != home
        # One exclusive private directory per operation. Never overwrite a
        # previous backup or follow a destination supplied by the guest report.
        os.mkdir(folder, 0o700, dir_fd=share_fd)
        directory = os.open(folder, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=share_fd)
        try:
            fd = os.open('home.tgz.partial', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                         0o600, dir_fd=directory)
            with os.fdopen(fd, 'wb') as output:
                runner(['/usr/bin/tar', '--acls', '--xattrs', '--sparse', '--one-file-system',
                        '-czpf', '-', '-C', '/proc/' + str(os.getpid()) + '/fd/' + str(home_fd), '.'], output, control_fd)
                output.flush()
                os.fsync(output.fileno())
            fd = os.open('home.tgz.partial', os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory)
            try:
                info = os.fstat(fd)
                assert stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_size > 0
                # Test the entire gzip stream/CRC as well as tar structure.
                # Suppress the listing (which can contain private file names).
                path = '/proc/' + str(os.getpid()) + '/fd/' + str(fd)
                runner(['/usr/bin/gzip', '-t', path], subprocess.DEVNULL, control_fd)
                runner(['/usr/bin/tar', '-tzf', path], subprocess.DEVNULL, control_fd)
                publisher(directory)
                os.fsync(directory)
                return info.st_size
            finally:
                os.close(fd)
        finally:
            os.close(directory)
    finally:
        os.close(home_fd)
        os.close(share_fd)


def main(vm, session, user, operation):
    def interrupted(signum, frame):
        raise InterruptedError('cancelled')
    for signum in (signal.SIGHUP, signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, interrupted)
    stage = 'prerequisites'
    try:
        identity = json.loads(subprocess.check_output(
            ['/usr/lib/try-omarchy/managed-ssh-identity'], timeout=3, stderr=subprocess.DEVNULL))
        mount = json.loads(subprocess.check_output(
            ['/usr/bin/findmnt', '--json', '--mountpoint', '/mnt/mac', '--output', 'SOURCE,TARGET,FSTYPE,OPTIONS'],
            timeout=3, stderr=subprocess.DEVNULL))
        verify(identity, mount, vm, session, user)
        account = pwd.getpwuid(os.getuid())
        assert account.pw_name == user and os.access('/mnt/mac', os.R_OK | os.W_OK | os.X_OK)
        folder = 'home-backup-' + str(uuid.UUID(operation))
        stage = 'archive'
        size = archive(account.pw_dir, '/mnt/mac', folder, sys.stdin.fileno())
        print(json.dumps({'vmID': vm, 'sessionID': session, 'operationID': operation, 'bytes': size}))
    except BaseException:
        # A failed/lost result never implies a complete backup. Preserve partial
        # output for explicit cleanup; never expose tar diagnostics or names.
        print(json.dumps({'failure': stage}))
        sys.exit(1)
