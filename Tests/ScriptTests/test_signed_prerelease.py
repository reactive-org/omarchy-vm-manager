import hashlib
import datetime
import base64
import json
from pathlib import Path
import sys
import unittest
import tempfile
import os
import subprocess
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

    def test_profile_staging_is_ci_only_and_requires_a_secret(self):
        for values, message in [({}, "restricted"), ({"GITHUB_ACTIONS": "true", "RUNNER_TEMP": "/tmp"}, "Missing GitHub secret")]:
            with patch.dict(os.environ, values, clear=True), self.assertRaisesRegex((RuntimeError, ValueError), message):
                with signed_prerelease.provisioning_profile():
                    self.fail("Unconfigured profile staging succeeded")

    def test_profile_staging_validates_scope_and_cleans_up_after_success_or_failure(self):
        for outcome in ("success", "body-failure", "decode-failure", "wrong-team", "wrong-digest"):
            with self.subTest(outcome=outcome), tempfile.TemporaryDirectory() as temp:
                values = dict(GITHUB_ACTIONS="true", RUNNER_TEMP=temp, APPLE_TEAM_ID=self.team,
                              MACOS_KEYCHAIN_PROFILE_BASE64=base64.b64encode(b"synthetic-profile").decode())
                profile = dict(TeamIdentifier=[self.team], Platform=["OSX"], ProvisionsAllDevices=True,
                               DeveloperCertificates=[b"synthetic-certificate"],
                               ExpirationDate=datetime.datetime.now() + datetime.timedelta(days=90),
                               Entitlements={"com.apple.application-identifier": self.team + ".dev.omarchy.vm-manager",
                                             "com.apple.developer.team-identifier": self.team})
                def decode(path):
                    self.assertEqual(path.read_bytes(), b"synthetic-profile")
                    self.assertEqual(path.stat().st_mode & 0o777, 0o600)
                    self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
                    if outcome == "decode-failure":
                        raise RuntimeError("synthetic-decode-failure")
                    if outcome == "wrong-team":
                        return dict(profile, TeamIdentifier=["ZZZ1234567"])
                    return profile
                with patch.dict(os.environ, values, clear=True), patch.object(signed_prerelease, "REDACTIONS", []), patch.object(signed_prerelease, "decode_profile", side_effect=decode), patch.object(signed_prerelease, "verify_profile_bytes", side_effect=AssertionError("wrong digest") if outcome == "wrong-digest" else None):
                    def exercise():
                        with signed_prerelease.provisioning_profile() as path:
                            self.assertTrue(path.is_file())
                            if outcome == "body-failure":
                                raise RuntimeError("synthetic-body-failure")
                    if outcome == "success":
                        exercise()
                    else:
                        with self.assertRaises((RuntimeError, AssertionError)):
                            exercise()
                self.assertEqual(list(Path(temp).iterdir()), [])

    def test_profile_secret_is_scoped_to_tagged_signing_job(self):
        workflow = (Path(__file__).resolve().parents[2] / ".github/workflows/test.yml").read_text()
        unprivileged, release = workflow.split("  prerelease:\n", 1)
        self.assertNotIn("MACOS_KEYCHAIN_PROFILE_BASE64", unprivileged)
        self.assertIn("if: startsWith(github.ref, 'refs/tags/v') && github.event_name == 'push'", release)
        self.assertEqual(release.count("${{ secrets.MACOS_KEYCHAIN_PROFILE_BASE64 }}"), 1)

    def test_errors_redact_credentials(self):
        with patch.object(signed_prerelease, "REDACTIONS", ["synthetic-private-key", "synthetic-password"]):
            self.assertEqual(signed_prerelease.redact("synthetic-private-key synthetic-password"), "[redacted] [redacted]")

    def test_status_credentials_are_refused_outside_github(self):
        with patch.dict(os.environ, {}, clear=True), self.assertRaisesRegex(RuntimeError, "restricted"):
            signed_prerelease.check_submission("12345678-1234-1234-1234-123456789abc")

    def test_existing_status_is_read_without_upload_or_signing_and_key_is_removed(self):
        identifier = "12345678-1234-1234-1234-123456789abc"
        for outcome in ("Accepted", "In Progress", "Invalid"):
            with self.subTest(outcome=outcome), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                private = root / "private"; private.mkdir()
                values = dict(GITHUB_ACTIONS="true", RUNNER_TEMP=str(private), APPLE_API_KEY_P8="synthetic-p8",
                              APPLE_API_KEY_ID="synthetic-key-id", APPLE_API_ISSUER_ID="synthetic-issuer",
                              GITHUB_OUTPUT=str(root / "outputs"))
                def command(label, *arguments):
                    self.assertEqual(arguments[:2], ("xcrun", "notarytool"))
                    self.assertIn(arguments[2], ("info", "log"))
                    key = Path(arguments[arguments.index("--key") + 1])
                    self.assertEqual(key.read_text(), "synthetic-p8\n")
                    self.assertEqual(key.stat().st_mode & 0o777, 0o600)
                    return SimpleNamespace(stdout=json.dumps(dict(id=identifier, status=outcome)))
                with patch.dict(os.environ, values, clear=True), patch.object(signed_prerelease, "ROOT", root), patch.object(signed_prerelease, "REDACTIONS", []), patch.object(signed_prerelease, "run", side_effect=command) as commands:
                    self.assertEqual(signed_prerelease.check_submission(identifier)["status"], outcome)
                self.assertEqual(commands.call_count, 2 if outcome == "Invalid" else 1)
                self.assertEqual(list(private.iterdir()), [])
                self.assertEqual((root / "outputs").read_text(), "status=" + outcome + "\n")
                self.assertEqual(json.loads((root / ".build/notarization/existing-submission.json").read_text())["id"], identifier)

    def test_status_key_is_removed_on_api_failure_and_mismatched_reply_is_refused(self):
        identifier = "12345678-1234-1234-1234-123456789abc"
        for response in (RuntimeError("synthetic API failure"), SimpleNamespace(stdout=json.dumps(dict(id="87654321-1234-1234-1234-123456789abc", status="Accepted")))):
            with self.subTest(response=response), tempfile.TemporaryDirectory() as temp:
                values = dict(GITHUB_ACTIONS="true", RUNNER_TEMP=temp, APPLE_API_KEY_P8="synthetic-p8",
                              APPLE_API_KEY_ID="synthetic-key-id", APPLE_API_ISSUER_ID="synthetic-issuer")
                with patch.dict(os.environ, values, clear=True), patch.object(signed_prerelease, "REDACTIONS", []), patch.object(signed_prerelease, "run", side_effect=[response]), self.assertRaises((RuntimeError, AssertionError)):
                    signed_prerelease.check_submission(identifier)
                self.assertEqual(list(Path(temp).iterdir()), [])

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
            with patch.dict(signed_prerelease.os.environ, values, clear=True), patch.object(signed_prerelease, "REDACTIONS", []), patch.object(signed_prerelease, "run", side_effect=command), patch.object(signed_prerelease, "compatible_certificate", return_value=(Path(temp)/"synthetic.p12", "transfer-fixture")), patch.object(signed_prerelease.subprocess, "run") as cleanup:
                with self.assertRaisesRegex(RuntimeError, "synthetic failure"):
                    with signed_prerelease.credentials():
                        raise RuntimeError("synthetic failure")
                self.assertTrue(any(call.args[0][:2] == ["security", "delete-keychain"] for call in cleanup.call_args_list))
            self.assertEqual(list(Path(temp).iterdir()), [])

    @unittest.skipUnless(Path("/opt/homebrew/opt/openssl@3/bin/openssl").is_file(), "macOS OpenSSL container compatibility check")
    def test_pkcs12_rewrap_preserves_certificate_and_rejects_wrong_password(self):
        openssl = "/opt/homebrew/opt/openssl@3/bin/openssl"
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            key, certificate, archive = folder/"fixture.key", folder/"fixture.crt", folder/"fixture.p12"
            def execute(*args, env=None):
                return subprocess.run([openssl, *map(str,args)], env=env, check=True, capture_output=True).stdout
            execute("req", "-x509", "-newkey", "rsa:2048", "-noenc", "-days", "1", "-subj", "/CN=Omarchy synthetic CI fixture", "-keyout", key, "-out", certificate)
            with patch.dict(os.environ, {"MACOS_CERTIFICATE_PASSWORD": "synthetic-export-password"}), patch.object(signed_prerelease, "REDACTIONS", []):
                execute("pkcs12", "-export", "-inkey", key, "-in", certificate, "-out", archive, "-passout", "env:MACOS_CERTIFICATE_PASSWORD")
                normalized, password = signed_prerelease.compatible_certificate(archive, folder)
                self.assertFalse((folder/"identity.pem").exists())
                values = dict(os.environ, OMARCHY_FIXTURE_PASSWORD=password)
                public = execute("pkcs12", "-in", normalized, "-passin", "env:OMARCHY_FIXTURE_PASSWORD", "-nokeys", env=values)
                self.assertIn(certificate.read_bytes().strip(), public)
                with patch.dict(os.environ, {"MACOS_CERTIFICATE_PASSWORD": "wrong-synthetic-password"}), self.assertRaisesRegex(RuntimeError, "could not be decrypted"):
                    signed_prerelease.compatible_certificate(archive, folder)
                self.assertFalse((folder/"identity.pem").exists())
