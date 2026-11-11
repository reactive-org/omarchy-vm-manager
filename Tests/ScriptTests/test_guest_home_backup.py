"""No VM/SSH: exercise the shipped guest program against disposable files."""
import ctypes
import errno
import importlib.util
import gzip
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import unittest
import uuid
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[2] / 'Sources/OmarchyVMManagerCore/Resources/GuestHomeBackup.py'
spec = importlib.util.spec_from_file_location('guest_home_backup', SOURCE)
backup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backup)


class FakeLibc:
    """Stands in for Linux libc on macOS: renameat2 fails with a chosen errno
    (v9fs rejects any rename flag with EINVAL) or succeeds by plain rename."""
    def __init__(self, error=errno.EINVAL):
        self.error, self.calls = error, []
        def renameat2(old_dir, old, new_dir, new, flags):
            self.calls.append(flags)
            if self.error is None:
                os.rename(old.decode(), new.decode(), src_dir_fd=old_dir, dst_dir_fd=new_dir)
                return 0
            ctypes.set_errno(self.error)
            return -1
        self.renameat2 = renameat2


class HomeBackupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='omarchy-backup-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.home = self.root / 'home'
        self.share = self.root / 'share'
        self.home.mkdir(mode=0o700)
        self.share.mkdir(mode=0o700)
        (self.home / '.hidden').write_text('synthetic hidden data')
        (self.home / 'file').write_text('synthetic home data')
        (self.share / 'unrelated').write_text('preserve me')
        (self.home / 'Shared').symlink_to(self.share, target_is_directory=True)
        self.folder = 'home-backup-' + str(uuid.uuid4())
        self.calls = []

    def runner(self, arguments, output, control):
        # Test the archive flow and actual gzip/tar bytes portably on macOS.
        # GNU tar flags, Linux /proc descriptors and renameat2 stay explicit
        # production dependencies, not falsely simulated live validation.
        self.calls.append(arguments)
        if '-czpf' in arguments:
            self.assertTrue({'--acls', '--xattrs', '--sparse', '--one-file-system'} <= set(arguments))
            self.assertEqual(arguments[-1], '.')
            with tarfile.open(fileobj=output, mode='w:gz') as stream:
                stream.add(self.home, arcname='.', recursive=True)
        elif '-tzf' in arguments:
            with tarfile.open(self.share / self.folder / 'home.tgz.partial', 'r:gz') as stream:
                for entry in stream:
                    if entry.isfile():
                        stream.extractfile(entry).read()
        else:
            self.assertEqual(arguments[:2], ['/usr/bin/gzip', '-t'])
            with gzip.open(self.share / self.folder / 'home.tgz.partial', 'rb') as stream:
                while stream.read(65536):
                    pass

    @staticmethod
    def publisher(directory):
        # The production publisher on its 9p path: renameat2 refuses flags with
        # EINVAL, so the no-replace link/unlink fallback publishes.
        backup.publish(directory, libc=FakeLibc(errno.EINVAL))

    def archive(self, runner=None, publisher=None, progress=None):
        return backup.archive(str(self.home), str(self.share), self.folder, 0,
                              runner=runner or self.runner, publisher=publisher or self.publisher,
                              progress=progress or (lambda stage: None))

    def publish_fixture(self, libc):
        directory = self.share / self.folder
        directory.mkdir(mode=0o700)
        (directory / 'home.tgz.partial').write_bytes(b'synthetic archive')
        fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
        self.addCleanup(os.close, fd)
        return directory, lambda: backup.publish(fd, libc=libc)

    def test_unsupported_rename_flags_fall_back_to_no_replace_link(self):
        for libc in [FakeLibc(errno.EINVAL), FakeLibc(errno.ENOSYS), FakeLibc(errno.EOPNOTSUPP), object()]:
            self.folder = 'home-backup-' + str(uuid.uuid4())
            directory, publish = self.publish_fixture(libc)
            publish()
            self.assertFalse((directory / 'home.tgz.partial').exists())
            self.assertEqual((directory / 'home.tgz').read_bytes(), b'synthetic archive')
            self.assertEqual((directory / 'home.tgz').stat().st_nlink, 1)
            if isinstance(libc, FakeLibc):
                self.assertEqual(libc.calls, [backup.RENAME_NOREPLACE])

    def test_fallback_never_replaces_an_existing_name(self):
        directory, publish = self.publish_fixture(FakeLibc(errno.EINVAL))
        (directory / 'home.tgz').write_text('pre-existing data')
        with self.assertRaises(FileExistsError):
            publish()
        self.assertEqual((directory / 'home.tgz').read_text(), 'pre-existing data')
        self.assertEqual((directory / 'home.tgz.partial').read_bytes(), b'synthetic archive')

    def test_other_rename_errors_and_success_never_link(self):
        for error in [errno.EIO, errno.EEXIST, None]:
            self.folder = 'home-backup-' + str(uuid.uuid4())
            directory, publish = self.publish_fixture(FakeLibc(error))
            with patch.object(backup.os, 'link', side_effect=AssertionError('link used')) as link:
                if error is None:
                    publish()
                    self.assertEqual((directory / 'home.tgz').read_bytes(), b'synthetic archive')
                else:
                    with self.assertRaises(OSError) as raised:
                        publish()
                    self.assertEqual(raised.exception.errno, error)
                    self.assertTrue((directory / 'home.tgz.partial').exists())
                    self.assertFalse((directory / 'home.tgz').exists())
                link.assert_not_called()

    def test_progress_names_each_step_and_the_failing_one(self):
        stages = []
        self.archive(progress=stages.append)
        self.assertEqual(stages, ['archive', 'verification', 'publish', 'sync'])
        def fail_tar(arguments, output, control):
            raise RuntimeError('synthetic tar failure')
        def fail_check(arguments, output, control):
            if '-czpf' not in arguments:
                raise RuntimeError('synthetic check failure')
            self.runner(arguments, output, control)
        def fail_publish(directory):
            backup.publish(directory, libc=FakeLibc(errno.EIO))
        for expected, runner, publisher in [('archive', fail_tar, None), ('verification', fail_check, None),
                                            ('publish', None, fail_publish)]:
            self.folder = 'home-backup-' + str(uuid.uuid4())
            stages = []
            with self.assertRaises((RuntimeError, OSError)):
                self.archive(runner=runner, publisher=publisher, progress=stages.append)
            self.assertEqual(stages[-1], expected)
        self.folder = 'home-backup-' + str(uuid.uuid4())
        stages = []
        real_fsync = os.fsync
        def fsync(fd):
            if stages[-1] == 'sync':
                raise OSError(errno.EIO, 'synthetic sync failure')
            real_fsync(fd)
        with patch.object(backup.os, 'fsync', side_effect=fsync), self.assertRaises(OSError):
            self.archive(progress=stages.append)
        self.assertEqual(stages[-1], 'sync')

    def test_failure_report_carries_only_stage_and_errno(self):
        vm, session, operation = str(uuid.uuid4()), str(uuid.uuid4()), str(uuid.uuid4())
        account = type('Account', (), {'pw_name': 'owner', 'pw_dir': str(self.home)})()
        cases = [(OSError(errno.EINVAL, 'private file name'), {'failure': 'publish', 'errno': errno.EINVAL}),
                 (RuntimeError('archive-failed /private/name'), {'failure': 'publish'}),
                 (InterruptedError('cancelled'), {'failure': 'publish'})]
        for error, expected in cases:
            def archive(*arguments, progress, **options):
                progress('verification'); progress('publish')
                raise error
            output = io.StringIO()
            with patch.object(backup.subprocess, 'check_output', return_value=b'{}'), \
                 patch.object(backup, 'verify'), patch.object(backup, 'archive', side_effect=archive), \
                 patch.object(backup.pwd, 'getpwuid', return_value=account), \
                 patch.object(backup.os, 'access', return_value=True), \
                 patch.object(backup.signal, 'signal'), patch('sys.stdout', output), \
                 self.assertRaises(SystemExit) as exit:
                backup.main(vm, session, 'owner', operation)
            self.assertEqual(exit.exception.code, 1)
            self.assertEqual(json.loads(output.getvalue()), expected)
        output = io.StringIO()
        with patch.object(backup.subprocess, 'check_output', side_effect=OSError(errno.ENOENT, 'missing')), \
             patch.object(backup.signal, 'signal'), patch('sys.stdout', output), self.assertRaises(SystemExit):
            backup.main(vm, session, 'owner', operation)
        self.assertEqual(json.loads(output.getvalue()), {'failure': 'prerequisites', 'errno': errno.ENOENT})

    def test_archive_includes_hidden_files_stores_share_link_and_preserves_other_files(self):
        size = self.archive()
        output = self.share / self.folder / 'home.tgz'
        self.assertEqual(size, output.stat().st_size)
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)
        self.assertEqual(output.parent.stat().st_mode & 0o777, 0o700)
        self.assertFalse(output.with_name('home.tgz.partial').exists())
        with tarfile.open(output, 'r:gz') as stream:
            self.assertEqual(stream.extractfile('./.hidden').read(), b'synthetic hidden data')
            self.assertTrue(stream.getmember('./Shared').issym())
            self.assertNotIn('./Shared/unrelated', stream.getnames())
        self.assertEqual((self.share / 'unrelated').read_text(), 'preserve me')
        self.assertEqual(len(self.calls), 3)

    def test_collision_or_symlink_destination_never_overwrites(self):
        for kind in ['directory', 'symlink']:
            self.folder = 'home-backup-' + str(uuid.uuid4())
            target = self.share / self.folder
            target.mkdir() if kind == 'directory' else target.symlink_to(self.home)
            with self.assertRaises(FileExistsError):
                self.archive()
        self.assertEqual((self.home / '.hidden').read_text(), 'synthetic hidden data')

    def test_archiver_failure_or_failed_verification_retains_only_partial(self):
        for stage in ['archive', 'verification']:
            self.folder = 'home-backup-' + str(uuid.uuid4())
            def runner(arguments, output, control):
                if stage == 'archive':
                    output.write(b'incomplete')
                    raise RuntimeError('synthetic unreadable or changed file')
                if '-tzf' in arguments:
                    raise RuntimeError('synthetic corrupt archive')
                self.runner(arguments, output, control)
            with self.assertRaises(RuntimeError):
                self.archive(runner)
            self.assertTrue((self.share / self.folder / 'home.tgz.partial').exists())
            self.assertFalse((self.share / self.folder / 'home.tgz').exists())

    def test_late_destination_collision_is_preserved(self):
        def runner(arguments, output, control):
            self.runner(arguments, output, control)
            if '-tzf' in arguments:
                (self.share / self.folder / 'home.tgz').write_text('pre-existing data')
        with self.assertRaises(FileExistsError):
            self.archive(runner)
        self.assertEqual((self.share / self.folder / 'home.tgz').read_text(), 'pre-existing data')

    def test_share_inside_home_and_unsafe_paths_are_refused(self):
        with self.assertRaises(AssertionError):
            backup.archive(str(self.home), str(self.home), self.folder, 0, self.runner)
        for name in ['../outside', 'home-backup-invalid', '/absolute']:
            with self.assertRaises(AssertionError):
                backup.archive(str(self.home), str(self.share), name, 0, self.runner)
        alias = self.root / 'alias'
        alias.symlink_to(self.share)
        with self.assertRaises(OSError):
            backup.archive(str(self.home), str(alias), self.folder, 0, self.runner)

    def test_session_and_mount_must_match_before_any_backup(self):
        vm, session = str(uuid.uuid4()), str(uuid.uuid4())
        identity = {'vmID': vm, 'sessionToken': session, 'user': 'owner', 'uid': 1000}
        entry = {'source': 'mac', 'target': '/mnt/mac', 'fstype': '9p',
                 'options': 'rw,trans=virtio,cache=0x1'}
        with patch.object(backup.os, 'getuid', return_value=1000):
            backup.verify(identity, {'filesystems': [entry]}, vm, session, 'owner')
            with self.assertRaises(AssertionError):
                backup.verify(identity, {'filesystems': [entry]}, vm, str(uuid.uuid4()), 'owner')
            for field, value in [('source', 'other'), ('fstype', 'ext4'), ('target', '/home'),
                                 ('options', 'rw,trans=virtio,cache=mmap'), ('options', 'ro,trans=virtio,cache=0x1')]:
                with self.assertRaises(AssertionError):
                    backup.verify(identity, {'filesystems': [dict(entry, **{field: value})]}, vm, session, 'owner')

    def test_closed_control_channel_cancels_subprocess(self):
        read, write = os.pipe()
        timer = threading.Timer(0.1, lambda: os.close(write))
        timer.start()
        try:
            with self.assertRaises(InterruptedError):
                backup.run_child(['/bin/sh', '-c', 'sleep 30'], subprocess.DEVNULL, read)
        finally:
            timer.join()
            os.close(read)

    def test_nonzero_child_is_failure(self):
        read, write = os.pipe()
        try:
            with self.assertRaises(RuntimeError):
                backup.run_child(['/bin/sh', '-c', 'exit 1'], subprocess.DEVNULL, read)
        finally:
            os.close(read)
            os.close(write)

    def test_failed_leader_cannot_leave_a_term_ignoring_compressor(self):
        pid_file = self.root / 'synthetic-child.pid'
        worker = "import os,pathlib,signal,time,sys; signal.signal(signal.SIGTERM, signal.SIG_IGN); pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(30)"
        leader = "import pathlib,subprocess,sys,time,os; subprocess.Popen([sys.executable, '-c', sys.argv[1], sys.argv[2]]); p=pathlib.Path(sys.argv[2]);\nwhile not p.exists(): time.sleep(.01)\nos._exit(1)"
        read, write = os.pipe()
        pid = None
        try:
            with self.assertRaises(RuntimeError):
                backup.run_child([sys.executable, '-c', leader, worker, str(pid_file)], subprocess.DEVNULL, read)
            pid = int(pid_file.read_text())
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                status = subprocess.run(['ps', '-p', str(pid), '-o', 'stat='], capture_output=True, text=True)
                if status.returncode or not status.stdout.strip() or status.stdout.lstrip().startswith('Z'):
                    break
                time.sleep(.05)
            else:
                self.fail('A compressor outlived its failed supervisor')
        finally:
            if pid is None and pid_file.exists(): pid = int(pid_file.read_text())
            if pid is not None:
                try: os.kill(pid, signal.SIGKILL)
                except ProcessLookupError: pass
            os.close(read); os.close(write)


if __name__ == '__main__':
    unittest.main()
