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


class ProvisioningPackageTests(unittest.TestCase):
    def test_source_export_pin_and_generated_swift_match(self):
        raw, lock = package.read_lock()
        self.assertEqual(lock["revision"], "bb3fae22be45b38035fac52aefa0eb270a9d0fea")
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
            package.prepare(root)
            launcher = root / ".build/provisioning-launcher-source/Sources"
            self.assertEqual((launcher / "main.c").read_bytes(), (root / "Vendor/dev-vm/Sources/dev-vm-process-host/main.c").read_bytes())
            (launcher / "extra.c").write_text("not admitted")
            with self.assertRaisesRegex(ValueError, "Unexpected launcher"): package.prepare(root)
