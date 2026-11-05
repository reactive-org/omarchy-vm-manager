import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
import uuid

SOURCE = Path(__file__).resolve().parents[2] / '.build/runtime-source/guest/package/try-omarchy/files/usr/lib/try-omarchy/managed-home'
loader = importlib.machinery.SourceFileLoader('managed_home_guard', str(SOURCE))
spec = importlib.util.spec_from_loader(loader.name, loader)
home = importlib.util.module_from_spec(spec)
loader.exec_module(home)


class ManagedHomeGuardTests(unittest.TestCase):
    def test_growth_is_detected_and_cannot_shrink_a_filesystem(self):
        header = 'Block count: 16384\nBlock size: 4096\n'
        for capacity, expected in [(64 * 1024**2, False), (80 * 1024**2, True)]:
            with mock.patch.object(home.subprocess, 'check_output', side_effect=[header, str(capacity)]):
                self.assertEqual(home.needs_growth(Path('/dev/fixture')), expected)
        with mock.patch.object(home.subprocess, 'check_output', side_effect=[header, str(32 * 1024**2)]):
            with self.assertRaises(ValueError): home.needs_growth(Path('/dev/fixture'))
        source = SOURCE.read_text()
        self.assertIn("(['-f'] if grow else [])", source)
        self.assertIn("if grow:\n        run(['/usr/bin/resize2fs'", source)

    def test_visible_home_device_is_idempotent_without_fsck_or_remount(self):
        with tempfile.TemporaryDirectory(prefix='omarchy-home-mounted-') as scratch:
            root = Path(scratch); disk_id = str(uuid.uuid4())
            (root / 'tryomarchy.home').write_text(disk_id)
            device = root / 'device'; device.touch()
            mounted = root / 'mounted'; mounted.mkdir()
            owner = SimpleNamespace(pw_name='owner', pw_uid=1000, pw_gid=1000, pw_dir='/home/owner')
            (mounted / home.MARKER).write_text(json.dumps({'schemaVersion': 1, 'id': disk_id, 'owner': 'owner', 'uid': 1000, 'gid': 1000}))
            real_stat = os.stat
            def lookup(path, *args, **kwargs):
                if Path(path) == mounted: return SimpleNamespace(st_dev=device.stat().st_rdev)
                return real_stat(path, *args, **kwargs)
            with mock.patch.object(home, 'DEVICE', device), mock.patch.object(home, 'HOME', mounted), \
                 mock.patch.dict(os.environ, {'CREDENTIALS_DIRECTORY': scratch}), \
                 mock.patch.object(home.stat, 'S_ISBLK', return_value=True), \
                 mock.patch.object(home.pwd, 'getpwuid', return_value=owner), \
                 mock.patch.object(home, 'identity', return_value={'TYPE': 'ext4', 'UUID': disk_id}), \
                 mock.patch.object(home.Path, 'stat', autospec=True, side_effect=lookup), \
                 mock.patch.object(home, 'run') as commands, mock.patch.object(home.subprocess, 'run') as subprocesses:
                home.main()
                commands.assert_not_called(); subprocesses.assert_not_called()

    def test_boot_gate_is_supplied_before_guest_package_update(self):
        runtime = SOURCE.resolve().parent
        # Locate the repository without depending on the prepared checkout name.
        while not (runtime / 'macos/run-qemu-gpu.sh').exists():
            if runtime.parent == runtime: self.fail('runtime checkout missing')
            runtime = runtime.parent
        launcher = (runtime / 'macos/run-qemu-gpu.sh').read_text()
        self.assertIn('systemd.extra-unit.try-omarchy-home.service', launcher)
        self.assertIn('systemd.unit-dropin.${login_unit}~60-omarchy-home', launcher)
        self.assertIn('ConditionPathExists=!/etc/initrd-release', launcher)
        self.assertIn('display-manager.service getty@.service serial-getty@.service console-getty.service sshd.service try-omarchy-managed-ssh.service', launcher)

    def test_home_handoff_supports_a_shared_run_parent(self):
        source = SOURCE.read_text()
        self.assertNotIn("'--move'", source)
        self.assertIn("run(['/usr/bin/mount', '--bind', str(STAGING), '/home'])", source)
        self.assertIn("run(['/usr/bin/umount', str(STAGING)])", source)

    def test_unrecognized_and_interrupted_blank_headers_never_format(self):
        with tempfile.TemporaryDirectory(prefix='omarchy-home-guard-') as scratch:
            root = Path(scratch)
            disk_id = str(uuid.uuid4())
            (root / 'tryomarchy.home').write_text(disk_id)
            device = root / 'device'
            owner = SimpleNamespace(pw_name='owner', pw_uid=1000, pw_gid=1000, pw_dir='/home/owner')
            for content in [b'unrecognized data', b'OMARCHY_HOME_FORMATTING_V1\n', ('OMARCHY_HOME_BLANK_V1\n' + str(uuid.uuid4()) + '\n').encode()]:
                device.write_bytes(content)
                with mock.patch.object(home, 'DEVICE', device), mock.patch.dict(os.environ, {'CREDENTIALS_DIRECTORY': scratch}), \
                     mock.patch.object(home.stat, 'S_ISBLK', return_value=True), mock.patch.object(home.pwd, 'getpwuid', return_value=owner), \
                     mock.patch.object(home, 'identity', return_value={}), mock.patch.object(home, 'run') as commands:
                    with self.assertRaises(ValueError): home.main()
                    commands.assert_not_called()
                    self.assertEqual(device.read_bytes(), content)

    def test_wrong_filesystem_or_uuid_never_formats_or_copies(self):
        with tempfile.TemporaryDirectory(prefix='omarchy-home-guard-') as scratch:
            root = Path(scratch)
            disk_id = str(uuid.uuid4())
            (root / 'tryomarchy.home').write_text(disk_id)
            device = root / 'device'; device.write_bytes(b'preserved fixture')
            owner = SimpleNamespace(pw_name='owner', pw_uid=1000, pw_gid=1000, pw_dir='/home/owner')
            for found in [{'TYPE': 'btrfs', 'UUID': disk_id}, {'TYPE': 'ext4', 'UUID': str(uuid.uuid4())}]:
                with mock.patch.object(home, 'DEVICE', device), mock.patch.dict(os.environ, {'CREDENTIALS_DIRECTORY': scratch}), \
                     mock.patch.object(home.stat, 'S_ISBLK', return_value=True), mock.patch.object(home.pwd, 'getpwuid', return_value=owner), \
                     mock.patch.object(home, 'identity', return_value=found), mock.patch.object(home, 'run') as commands:
                    with self.assertRaises(ValueError): home.main()
                    commands.assert_not_called()
                    self.assertEqual(device.read_bytes(), b'preserved fixture')


if __name__ == '__main__': unittest.main()
