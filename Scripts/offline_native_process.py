"""Explicit worker factory and POSIX handle; construction does not spawn/load FFI."""
import ctypes as C
import errno
import os
from pathlib import Path
import selectors
import signal
import stat
import subprocess
import sys
import time

import private_provisioning_package as p
from offline_inspection_runner import OfflineAuthorization, MAX_OUTPUT
from offline_inspection_worker import Task

WIRE_LIMIT = 2 * 1024 * 1024 + 4096
PERMIT_LIMIT = 4096


class SigValue(C.Union):
    _fields_ = [("integer", C.c_int), ("pointer", C.c_void_p)]


class SigInfo(C.Structure):
    # Darwin 64-bit siginfo_t from sys/signal.h (macOS 15+).
    _fields_ = [("signo", C.c_int), ("error", C.c_int), ("code", C.c_int), ("pid", C.c_int),
                ("uid", C.c_uint32), ("status", C.c_int), ("address", C.c_void_p),
                ("value", SigValue), ("band", C.c_long), ("padding", C.c_ulong * 7)]


class WaitBinding:
    def __init__(self, loader=None):
        self.loader = loader or (lambda path: C.CDLL(path, use_errno=True)); self.function = None

    def prepare(self):
        p.require(C.sizeof(SigInfo) == 104 and SigInfo.status.offset == 20, "offline-waitid-abi")
        if self.function is None:
            self.library = self.loader("/usr/lib/libSystem.B.dylib")
            fn = self.library.waitid; fn.argtypes = [C.c_int, C.c_uint32, C.POINTER(SigInfo), C.c_int]; fn.restype = C.c_int
            self.function = fn

    def observe(self, pid):
        self.prepare(); result = SigInfo(); C.set_errno(0)
        status = self.function(1, pid, C.byref(result), 4 | 1 | 32)  # P_PID, WEXITED|WNOHANG|WNOWAIT
        if status != 0:
            if C.get_errno() == errno.ECHILD: raise ChildProcessError("offline-root-ownership-lost")
            raise p.Refused("offline-waitid-status")
        if result.pid == 0: return None
        p.require(result.pid == pid and result.code in (1, 2, 3), "offline-waitid-result")
        return result.status if result.code == 1 else -result.status


class ProcessOps:
    test_double = False
    clock = staticmethod(time.monotonic)
    pause = staticmethod(time.sleep)
    pipe = staticmethod(os.pipe)
    write = staticmethod(os.write)
    read = staticmethod(os.read)
    close_fd = staticmethod(os.close)
    blocking = staticmethod(os.set_blocking)
    selector = staticmethod(selectors.DefaultSelector)
    popen = staticmethod(subprocess.Popen)
    nonce = staticmethod(lambda: os.urandom(32).hex())
    parent_pid = staticmethod(os.getpid)

    def observe(self, pid):
        # WNOWAIT keeps the root unreaped, reserving its process-group identity.
        if not hasattr(os, "waitid"):
            if not hasattr(self, "_wait"): self._wait = WaitBinding()
            return self._wait.observe(pid)
        result = os.waitid(getattr(os, "P_PID", 1), pid, getattr(os, "WEXITED", 4) | os.WNOHANG | os.WNOWAIT)
        if result is None: return None
        if result.si_code == getattr(os, "CLD_EXITED", 1): return result.si_status
        p.require(result.si_code in (getattr(os, "CLD_KILLED", 2), getattr(os, "CLD_DUMPED", 3)), "offline-root-status")
        return -result.si_status

    def group_members(self, pgid):
        if not hasattr(self, "_list_group"):
            library = C.CDLL("/usr/lib/libproc.dylib")
            # proc_listpids returns bytes; convenience wrappers can return PID counts.
            fn = library.proc_listpids; fn.argtypes = [C.c_uint32, C.c_uint32, C.c_void_p, C.c_int]; fn.restype = C.c_int
            self._libproc, self._list_group = library, fn
        buffer = (C.c_int * 4097)()
        size = self._list_group(2, pgid, buffer, C.sizeof(buffer))  # PROC_PGRP_ONLY
        p.require(C.sizeof(C.c_int) <= size < C.sizeof(buffer) and size % C.sizeof(C.c_int) == 0, "offline-group-query")
        members = [pid for pid in buffer[:size // C.sizeof(C.c_int)] if pid > 0]
        p.require(pgid in members, "offline-group-root-missing")
        return members

    def kill_group(self, pgid): os.killpg(pgid, signal.SIGKILL)

    def preflight(self):
        if not hasattr(os, "waitid"):
            self._wait = WaitBinding(); self._wait.prepare()
        if not hasattr(self, "_list_group"):
            library = C.CDLL("/usr/lib/libproc.dylib")
            fn = library.proc_listpids; fn.argtypes = [C.c_uint32, C.c_uint32, C.c_void_p, C.c_int]; fn.restype = C.c_int
            self._libproc, self._list_group = library, fn


class ProcessHandle:
    def __init__(self, process, ops, request, on_close=lambda _: None):
        self.process, self.ops, self.request, self.on_close = process, ops, request, on_close
        self.selector = None; self.open_streams = {}; self.sent = 0
        self.counts = {"stdout": 0, "stderr": 0}
        self.reaped = False; self.quiet = False; self.status = None; self.closed = False; self.clean_descriptors = False

    def prepare(self):
        self.open_streams = {name: getattr(self.process, name, None) for name in ("stdin", "stdout", "stderr")}
        p.require(all(self.open_streams.values()), "offline-worker-pipes")
        self.selector = self.ops.selector()
        for name in ("stdin", "stdout", "stderr"):
            stream = getattr(self.process, name); fd = stream.fileno()
            self.ops.blocking(fd, False)
            self.selector.register(fd, selectors.EVENT_WRITE if name == "stdin" else selectors.EVENT_READ, name)

    def _close_stream(self, name):
        stream = self.open_streams.pop(name)
        try:
            if self.selector is not None:
                try: self.selector.unregister(stream.fileno())
                except KeyError: pass
        finally: stream.close()

    def read_ready(self, maximum, timeout):
        p.require(maximum <= 65536 and 0 <= timeout <= 0.05, "offline-read-bound")
        events = []
        for key, _ in self.selector.select(timeout):
            name = key.data
            try:
                if name == "stdin":
                    count = self.ops.write(key.fd, self.request[self.sent:self.sent + maximum])
                    p.require(0 < count <= maximum, "offline-request-write")
                    self.sent += count
                    if self.sent == len(self.request): self._close_stream("stdin")
                else:
                    data = self.ops.read(key.fd, maximum)
                    p.require(type(data) is bytes and len(data) <= maximum, "offline-read-protocol")
                    if not data: self._close_stream(name)
                    else:
                        self.counts[name] += len(data)
                        p.require(self.counts[name] <= MAX_OUTPUT, "offline-live-output-bound")
                        events.append((name, data))
            except BlockingIOError: continue
        return events

    def poll(self):
        if self.reaped: return self.status
        self.status = self.ops.observe(self.process.pid)
        if self.status is not None: p.require(self.sent == len(self.request), "offline-incomplete-request")
        return self.status

    def group_alive(self):
        if self.reaped:
            p.require(self.quiet, "offline-group-ownership-lost"); return False
        if self.ops.observe(self.process.pid) is None: return True
        return any(pid != self.process.pid for pid in self.ops.group_members(self.process.pid))

    def streams_closed(self): return not self.open_streams

    def kill_group(self):
        if self.reaped: return  # Never signal a PGID after releasing its root PID.
        self.ops.observe(self.process.pid)  # ECHILD means ownership is lost: refuse.
        self.ops.kill_group(self.process.pid)

    def wait(self, timeout):
        p.require(0 < timeout <= 5)
        if self.reaped: return self.status
        deadline = self.ops.clock() + timeout
        while True:
            status = self.ops.observe(self.process.pid)
            if status is not None and not any(pid != self.process.pid for pid in self.ops.group_members(self.process.pid)):
                remaining = deadline - self.ops.clock(); p.require(remaining > 0, "offline-reap-timeout")
                result = self.process.wait(timeout=remaining)
                p.require(result == status, "offline-root-status-changed")
                self.status, self.reaped, self.quiet = result, True, True
                return result
            remaining = deadline - self.ops.clock(); p.require(remaining > 0, "offline-reap-timeout")
            self.ops.pause(min(0.01, remaining))

    def close(self):
        errors = False
        for name in ("stdin", "stdout", "stderr"):
            stream = getattr(self.process, name, None)
            if stream is not None and not stream.closed and name not in self.open_streams: self.open_streams[name] = stream
        for name in list(self.open_streams):
            if self.open_streams[name] is None:
                self.open_streams.pop(name); continue
            try: self._close_stream(name)
            except BaseException: errors = True
        if self.selector is not None:
            try: self.selector.close()
            except BaseException: errors = True
        self.closed = True; self.clean_descriptors = not errors; self.on_close(self)
        p.require(not errors, "offline-descriptor-cleanup")


class MacOSWorkerFactory:
    requires_mode_proof = True

    def __init__(self, review, scope, selection, source_fixture, ops=None):
        # Typed/authorization checks are deferred to bind_authorization; no IO here.
        self.review, self.scope, self.selection, self.source_fixture = review, scope, selection, source_fixture
        self.ops = ops if ops is not None else ProcessOps()
        self.test_double = self.api_test_double = self.ops.test_double
        self.authorization = None; self.serial = 0; self.pending_cleanup = []

    @property
    def implementationSHA256(self):
        from private_provisioning_offline import implementation_digest
        return implementation_digest()

    def bind_authorization(self, authorization):
        from private_provisioning_offline import OfflineReview
        p.require(type(self.review) is OfflineReview and type(authorization) is OfflineAuthorization
                  and type(authorization.effects) is frozenset and authorization.effects == frozenset({"offline-native-inspect"}), "offline-launch-authorization")
        p.require((authorization.requestSHA256, authorization.scopeSHA256, authorization.selectionSHA256,
                   authorization.implementationSHA256) == (self.review.request_digest(), self.scope, self.selection,
                   self.review.implementationSHA256), "offline-launch-binding")
        p.require(type(self.test_double) is bool and type(self.source_fixture) is bool
                  and (self.test_double or (not self.source_fixture and sys.platform == "darwin")), "offline-launch-mode")
        p.require(self.authorization is None or self.authorization == authorization, "offline-launch-rebinding")
        self.authorization = authorization

    def _closed(self, handle):
        if not handle.reaped or not handle.quiet or not handle.clean_descriptors:
            if handle not in self.pending_cleanup: self.pending_cleanup.append(handle)
        elif handle in self.pending_cleanup: self.pending_cleanup.remove(handle)

    def spawn(self, spec):
        p.require(type(spec) is Task and self.authorization is not None, "offline-launch-not-authorized")
        self.bind_authorization(self.authorization)
        p.require(self.implementationSHA256 == self.review.implementationSHA256 and not self.pending_cleanup, "offline-launch-implementation-or-cleanup")
        fields = spec.decode()
        if hasattr(self.ops, "preflight"): self.ops.preflight()
        p.private_directory(self.review.output)
        self.serial += 1; work = self.review.output / ("worker-" + str(self.serial)); work.mkdir(mode=0o700)
        p.private_directory(work)
        body = {"kind": spec.kind, "fields": fields}
        token = self.ops.nonce()
        p.require(isinstance(token, str) and len(token) == 64, "offline-launch-token")
        request = p.canonical(dict(body, token=token))
        permit = p.canonical({"token": token, "taskSHA256": p.digest(p.canonical(body)),
            "implementationSHA256": self.review.implementationSHA256, "parent": self.ops.parent_pid(), "testDouble": self.test_double})
        p.require(len(request) <= WIRE_LIMIT and len(permit) <= PERMIT_LIMIT)
        read_fd = write_fd = None; handle = None
        try:
            read_fd, write_fd = self.ops.pipe()
            p.require(type(read_fd) is int and type(write_fd) is int and read_fd > 2 and write_fd > 2 and read_fd != write_fd, "offline-permit-descriptors")
            p.require(self.ops.write(write_fd, permit) == len(permit), "offline-permit-write")
            self.ops.close_fd(write_fd); write_fd = None
            entry = Path(__file__).resolve().parent / "offline_native_worker.py"
            command = [str(Path(sys.executable).resolve()), "-I", "-B", str(entry), "--worker-fd", str(read_fd)]
            environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(work), "TMPDIR": str(work),
                           "LC_ALL": "C", "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1"}
            process = self.ops.popen(command, cwd=work, env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, bufsize=0, close_fds=True, pass_fds=(read_fd,), start_new_session=True)
            handle = ProcessHandle(process, self.ops, request, self._closed)
            self.ops.close_fd(read_fd); read_fd = None
            handle.prepare(); return handle
        except BaseException:
            if handle is not None:
                try: handle.kill_group()
                except BaseException: pass
                try: handle.wait(timeout=5)
                except BaseException: pass
                try: handle.close()
                except BaseException: pass
            raise p.Refused("offline-native-launch-refused") from None
        finally:
            for fd in (read_fd, write_fd):
                if fd is not None: self.ops.close_fd(fd)
