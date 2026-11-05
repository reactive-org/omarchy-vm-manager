#!/usr/bin/python3 -I
"""Synthetic fixtures for explicitly approved disposable home-disk acceptance."""
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import uuid

mode, run_id, home_id, system_gib, home_gib = sys.argv[1:]
run_id = str(uuid.UUID(run_id))
home = Path.home()
assert os.getuid() == 1000 and home == Path('/home/homepoc')
folder = home / ('.omarchy-home-poc-' + run_id)
system_marker = Path('/var/tmp') / ('omarchy-home-poc-system-' + run_id)
replacement_marker = folder / 'replacement-only'
mount = json.loads(subprocess.check_output(['findmnt', '-J', '-o', 'TARGET,FSTYPE,UUID', '--target', str(home)], text=True))['filesystems'][0]
disks = json.loads(subprocess.check_output(['lsblk', '-J', '-b', '-o', 'NAME,TYPE,SERIAL,SIZE,UUID,FSTYPE'], text=True))['blockdevices']
home_disks = [d for d in disks if d.get('serial') == 'omarchy-home']
if mode == 'diagnostic':
    print(json.dumps({'homeFindmnt': mount, 'disks': disks,
        'homeFilesystemStat': subprocess.check_output(['stat', '-f', '--format=%T', str(home)], text=True).strip(),
        'homeService': subprocess.check_output(['systemctl', 'show', 'try-omarchy-home.service', '-p', 'Result', '-p', 'SubState', '-p', 'ExecMainStatus'], text=True).strip(),
        'homeMountInfo': [line for line in Path('/proc/self/mountinfo').read_text().splitlines() if line.split()[4] == '/home']}, sort_keys=True))
    sys.exit(0)
if home_id == 'single':
    root_mount = json.loads(subprocess.check_output(['findmnt', '-J', '-o', 'UUID', '--target', '/'], text=True))['filesystems'][0]
    # Btrfs factories mount @home separately even when both use one root disk.
    assert not home_disks and mount['uuid'] == root_mount['uuid']
else:
    assert len(home_disks) == 1 and int(home_disks[0]['size']) == int(home_gib) * 1024**3
    disk = home_disks[0]
    assert os.stat(home).st_dev == os.stat('/dev/' + disk['name']).st_rdev
    device = f'{os.major(os.stat(home).st_dev)}:{os.minor(os.stat(home).st_dev)}'
    visible = [line for line in Path('/proc/self/mountinfo').read_text().splitlines() if line.split()[2] == device and line.split()[4] == '/home']
    assert visible and disk['fstype'] == 'ext4' and disk['uuid'] == str(uuid.UUID(home_id))
    mount = {'target': '/home', 'fstype': disk['fstype'], 'uuid': disk['uuid']}
    assert os.statvfs(home).f_blocks * os.statvfs(home).f_frsize > int(home_gib) * 1024**3 * .85
    assert subprocess.check_output(['systemctl', 'is-active', 'try-omarchy-home.service'], text=True).strip() == 'active'
system_disks = [d for d in disks if d.get('type') == 'disk' and d.get('serial') != 'omarchy-home']
assert any(int(d['size']) == int(system_gib) * 1024**3 for d in system_disks)
assert os.statvfs('/').f_blocks * os.statvfs('/').f_frsize > int(system_gib) * 1024**3 * .75


def inventory():
    result = {}
    for path in sorted(folder.rglob('*')):
        if path.name in ('manifest.json', 'replacement-manifest.json'):
            continue
        info = path.lstat()
        item = {'mode': stat.S_IMODE(info.st_mode), 'uid': info.st_uid, 'gid': info.st_gid, 'size': info.st_size}
        if stat.S_ISLNK(info.st_mode):
            item['link'] = os.readlink(path)
        elif stat.S_ISREG(info.st_mode):
            with path.open('rb') as stream:
                item['sha256'] = hashlib.file_digest(stream, 'sha256').hexdigest()
            item['xattrs'] = {key: os.getxattr(path, key).hex() for key in os.listxattr(path)}
        elif stat.S_ISDIR(info.st_mode):
            item.pop('size')
        else:
            raise AssertionError('unexpected fixture type')
        result[str(path.relative_to(folder))] = item
    assert (folder/'normal.txt').stat().st_ino == (folder/'hardlink.txt').stat().st_ino
    assert (folder/'sparse.bin').stat().st_blocks * 512 < 1024**2
    return result


if mode in ('seed', 'single-seed'):
    folder.mkdir(mode=0o700)
    (folder/'nested').mkdir(mode=0o700)
    (folder/'normal.txt').write_bytes(b'synthetic home persistence fixture\n')
    (folder/'normal.txt').chmod(0o640)
    os.setxattr(folder/'normal.txt', 'user.omarchy-home-poc', b'synthetic-xattr')
    os.link(folder/'normal.txt', folder/'hardlink.txt')
    (folder/'.hidden').write_bytes(bytes(range(256)) * 8192)
    (folder/'nested'/'unicode-\u03bb.txt').write_text('synthetic Unicode fixture\n')
    (folder/'symlink').symlink_to('normal.txt')
    with (folder/'sparse.bin').open('wb') as stream:
        stream.seek(64 * 1024**2 - 1); stream.write(b'X')
    system_marker.write_text('synthetic system-only fixture\n')
    (folder/'manifest.json').write_text(json.dumps(inventory(), sort_keys=True))
elif mode in ('verify-source', 'single-verify', 'verify-replacement'):
    assert inventory() == json.loads((folder/'manifest.json').read_text())
    assert not replacement_marker.exists()
    assert system_marker.exists() == (mode != 'verify-replacement')
elif mode == 'modify':
    assert not system_marker.exists()
    with (folder/'normal.txt').open('ab') as stream:
        stream.write(b'replacement-only mutation\n')
    replacement_marker.write_text('synthetic replacement-only fixture\n')
    (folder/'replacement-manifest.json').write_text(json.dumps(inventory(), sort_keys=True))
elif mode == 'verify-modified':
    assert inventory() == json.loads((folder/'replacement-manifest.json').read_text())
    assert not system_marker.exists() and replacement_marker.exists()
else:
    raise AssertionError('unknown acceptance phase')
os.sync()
print(json.dumps({'mode': mode, 'verified': True, 'homeMount': mount['target'], 'homeFilesystem': mount['fstype'],
                  'homeGiB': int(home_gib), 'systemGiB': int(system_gib),
                  'integrationPackage': subprocess.check_output(['pacman', '-Q', 'try-omarchy'], text=True).strip()}, sort_keys=True))
