"""Internal pipe worker. A JSON file/environment/ordinary CLI is not approval."""
from pathlib import Path
import hashlib
import os
import selectors
import stat
import subprocess
import sys
import time

# -I excludes the script directory; import only our adjacent reviewed sources.
if __name__ == "__main__": sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_provisioning_package as p
from offline_inspection_worker import Task, perform
from offline_native_process import WIRE_LIMIT, PERMIT_LIMIT
from offline_macos_api import MacOSAPI


class GitOps:
    test_double = False
    popen = staticmethod(subprocess.Popen)
    selector = staticmethod(selectors.DefaultSelector)
    blocking = staticmethod(os.set_blocking)
    read = staticmethod(os.read)
    clock = staticmethod(time.monotonic)


def bounded_git(path, ops=None):
    """Filter-free Git metadata plus raw tracked bytes, never git status/filters."""
    ops = ops or GitOps()
    environment = {"PATH": "/usr/bin:/bin", "HOME": os.environ.get("HOME", "/private/tmp"),
        "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0",
        "GIT_ASKPASS": "/usr/bin/false", "GIT_SSH_COMMAND": "/usr/bin/false", "GIT_NO_REPLACE_OBJECTS": "1", "LC_ALL": "C"}
    results = []
    for args in (("rev-parse", "HEAD"), ("ls-tree", "-r", "--full-tree", "-z", "HEAD"),
                 ("ls-files", "--others", "--exclude-standard", "-z"), ("ls-files", "--stage", "-z")):
        process = selector = None; streams = {}; output = bytearray(); counts = {"stdout": 0, "stderr": 0}
        try:
            process = ops.popen(["/usr/bin/git", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
                "-C", str(path), *args], env=environment, stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0, close_fds=True, start_new_session=False)
            streams = {"stdout": process.stdout, "stderr": process.stderr}; selector = ops.selector()
            for name, stream in streams.items():
                ops.blocking(stream.fileno(), False); selector.register(stream.fileno(), selectors.EVENT_READ, name)
            deadline = ops.clock() + 10
            while streams:
                p.require(ops.clock() < deadline, "offline-git-timeout")
                for key, _ in selector.select(min(0.05, max(0, deadline - ops.clock()))):
                    try: data = ops.read(key.fd, 65536)
                    except BlockingIOError: continue
                    p.require(type(data) is bytes and len(data) <= 65536, "offline-git-read")
                    if not data:
                        selector.unregister(key.fd); streams.pop(key.data).close()
                    else:
                        counts[key.data] += len(data); p.require(counts[key.data] <= 2 * 1024 * 1024, "offline-git-output")
                        if key.data == "stdout": output.extend(data)
            p.require(process.wait(timeout=max(0.001, deadline - ops.clock())) == 0, "offline-git-failed")
            results.append(bytes(output))
        except BaseException:
            if process is not None:
                try: process.kill()
                except BaseException: pass
                try: process.wait(timeout=2)
                except BaseException: pass
            raise p.Refused("offline-git-refused") from None
        finally:
            for stream in streams.values(): stream.close()
            if selector is not None: selector.close()
    tree = {}; index = {}
    for row in results[1].split(b"\0"):
        if not row: continue
        info, name = row.split(b"\t", 1); mode, kind, digest = info.split(b" ")
        p.require(kind == b"blob" and mode in (b"100644", b"100755", b"120000"), "offline-git-tree")
        relative = p.relative(name.decode("utf-8")); p.require(".git" not in relative.parts and name not in tree)
        tree[name] = (mode, digest)
    for row in results[3].split(b"\0"):
        if not row: continue
        info, name = row.split(b"\t", 1); mode, digest, stage = info.split(b" ")
        p.require(stage == b"0" and name not in index, "offline-git-index")
        index[name] = (mode, digest)
    clean = not results[2] and tree == index
    total = 0
    p.require(len(tree) <= 4096, "offline-git-inventory-bound")
    if clean:
        for name, (mode, digest) in tree.items():
            relative = name.decode("utf-8")
            p.require(not relative.lower().endswith((".p12", ".p8", ".keychain", ".keychain-db")), "offline-git-credential-file")
            target = path / relative
            p.require(target.parent.resolve() == target.parent, "offline-git-linked-parent")
            if mode == b"120000":
                p.require(target.is_symlink(), "offline-git-mode")
                data = os.fsencode(os.readlink(target))
            else:
                data = p.read(target)
                actual_executable = bool(target.stat().st_mode & 0o111)
                clean = clean and actual_executable == (mode == b"100755")
            total += len(data); p.require(total <= 1024 * 1024 * 1024, "offline-git-inventory-bound")
            raw_digest = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest().encode()
            clean = clean and raw_digest == digest
    return {"revision": results[0].decode("ascii").strip(), "clean": clean}


def run_frame(permit_raw, request_raw, parent_pid, api_factory=None, digest=None):
    """Permit bytes come solely from the anonymous inherited parent pipe."""
    p.require(type(permit_raw) is bytes and len(permit_raw) <= PERMIT_LIMIT
              and type(request_raw) is bytes and len(request_raw) <= WIRE_LIMIT, "offline-worker-frame-bound")
    permit = p.decode(permit_raw); request = p.decode(request_raw)
    p.require(type(permit) is dict and set(permit) == {"token", "taskSHA256", "implementationSHA256", "parent", "testDouble"}
              and type(request) is dict and set(request) == {"kind", "fields", "token"}, "offline-worker-frame")
    p.require(isinstance(permit["token"], str) and len(permit["token"]) == 64 and permit["token"] == request["token"]
              and type(permit["parent"]) is int and permit["parent"] == parent_pid
              and type(permit["testDouble"]) is bool, "offline-worker-parent-capability")
    body = {"kind": request["kind"], "fields": request["fields"]}
    p.require(p.digest(p.canonical(body)) == permit["taskSHA256"], "offline-worker-task-binding")
    if digest is None:
        from private_provisioning_offline import implementation_digest
        digest = implementation_digest
    p.require(digest() == permit["implementationSHA256"], "offline-worker-code-binding")
    spec = Task(request["kind"], p.canonical(request["fields"])); spec.decode()
    api = api_factory() if api_factory is not None else MacOSAPI(dependency_checker=bounded_git)
    result = perform(spec, api, expected_test_double=permit["testDouble"])
    return p.canonical(dict(result, _offlineAPITestDouble=api.test_double))


def pipe_read(fd, maximum):
    data = bytearray()
    while True:
        block = os.read(fd, min(65536, maximum + 1 - len(data)))
        if not block: break
        data.extend(block); p.require(len(data) <= maximum, "offline-worker-input-bound")
    return bytes(data)


def main():
    # No mode accepting authorization/review files, identity selectors or flags.
    p.require(len(sys.argv) == 3 and sys.argv[1] == "--worker-fd" and sys.argv[2].isdigit(), "offline-worker-private-entry")
    fd = int(sys.argv[2]); p.require(fd > 2 and stat.S_ISFIFO(os.fstat(fd).st_mode), "offline-worker-private-pipe")
    try: permit = pipe_read(fd, PERMIT_LIMIT)
    finally: os.close(fd)
    request = pipe_read(0, WIRE_LIMIT)
    result = run_frame(permit, request, os.getppid())
    p.require(len(result) <= 2 * 1024 * 1024, "offline-worker-result-bound")
    sys.stdout.buffer.write(result); sys.stdout.buffer.flush()


if __name__ == "__main__":
    try: main()
    except BaseException:
        sys.stderr.write("offline-native-worker-refused\n")
        raise SystemExit(1) from None
