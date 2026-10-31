import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[2] / "Scripts"
sys.path.insert(0, str(SCRIPTS))
import kit_artifacts


class PinnedAcquisitionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / "Config").mkdir()
        self.folder = self.root / "artifact"
        self.folder.mkdir()
        self.manifest = {"format": 1, "version": "v1.3.0", "runProtocolVersion": 1, "buildDate": "2026-10-31T00:00:00Z"}
        (self.folder / "TryOmarchyKit.json").write_text(json.dumps(self.manifest))
        self.archive()
        self.root_patch = patch.object(kit_artifacts, "ROOT", self.root)
        self.root_patch.start()

    def tearDown(self):
        self.root_patch.stop()
        self.temp.cleanup()

    def archive(self, extra=None):
        archive = self.folder / "TryOmarchyKit.zip"
        with zipfile.ZipFile(archive, "w") as z:
            z.writestr("TryOmarchyKit.bundle/Contents/Resources/kit.json", json.dumps(self.manifest))
            if extra:
                z.writestr(extra, "unexpected")
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        (self.folder / "TryOmarchyKit.zip.sha256").write_text(digest + "  TryOmarchyKit.zip\n")
        (self.root / "Config/TryOmarchyUpstream.lock.json").write_text(json.dumps({"kitSHA256": digest, "tag": "v1.3.0"}))

    def test_valid_pinned_archive(self):
        kit_artifacts.verify_reference(self.folder)

    def test_checksum_mismatch(self):
        with open(self.folder / "TryOmarchyKit.zip", "ab") as stream:
            stream.write(b"tamper")
        with self.assertRaises(AssertionError):
            kit_artifacts.verify_reference(self.folder)

    def test_sidecar_mismatch(self):
        (self.folder / "TryOmarchyKit.zip.sha256").write_text("0" * 64 + "  TryOmarchyKit.zip\n")
        with self.assertRaises(AssertionError):
            kit_artifacts.verify_reference(self.folder)

    def test_wrong_protocol(self):
        value = dict(self.manifest, runProtocolVersion=2)
        (self.folder / "TryOmarchyKit.json").write_text(json.dumps(value))
        with self.assertRaises(AssertionError):
            kit_artifacts.verify_reference(self.folder)

    def test_zip_escape_and_wrong_top_level(self):
        for name in ["TryOmarchyKit.bundle/../../escape", "/absolute", "Other.bundle/file"]:
            with self.subTest(name=name):
                self.archive(extra=name)
                with self.assertRaises(AssertionError):
                    kit_artifacts.verify_reference(self.folder)

    def test_extracted_artifact_must_match_archive(self):
        resource = self.folder / "TryOmarchyKit.bundle/Contents/Resources/kit.json"
        resource.parent.mkdir(parents=True)
        resource.write_text(json.dumps(self.manifest))
        (resource.parent / "injected-script").write_text("extra")
        with self.assertRaisesRegex(AssertionError, "extracted reference differs"):
            kit_artifacts.verify_reference(self.folder)

    def test_ditto_consumes_appledouble_metadata(self):
        self.archive(extra="TryOmarchyKit.bundle/Contents/Resources/._kit.json")
        resource = self.folder / "TryOmarchyKit.bundle/Contents/Resources/kit.json"
        resource.parent.mkdir(parents=True)
        resource.write_text(json.dumps(self.manifest))
        with patch.object(kit_artifacts.subprocess, "run"):
            kit_artifacts.verify_reference(self.folder)

    def test_download_scope_is_fixed(self):
        requested = []
        def download(url, **kwargs):
            requested.append(url)
            raise RuntimeError("test stops before network")
        with patch.object(kit_artifacts.urllib.request, "urlopen", download):
            with self.assertRaises(RuntimeError):
                kit_artifacts.fetch()
        self.assertEqual(requested, ["https://github.com/omacom/try-omarchy/releases/download/v1.3.0/TryOmarchyKit.zip"])

class OptimizedExecutionTests(unittest.TestCase):
    def test_optimized_validation_is_refused(self):
        import subprocess
        result = subprocess.run([sys.executable, "-O", str(SCRIPTS / "kit_artifacts.py"), "fetch"], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Optimized Python execution is refused", result.stderr)


if __name__ == "__main__":
    unittest.main()
