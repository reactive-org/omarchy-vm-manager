import hashlib
import json
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

SCRIPTS = Path(__file__).resolve().parents[2] / "Scripts"
sys.path.insert(0, str(SCRIPTS))
import fetch_runtime_kit
from package_prerelease import validate_tag
from bundle_layout import core_resource_directory


class LockedRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.folder = Path(self.temp.name)
        self.archive = self.folder / "TryOmarchyKit.zip"
        self.value = {"format": 1, "version": "development", "runProtocolVersion": 1,
                      "buildDate": "2026-10-31T00:00:00Z"}
        self.payload = {"Contents/Resources/kit.json": json.dumps(self.value).encode(),
                        "Contents/MacOS/omarchy-vm-helper": b"synthetic helper; no VM"}
        self.lock = {"kitVersion": "development", "runProtocolVersion": 1,
                     "buildDate": self.value["buildDate"],
                     "files": {name: hashlib.sha256(data).hexdigest() for name, data in self.payload.items()}}
        self.write_archive()

    def tearDown(self):
        self.temp.cleanup()

    def write_archive(self, extra=None, symlink=False):
        with zipfile.ZipFile(self.archive, "w") as z:
            for name, data in self.payload.items():
                z.writestr("TryOmarchyKit.bundle/" + name, data)
            if extra:
                item = zipfile.ZipInfo(extra)
                if symlink:
                    item.external_attr = (stat.S_IFLNK | 0o777) << 16
                z.writestr(item, b"extra")
        self.lock["kitSHA256"] = hashlib.sha256(self.archive.read_bytes()).hexdigest()

    def test_exact_archive(self):
        self.assertEqual(fetch_runtime_kit.archive_manifest(self.archive, self.lock), self.value)

    def test_changed_bytes_and_inventory_are_refused(self):
        self.archive.write_bytes(self.archive.read_bytes() + b"tamper")
        with self.assertRaisesRegex(AssertionError, "digest mismatch"):
            fetch_runtime_kit.archive_manifest(self.archive, self.lock)
        self.write_archive(extra="TryOmarchyKit.bundle/extra")
        with self.assertRaisesRegex(AssertionError, "inventory mismatch"):
            fetch_runtime_kit.archive_manifest(self.archive, self.lock)

    def test_unsafe_archive_paths_duplicates_and_symlinks(self):
        for name in ["../escape", "/absolute", "Other.bundle/file", "TryOmarchyKit.bundle/../escape",
                     "TryOmarchyKit.bundle/Contents//file"]:
            with self.subTest(name=name):
                self.write_archive(extra=name)
                with self.assertRaises(AssertionError):
                    fetch_runtime_kit.archive_manifest(self.archive, self.lock)
        self.write_archive(extra="TryOmarchyKit.bundle/link", symlink=True)
        with self.assertRaisesRegex(AssertionError, "special runtime"):
            fetch_runtime_kit.archive_manifest(self.archive, self.lock)
        with self.assertWarns(UserWarning):
            self.write_archive(extra="TryOmarchyKit.bundle/Contents/MacOS/omarchy-vm-helper")
        with self.assertRaises(AssertionError):
            fetch_runtime_kit.archive_manifest(self.archive, self.lock)

    def test_appledouble_is_consumed_by_ditto(self):
        self.write_archive(extra="TryOmarchyKit.bundle/Contents/._Resources")
        self.assertEqual(fetch_runtime_kit.archive_manifest(self.archive, self.lock), self.value)

    def test_extracted_tampering_and_manifest_mismatch(self):
        bundle = self.folder / "TryOmarchyKit.bundle"
        for name, data in self.payload.items():
            path = bundle / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        with patch.object(fetch_runtime_kit.subprocess, "run") as command:
            fetch_runtime_kit.verify(self.folder, self.lock)
            self.assertEqual(command.call_args.args[0][:4], ["codesign", "--verify", "--deep", "--strict"])
        (bundle / "extra").write_bytes(b"extra")
        with self.assertRaisesRegex(AssertionError, "extracted runtime inventory mismatch"):
            fetch_runtime_kit.verify(self.folder, self.lock)
        self.lock["buildDate"] = "2026-11-01T00:00:00Z"
        with self.assertRaises(AssertionError):
            fetch_runtime_kit.archive_manifest(self.archive, self.lock)

    def test_archive_size_is_bounded(self):
        with patch.object(fetch_runtime_kit, "MAX_ARCHIVE_BYTES", 1):
            with self.assertRaises(AssertionError):
                fetch_runtime_kit.archive_manifest(self.archive, self.lock)
        with patch.object(fetch_runtime_kit, "MAX_EXPANDED_BYTES", 1):
            with self.assertRaises(AssertionError):
                fetch_runtime_kit.archive_manifest(self.archive, self.lock)


class PrereleaseVersionTests(unittest.TestCase):
    def test_only_matching_development_tags_are_accepted(self):
        self.assertEqual(validate_tag("v0.9.3-dev.1", "0.9.3"), "v0.9.3-dev.1")
        for tag in ["", "v0.9.3", "v0.9.3-dev.0", "v0.9.3-dev.01", "v1.0.0-dev.1", "v0.9.3-dev.1/extra", "v0.9.3-dev.$(id)"]:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                validate_tag(tag, "0.9.3")

    def test_flat_and_contents_resource_layouts(self):
        for relative in [".", "Contents/Resources"]:
            with self.subTest(relative=relative), tempfile.TemporaryDirectory() as temp:
                bundle = Path(temp) / "Core.bundle"
                resources = bundle / relative
                resources.mkdir(parents=True)
                (resources / "OwnerSetupContract.json").write_text("{}")
                self.assertEqual(core_resource_directory(bundle), resources)
                other = bundle / ("Contents/Resources" if relative == "." else ".")
                other.mkdir(parents=True, exist_ok=True)
                (other / "OwnerSetupContract.json").write_text("{}")
                with self.assertRaises(ValueError):
                    core_resource_directory(bundle)
        with tempfile.TemporaryDirectory() as temp, self.assertRaises(ValueError):
            core_resource_directory(Path(temp))
