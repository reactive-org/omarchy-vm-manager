import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('prepare_factory_bundle', ROOT / 'Scripts/prepare_factory_bundle.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class FactoryPreparationTests(unittest.TestCase):
    def fixture(self, folder):
        bundle = folder.resolve() / 'Prepared.factory'
        bundle.mkdir()
        (bundle / 'test.img.zst').write_bytes(b'no VM synthetic fixture')
        (bundle / 'recipe.json').write_text('{"fixture":true}')
        (bundle / 'factory.json').write_text(json.dumps({
            'format': 1, 'kind': 'upstream-shell-factory', 'platform': 'aarch64', 'boot': 'uefi-limine',
            'compressed': {'path': 'test.img.zst', 'sha256': module.digest(bundle / 'test.img.zst')},
            'disk': {'path': 'test.img', 'bytes': 21474836480, 'sha256': 'a' * 64},
        }))
        lock = folder / 'runtime.json'
        lock.write_text(json.dumps({'runProtocolVersion': 1, 'customFactoryVersion': 1, 'managedSSHVersion': 1, 'managedSetupVersion': 1, 'ownerSetupReportVersion': 1,
                                    'files': {name: 'b' * 64 for name in [module.PACKAGE, 'Contents/MacOS/omarchy-vm-helper', 'Contents/Resources/runtime/bin/Try Omarchy', 'Contents/Resources/firmware/edk2-aarch64-code.fd', 'Contents/Resources/scripts/run-qemu-gpu.sh']}}))
        return bundle, lock

    def test_manifest_records_image_provisioning_and_runtime_without_approving_it(self):
        with tempfile.TemporaryDirectory() as temp:
            bundle, lock = self.fixture(Path(temp))
            digest = module.prepare(bundle, 'Fixture', ['recipe.json'], lock)
            value = json.loads((bundle / 'reviewed-factory.json').read_bytes())
            self.assertEqual(digest, module.digest(bundle / 'reviewed-factory.json'))
            self.assertEqual(value['provisioning'], {'recipe.json': module.digest(bundle / 'recipe.json')})
            self.assertEqual(value['integrationPackageSHA256'], 'b' * 64)
            with self.assertRaises(ValueError):
                module.prepare(bundle, 'Fixture', ['recipe.json'], lock)

    def test_missing_provisioning_changed_image_and_symlinks_are_refused(self):
        for case in ('missing', 'image', 'symlink'):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as temp:
                bundle, lock = self.fixture(Path(temp))
                if case == 'image':
                    (bundle / 'test.img.zst').write_bytes(b'changed')
                if case == 'symlink':
                    (bundle / 'unexpected').symlink_to(bundle / 'recipe.json')
                with self.assertRaises(ValueError):
                    module.prepare(bundle, 'Fixture', ['missing.json' if case == 'missing' else 'recipe.json'], lock)
                self.assertFalse((bundle / 'reviewed-factory.json').exists())

    def test_preparer_rejects_metadata_the_importer_cannot_accept(self):
        for case in ('boolean-format', 'disk-path', 'large-metadata', 'control-name', 'runtime-capability', 'runtime-report', 'runtime-path', 'runtime-protocol'):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as temp:
                bundle, lock = self.fixture(Path(temp))
                image = json.loads((bundle / 'factory.json').read_bytes())
                if case == 'boolean-format': image['format'] = True
                if case == 'disk-path': image['disk']['path'] = '../disk.img'
                if case == 'large-metadata': image['padding'] = 'x' * 65536
                (bundle / 'factory.json').write_text(json.dumps(image))
                runtime = json.loads(lock.read_bytes())
                if case == 'runtime-capability': runtime['customFactoryVersion'] = True
                if case == 'runtime-report': del runtime['ownerSetupReportVersion']
                if case == 'runtime-path': runtime['files']['Contents/../outside'] = 'a' * 64
                if case == 'runtime-protocol': runtime['runProtocolVersion'] = 2
                lock.write_text(json.dumps(runtime))
                with self.assertRaises(ValueError):
                    module.prepare(bundle, 'Invalid\u0085name' if case == 'control-name' else 'Fixture', ['recipe.json'], lock)
                self.assertFalse((bundle / 'reviewed-factory.json').exists())

    def test_growing_payload_is_bounded_to_its_initial_size(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'recipe.json'
            path.write_bytes(b'x' * (1024 * 1024 + 1))
            reader = module.read_regular(path)
            self.assertEqual(len(next(reader)), 1024 * 1024)
            with path.open('ab') as output:
                output.write(b'grew during verification')
            self.assertEqual(next(reader), b'x')
            with self.assertRaises(ValueError): next(reader)


class FactoryReviewPinTests(unittest.TestCase):
    def test_only_valid_catalogs_regenerate_the_compiled_pin(self):
        import sys
        sys.path.insert(0, str(ROOT / 'Scripts'))
        import prepare_runtime_source
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            core = root / 'Sources/OmarchyVMManagerCore'
            (core / 'Resources').mkdir(parents=True)
            reviews = core / 'Resources/ReviewedFactories.json'
            reviews.write_text('[]\n')
            prepare_runtime_source.update_factory_review_pin(root)
            pin = core / 'FactoryReviewPin.swift'
            original = pin.read_bytes()
            self.assertIn(module.digest(reviews).encode(), original)
            for values in (['bad'], [True], ['a' * 64, 'a' * 64], {'unexpected': True}):
                reviews.write_text(json.dumps(values))
                with self.assertRaises(ValueError): prepare_runtime_source.update_factory_review_pin(root)
                self.assertEqual(pin.read_bytes(), original)

class LeanPreparationTests(unittest.TestCase):
    fixture = FactoryPreparationTests.fixture

    def test_lean_admission_uses_verified_archive_and_preserves_source_provenance(self):
        from unittest.mock import patch
        for case in ('success', 'success-a948d8a', 'crossed-contract', 'different-source', 'unknown', 'mixed', 'old-package', 'malformed-source', 'capability', 'missing-package', 'tampered-package', 'runtime-package'):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                bundle, lock_path = self.fixture(Path(directory))
                package = 'try-omarchy-fixture.pkg.tar.zst'
                (bundle / package).write_bytes(b'synthetic entire package archive; never executable')
                owner_contract = 'lean-a948d8a' if case == 'success-a948d8a' else 'lean-e4fffc6'
                contract_file, version = module.LEAN_CONTRACTS[owner_contract]
                contract = json.loads(json.dumps(module.reviewed_contract()))
                for entry in contract['leanContracts']:
                    if entry['ownerSetupContractSHA256'] == module.digest(ROOT / 'Sources/OmarchyVMManagerCore/Resources' / contract_file):
                        entry['leanPackageSHA256'] = module.digest(bundle / package)
                contract['runtimePackageSHA256'] = 'b' * 64
                lock = json.loads(lock_path.read_bytes())
                lock.update(ownerSetupContractsVersion=1, factoryCompatibilityVersion=1, patchCommit='e' * 40)
                lock['files']['Contents/Resources/owner-setup-provenance.json'] = 'f' * 64
                expected_file = 'LeanOwnerSetupContract-a948d8a.json' if case == 'crossed-contract' else contract_file
                expected = json.loads((ROOT / 'Sources/OmarchyVMManagerCore/Resources' / expected_file).read_bytes())['programs']
                del expected['/usr/share/omarchy/install/provisioning/progress-icon.sh']
                if case == 'mixed': expected['/usr/bin/omarchy-provision-owner'] = 'a' * 64
                (bundle / 'compatibility.json').write_text(json.dumps({'owner_programs': expected, 'packages': {'try-omarchy': '0.1.0-36.1' if case == 'old-package' else version}}))
                source = 'f' * 40 if case == 'different-source' else 'bad' if case == 'malformed-source' else lock['patchCommit']
                (bundle / 'image-build.json').write_text(json.dumps({'try_commit': source}))
                if case == 'capability': del lock['factoryCompatibilityVersion']
                if case == 'tampered-package': (bundle / package).write_bytes(b'changed integration components')
                if case == 'runtime-package': lock['files'][module.PACKAGE] = 'c' * 64
                lock_path.write_text(json.dumps(lock))
                kwargs = dict(runtime_lock=lock_path, owner_contract='unknown' if case == 'unknown' else owner_contract, compatibility='compatibility.json', image_build='image-build.json', integration_package=None if case == 'missing-package' else package)
                with patch.object(module, 'reviewed_contract', return_value=contract):
                    if case in ('success', 'success-a948d8a', 'different-source'):
                        module.prepare(bundle, 'Lean fixture', ['compatibility.json', 'image-build.json', package], **kwargs)
                        value = json.loads((bundle / 'reviewed-factory.json').read_bytes())
                        self.assertEqual(value['format'], 2)
                        self.assertEqual(value['imageIntegrationSourceCommit'], source)
                        self.assertEqual(value['guestIntegration']['packageSHA256'], module.digest(bundle / package))
                        self.assertEqual(value['imageIntegrationVersion'], version)
                        self.assertEqual(value['ownerSetupContractSHA256'], module.digest(ROOT / 'Sources/OmarchyVMManagerCore/Resources' / contract_file))
                        self.assertEqual(value['guestIntegration']['capabilities'], contract['capabilities'])
                    else:
                        with self.assertRaises(ValueError): module.prepare(bundle, 'Lean fixture', ['compatibility.json', 'image-build.json', package], **kwargs)
                        self.assertFalse((bundle / 'reviewed-factory.json').exists())

    def test_real_policy_is_pinned_in_client_and_covers_all_capabilities(self):
        import sys
        sys.path.insert(0, str(ROOT / 'Scripts'))
        from upstream_source import prepare
        source = prepare()
        policy = (ROOT / 'Config/GuestIntegrationCompatibility.json').read_text()
        client = (source / 'macos/Sources/TryOmarchyKitClient/VMGuestIntegrationContract.swift').read_text()
        self.assertIn(policy.rstrip(), client)
        contract = module.reviewed_contract()
        self.assertEqual(contract['capabilities'], dict(guestStatus=1, managedSSH=1, managedSetup=1, ownerSetupContracts=1, ownerSetupReport=1))
        self.assertEqual([lean['ownerSetupContractSHA256'] for lean in contract['leanContracts']],
                         [module.digest(ROOT / 'Sources/OmarchyVMManagerCore/Resources' / name) for name, _ in module.LEAN_CONTRACTS.values()])
        self.assertEqual([lean['leanPackageVersion'] for lean in contract['leanContracts']], [version for _, version in module.LEAN_CONTRACTS.values()])

    def test_missing_malformed_or_unsupported_reviewed_policy_is_refused(self):
        from unittest.mock import patch
        original = module.reviewed_contract()
        for case in ('schema', 'protocol', 'missing', 'malformed', 'boolean'):
            with self.subTest(case=case):
                value = json.loads(json.dumps(original))
                if case == 'schema': value['schemaVersion'] = 1
                if case == 'protocol': value['capabilities']['guestStatus'] = 2
                if case == 'missing': del value['runtimePackageSHA256']
                if case == 'malformed': value = []
                if case == 'boolean': value['capabilities']['managedSSH'] = True
                with patch.object(module, 'metadata', return_value=value):
                    with self.assertRaisesRegex(ValueError, 'malformed or unsupported'): module.reviewed_contract()


class GuestPackageReuseTests(unittest.TestCase):
    def test_reuse_requires_complete_kit_integrity_clean_source_and_identical_package_tree(self):
        from unittest.mock import patch
        import sys
        sys.path.insert(0, str(ROOT / 'Scripts'))
        import build_patched_kit
        for case in ('valid', 'inventory', 'native-inventory', 'commit', 'dirty', 'package-tree', 'license'):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                source, bundle = root / 'new-source', root / 'previous-kit'
                source.mkdir()
                package = bundle / module.PACKAGE
                package.parent.mkdir(parents=True)
                package.write_bytes(b'synthetic guest package archive')
                native = package.with_name('try-omarchy-0.1.0-48.1-aarch64.pkg.tar.zst')
                native.write_bytes(b'synthetic native-rendering package archive')
                lock = {'files': build_patched_kit.inventory(bundle), 'patchCommit': 'e' * 40}
                if case == 'inventory': package.write_bytes(b'changed archive')
                if case == 'native-inventory': native.write_bytes(b'changed native archive')

                def git(command, **kwargs):
                    folder, args = Path(command[2]), command[3:]
                    if args == ['rev-parse', 'HEAD']: return 'wrong' if case == 'commit' else lock['patchCommit']
                    if args == ['status', '--porcelain']: return 'dirty' if case == 'dirty' else ''
                    changed = (args == ['rev-parse', 'HEAD:guest/package'] and case == 'package-tree'
                               or args == ['rev-parse', 'HEAD:LICENSE'] and case == 'license')
                    return 'different-tree' if changed and folder == source else 'same-tree'

                with patch.object(build_patched_kit, 'run'), patch.object(build_patched_kit.subprocess, 'check_output', side_effect=git):
                    if case == 'valid':
                        build_patched_kit.reuse_guest_package(source, bundle, lock)
                        self.assertEqual((source / 'dist/guest/packages' / package.name).read_bytes(), package.read_bytes())
                        self.assertEqual((source / 'dist/guest/packages-lean' / native.name).read_bytes(), native.read_bytes())
                    else:
                        with self.assertRaises(AssertionError): build_patched_kit.reuse_guest_package(source, bundle, lock)
                        self.assertFalse((source / 'dist/guest/packages').exists())
