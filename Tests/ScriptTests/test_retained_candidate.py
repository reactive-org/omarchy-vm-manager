import copy
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Scripts"))
import retained_candidate
import signed_prerelease


class RetainedCandidateTests(unittest.TestCase):
    def setUp(self):
        self.receipt = dict(sourceRun=123, sourceCommit="a"*40, releaseTag="v0.9.4-dev.1",
                            artifactID=456, artifactSHA256="b"*64, runtimeArchiveSHA256="c"*64,
                            appleSubmissionID="12345678-1234-1234-1234-123456789abc",
                            appleCreatedDate="2026-11-01T10:19:22.100Z")
        self.run = dict(id=123, run_attempt=1, head_sha="a"*40, head_branch="v0.9.4-dev.1",
                        event="push", path=".github/workflows/test.yml", conclusion="failure")
        self.artifact = dict(id=456, expired=False, name="notarization-diagnostics-v0.9.4-dev.1",
                             digest="sha256:"+"b"*64,
                             workflow_run=dict(id=123, head_sha="a"*40, head_branch="v0.9.4-dev.1"))
        self.jobs = [dict(name=name, conclusion="success") for name in ("macOS build and tests", "managed-ssh")]

    def test_origin_rejects_changed_source_tag_artifact_or_failed_tests(self):
        retained_candidate.validate_origin(self.receipt, self.run, self.artifact, self.jobs)
        for field, value in (("head_sha", "d"*40), ("head_branch", "main"), ("run_attempt", 2),
                             ("event", "pull_request"), ("path", "untrusted.yml")):
            with self.subTest(field=field), self.assertRaises(AssertionError):
                retained_candidate.validate_origin(self.receipt, dict(self.run, **{field:value}), self.artifact, self.jobs)
        for field, value in (("id", 789), ("expired", True), ("digest", "sha256:"+"d"*64),
                             ("workflow_run", dict(self.artifact["workflow_run"], id=789))):
            with self.subTest(field=field), self.assertRaises(AssertionError):
                retained_candidate.validate_origin(self.receipt, self.run, dict(self.artifact, **{field:value}), self.jobs)
        for name in ("macOS build and tests", "managed-ssh"):
            jobs = [dict(job, conclusion="failure") if job["name"] == name else job for job in self.jobs]
            with self.assertRaises(AssertionError):
                retained_candidate.validate_origin(self.receipt, self.run, self.artifact, jobs)

    def test_candidate_extraction_requires_both_digests_and_exact_submission(self):
        for problem in (None, "artifact", "runtime", "submission", "extra", "duplicate"):
            with self.subTest(problem=problem), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                archive = root / "artifact.zip"
                receipt = dict(self.receipt, runtimeArchiveSHA256=hashlib.sha256(b"runtime").hexdigest())
                status = dict(id=receipt["appleSubmissionID"], createdDate=receipt["appleCreatedDate"], status="In Progress")
                if problem == "submission":
                    status["id"] = "wrong"
                with zipfile.ZipFile(archive, "w") as zipped:
                    zipped.writestr("signed-release/kit/TryOmarchyKit.zip", b"runtime")
                    zipped.writestr("signed-release/kit/TryOmarchyKit.json", "{}")
                    zipped.writestr("notarization/runtime-submission.json", json.dumps(status))
                    if problem == "extra":
                        zipped.writestr("../injected", "unsafe")
                    if problem == "duplicate":
                        import warnings
                        with warnings.catch_warnings():
                            warnings.simplefilter("ignore")
                            zipped.writestr("signed-release/kit/TryOmarchyKit.zip", b"runtime")
                receipt["artifactSHA256"] = retained_candidate.sha256(archive)
                if problem == "artifact": receipt["artifactSHA256"] = "f"*64
                if problem == "runtime": receipt["runtimeArchiveSHA256"] = "f"*64
                if problem is None:
                    retained_candidate.extract_candidate(receipt, archive, root/"result")
                    self.assertEqual((root/"result/TryOmarchyKit.zip").read_bytes(), b"runtime")
                else:
                    with self.assertRaises(AssertionError):
                        retained_candidate.extract_candidate(receipt, archive, root/"result")

    def test_source_binding_rejects_current_main_or_changed_lock_and_kit(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root/"Config").mkdir()
            data = json.dumps(dict(kitSHA256="e"*64)).encode()
            (root/"Config/TryOmarchyRuntime.lock.json").write_bytes(data)
            receipt = dict(self.receipt, sourceLockSHA256=hashlib.sha256(data).hexdigest(), sourceKitSHA256="e"*64)
            with patch.dict(os.environ, RELEASE_TAG=receipt["releaseTag"]), patch.object(retained_candidate.subprocess, "check_output", return_value="a"*40):
                retained_candidate.validate_source(receipt, root)
                for key, value in (("sourceCommit", "f"*40), ("sourceLockSHA256", "f"*64), ("sourceKitSHA256", "f"*64), ("releaseTag", "v0.9.3-dev.6")):
                    with self.subTest(key=key), self.assertRaises(AssertionError):
                        retained_candidate.validate_source(dict(receipt, **{key:value}), root)

    def test_accepted_log_requires_exact_archive_and_submission_and_tickets(self):
        value = dict(jobId=self.receipt["appleSubmissionID"], status="Accepted", statusCode=0,
                     sha256="c"*64, ticketContents=[dict(path="runtime")], issues=None)
        signed_prerelease.validate_accepted_log(value, self.receipt["appleSubmissionID"], "c"*64)
        for key, changed in (("jobId", "different"), ("status", "In Progress"), ("statusCode", 4000),
                             ("sha256", "f"*64), ("ticketContents", []), ("issues", [dict(message="rejected")])):
            with self.subTest(key=key), self.assertRaises(AssertionError):
                signed_prerelease.validate_accepted_log(dict(value, **{key:changed}), self.receipt["appleSubmissionID"], "c"*64)

    def test_fresh_accepted_log_is_checked_without_signing_or_resubmission(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            archive = root/"runtime.zip"; archive.write_bytes(b"runtime")
            identifier = self.receipt["appleSubmissionID"]
            def command(label, *arguments):
                self.assertEqual(arguments[:2], ("xcrun", "notarytool"))
                self.assertIn(arguments[2], ("info", "log"))
                if arguments[2] == "log":
                    Path(arguments[-1]).write_text(json.dumps(dict(jobId=identifier, status="Accepted", statusCode=0,
                        sha256=retained_candidate.sha256(archive), ticketContents=[dict(path="runtime")], issues=None)))
                return SimpleNamespace(stdout=json.dumps(dict(id=identifier, status="Accepted")))
            with patch.object(signed_prerelease, "ROOT", root), patch.object(signed_prerelease, "run", side_effect=command) as commands:
                result = signed_prerelease.accepted_submission(archive, [], "runtime", identifier)
                self.assertEqual(result["status"], "Accepted")
                self.assertEqual(commands.call_count, 2)

    def test_complete_build_layout_binds_every_member_to_source_and_acceptance(self):
        for problem in (None, 'extra', 'member', 'source', 'acceptance', 'candidate'):
            with self.subTest(problem=problem), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                receipt = dict(self.receipt, artifactLayout='complete-build-v1',
                               runtimeArchiveSHA256=hashlib.sha256(b'runtime').hexdigest(),
                               sourceLockSHA256=hashlib.sha256(b'source-lock').hexdigest())
                status = dict(id=receipt['appleSubmissionID'], createdDate=receipt['appleCreatedDate'], status='Accepted')
                candidate = dict(submissionID=receipt['appleSubmissionID'], archiveSHA256=receipt['runtimeArchiveSHA256'], releaseTag=receipt['releaseTag'])
                origin = dict(applicationSourceCommit=receipt['sourceCommit'], workflowRunID=str(receipt['sourceRun']), releaseTag=receipt['releaseTag'])
                accepted = dict(jobId=receipt['appleSubmissionID'], status='Accepted', statusCode=0,
                                sha256=receipt['runtimeArchiveSHA256'], ticketContents=[dict(path='runtime')], issues=None)
                if problem == 'source': origin['applicationSourceCommit'] = 'f' * 40
                if problem == 'acceptance': accepted['status'] = 'In Progress'
                if problem == 'candidate': candidate['submissionID'] = 'wrong'
                members = {
                    '.build/signed-release/kit/TryOmarchyKit.zip': b'runtime',
                    '.build/signed-release/kit/TryOmarchyKit.json': b'{}',
                    '.build/signed-release/notary-runtime.zip': b'runtime',
                    '.build/signed-release/SourceRuntime.lock.json': b'source-lock',
                    '.build/signed-release/ReleaseSource.json': json.dumps(origin).encode(),
                    '.build/notarization/runtime-submission.json': json.dumps(status).encode(),
                    '.build/notarization/runtime-candidate.json': json.dumps(candidate).encode(),
                    '.build/notarization/runtime-log.json': json.dumps(accepted).encode(),
                }
                receipt['artifactMemberSHA256'] = {name: hashlib.sha256(data).hexdigest() for name, data in members.items()}
                if problem == 'extra': members['../injected'] = b'unsafe'
                if problem == 'member': receipt['artifactMemberSHA256']['.build/signed-release/kit/TryOmarchyKit.zip'] = 'f' * 64
                archive = root / 'artifact.zip'
                with zipfile.ZipFile(archive, 'w') as zipped:
                    for name, data in members.items(): zipped.writestr(name, data)
                receipt['artifactSHA256'] = retained_candidate.sha256(archive)
                if problem is None:
                    retained_candidate.extract_candidate(receipt, archive, root / 'result')
                    self.assertEqual((root / 'result/SubmittedRuntime.zip').read_bytes(), b'runtime')
                    self.assertEqual(json.loads((root / 'result/RuntimeNotarizationLog.json').read_bytes())['status'], 'Accepted')
                else:
                    with self.assertRaises(AssertionError):
                        retained_candidate.extract_candidate(receipt, archive, root / 'result')
