#!/usr/bin/env python3
"""Acquire a reviewed retained CI candidate; never signs or submits an archive."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import subprocess
import sys
import zipfile

if sys.flags.optimize:
    raise RuntimeError("Optimized execution is refused; candidate validation assertions are required")

REPOSITORY = "reactive-org/omarchy-vm-manager"


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate_source(receipt, root):
    actual = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
    assert actual == receipt["sourceCommit"], "immutable application source mismatch"
    assert os.environ.get("RELEASE_TAG") == receipt["releaseTag"], "release tag mismatch"
    assert sha256(root / "Config/TryOmarchyRuntime.lock.json") == receipt["sourceLockSHA256"]
    source = json.loads((root / "Config/TryOmarchyRuntime.lock.json").read_bytes())
    assert source["kitSHA256"] == receipt["sourceKitSHA256"], "source kit mismatch"


def validate_origin(receipt, run, artifact, jobs):
    assert run["id"] == receipt["sourceRun"] and run["run_attempt"] == 1
    assert run["head_sha"] == receipt["sourceCommit"] and run["head_branch"] == receipt["releaseTag"]
    assert run["event"] == "push" and run["path"] == ".github/workflows/test.yml"
    assert run["conclusion"] == "failure", "only the retained pending release is supported"
    assert artifact["id"] == receipt["artifactID"] and artifact["expired"] is False
    assert artifact["name"] == "notarization-diagnostics-" + receipt["releaseTag"]
    assert artifact["digest"] == "sha256:" + receipt["artifactSHA256"]
    assert artifact["workflow_run"]["id"] == receipt["sourceRun"]
    assert artifact["workflow_run"]["head_sha"] == receipt["sourceCommit"]
    assert artifact["workflow_run"]["head_branch"] == receipt["releaseTag"]
    results = {job["name"]: job["conclusion"] for job in jobs}
    assert results.get("macOS build and tests") == "success"
    assert results.get("managed-ssh") == "success", "original no-VM test jobs did not pass"


def extract_candidate(receipt, archive, destination):
    assert sha256(archive) == receipt["artifactSHA256"], "original CI artifact digest mismatch"
    selected = {"signed-release/kit/TryOmarchyKit.zip": "TryOmarchyKit.zip",
                "signed-release/kit/TryOmarchyKit.json": "TryOmarchyKit.json",
                "notarization/runtime-submission.json": "RuntimeSubmission.json"}
    with zipfile.ZipFile(archive) as zipped:
        assert sum(item.file_size for item in zipped.infolist()) < 100_000_000
        names = [item.filename for item in zipped.infolist() if not item.is_dir()]
        assert len(names) == len(set(names)) and set(names) == set(selected), "unexpected retained artifact contents"
        destination.mkdir(parents=True, exist_ok=False)
        for name, target in selected.items():
            assert ".." not in PurePosixPath(name).parts
            (destination / target).write_bytes(zipped.read(name))
    assert sha256(destination / "TryOmarchyKit.zip") == receipt["runtimeArchiveSHA256"]
    status = json.loads((destination / "RuntimeSubmission.json").read_bytes())
    assert status["id"] == receipt["appleSubmissionID"]
    assert status["createdDate"] == receipt["appleCreatedDate"]
    (destination / "CandidateReceipt.json").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")


def acquire(receipt_path, root, destination):
    receipt = json.loads(receipt_path.read_bytes())
    validate_source(receipt, root)
    def api(endpoint):
        return json.loads(subprocess.check_output(["gh", "api", "repos/" + REPOSITORY + endpoint]))
    run = api("/actions/runs/" + str(receipt["sourceRun"]))
    artifact = api("/actions/artifacts/" + str(receipt["artifactID"]))
    jobs = api("/actions/runs/" + str(receipt["sourceRun"]) + "/jobs?per_page=100")["jobs"]
    validate_origin(receipt, run, artifact, jobs)
    archive = destination.parent / "original-ci-artifact.zip"
    destination.parent.mkdir(parents=True, exist_ok=True)
    with archive.open("xb") as output:
        subprocess.run(["gh", "api", "repos/" + REPOSITORY + "/actions/artifacts/" +
                        str(receipt["artifactID"]) + "/zip"], stdout=output, check=True)
    extract_candidate(receipt, archive, destination)
    for name, value in (("SourceRun.json", run), ("SourceArtifact.json", artifact), ("SourceJobs.json", jobs)):
        (destination / name).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    (destination / "SourceRuntime.lock.json").write_bytes((root / "Config/TryOmarchyRuntime.lock.json").read_bytes())
    print("Retained runtime: exact original CI artifact, immutable source and passed test jobs verified")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("receipt", type=Path)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    acquire(args.receipt, args.source, args.destination)
