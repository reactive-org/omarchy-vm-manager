"""Synthetic detached records and resource bundles; no cryptography or tools."""
from pathlib import Path
import plistlib

import private_provisioning_package as p
from test_private_provisioning_package import put

# Literal fixture contract, independent of the production exclusion set.
SIGNATURE_RECORDS = ('Contents/_CodeSignature/CodeDirectory',
                     'Contents/_CodeSignature/CodeRequirements',
                     'Contents/_CodeSignature/CodeResources',
                     'Contents/_CodeSignature/CodeSignature')


def add_signature_records(bundle):
    for name in SIGNATURE_RECORDS:
        put(bundle / name, b'INHERITED_RECORD_FIXTURE_NOT_A_SIGNATURE\n' + name.encode())


class ResourceFixture:
    def __init__(self, root, *, signed=True, nested=True):
        self.inputs = root / 'inputs'
        self.reference = self.inputs / p.package.BUNDLE
        self.binaries = root / 'products'
        self.built = self.binaries / p.package.BUNDLE
        resources = {'engine-identity.json': b'{"fixture":true}\n', 'Provisioning/play.yml': b'# not executed\n'}
        prefix = 'Contents/Resources/Resources/' if nested else 'Resources/'
        self.payload = {prefix + name: body for name, body in resources.items()}
        if nested:
            self.payload['Contents/Info.plist'] = plistlib.dumps({'CFBundlePackageType': 'BNDL', 'fixture': True})
        for name, body in self.payload.items():
            put(self.reference / name, body)
            put(self.built / name, body)
        if signed:
            add_signature_records(self.reference)
        self.lock = {'format': 1, 'setupAPI': 1, 'package': 'Vendor/dev-vm',
            'resourceBundle': p.package.BUNDLE, 'launcher': 'dev-vm-process-host',
            'files': {'Sources/DevVMProvisioningCore/Resources/' + n: p.digest(b) for n, b in resources.items()}}
        put(self.inputs / p.package.LOCK, p.canonical(self.lock))
        self.expected = {n: p.digest(b) for n, b in self.payload.items()}
        self.app = root / 'Fixture.app'
        self.target = self.app / 'Contents/Resources' / p.package.BUNDLE
        self.target.parent.mkdir(parents=True, mode=0o700)
