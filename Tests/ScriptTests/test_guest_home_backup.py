"""No VM/SSH: exercise the shipped guest program against disposable files."""
import importlib.util
import gzip
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
        # Portable no-replace publication for these local fixtures only.
        os.link('home.tgz.partial', 'home.tgz', src_dir_fd=directory, dst_dir_fd=directory,
                follow_symlinks=False)
        os.unlink('home.tgz.partial', dir_fd=directory)

    def archive(self, runner=None):
        return backup.archive(str(self.home), str(self.share), self.folder, 0,
                              runner=runner or self.runner, publisher=self.publisher)

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
