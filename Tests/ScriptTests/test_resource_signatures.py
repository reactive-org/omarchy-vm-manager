"""Narrow resource admission using synthetic bytes and disposable local files."""
from pathlib import Path
import os
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'Scripts'))
import private_provisioning_package as p
import private_provisioning_signer as signer
from test_private_provisioning_package import put
from resource_signature_fixtures import ResourceFixture, SIGNATURE_RECORDS, add_signature_records


class ResourceAdmissionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='resource-signature-fixture-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        for name in ('subprocess.Popen', 'subprocess.run', 'ctypes.CDLL', 'socket.socket'):
            guard = patch(name, side_effect=AssertionError('No process/native/network in resource fixtures'))
            guard.start(); self.addCleanup(guard.stop)
        self.serial = 0

    def fixture(self, **kwargs):
        self.serial += 1
        return ResourceFixture(self.root / str(self.serial), **kwargs)

    def adapter(self, f):
        adapter = signer.Adapter(None, None)
        adapter.handoff = f.inputs.parent
        adapter.binaries = f.binaries
        adapter._revalidate_inputs = lambda: None
        return adapter

    def test_complete_inherited_block_and_unsigned_build_admit_exact_payload(self):
        f = self.fixture(); before = p.tree(f.inputs); adapter = self.adapter(f)
        self.assertEqual(signer.provisioning_payload(f.inputs), f.expected)
        adapter._copy_provisioning_resources(f.target)
        self.assertEqual(p.tree(f.target), f.expected)
        self.assertEqual(p.tree(f.inputs), before)
        self.assertTrue(set(SIGNATURE_RECORDS) <= p.tree(f.reference).keys())

    def test_unsigned_flat_reference_remains_supported(self):
        f = self.fixture(signed=False, nested=False)
        self.adapter(f)._copy_provisioning_resources(f.target)
        self.assertEqual(p.tree(f.target), f.expected)

    def test_generic_inventory_copy_still_rejects_missing_signature_records(self):
        f = self.fixture()
        with self.assertRaisesRegex(p.Refused, 'input-inventory-changed'):
            p.copy_tree(f.built, f.target, p.tree(f.reference))
        self.assertFalse(f.target.exists())

    def test_partial_unknown_and_nested_reference_signature_blocks_refuse(self):
        for kind in ('partial', 'unknown', 'nested'):
            f = self.fixture()
            if kind == 'partial': (f.reference / SIGNATURE_RECORDS[0]).unlink()
            else: put(f.reference / ('Contents/_CodeSignature/Unknown' if kind == 'unknown' else 'Resources/_CodeSignature/CodeResources'), b'not a signature')
            with self.subTest(kind=kind), self.assertRaisesRegex(p.Refused, 'provisioning-resource-signature-layout'):
                self.adapter(f)._copy_provisioning_resources(f.target)
            self.assertFalse(f.target.exists())

    def test_fresh_build_cannot_reintroduce_even_known_inherited_signatures(self):
        for complete in (False, True):
            f = self.fixture()
            if complete: add_signature_records(f.built)
            else: put(f.built / SIGNATURE_RECORDS[0], b'stale record')
            with self.subTest(complete=complete), self.assertRaisesRegex(p.Refused, 'input-inventory-changed'):
                self.adapter(f)._copy_provisioning_resources(f.target)

    def test_payload_and_wrapper_addition_removal_or_mutation_refuse(self):
        for kind in ('payload', 'wrapper', 'extra', 'missing'):
            f = self.fixture()
            resource = f.built / 'Contents/Resources/Resources/Provisioning/play.yml'
            if kind == 'payload': resource.write_bytes(b'changed payload')
            elif kind == 'wrapper': (f.built / 'Contents/Info.plist').write_bytes(b'changed wrapper')
            elif kind == 'extra': put(f.built / 'Contents/extra', b'extra')
            else: resource.unlink()
            with self.subTest(kind=kind), self.assertRaisesRegex(p.Refused, 'input-inventory-changed'):
                self.adapter(f)._copy_provisioning_resources(f.target)

    def test_reference_resources_must_independently_match_the_package_lock(self):
        f = self.fixture()
        for bundle in (f.reference, f.built):
            (bundle / 'Contents/Resources/Resources/Provisioning/play.yml').write_bytes(b'same unpinned bytes')
        with self.assertRaisesRegex(p.Refused, 'provisioning-resource-lock-mismatch'):
            self.adapter(f)._copy_provisioning_resources(f.target)

    def test_ambiguous_reference_resource_roots_are_not_guessed(self):
        f = self.fixture()
        put(f.reference / 'Resources/engine-identity.json', b'{"fixture":true}\n')
        with self.assertRaisesRegex(p.Refused, 'provisioning-resource-contract'):
            self.adapter(f)._copy_provisioning_resources(f.target)

    def test_link_writable_and_special_built_entries_refuse_before_copy(self):
        for kind in ('link', 'directory-link', 'writable', 'fifo'):
            f = self.fixture()
            if kind == 'link': (f.built / 'extra').symlink_to(f.reference / 'Contents/Info.plist')
            elif kind == 'directory-link': (f.built / 'extra').symlink_to(f.reference, target_is_directory=True)
            elif kind == 'writable': (f.built / 'Contents/Info.plist').chmod(0o666)
            else: os.mkfifo(f.built / 'extra', 0o600)
            with self.subTest(kind=kind), self.assertRaises(p.Refused):
                self.adapter(f)._copy_provisioning_resources(f.target)
            self.assertFalse(f.target.exists())

    def test_reference_mutation_during_copy_cannot_be_promoted_to_admitted_payload(self):
        f = self.fixture(); adapter = self.adapter(f); copy = p.copy_tree
        def mutate(*args):
            copy(*args)
            (f.reference / 'Contents/Info.plist').write_bytes(b'changed during copy')
        with patch.object(p, 'copy_tree', side_effect=mutate), self.assertRaisesRegex(p.Refused, 'provisioning-resource-reference-changed'):
            adapter._copy_provisioning_resources(f.target)
        self.assertFalse(hasattr(adapter, 'provisioning_payload_inventory'))

    def test_final_verification_rejects_wrapper_payload_or_signature_changes(self):
        for kind in ('wrapper', 'payload', 'signature'):
            f = self.fixture(); adapter = self.adapter(f)
            adapter._copy_provisioning_resources(f.target)
            adapter._verify_provisioning_resources(f.app)
            if kind == 'wrapper': (f.target / 'Contents/Info.plist').write_bytes(b'changed after assembly')
            elif kind == 'payload': (f.target / 'Contents/Resources/Resources/Provisioning/play.yml').write_bytes(b'changed after seal')
            else: put(f.target / SIGNATURE_RECORDS[0], b'inherited record returned')
            with self.subTest(kind=kind), self.assertRaisesRegex(p.Refused, 'provisioning-resource-payload-changed'):
                adapter._verify_provisioning_resources(f.app)


if __name__ == '__main__': unittest.main()
