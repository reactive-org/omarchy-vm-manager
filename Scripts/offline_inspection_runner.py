"""Live worker supervision with an injected process factory; never calls Popen.

Factories own a process group atomically: spawn returns promptly with its handle;
native work belongs in the child, never inline in spawn. Handles drain bounded nonblocking chunks, expose EOF/group
state, kill the whole group and wait/reap with a timeout. No factory is selected
implicitly; the concrete factory requires explicit trusted composition. A failed handoff leaves cleanup unconfirmed.
Tests supply virtual processes and clocks.
"""
from dataclasses import dataclass
import subprocess
import threading
import time

import private_provisioning_package as private
from offline_inspection_worker import Task, validate_failure

MAX_OUTPUT = 2 * 1024 * 1024
JOB_SECONDS = 300
STAGE_SECONDS = 120
MAX_WORKERS = 4112


@dataclass(frozen=True, repr=False)
class OfflineAuthorization:
    requestSHA256: str
    scopeSHA256: str
    selectionSHA256: str
    implementationSHA256: str
    effects: frozenset

    def __repr__(self): return "OfflineInspectionAuthorization(redacted)"


class Runner:
    def __init__(self, factory=None, authorization=None, clock=time.monotonic):
        self.factory, self.authorization, self.clock = factory, authorization, clock
        self.test_double = factory.test_double if factory is not None else False
        self._lock = threading.Lock(); self._operation = threading.Lock(); self._used = False
        self.active = None; self.cleanup_confirmed = True
        self.worker_records = []

    def __repr__(self): return "BoundedOfflineInspectionRunner(redacted)"

    def authorize(self, request, scope, selection, implementation):
        a = self.authorization
        private.require(type(a) is OfflineAuthorization and type(a.effects) is frozenset
                        and a.effects == frozenset({"offline-native-inspect"})
                        and (a.requestSHA256, a.scopeSHA256, a.selectionSHA256, a.implementationSHA256)
                        == (request, scope, selection, implementation), "offline-inspection-not-authorized")
        private.require(self.factory is not None and type(self.test_double) is bool
                        and self.factory.api_test_double is self.test_double
                        and self.factory.implementationSHA256 == implementation, "offline-worker-factory-unavailable")
        if hasattr(self.factory, "bind_authorization"): self.factory.bind_authorization(a)

    def start(self, bindings):
        self.authorize(*bindings)
        with self._lock:
            private.require(not self._used, "offline-runner-already-used"); self._used = True
        self.bindings = bindings; self.deadline = self.clock() + JOB_SECONDS

    def check(self, cancel=None):
        private.require(not cancel or not cancel(), "offline-inspection-cancelled")
        private.require(self.clock() < self.deadline, "offline-job-timeout")

    def run(self, spec, revalidate, cancel=None):
        private.require(self._operation.acquire(blocking=False), "offline-worker-overlap")
        try: return self._run(spec, revalidate, cancel)
        finally: self._operation.release()

    def _run(self, spec, revalidate, cancel=None):
        private.require(type(spec) is Task, "offline-worker-task")
        spec.decode()
        self.authorize(*self.bindings); self.check(cancel)
        private.require(self.active is None, "offline-worker-overlap")
        revalidate(); self.check(cancel)
        deadline = min(self.deadline, self.clock() + STAGE_SECONDS)
        private.require(len(self.worker_records) < MAX_WORKERS, "offline-worker-count-bound")
        record = {"sequence": len(self.worker_records) + 1, "kind": spec.kind, "exitStatus": None,
                  "failureCategory": None, "diagnostic": None, "cleanupOperations": []}
        self.worker_records.append(record)
        process = None; failed = True; cleanup = True; quiet_observed = False
        output = bytearray(); totals = {"stdout": 0, "stderr": 0}
        try:
            process = self.factory.spawn(spec)
            self.active = process
            while True:
                self.check(cancel)
                private.require(self.clock() < deadline, "offline-stage-timeout")
                events = process.read_ready(65536, min(0.05, deadline - self.clock()))
                private.require(type(events) in (list, tuple) and len(events) <= 2, "offline-worker-stream-protocol")
                for stream, data in events:
                    private.require(stream in totals and type(data) is bytes and len(data) <= 65536, "offline-worker-stream-protocol")
                    totals[stream] += len(data)
                    private.require(totals[stream] <= MAX_OUTPUT, "offline-worker-output-limit")
                    if stream == "stdout": output.extend(data)
                if events: revalidate()
                self.check(cancel)
                private.require(self.clock() < deadline, "offline-stage-timeout")
                status = process.poll()
                if status is not None:
                    private.require(type(status) is int and -255 <= status <= 255, "offline-worker-exit-status")
                    record["exitStatus"] = status
                    quiet_observed = not process.group_alive()
                    if status != 0: record["failureCategory"] = "worker-exit"
                    private.require(status == 0, "offline-worker-failed")
                    private.require(quiet_observed, "offline-worker-descendants-remain")
                    if process.streams_closed(): break
            revalidate(); self.check(cancel)
            value = private.decode(bytes(output))
            private.require(type(value) is dict, "offline-worker-response")
            if getattr(self.factory, "requires_mode_proof", False):
                private.require(value.pop("_offlineAPITestDouble", None) is self.factory.api_test_double, "offline-worker-mode-proof")
            if "offlineFailure" in value:
                record["failureCategory"] = "worker-diagnostic-invalid"
                private.require(set(value) == {"offlineFailure"}, "offline-worker-diagnostic-invalid")
                record["diagnostic"] = validate_failure(value["offlineFailure"])
                record["failureCategory"] = "worker-diagnostic"
                raise private.Refused("offline-worker-reported-failure")
            failed = False
            return value
        except BaseException:
            if process is None: cleanup = False
            raise private.Refused("offline-worker-refused") from None
        finally:
            def error_kind(error):
                if isinstance(error, (TimeoutError, subprocess.TimeoutExpired)): return "timeout"
                if isinstance(error, PermissionError): return "permission"
                if isinstance(error, ChildProcessError): return "ownership-lost"
                if isinstance(error, private.Refused): return "validation"
                return "other"

            def operation(label, action, absent_ok=False):
                nonlocal cleanup
                try:
                    action()
                    record["cleanupOperations"].append({"operation": label, "result": "ok"})
                    return True
                except ProcessLookupError:
                    if absent_ok:
                        record["cleanupOperations"].append({"operation": label, "result": "process-absent"})
                        return True
                    cleanup = False
                    record["cleanupOperations"].append({"operation": label, "result": "ownership-lost"})
                except BaseException as error:
                    cleanup = False
                    record["cleanupOperations"].append({"operation": label, "result": error_kind(error)})
                return False

            def wait_and_check():
                status = process.wait(timeout=5)
                private.require(failed or (type(status) is int and status == 0))
                private.require(not process.group_alive())

            if process is not None:
                # A held exited root plus an observed quiet group needs reaping,
                # not a signal. Never infer quietness merely from an exit code.
                if failed and not quiet_observed:
                    operation("kill-primary", process.kill_group, absent_ok=True)
                if not operation("wait-primary", wait_and_check):
                    operation("kill-fallback", process.kill_group, absent_ok=True)
                    operation("wait-fallback", wait_and_check)
                operation("close", process.close)
                if hasattr(process, "evidence"):
                    # Concrete handles return only local lifecycle facts; no raw
                    # argv, paths, task bodies, native errors or certificate data.
                    operation("evidence", lambda: record.update(handle=process.evidence()))
            else:
                cleanup = False
                record["cleanupOperations"].append({"operation": "spawn-handoff", "result": "unconfirmed"})
            record["status"] = "REFUSED" if failed else "COMPLETED"
            if failed and record["failureCategory"] is None: record["failureCategory"] = "supervision"
            record["cleanupConfirmed"] = cleanup
            self.active = None
            # Intermediate failures stay latched, even if fallback ultimately
            # reaps and closes the handle. Evidence explains that distinction.
            self.cleanup_confirmed = self.cleanup_confirmed and cleanup
            if not cleanup: raise private.Refused("offline-worker-cleanup-unconfirmed") from None



if __name__ == "__main__":
    raise SystemExit("No process launcher or authorization loader; inject an approved factory.")
