import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[2] / "Scripts"
sys.path.insert(0, str(SCRIPTS))
import provisioning_package as package
from Fixtures.provisioning_patch import add_patch_fixture


class ProvisioningPackageTests(unittest.TestCase):
    def test_read_only_export_verification_does_not_generate_build_inputs(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "Config").mkdir()
            shutil.copy2(package.ROOT / package.LOCK, root / package.LOCK)
            shutil.copytree(package.ROOT / "Vendor/dev-vm", root / "Vendor/dev-vm")
            shutil.copytree(package.ROOT / "Patches", root / "Patches")
            raw, lock = package.verify_source(root)
            self.assertEqual(raw, (root / package.LOCK).read_bytes())
            self.assertEqual(lock["files"], package.files(root / "Vendor/dev-vm"))
            self.assertFalse((root / ".build").exists())
            self.assertFalse((root / "Sources").exists())

    def test_source_export_pin_and_generated_swift_match(self):
        raw, lock = package.read_lock()
        self.assertEqual(lock["revision"], "ea73f93a07e6be42ad76cc32787ad8c05c109783")
        # The merged dev-vm commit already contains every former integration patch.
        self.assertEqual(lock["integrationPatches"], [])
        self.assertEqual(lock["baseFiles"], lock["files"])
        package.verify_source()
        self.assertEqual(package.files(package.ROOT / lock["package"]), lock["files"])
        self.assertEqual((package.ROOT / "Sources/OmarchyVMManagerCore/ProvisioningPackagePin.swift").read_text(), package.pin_source(raw, lock))
        resolved = json.loads((package.ROOT / "Package.resolved").read_bytes())
        self.assertEqual(resolved["pins"][0]["state"]["revision"], "a2bbd2796fe3064e107de18cb56031052c4fa899")

    def test_inventory_rejects_changes_extra_symlinks_and_special_files(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); (root / "original").write_bytes(b"fixture")
            original = package.files(root)
            (root / "original").write_bytes(b"changed")
            self.assertNotEqual(package.files(root), original)
            (root / "link").symlink_to("original")
            with self.assertRaises(ValueError): package.files(root)
            (root / "link").unlink()
            import os
            os.mkfifo(root / "fifo")
            with self.assertRaises(ValueError): package.files(root)

    def test_layouts_are_unambiguous(self):
        with tempfile.TemporaryDirectory() as temp:
            bundle = Path(temp)
            for relative in ["Resources", "Contents/Resources/Resources"]:
                folder = bundle / relative; folder.mkdir(parents=True)
                (folder / "engine-identity.json").write_text("{}")
                if relative == "Resources": self.assertEqual(package.resource_directory(bundle), folder)
                else:
                    with self.assertRaises(ValueError): package.resource_directory(bundle)

    def test_prepare_refuses_changed_source(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "Config").mkdir()
            shutil.copy2(package.ROOT / package.LOCK, root / package.LOCK)
            (root / "Vendor/dev-vm").mkdir(parents=True)
            with self.assertRaisesRegex(ValueError, "source changed"): package.prepare(root)

    def test_launcher_build_is_exact_and_optional_plugins_are_refused(self):
        with patch.dict("os.environ", {"TOMLDECODER_DOCS": "1"}):
            with self.assertRaisesRegex(ValueError, "plugins"): package.prepare()
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "Config").mkdir(); (root / "Sources/OmarchyVMManagerCore").mkdir(parents=True)
            shutil.copy2(package.ROOT / package.LOCK, root / package.LOCK)
            shutil.copytree(package.ROOT / "Vendor/dev-vm", root / "Vendor/dev-vm")
            shutil.copytree(package.ROOT / "Patches", root / "Patches")
            package.prepare(root)
            launcher = root / ".build/provisioning-launcher-source/Sources"
            self.assertEqual((launcher / "main.c").read_bytes(), (root / "Vendor/dev-vm/Sources/dev-vm-process-host/main.c").read_bytes())
            (launcher / "extra.c").write_text("not admitted")
            with self.assertRaisesRegex(ValueError, "Unexpected launcher"): package.prepare(root)

    def test_patched_snapshot_requires_exact_patch_and_reconstructed_base(self):
        for kind in ("valid", "patch", "base", "snapshot", "missing-patch"):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                (root / "Config").mkdir()
                (root / "Sources/OmarchyVMManagerCore").mkdir(parents=True)
                shutil.copytree(package.ROOT / "Vendor/dev-vm", root / "Vendor/dev-vm")
                shutil.copytree(package.ROOT / "Patches", root / "Patches")
                shutil.copy2(package.ROOT / package.LOCK, root / package.LOCK)
                lock = add_patch_fixture(root, package)
                patch_file = root / lock["integrationPatches"][0]["path"]
                if kind == "patch": patch_file.write_text("changed fixture")
                elif kind == "missing-patch": patch_file.unlink()
                elif kind == "base": lock["baseFiles"]["Package.swift"] = "a" * 64
                elif kind == "snapshot": lock["sourceSnapshotSHA256"] = "b" * 64
                (root / package.LOCK).write_text(json.dumps(lock))
                if kind == "valid": package.prepare(root)
                else:
                    with self.assertRaises(ValueError): package.prepare(root)

    def test_unpatched_export_requires_identical_base_inventory(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "Config").mkdir()
            shutil.copytree(package.ROOT / "Vendor/dev-vm", root / "Vendor/dev-vm")
            _, lock = package.read_lock()
            lock["integrationPatches"] = []
            lock["baseFiles"]["README.md"] = "a" * 64
            (root / package.LOCK).write_text(json.dumps(lock))
            with self.assertRaisesRegex(ValueError, "Unpatched provisioning base differs"):
                package.verify_source(root)
