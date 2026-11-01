import datetime
import hashlib
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Scripts"))
import keychain_profile


class KeychainProfileTests(unittest.TestCase):
    def setUp(self):
        self.team = "ABC1234567"
        self.bundle = "dev.omarchy.vm-manager"
        self.now = datetime.datetime.now(datetime.timezone.utc)
        self.entitlements = {"com.apple.application-identifier": self.team + "." + self.bundle,
                             "com.apple.developer.team-identifier": self.team}
        self.profile = dict(TeamIdentifier=[self.team], Platform=["OSX"], ProvisionsAllDevices=True,
                            DeveloperCertificates=[b"synthetic-certificate"],
                            ExpirationDate=(self.now + datetime.timedelta(days=90)).replace(tzinfo=None), Entitlements=self.entitlements)
        pin = patch.object(keychain_profile, "profile_pin", return_value=dict(format=1, bundleID=self.bundle,
                           profileSHA256=hashlib.sha256(b"synthetic-profile").hexdigest()))
        pin.start(); self.addCleanup(pin.stop)
        certificate = patch.object(keychain_profile, "signing_certificate", return_value=b"synthetic-certificate")
        certificate.start(); self.addCleanup(certificate.stop)

    def test_changed_profile_bytes_are_refused(self):
        keychain_profile.verify_profile_bytes(b"synthetic-profile")
        with self.assertRaisesRegex(AssertionError, "digest mismatch"):
            keychain_profile.verify_profile_bytes(b"changed-profile")

    def test_only_the_exact_manager_app_id_is_granted(self):
        allowed = dict(self.entitlements, **{"keychain-access-groups": [self.team + ".*"]})
        profile = dict(self.profile, Entitlements=allowed)
        self.assertEqual(keychain_profile.profile_entitlements(profile, self.team, self.bundle, self.now), self.entitlements)

    def test_wrong_team_platform_expired_missing_cert_or_development_profiles_are_refused(self):
        for changes in [dict(TeamIdentifier=["ZZZ1234567"]), dict(Platform=["iOS"]),
                        dict(ProvisionsAllDevices=False), dict(DeveloperCertificates=[]),
                        dict(ExpirationDate=self.now), dict(ExpirationDate="invalid"),
                        dict(Entitlements=dict(self.entitlements, **{"com.apple.application-identifier": self.team + ".*"})),
                        dict(Entitlements=dict(self.entitlements, **{"get-task-allow": True})),
                        dict(Entitlements=dict(self.entitlements, **{"com.apple.security.get-task-allow": True})),
                        dict(Entitlements=dict(self.entitlements, **{"com.apple.developer.team-identifier": "ZZZ1234567"}))]:
            with self.subTest(changes=changes), self.assertRaises(AssertionError):
                keychain_profile.profile_entitlements(dict(self.profile, **changes), self.team, self.bundle, self.now)

    def test_profiles_cannot_be_reused_by_cli_or_layout_preview(self):
        for bundle in [self.bundle + ".cli", self.bundle + ".storage", self.bundle + ".layout-preview"]:
            with self.subTest(bundle=bundle), self.assertRaises(AssertionError):
                keychain_profile.profile_entitlements(self.profile, self.team, bundle, self.now)

    def test_profile_is_copied_before_decoding_and_grants_no_shared_groups(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); stage = root / "Synthetic.app"; (stage / "Contents").mkdir(parents=True)
            source = root / "Synthetic.provisionprofile"; source.write_bytes(b"synthetic-profile")
            def decode(embedded):
                self.assertEqual(embedded.read_bytes(), b"synthetic-profile")
                self.assertNotEqual(embedded, source)
                return self.profile
            with patch.object(keychain_profile, "decode_profile", side_effect=decode):
                result = keychain_profile.stage_keychain_profile(source, stage, self.team, self.bundle, {})
            self.assertEqual(result, self.entitlements)

    def test_packaged_scope_must_match_and_unprofiled_builds_have_no_restricted_entitlements(self):
        with tempfile.TemporaryDirectory() as temp:
            app = Path(temp) / "Synthetic.app"; (app / "Contents").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(dict(CFBundleIdentifier=self.bundle)))
            def verify(actual):
                with patch.object(keychain_profile.subprocess, "run", return_value=SimpleNamespace(stdout=plistlib.dumps(actual))), patch.object(keychain_profile, "decode_profile", return_value=self.profile):
                    return keychain_profile.verify_keychain_profile(app, self.team)
            self.assertFalse(verify({}))
            with self.assertRaises(AssertionError):
                verify(self.entitlements)
            (app / "Contents/embedded.provisionprofile").write_bytes(b"synthetic-profile")
            self.assertTrue(verify(self.entitlements))
            with patch.object(keychain_profile, "signing_certificate", return_value=b"wrong-certificate"), self.assertRaisesRegex(AssertionError, "signing certificate"):
                verify(self.entitlements)
            for actual in [{}, dict(self.entitlements, **{"keychain-access-groups": [self.team + ".*"]})]:
                with self.assertRaises(AssertionError):
                    verify(actual)
