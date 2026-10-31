#!/usr/bin/env python3
"""Real OpenSSH integration with disposable containers and synthetic keys only."""
import argparse
import datetime
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import uuid

from upstream_source import ROOT, prepare


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def capture(*args):
    return subprocess.check_output([str(a) for a in args], text=True).strip()


def key(path):
    run("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "managed-ssh-fixture", "-f", path)
    path.chmod(0o600); Path(str(path) + ".pub").chmod(0o600)
    return " ".join(Path(str(path) + ".pub").read_text().split()[:2])


def private(path, value):
    with open(path, "x", opener=lambda p, f: os.open(p, f, 0o600)) as stream:
        stream.write(value)


def port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path)
    parser.add_argument("--base-image", default="ubuntu:24.04")
    parser.add_argument("--swift-probe", action="store_true")
    args = parser.parse_args()
    source = args.source or prepare()
    library = source / "guest/package/try-omarchy/files/usr/lib/try-omarchy"
    assert (library / "managed-ssh").is_file()
    image = "omarchy-managed-ssh-integration:" + ("arch" if args.base_image != "ubuntu:24.04" else "ubuntu")
    run("docker", "build", "--build-arg", "BASE_IMAGE=" + args.base_image, "-t", image,
        "-f", ROOT / "Tests/SSHDIntegration/Containerfile", ROOT / "Tests/SSHDIntegration")
    units = library.parent / "systemd/system"
    run("docker", "run", "--rm", "--entrypoint", "/usr/bin/systemd-analyze",
        "-v", f"{units}:/test-units:ro", "-v", f"{library}:/usr/lib/try-omarchy:ro", image,
        "verify", "--man=no", *["/test-units/" + name for name in (
            "try-omarchy-managed-ssh.timer", "try-omarchy-managed-ssh.service", "try-omarchy-host-config.service",
            "try-omarchy-package-install.service", "try-omarchy-ssh-access.service")])
    print("PASS: systemd timer/service boot graph", flush=True)
    names = []
    with tempfile.TemporaryDirectory(prefix="omarchy ssh integration ") as directory:
        work = Path(directory); work.chmod(0o700)
        systemctl = work / "systemctl"
        private(systemctl, '''#!/bin/sh
set -eu
case "$1" in
 daemon-reload) exit 0 ;;
 restart) if [ -f /run/sshd.pid ]; then kill "$(cat /run/sshd.pid)" 2>/dev/null || true; fi ;;
 start) if [ -f /run/sshd.pid ] && kill -0 "$(cat /run/sshd.pid)" 2>/dev/null; then exit 0; fi ;;
 *) exit 1 ;;
esac
/usr/bin/sshd -f /run/try-omarchy/managed-ssh/sshd_config -E /run/managed-sshd.log
'''); systemctl.chmod(0o700)
        fixtures = []
        try:
            for label in ("a", "b"):
                identity = str(uuid.uuid4()).upper(); token = str(uuid.uuid4()).upper()
                root = work / identity; root.mkdir(mode=0o700)
                credentials = root / ".manager-ssh"; credentials.mkdir(mode=0o700)
                bootstrap = credentials / "bootstrap"; bootstrap.mkdir(mode=0o700)
                (root / "shell").mkdir(mode=0o700)
                client = key(credentials / "client")
                host = key(bootstrap / "host_ed25519")
                personal = key(credentials / "personal")
                manifest = {"schemaVersion": 1, "vmID": identity, "sessionToken": token, "publicKeys": [client, personal]}
                private(bootstrap / "manifest.json", json.dumps(manifest))
                private(credentials / "known_hosts", "omarchy-" + identity.lower() + " " + host + "\n")
                name = "omarchy-ssh-test-" + label + "-" + uuid.uuid4().hex[:10]
                host_port = port(); names.append(name)
                command = '''set -eu
mkdir -p /run/sshd /run/try-omarchy /var/lib/omarchy/provisioning
printf 'tryomarchy.ssh_access=1 tryomarchy.managed_ssh=1\\n' > /run/try-omarchy/cmdline
touch /var/lib/omarchy/provisioning/pending
TRY_OMARCHY_MANAGED_SHARE=/bootstrap TRY_OMARCHY_SYSTEMCTL=/test-systemctl /usr/lib/try-omarchy/managed-ssh
python3 -c 'import json; assert json.load(open("/run/try-omarchy/managed-ssh/status.json"))["state"] == "waiting-owner"'
rm /var/lib/omarchy/provisioning/pending
TRY_OMARCHY_MANAGED_SHARE=/bootstrap TRY_OMARCHY_SYSTEMCTL=/test-systemctl /usr/lib/try-omarchy/managed-ssh
touch /run/ssh-test-ready
exec sleep infinity'''
                run("docker", "run", "-d", "--rm", "--name", name, "-p", f"127.0.0.1:{host_port}:22",
                    "-v", f"{bootstrap}:/bootstrap:ro", "-v", f"{library}:/usr/lib/try-omarchy:ro",
                    "-v", f"{systemctl}:/test-systemctl:ro", image, "-c", command, stdout=subprocess.DEVNULL)
                for _ in range(100):
                    done = subprocess.run(["docker", "exec", name, "test", "-f", "/run/ssh-test-ready"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    if done.returncode == 0: break
                    if capture("docker", "inspect", "-f", "{{.State.Running}}", name) != "true":
                        raise RuntimeError("Synthetic SSH container exited during provisioning")
                    time.sleep(.2)
                else: raise RuntimeError("Synthetic SSH container did not become ready")
                bindings = json.loads(capture("docker", "inspect", "-f", "{{json .HostConfig.PortBindings}}", name))
                assert bindings["22/tcp"][0]["HostIp"] == "127.0.0.1"
                guest = json.loads(capture("docker", "exec", name, "cat", "/run/try-omarchy/managed-ssh/status.json"))
                private(root / "shell/guest-status.json", json.dumps({"receivedAt": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"), "report": {"protocol": 1, "managedSSH": guest}}))
                fixture = {"id": identity, "sessionID": token, "root": str(root), "port": host_port, "container": name}
                fixtures.append(fixture)
                def ssh(identity_path):
                    return ["ssh", "-F", "/dev/null", "-T", "-p", str(host_port), "-i", str(identity_path),
                        "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none", "-o", "BatchMode=yes", "-o", "ForwardAgent=no",
                        "-o", "StrictHostKeyChecking=yes", "-o", "HostKeyAlgorithms=ssh-ed25519",
                        "-o", "HostKeyAlias=omarchy-" + identity.lower(), "-o", 'UserKnownHostsFile="' + str(credentials / "known_hosts") + '"',
                        "-o", "GlobalKnownHostsFile=/dev/null", "-o", "ConnectTimeout=3", "owner@127.0.0.1", "/usr/lib/try-omarchy/managed-ssh-identity"]
                for private_key in (credentials / "client", credentials / "personal"):
                    result = run(*ssh(private_key), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                    report = json.loads(result.stdout)
                    assert report["vmID"] == identity and report["sessionToken"] == token and report["user"] == "owner" and report["uid"] == 1000
                if label == "b":
                    wrong = subprocess.run(ssh(Path(fixtures[0]["root"]) / ".manager-ssh/client"), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                    assert wrong.returncode != 0, "Another VM's managed credential authenticated unexpectedly"
                fixture["sshArguments"] = ssh(credentials / "client")
                print("PASS: " + label + " owner provisioning, managed/personal key login and loopback-only endpoint", flush=True)
            if args.swift_probe:
                manifest_path = work / "fixtures.json"
                private(manifest_path, json.dumps(fixtures))
                env = dict(os.environ, OMARCHY_SSH_FIXTURE_MANIFEST=str(manifest_path))
                run("make", "test", cwd=ROOT, env=env)
            first = fixtures[0]
            run("docker", "exec", first["container"], "sh", "-c",
                "ssh-keygen -q -t ed25519 -N '' -C changed-fixture -f /run/changed-host; kill $(cat /run/sshd.pid); sed 's@^HostKey .*@HostKey /run/changed-host@' /run/try-omarchy/managed-ssh/sshd_config > /run/changed-sshd-config; /usr/bin/sshd -f /run/changed-sshd-config")
            changed = subprocess.run(first["sshArguments"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            assert changed.returncode != 0, "Changed guest host key was accepted"
            print("PASS: cross-VM credentials rejected; changed host identity rejected", flush=True)
        finally:
            for name in names:
                subprocess.run(["docker", "rm", "-f", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == "__main__": main()
