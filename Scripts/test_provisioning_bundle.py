#!/usr/bin/env python3
"""Relocated read-only package checks. Runs only the offline helper on fixtures."""
import argparse
import base64
import hashlib
import hmac
import json
import os
from pathlib import Path
import plistlib
import shutil
import socket
import struct
import subprocess
import tempfile
import uuid

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

        def ownership_fixture(scenario):
            # Actual packaged helper, anonymous inherited socket and bootstrap
            # pipe only. Its registry is empty; it cannot claim a worker or run.
            encode = lambda value: json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
            identifier = lambda: str(uuid.uuid4()).upper()
            secret = os.urandom(32)
            identity = {"instanceID": identifier(), "executableSHA256": package.sha(helper.read_bytes()),
                        "packageLockSHA256": package.sha((contents / "Resources/DevVMProvisioning.lock.json").read_bytes())}
            channel = identifier()
            bootstrap = {"version": 1, "identity": identity, "channelID": channel,
                         "secret": base64.b64encode(secret).decode()}
            if scenario == "bootstrap": bootstrap["identity"] = {**identity, "executableSHA256": "a" * 64}
            parent, child = socket.socketpair()
            parent.settimeout(3)
            process = subprocess.Popen([str(helper), "--ownership-channel-fd", str(child.fileno())],
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       pass_fds=(child.fileno(),), env=environment, cwd=root)
            child.close()
            try:
                data = encode(bootstrap)
                process.stdin.write(struct.pack(">I", len(data)) + data)
                process.stdin.close()
                if scenario != "bootstrap":
                    scope = {name: identifier() for name in ("challenge", "jobID", "vmID", "sessionID", "payloadID", "workerToken")}
                    scope.update({name: "b" * 64 for name in ("engineDigest", "dependencyDigest", "bindingDigest", "reviewDigest", "checkpointDigest")})
                    request = {"requestID": identifier(), "expectation": scope}
                    signed = {"version": 1, "identity": identity, "channelID": channel, "role": "manager", "sequence": 1,
                              "payload": base64.b64encode(encode(request)).decode()}
                    mac = hmac.digest(secret, encode(signed), hashlib.sha256)
                    if scenario == "mac": mac = bytes(32)
                    frame = encode({"signed": signed, "mac": base64.b64encode(mac).decode()})
                    parent.sendall(struct.pack(">I", len(frame)) + frame)
                    if scenario == "valid":
                        def exact(count):
                            result = b""
                            while len(result) < count:
                                chunk = parent.recv(count - len(result))
                                package.require(bool(chunk), "Incomplete ownership fixture frame")
                                result += chunk
                            return result
                        length = struct.unpack(">I", exact(4))[0]
                        package.require(0 < length <= 24 * 1024)
                        response = json.loads(exact(length)); authenticated = response["signed"]
                        package.require(hmac.compare_digest(base64.b64decode(response["mac"]), hmac.digest(secret, encode(authenticated), hashlib.sha256)))
                        package.require(authenticated["role"] == "helper" and authenticated["sequence"] == 1
                                        and authenticated["identity"] == identity and authenticated["channelID"] == channel)
                        payload = json.loads(base64.b64decode(authenticated["payload"]))
                        package.require(payload == {**request, "priorWorker": "unknown"}, "Empty helper invented ownership")
                        # Replay a correctly signed request: no second proof.
                        parent.sendall(struct.pack(">I", len(frame)) + frame)
                process.wait(timeout=5)
                stdout, stderr = process.stdout.read(), process.stderr.read()
                package.require(process.returncode == (1 if scenario == "bootstrap" else 0))
                package.require(not stderr and (not stdout if scenario != "bootstrap" else json.loads(stdout)["ok"] is False))
                package.require(base64.b64encode(secret) not in stdout + stderr, "Bootstrap secret leaked")
            finally:
                parent.close()
                if process.poll() is None: process.kill(); process.wait(timeout=5)
                process.stdout.close(); process.stderr.close()

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
            for scenario in ("valid", "mac", "bootstrap"): ownership_fixture(scenario)
            # The Swift fixture uses the real admitted-launch factory. It is a
            # debug-only build product, never staged into the application.
            for scenario in ("policy", "tamper", "replace", "normal", "dispatch-denied"):
                control_root = root / str(uuid.uuid4()); control_root.mkdir(mode=0o700)
                result = subprocess.run([str(binaries / "OmarchyProvisioningLaunchFixture"), str(contents), str(control_root), scenario],
                                        env=environment, cwd=root, capture_output=True, timeout=20)
                if result.returncode != 0:
                    diagnostic = json.loads(result.stdout)
                    # Fixture emits only fixed typed codes/stages, never errors or bootstrap bytes.
                    print("admitted-helper-fixture:", scenario, diagnostic.get("code"), diagnostic.get("step"))
                package.require(result.returncode == 0 and not result.stderr, "Admitted helper launch fixture failed: " + scenario)
                value = json.loads(result.stdout)
                package.require(value.get("policyRejected") or value.get("changedSourceRejected") or
                                (value.get("registered") and value.get("reconciled") and value.get("exited") and value.get("executionEnabled") is False))
            # Separate, explicitly re-signed fixture app: replace only its helper
            # with the excluded debug fixture binary, which hosts a fake engine
            # factory. The actual product helper above has no execution backend.
            engine_app = root / "EngineFixture.app"
            shutil.copytree(relocated, engine_app)
            for path in [engine_app, *engine_app.rglob("*")]:
                path.chmod(0o755 if path.is_dir() or path.parent.name == "MacOS" else 0o644)
            engine_contents = engine_app / "Contents"
            fake_helper = engine_contents / "MacOS/OmarchyVMProvisioningHelper"
            shutil.copy2(binaries / "OmarchyProvisioningLaunchFixture", fake_helper)
            subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(fake_helper)], check=True, capture_output=True)
            package.seal(engine_contents)
            subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(engine_app)], check=True, capture_output=True)
            for path in [engine_app, *engine_app.rglob("*")]:
                path.chmod(0o555 if path.is_dir() or path.parent.name == "MacOS" else 0o444)
            try:
                for scenario in ("dispatch", "dispatch-cancel"):
                    control_root = root / str(uuid.uuid4()); control_root.mkdir(mode=0o700)
                    result = subprocess.run([str(binaries / "OmarchyProvisioningLaunchFixture"), str(engine_contents), str(control_root), scenario],
                                            env=environment, cwd=root, capture_output=True, timeout=20)
                    if result.returncode != 0:
                        diagnostic = json.loads(result.stdout)
                        print("engine-helper-fixture:", scenario, diagnostic.get("code"), diagnostic.get("step"))
                    package.require(result.returncode == 0 and not result.stderr, "Helper-side fixture dispatch failed")
                    package.require(json.loads(result.stdout)["exited"] is True)
            finally:
                for path in [engine_app, *engine_app.rglob("*")]:
                    path.chmod(0o755 if path.is_dir() else 0o644)
            package.require(invoke("--ownership-channel-fd", "0", ok=False)["ok"] is False)
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
    print("provisioning-package: PASS; relocated/read-only helper, authenticated inherited ownership IPC, exact resources, disabled execution, no host state")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--binaries", required=True, type=Path)
    parser.add_argument("--launcher-binaries", required=True, type=Path)
    args = parser.parse_args()
    run_checks(args.binaries, args.launcher_binaries)
