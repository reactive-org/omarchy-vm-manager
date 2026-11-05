from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Scripts"))
from release_metadata import RELEASE_TAG_KEY, release_info, verify_release_info, channel_spec
import package_prerelease


class ReleaseMetadataTests(unittest.TestCase):
    def test_generated_versions_and_channel_identity_are_verified_before_packaging(self):
        original = {'CFBundleShortVersionString': '0.11.0', 'CFBundleVersion': '23'}
        for channel, tag in [('stable', 'v0.11.1'), ('development', 'v0.11.1-dev.3')]:
            bundle, name, _, _ = channel_spec(channel)
            info = release_info(original, tag, channel, '0.11.1', '101')
            info.update(CFBundleIdentifier=bundle, CFBundleDisplayName=name, OmarchyAppChannel=channel)
            verify_release_info(info, tag, '0.11.1', channel)
            self.assertEqual(info['CFBundleVersion'], '101')
            with self.assertRaises(ValueError):
                verify_release_info(dict(info, CFBundleIdentifier='wrong'), tag, '0.11.1', channel)
        self.assertEqual(original['CFBundleShortVersionString'], '0.11.0')
        for channel, tag in [('stable', 'v0.11.1-dev.1'), ('development', 'v0.11.1')]:
            with self.assertRaises(ValueError):
                release_info(original, tag, channel, '0.11.1', '101')
        for version, build in [('0.11.1', None), (None, '101'), ('0.11.1', '0'), ('0.11.1', '1234567890')]:
            with self.assertRaises(ValueError):
                release_info(original, 'v0.11.1', 'stable', version, build)

    def test_full_tag_survives_plist_round_trip_without_changing_bundle_versions(self):
        original = {"CFBundleShortVersionString": "0.10.0", "CFBundleVersion": "23"}
        for tag in ["v0.10.0-dev.1", "v0.10.0-dev.10"]:
            info = plistlib.loads(plistlib.dumps(release_info(original, tag)))
            self.assertEqual(info[RELEASE_TAG_KEY], tag)
            self.assertEqual(info["CFBundleVersion"], "23")
            verify_release_info(info, tag, "0.10.0")
        self.assertNotIn(RELEASE_TAG_KEY, original)

    def test_local_builds_do_not_inherit_stale_release_identity(self):
        info = release_info({"CFBundleShortVersionString": "0.10.0", RELEASE_TAG_KEY: "v0.9.0-dev.1"}, "")
        self.assertNotIn(RELEASE_TAG_KEY, info)

    def test_invalid_or_mismatched_tags_are_refused_before_packaging(self):
        original = {"CFBundleShortVersionString": "0.10.0"}
        for tag in ["v0.9.0-dev.1", "v0.10.0-dev.0", "v0.10.0-dev.01", "v0.10.0-dev.1\n", "v0.10.0-dev.$(id)"]:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release_info(original, tag)
        for info in [original, {**original, RELEASE_TAG_KEY: "v0.10.0-dev.2"},
                     {"CFBundleShortVersionString": "0.9.0", RELEASE_TAG_KEY: "v0.10.0-dev.1"}]:
            with self.assertRaises(ValueError):
                verify_release_info(info, "v0.10.0-dev.1", "0.10.0")

    def test_packager_refuses_unstamped_or_wrong_staged_app_before_archiving(self):
        for embedded in [None, "v0.10.0-dev.2"]:
            with self.subTest(embedded=embedded), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                (root / "App").mkdir()
                info = {"CFBundleShortVersionString": "0.10.0"}
                (root / "App/Info.plist").write_bytes(plistlib.dumps(info))
                app = root / "dist/prerelease-staging/Omarchy VM Manager.app/Contents"
                app.mkdir(parents=True)
                if embedded:
                    info[RELEASE_TAG_KEY] = embedded
                (app / "Info.plist").write_bytes(plistlib.dumps(info))
                with patch.object(package_prerelease, "ROOT", root), patch.object(sys, "argv", ["package_prerelease.py"]), \
                     patch.dict("os.environ", {"RELEASE_TAG": "v0.10.0-dev.1"}), \
                     patch.object(package_prerelease.subprocess, "check_output", return_value="a" * 40), \
                     patch.object(package_prerelease.subprocess, "run") as command:
                    with self.assertRaisesRegex(ValueError, "release identity"):
                        package_prerelease.package()
                    command.assert_not_called()
