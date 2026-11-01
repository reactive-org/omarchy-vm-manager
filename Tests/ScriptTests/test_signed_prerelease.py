import hashlib
import base64
import json
from pathlib import Path
import sys
import unittest
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Scripts"))
import signed_prerelease


class SignedProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.source = {"format": 1, "kitSHA256": "a" * 64, "patchCommit": "b" * 40,
                       "focusAwareClipboard": True, "managedSSHVersion": 1,
                       "buildDate": "2026-11-01T00:00:00Z", "composition": "source", "files": {"firmware": "c" * 64}}
        self.sha = "d" * 64
        self.team = "ABC1234567"
        self.lock = dict(self.source, kitSHA256="e" * 64, signingTeamID=self.team,
                         sourceLockSHA256=self.sha, sourceKitSHA256=self.source["kitSHA256"], artifactTag="v0.9.3-dev.4")

    def test_exact_signed_origin(self):
        signed_prerelease.validate_signed_lock(self.lock, self.source, self.sha, self.team)

    def test_wrong_origin_team_capabilities_or_artifact_tag_are_rejected(self):
        for key, value in [("signingTeamID", "ZZZ1234567"), ("sourceLockSHA256", "f" * 64),
                           ("sourceKitSHA256", "f" * 64), ("kitSHA256", "a" * 64),
                           ("patchCommit", "f" * 40), ("managedSSHVersion", 2),
                           ("focusAwareClipboard", False), ("artifactTag", "../../escape")]:
            with self.subTest(key=key), self.assertRaises(AssertionError):
                signed_prerelease.validate_signed_lock(dict(self.lock, **{key: value}), self.source, self.sha, self.team)

    def test_unsigned_payloads_cannot_change_or_disappear(self):
        source = {"Contents/MacOS/helper": "a", "Contents/Resources/guest/package": "b", "Contents/Resources/kit.json": "c"}
        updated = dict(source, **{"Contents/MacOS/helper": "signed", "Contents/Resources/kit.json": "new date", "Contents/CodeResources": "ticket"})
        signed_prerelease.validate_payload(source, updated, {"Contents/MacOS/helper"})
        for changed in [dict(updated, **{"Contents/Resources/guest/package": "changed"}),
                        {name: value for name, value in updated.items() if name != "Contents/Resources/guest/package"},
                        dict(updated, **{"unexpected": "injected"})]:
            with self.subTest(changed=changed), self.assertRaises(AssertionError):
                signed_prerelease.validate_payload(source, changed, {"Contents/MacOS/helper"})

    def test_real_credentials_are_refused_outside_github(self):
        with patch.dict(signed_prerelease.os.environ, {}, clear=True), self.assertRaisesRegex(RuntimeError, "restricted"):
            with signed_prerelease.credentials():
                self.fail("Signing credentials were enabled locally")

    def test_errors_redact_credentials(self):
        with patch.object(signed_prerelease, "REDACTIONS", ["synthetic-private-key", "synthetic-password"]):
            self.assertEqual(signed_prerelease.redact("synthetic-private-key synthetic-password"), "[redacted] [redacted]")

    def test_notary_only_accepts_accepted_status_and_retains_diagnostics(self):
        identifier = "12345678-1234-1234-1234-123456789abc"
        for outcome in ["Accepted", "Invalid"]:
            with self.subTest(outcome=outcome), tempfile.TemporaryDirectory() as temp:
                responses = [SimpleNamespace(stdout=json.dumps({"id": identifier})),
                             SimpleNamespace(stdout=json.dumps({"id": identifier, "status": "In Progress"})),
                             SimpleNamespace(stdout=json.dumps({"id": identifier, "status": outcome})), SimpleNamespace(stdout="")]
                with patch.object(signed_prerelease, "ROOT", Path(temp)), patch.object(signed_prerelease, "run", side_effect=responses), patch.object(signed_prerelease.time, "sleep"):
                    if outcome == "Accepted":
                        self.assertEqual(signed_prerelease.notarize(Path("fixture.zip"), [], "app")["status"], "Accepted")
                    else:
                        with self.assertRaisesRegex(RuntimeError, "not accepted"):
                            signed_prerelease.notarize(Path("fixture.zip"), [], "app")
                saved = json.loads((Path(temp) / ".build/notarization/app-submission.json").read_text())
                self.assertEqual(saved["status"], outcome)

    def test_credentials_are_cleaned_up_on_signing_failure(self):
        with tempfile.TemporaryDirectory() as temp:
            identity = "Developer ID Application: Synthetic Fixture (ABC1234567)"
            values = {name: "synthetic" for name in signed_prerelease.REQUIRED_SECRETS}
            values.update(GITHUB_ACTIONS="true", RUNNER_TEMP=temp, APPLE_TEAM_ID="ABC1234567",
                          MACOS_SIGNING_IDENTITY=identity, MACOS_CERTIFICATE_P12_BASE64=base64.b64encode(b"synthetic-p12").decode())
            def command(label, *arguments):
                return SimpleNamespace(stdout=('"/synthetic/login.keychain-db"' if arguments[:2] == ("security", "list-keychains") else identity))
            with patch.dict(signed_prerelease.os.environ, values, clear=True), patch.object(signed_prerelease, "REDACTIONS", []), patch.object(signed_prerelease, "run", side_effect=command), patch.object(signed_prerelease.subprocess, "run") as cleanup:
                with self.assertRaisesRegex(RuntimeError, "synthetic failure"):
                    with signed_prerelease.credentials():
                        raise RuntimeError("synthetic failure")
                self.assertTrue(any(call.args[0][:2] == ["security", "delete-keychain"] for call in cleanup.call_args_list))
            self.assertEqual(list(Path(temp).iterdir()), [])
