#!/usr/bin/env python3
"""Describe an already prepared factory for review; never approves or boots it."""
import argparse
import hashlib
import json
import os
import stat
import unicodedata
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent.parent
PACKAGE = 'Contents/Resources/guest-packages/try-omarchy-0.1.0-40-aarch64.pkg.tar.zst'


def read_regular(path, maximum=None):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    with os.fdopen(descriptor, 'rb') as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or maximum is not None and not 0 < info.st_size <= maximum:
            raise ValueError('Metadata must be a bounded regular file')
        remaining = info.st_size
        while remaining:
            data = source.read(min(remaining, 1024 * 1024))
            if not data:
                raise ValueError('A factory payload changed during preparation')
            remaining -= len(data)
            yield data
        current = os.fstat(source.fileno())
        if source.read(1) or (current.st_size, current.st_mtime_ns, current.st_ctime_ns) != (info.st_size, info.st_mtime_ns, info.st_ctime_ns):
            raise ValueError('A factory payload changed during preparation')


def digest(path):
    value = hashlib.sha256()
    for data in read_regular(path):
        value.update(data)
    return value.hexdigest()


def metadata(path):
    return json.loads(b''.join(read_regular(path, maximum=65536)))


def safe_name(value):
    return isinstance(value, str) and value not in ('.', '..') and re.fullmatch(r'[A-Za-z0-9._-]{1,255}', value) is not None


def is_digest(value):
    return isinstance(value, str) and re.fullmatch('[0-9a-f]{64}', value) is not None


def prepare(bundle, name, provisioning, runtime_lock=ROOT / 'Config/TryOmarchyRuntime.lock.json'):
    bundle = Path(bundle).absolute()
    if bundle.resolve() != bundle or not bundle.is_dir():
        raise ValueError('Use a real prepared bundle directory without symbolic links')
    destination = bundle / 'reviewed-factory.json'
    if destination.exists() or destination.is_symlink():
        raise ValueError('An existing review manifest is preserved; prepare a separate bundle')
    if not name.strip() or len(name.encode()) > 128 or any(unicodedata.category(c) in ('Cc', 'Cf') for c in name):
        raise ValueError('Use a nonempty factory name of at most 128 UTF-8 bytes')
    files = {}
    for path in bundle.iterdir():
        if path.is_symlink() or not path.is_file() or not safe_name(path.name):
            raise ValueError('Bundle contents must be flat regular files with safe names')
        files[path.name] = digest(path)
    if not 2 <= len(files) <= 32:
        raise ValueError('The bundle must contain 2 through 32 payload files')
    if not provisioning or any(path not in files for path in provisioning):
        raise ValueError('Select the included provisioning evidence files')
    image = metadata(bundle / 'factory.json')
    if not isinstance(image, dict) or type(image.get('format')) is not int or (image.get('format'), image.get('kind'), image.get('platform'), image.get('boot')) != (1, 'upstream-shell-factory', 'aarch64', 'uefi-limine'):
        raise ValueError('The factory must be aarch64 Omarchy with UEFI/Limine boot')
    compressed = image.get('compressed')
    if not isinstance(compressed, dict) or not safe_name(compressed.get('path')) or not compressed['path'].endswith('.img.zst') or not is_digest(compressed.get('sha256')) or files.get(compressed['path']) != compressed['sha256']:
        raise ValueError('The compressed image must match factory.json')
    disk = image.get('disk')
    if not isinstance(disk, dict) or not safe_name(disk.get('path')) or not disk['path'].endswith('.img') or type(disk.get('bytes')) is not int or not 0 < disk['bytes'] <= 8192 * 1073741824 or not is_digest(disk.get('sha256')):
        raise ValueError('Invalid prepared disk size or digest')
    lock = metadata(Path(runtime_lock))
    if not isinstance(lock, dict) or any(type(lock.get(key)) is not int or lock[key] != 1 for key in ('customFactoryVersion', 'managedSSHVersion', 'managedSetupVersion')):
        raise ValueError('Build the reviewed factory/provisioning capable kit first')
    runtime_files = lock.get('files')
    required = {PACKAGE, 'Contents/MacOS/omarchy-vm-helper', 'Contents/Resources/runtime/bin/Try Omarchy',
                'Contents/Resources/firmware/edk2-aarch64-code.fd', 'Contents/Resources/scripts/run-qemu-gpu.sh'}
    if (not isinstance(runtime_files, dict) or not required.issubset(runtime_files) or len(runtime_files) > 256
            or any(not isinstance(path, str) or not path.startswith('Contents/') or any(part in ('', '.', '..') for part in path.split('/'))
                   or not is_digest(value) for path, value in runtime_files.items())):
        raise ValueError('The runtime inventory is missing, unsafe or incompatible')
    value = {
        'format': 1, 'name': name, 'architecture': 'aarch64', 'boot': 'uefi-limine',
        'customFactoryVersion': 1, 'managedSSHVersion': 1, 'managedSetupVersion': 1,
        'integrationPackageSHA256': lock['files'][PACKAGE],
        'ownerSetupContractSHA256': digest(ROOT / 'Sources/OmarchyVMManagerCore/Resources/OwnerSetupContract.json'),
        'runtimeFiles': lock['files'], 'files': files,
        'provisioning': {path: files[path] for path in provisioning},
    }
    with destination.open('x') as output:
        json.dump(value, output, indent=2, sort_keys=True)
        output.write('\n')
    return digest(destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', type=Path)
    parser.add_argument('--name', required=True)
    parser.add_argument('--provisioning', required=True, action='append', help='Included basename; repeat for every provisioning evidence file')
    args = parser.parse_args()
    print(prepare(args.bundle, args.name, args.provisioning))


if __name__ == '__main__':
    main()
