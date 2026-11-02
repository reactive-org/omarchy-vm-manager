#!/usr/bin/env python3
"""Relocated read-only package checks. Runs only the offline helper on fixtures."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

import provisioning_package as package


def run_checks(binaries, launcher_binaries):
    with tempfile.TemporaryDirectory(prefix="provisioning-package-") as temp:
        root = Path(temp).resolve()
        app = root / "Stage.app"
        contents = app / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        (contents / "Resources").mkdir()
        (contents / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "fixture.provisioning", "CFBundleExecutable": "OmarchyVMManager", "CFBundlePackageType": "APPL"}))
        package.stage(binaries, launcher_binaries, contents)
        # Seal a fixture container using the built manager as its main code;
        # it is never executed or opened. Only the offline helper runs below.
        shutil.copy2(binaries / "OmarchyVMManager", contents / "MacOS/OmarchyVMManager")
        for name in package.EXECUTABLES:
            subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(contents / "MacOS" / name)], check=True, capture_output=True)
        package.seal(contents)
        package.verify(contents)
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True)
        relocated = root / "read only ' relocated.app"
        app.rename(relocated); contents = relocated / "Contents"
        for path in relocated.rglob("*"):
            path.chmod(0o555 if path.is_dir() or path.parent.name == "MacOS" else 0o444)
        relocated.chmod(0o555)
        source = root / "source"; source.mkdir()
        (source / "vm.yml").write_text("schema_version: 1\nid: fixture\nsetup: {features: {enable: [cli]}}\nvars: {opaque: fixture-value-never-serialized}\n")
        home = root / "home"; home.mkdir()
        scratch = root / "scratch"; scratch.mkdir()
        helper = contents / "MacOS/OmarchyVMProvisioningHelper"
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(relocated)], check=True, capture_output=True)
        environment = {"PATH": "/nonexistent", "HOME": str(home), "TMPDIR": str(scratch), "LC_ALL": "C"}

        def invoke(*arguments, ok=True, extra=None):
            result = subprocess.run([str(helper), *map(str, arguments)], cwd=root, env={**environment, **(extra or {})},
                                    capture_output=True, timeout=10, check=False)
            package.require(result.returncode == (0 if ok else 1), "Unexpected offline helper exit")
            package.require(not result.stderr and len(result.stdout) <= 128*1024, "Unexpected helper diagnostic/output")
            return json.loads(result.stdout)

        try:
            status = invoke("--verify-package-json")
            package.require(status["sourceRevision"] == "bb3fae22be45b38035fac52aefa0eb270a9d0fea" and status["executionEnabled"] is False)
            validated = invoke("--validate-manifest-json", source / "vm.yml")
            package.require(validated["structure_valid"] is True and validated["execution_available"] is False)
            plan = invoke("--plan-json", source)
            package.require(plan["execution_available"] is False and plan["features"]["features"] == ["cli"])
            package.require("fixture-value-never-serialized" not in json.dumps(plan))
            for command in ("--apply", "--check", "--recover", "--exec", "--trash"):
                package.require(invoke(command, ok=False)["code"] == "provisioning-execution-disabled")
            package.require(invoke("--verify-package-json", ok=False, extra={"PACKAGE_RESOURCE_BUNDLE_PATH": str(binaries)})["code"] == "provisioning-package-invalid")
            (source / "vm.yml").write_text("schema_version: 1\nid: fixture\nid: duplicate\n")
            package.require(invoke("--validate-manifest-json", source / "vm.yml", ok=False)["ok"] is False)
            package.require(not list(home.iterdir()) and not list(scratch.iterdir()), "Helper created host state")
            resource = package.resource_directory(contents / "Resources" / package.BUNDLE)
            target = resource / "catalogue.json"; original = target.read_bytes()
            target.chmod(0o644); target.write_bytes(b"{}")
            package.require(invoke("--verify-package-json", ok=False)["code"] == "provisioning-package-invalid")
            package.require(subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(relocated)], capture_output=True).returncode != 0)
            target.write_bytes(original); target.chmod(0o444)
            executable = contents / "MacOS/dev-vm-process-host"; executable.chmod(0o755)
            with executable.open("ab") as stream: stream.write(b"tamper")
            package.require(invoke("--verify-package-json", ok=False)["code"] == "provisioning-package-invalid")
        finally:
            relocated.chmod(0o755)
            for path in relocated.rglob("*"):
                if path.is_dir(): path.chmod(0o755)
                else: path.chmod(0o644)
    print("provisioning-package: PASS; relocated/read-only offline helper, exact resources, disabled execution, no host state")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--binaries", required=True, type=Path)
    parser.add_argument("--launcher-binaries", required=True, type=Path)
    args = parser.parse_args()
    run_checks(args.binaries, args.launcher_binaries)
