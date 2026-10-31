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
        lock.write_text(json.dumps({'customFactoryVersion': 1, 'managedSSHVersion': 1, 'managedSetupVersion': 1,
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
        for case in ('boolean-format', 'disk-path', 'large-metadata', 'control-name', 'runtime-capability', 'runtime-path'):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as temp:
                bundle, lock = self.fixture(Path(temp))
                image = json.loads((bundle / 'factory.json').read_bytes())
                if case == 'boolean-format': image['format'] = True
                if case == 'disk-path': image['disk']['path'] = '../disk.img'
                if case == 'large-metadata': image['padding'] = 'x' * 65536
                (bundle / 'factory.json').write_text(json.dumps(image))
                runtime = json.loads(lock.read_bytes())
                if case == 'runtime-capability': runtime['customFactoryVersion'] = True
                if case == 'runtime-path': runtime['files']['Contents/../outside'] = 'a' * 64
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
