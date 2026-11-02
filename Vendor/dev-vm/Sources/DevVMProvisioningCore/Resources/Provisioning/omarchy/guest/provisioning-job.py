#!/usr/bin/env python3
"""Private protocol-1, non-root Linux job payload/scope controller.

Not a daemon, VM controller or sandbox for trusted task code. All mutable state
is beneath one verified UUID /tmp root; commands run in recorded user scopes.
Uncertain launch registration prevents a false quiescence/removal receipt.
"""
import fcntl
import json
import os
import platform
import re
import shutil
import signal
import stat
import subprocess
import sys
import time
import uuid
from pathlib import Path


def require(condition):
    if not condition:
        raise ValueError("job protocol refused")


def regular(path, maximum=65536):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and info.st_size <= maximum)
        with os.fdopen(os.dup(fd), "rb") as stream:
            data = stream.read(maximum + 1)
        require(len(data) <= maximum)
        return data
    finally:
        os.close(fd)


def private_write(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(os.dup(fd), "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
    finally:
        os.close(fd)


class Job:
    def __init__(self, job, payload):
        self.job, self.payload = str(uuid.UUID(job)), str(uuid.UUID(payload))
        self.root = Path("/tmp/dev-vm-provisioning-" + self.payload)
        require(platform.system() == "Linux" and platform.machine() == "aarch64" and os.getuid() != 0)
        require(Path("/sys/fs/cgroup/cgroup.controllers").is_file())
        info = self.root.lstat()
        require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == 0o700)
        self.marker = {"protocol": 1, "job": self.job, "payload": self.payload, "uid": os.getuid()}
        require(json.loads(regular(self.root / "lease.json")) == self.marker)
        self.prefix = "dev-vm-" + self.payload.replace("-", "") + "-"
        os.environ["XDG_RUNTIME_DIR"] = "/run/user/" + str(os.getuid())
        os.environ["DBUS_SESSION_BUS_ADDRESS"] = "unix:path=" + os.environ["XDG_RUNTIME_DIR"] + "/bus"
        os.environ["TMPDIR"] = str(self.root / "tmp")

    def lock(self):
        fd = os.open(self.root / "gate", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        require(stat.S_ISREG(os.fstat(fd).st_mode) and os.fstat(fd).st_uid == os.getuid())
        fcntl.flock(fd, fcntl.LOCK_EX)
        return os.fdopen(fd, "r+")

    def receipt(self, state):
        print(json.dumps({**self.marker, "state": state}), flush=True)

    def scopes(self):
        path = self.root / "units.json"
        values = json.loads(regular(path, maximum=1024 * 1024)) if path.exists() else []
        require(isinstance(values, list) and len(values) <= 4096 and len(values) == len(set(values)))
        require(all(isinstance(v, str) and re.fullmatch(re.escape(self.prefix) + r"[a-f0-9]{32}\.scope", v) for v in values))
        return values

    def append_scope(self, unit):
        values = self.scopes()
        require(len(values) < 4096)
        values.append(unit)
        temporary = self.root / ("units-" + uuid.uuid4().hex)
        private_write(temporary, json.dumps(values).encode())
        os.replace(temporary, self.root / "units.json")

    def unit_state(self, unit, timeout=3):
        result = subprocess.run(["/usr/bin/systemctl", "--user", "show", unit, "--property=LoadState", "--property=ActiveState", "--property=ControlGroup"],
                                capture_output=True, timeout=timeout, check=False)
        require(len(result.stdout) <= 32768 and result.returncode in (0, 1))
        lines = result.stdout.decode().splitlines()
        values = dict(line.split("=", 1) for line in lines)
        require(set(values) == {"LoadState", "ActiveState", "ControlGroup"})
        return values

    def empty_unit(self, unit, timeout=3):
        state = self.unit_state(unit, timeout)
        require(state["LoadState"] in ("loaded", "not-found") and state["ActiveState"] in ("inactive", "failed"))
        group = state["ControlGroup"]
        if group:
            require(group.startswith("/user.slice/") and ".." not in group.split("/"))
            path = Path("/sys/fs/cgroup" + group) / "cgroup.events"
            if path.parent.exists():
                require(path.is_file())
                require("populated 0" in path.read_text().splitlines())

    def run(self, argv, cleanup=False):
        require(argv)
        interrupted = False

        def stop(_signum, _frame):
            nonlocal interrupted
            interrupted = True

        for sig in (signal.SIGHUP, signal.SIGTERM):
            signal.signal(sig, stop)
        unit = self.prefix + uuid.uuid4().hex + ".scope"
        with self.lock():
            require(cleanup or not (self.root / "sealed").exists())
            require((self.root / "ready").exists())
            self.append_scope(unit)  # Record before any possible side effect.
            pending = self.root / ("pending-" + unit)
            private_write(pending, b"launch not yet acknowledged")
            started = self.root / ("started-" + unit)
            launcher = "import os,sys; f=os.open(sys.argv[1],os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600); os.close(f); os.execvp(sys.argv[2],sys.argv[2:])"
            child = subprocess.Popen(["/usr/bin/systemd-run", "--user", "--scope", "--quiet", "--expand-environment=no",
                                      "--property=KillMode=control-group", "--description=dev-vm-provisioning", "--unit=" + unit,
                                      "--", "/usr/bin/python3", "-I", "-c", launcher, str(started), *argv])
            deadline = time.monotonic() + 10
            observed = False
            while time.monotonic() < deadline:
                state = self.unit_state(unit)
                if state["LoadState"] == "loaded" or started.exists():
                    observed = True
                    break
                if child.poll() is not None:
                    break
                time.sleep(0.02)
            observed = observed or started.exists()
            if not observed:
                private_write(self.root / ("uncertain-" + uuid.uuid4().hex), b"registration not confirmed")
                child.terminate()
                raise ValueError("uncertain registration")
            pending.unlink()
        while child.poll() is None:
            if interrupted:
                subprocess.run(["/usr/bin/systemctl", "--user", "stop", unit], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10, check=False)
            time.sleep(0.02)
        return child.returncode

    def quiesce(self):
        deadline = time.monotonic() + 20
        with self.lock():
            if not (self.root / "sealed").exists():
                private_write(self.root / "sealed", b"sealed")
            require(not list(self.root.glob("uncertain-*")) and not list(self.root.glob("pending-*")))
            for unit in self.scopes():
                require(time.monotonic() < deadline)
                state = self.unit_state(unit)
                if state["LoadState"] == "loaded" and state["ActiveState"] not in ("inactive", "failed"):
                    result = subprocess.run(["/usr/bin/systemctl", "--user", "stop", unit], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5, check=False)
                    require(result.returncode == 0)
                self.empty_unit(unit)


def main():
    job = Job(sys.argv[1], sys.argv[2])
    action = sys.argv[3]
    if action == "prepare":
        with job.lock():
            require(not (job.root / "sealed").exists())
            subprocess.run(["/usr/bin/systemctl", "--user", "show-environment"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5, check=True)
            if not (job.root / "ready").exists():
                private_write(job.root / "ready", b"ready")
        # Establish required user-scope/flag support before any sudo grant.
        require(job.run(["/usr/bin/true"]) == 0)
        for unit in job.scopes():
            job.empty_unit(unit)
        job.receipt("ready")
    elif action in ("run", "cleanup-run", "shell"):
        argv = sys.argv[4:]
        if action == "shell":
            argv = ["/bin/bash", *argv]
        require(not argv or argv[0] != "--")
        sys.exit(job.run(argv, cleanup=action == "cleanup-run"))
    elif action == "quiesce":
        job.quiesce()
        job.receipt("quiescent")
    elif action == "remove":
        job.quiesce()
        require(shutil.rmtree.avoids_symlink_attacks)
        shutil.rmtree(job.root)
        job.receipt("absent")
    else:
        raise ValueError("unknown action")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Never print command output, paths, credentials or guest identifiers.
        print("job-control-failed", file=sys.stderr)
        sys.exit(1)
