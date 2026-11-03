import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Scripts"))
import provisioning_package as package
import provisioning_preflight as preflight


class ProvisioningPreflightTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="provisioning-preflight-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.binaries, self.launcher = self.root / "binaries", self.root / "launcher"
        self.raw, self.lock = package.read_lock()
        for folder in ("Config", "Sources/OmarchyVMManagerCore/Resources", "binaries", "launcher"):
            (self.root / folder).mkdir(parents=True, exist_ok=True)
        (self.root / package.LOCK).write_bytes(self.raw)
        (self.root / "Sources/OmarchyVMManagerCore/ProvisioningPackagePin.swift").write_text(package.pin_source(self.raw, self.lock))
        (self.root / "Config/TryOmarchyRuntime.lock.json").write_text('{"fixture": true}\n')
        (self.root / "Sources/OmarchyVMManagerCore/Resources/ReviewedFactories.json").write_text('[]\n')
        shutil.copytree(package.ROOT / self.lock["package"] / "Sources/DevVMProvisioningCore/Resources",
                        self.binaries / package.BUNDLE / "Resources")
        for folder, names in ((self.binaries, ("OmarchyVMManager", "omarchy-vm", "OmarchyVMStorageHelper", "OmarchyVMProvisioningHelper")),
                              (self.launcher, ("dev-vm-process-host",))):
            for name in names:
                path = folder / name
                path.write_text("#!/bin/sh\necho DO_NOT_EXECUTE_CANDIDATE\nexit 99\n")
                path.chmod(0o700)

    def collect(self, app=None, dirty=False):
        with patch.object(package, "verify_source", return_value=(self.raw, self.lock)), \
             patch.object(preflight, "repository", return_value={"head": "a" * 40, "dirty": dirty, "binarySourceBinding": "NOT_PROVEN"}), \
             patch.object(subprocess, "run", side_effect=AssertionError("No process may run in artifact tests")):
            return preflight.collect(self.root, self.binaries, self.launcher, app)

    def test_complete_offline_evidence_never_authorizes_execution(self):
        before = package.files(self.root)
        report = self.collect()
        self.assertEqual(report["offlineStatus"], "PASS")
        self.assertFalse(report["executionAuthorized"])
        self.assertEqual(report["guestAcceptance"], "NOT_RUN")
        self.assertEqual(report["evidence"]["pinnedSource"]["engineSHA256"], self.lock["engineSHA256"])
        self.assertIn("sha256", report["evidence"]["OmarchyVMManager"])
        self.assertTrue({"assembledApp", "disposableScope", "operationalCandidate", "signingAndLoadedCode", "factoryAndTools", "guestRun"}
                        <= {row["id"] for row in report["remaining"]})
        self.assertEqual(package.files(self.root), before)
        self.assertNotIn(str(self.root), json.dumps(report))

    def test_missing_artifacts_and_uncommitted_source_remain_review_blockers(self):
        (self.binaries / "OmarchyVMProvisioningHelper").unlink()
        report = self.collect(dirty=True)
        self.assertEqual(report["offlineStatus"], "BLOCKED")
        blocked = [row["id"] for row in report["checks"] if row["status"] == "BLOCKED"]
        self.assertEqual(blocked, ["OmarchyVMProvisioningHelper"])
        self.assertIn("sourceCommit", [row["id"] for row in report["remaining"]])
        self.assertFalse(report["executionAuthorized"])

    def test_changed_resources_and_stale_compiled_pin_are_reported_independently(self):
        (self.binaries / package.BUNDLE / "Resources/engine-identity.json").write_text('{}\n')
        (self.root / "Sources/OmarchyVMManagerCore/ProvisioningPackagePin.swift").write_text("stale fixture")
        report = self.collect()
        self.assertEqual({row["id"] for row in report["checks"] if row["status"] == "BLOCKED"},
                         {"pinnedSource", "builtProvisioningResources"})
        self.assertNotIn("pinnedSource", report["evidence"])

    def test_symlink_and_special_binary_files_refused_without_blocking(self):
        helper = self.binaries / "OmarchyVMProvisioningHelper"
        helper.unlink()
        helper.symlink_to(self.binaries / "OmarchyVMManager")
        self.assertEqual(self.collect()["offlineStatus"], "BLOCKED")
        helper.unlink()
        os.mkfifo(helper)
        self.assertEqual(self.collect()["offlineStatus"], "BLOCKED")

    def test_bounded_fingerprints_refuse_files_changed_during_read(self):
        path = self.binaries / "OmarchyVMManager"
        with self.assertRaises(ValueError):
            preflight.fingerprint(path, maximum=2)
        read = os.read
        def changed(fd, size):
            block = read(fd, size)
            if block:
                path.write_bytes(b"replacement bytes")
            return block
        with patch.object(os, "read", side_effect=changed), self.assertRaises(ValueError):
            preflight.fingerprint(path)

    def make_app(self):
        app = self.root / "candidate.app"
        contents = app / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        (contents / "Resources").mkdir()
        for folder, names in ((self.binaries, ("OmarchyVMManager", "omarchy-vm", "OmarchyVMStorageHelper", "OmarchyVMProvisioningHelper")),
                              (self.launcher, ("dev-vm-process-host",))):
            for name in names:
                shutil.copy2(folder / name, contents / "MacOS" / name)
        shutil.copytree(self.binaries / package.BUNDLE, contents / "Resources" / package.BUNDLE)
        for name in ("DevVMProvisioning.lock.json", "TryOmarchyRuntime.lock.json"):
            shutil.copy2(self.root / "Config" / name, contents / "Resources" / name)
        package.seal(contents, self.root)
        return app

    def test_optional_app_records_signed_byte_differences_without_claiming_source_binding(self):
        app = self.make_app()
        helper = app / "Contents/MacOS/OmarchyVMProvisioningHelper"
        helper.write_bytes(helper.read_bytes() + b"synthetic signed bytes\n")
        package.seal(app / "Contents", self.root)
        report = self.collect(app)
        self.assertEqual(report["offlineStatus"], "PASS")
        self.assertFalse(report["evidence"]["assembledProvisioningInventory"][helper.name]["matchesSuppliedBuild"])
        self.assertFalse(report["executionAuthorized"])
        self.assertNotIn("assembledApp", [row["id"] for row in report["remaining"]])
        self.assertIn("signingAndLoadedCode", [row["id"] for row in report["remaining"]])

    def test_optional_app_changed_seal_or_runtime_lock_blocks_offline_check(self):
        app = self.make_app()
        helper = app / "Contents/MacOS/OmarchyVMProvisioningHelper"
        helper.write_bytes(b"changed sealed bytes")
        self.assertEqual(self.collect(app)["offlineStatus"], "BLOCKED")
        package.seal(app / "Contents", self.root)
        (app / "Contents/Resources/TryOmarchyRuntime.lock.json").write_text("changed fixture")
        self.assertEqual(self.collect(app)["offlineStatus"], "BLOCKED")

    def test_repository_observation_is_bounded_read_only_and_disables_fsmonitor(self):
        replies = [subprocess.CompletedProcess([], 0, ("b" * 40 + "\n").encode(), b""),
                   subprocess.CompletedProcess([], 0, b"?? fixture\0", b"")]
        with patch.object(subprocess, "run", side_effect=replies) as run:
            info = preflight.repository(self.root)
        self.assertTrue(info["dirty"])
        self.assertEqual(info["binarySourceBinding"], "NOT_PROVEN")
        self.assertEqual(run.call_count, 2)
        for call in run.call_args_list:
            self.assertEqual(call.args[0][0], "/usr/bin/git")
            self.assertIn("core.fsmonitor=false", call.args[0])
            self.assertIn("--no-optional-locks", call.args[0])
            self.assertEqual(call.kwargs["timeout"], 10)


if __name__ == "__main__":
    unittest.main()
