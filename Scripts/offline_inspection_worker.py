"""Offline policy engine with an injected API facade; no native binding or CLI."""
from dataclasses import dataclass
import base64
import math
from pathlib import Path
import plistlib
import re

import private_provisioning_package as private

NO_NETWORK = 1 << 29  # kSecCSNoNetworkAccess, CSCommon.h
ALL_ARCHITECTURES = 1 << 0
CHECK_NESTED = 1 << 3
STRICT = 1 << 4
STATIC_FLAGS = NO_NETWORK | ALL_ARCHITECTURES | STRICT
RUNTIME = 0x10000
ADHOC = 0x0002
LIMIT = 1024 * 1024
DATA_OID = bytes.fromhex("2a864886f70d010701")
SIGNED_OID = bytes.fromhex("2a864886f70d010702")


def blob(raw): return base64.b64encode(raw).decode("ascii")


def unblob(value):
    private.require(isinstance(value, str) and len(value) <= 4 * ((LIMIT + 2) // 3), "offline-content-bound")
    try: raw = base64.b64decode(value, validate=True)
    except Exception: raise private.Refused("offline-content-invalid") from None
    private.require(len(raw) <= LIMIT, "offline-content-bound")
    return raw


def signed_content(raw):
    """Strict definite DER signedData with embedded data, before any native API.

    This is an envelope/content guard, not CMS signature or signer validation.
    In particular it must never hand an encrypted envelope to a native decoder.
    """
    private.require(type(raw) is bytes and 0 < len(raw) <= LIMIT, "offline-cms-envelope")
    nodes = 0

    def read(offset, end, depth=0):
        nonlocal nodes
        nodes += 1
        private.require(depth <= 32 and nodes <= 4096 and offset + 2 <= end, "offline-cms-envelope")
        tag, size = raw[offset], raw[offset + 1]; offset += 2
        private.require(tag != 0 and tag & 31 != 31, "offline-cms-envelope")
        if size & 128:
            count = size & 127
            private.require(1 <= count <= 4 and offset + count <= end and raw[offset] != 0, "offline-cms-envelope")
            size = int.from_bytes(raw[offset:offset + count], "big"); offset += count
            private.require(size >= 128, "offline-cms-envelope")
        stop = offset + size
        private.require(stop <= end, "offline-cms-envelope")
        children = []
        if tag & 32:
            cursor = offset
            while cursor < stop:
                child, cursor = read(cursor, stop, depth + 1); children.append(child)
            private.require(cursor == stop, "offline-cms-envelope")
        return (tag, raw[offset:stop], children), stop

    root, end = read(0, len(raw))
    private.require(end == len(raw) and root[0] == 0x30 and len(root[2]) == 2, "offline-cms-envelope")
    oid, wrapper = root[2]
    private.require(oid[:2] == (6, SIGNED_OID) and wrapper[0] == 0xA0 and len(wrapper[2]) == 1, "offline-cms-envelope")
    signed = wrapper[2][0]
    private.require(signed[0] == 0x30 and 4 <= len(signed[2]) <= 6, "offline-cms-envelope")
    version, algorithms, content, *tail = signed[2]
    private.require(version[0] == 2 and version[1] in (b"\x01", b"\x03", b"\x04", b"\x05")
                    and algorithms[0] == 0x31 and algorithms[2], "offline-cms-envelope")
    private.require(content[0] == 0x30 and len(content[2]) == 2, "offline-cms-envelope")
    kind, embedded = content[2]
    private.require(kind[:2] == (6, DATA_OID) and embedded[0] == 0xA0 and len(embedded[2]) == 1, "offline-cms-envelope")
    payload = embedded[2][0]
    private.require(payload[0] == 4 and payload[1] and tail[-1][0] == 0x31 and tail[-1][2], "offline-cms-envelope")
    private.require([n[0] for n in tail[:-1]] in ([], [0xA0], [0xA1], [0xA0, 0xA1]), "offline-cms-envelope")
    try: decoded = plistlib.loads(payload[1])
    except Exception: raise private.Refused("offline-cms-content-not-profile") from None
    private.require(type(decoded) is dict, "offline-cms-content-not-profile")
    return payload[1]


def safe_path(value):
    private.require(isinstance(value, str), "offline-path")
    path = Path(value); parts = tuple(p.casefold() for p in path.parts)
    private.require(path.is_absolute() and not any(parts[i:i + 2] == ("omarchy vm manager", "vms")
                    for i in range(len(parts) - 1)), "offline-path")
    private.require(path.resolve() == path, "offline-linked-path")
    return path


@dataclass(frozen=True, repr=False)
class Task:
    kind: str
    payload: bytes

    def __repr__(self): return "OfflineInspectionTask(redacted)"

    def decode(self):
        private.require(self.kind in {"dependency", "locked", "profile", "certificate", "static"}
                        and type(self.payload) is bytes and len(self.payload) <= 2 * LIMIT, "offline-task")
        value = private.decode(self.payload)
        private.require(type(value) is dict, "offline-task")
        return value


def task(kind, **fields):
    result = Task(kind, private.canonical(fields)); result.decode(); return result


def requirement_for(team):
    private.require(isinstance(team, str) and re.fullmatch(r"[A-Z0-9]{10}", team), "offline-static-team")
    return ('anchor apple generic and identifier "dev.tryomarchy.kit" and '
            'certificate leaf[field.1.2.840.113635.100.6.1.13] exists and '
            'certificate leaf[subject.OU] = "' + team + '"')


def perform(spec, api, expected_test_double=True):
    try:
        private.require(type(expected_test_double) is bool and api.test_double is expected_test_double, "offline-api-mode")
        return _perform(spec, api)
    except BaseException: raise private.Refused("offline-api-worker-refused") from None


def _perform(spec, api):
    """Facade contract: opaque handles are owned/released here, even on refusal.

    cms_content may only create/update/finalize/copy content, without signer trust
    evaluation. static_info must return kSecCodeInfoTimestamp, not the signer's
    self-declared kSecCodeInfoTime. There is deliberately no system facade here.
    """
    private.require(type(spec) is Task and type(api.test_double) is bool, "offline-worker-interface")
    fields = spec.decode()
    expected = {"dependency": {"path"}, "locked": {"path"}, "profile": {"content"},
                "certificate": {"content"}, "static": {"path", "team", "nested", "entitlements"}}
    private.require(set(fields) == expected[spec.kind], "offline-task-fields")
    # Reject unsafe envelopes/paths before even enabling an API context.
    content = unblob(fields["content"]) if "content" in fields else None
    embedded = signed_content(content) if spec.kind == "profile" else None
    path = safe_path(fields["path"]) if "path" in fields else None
    if spec.kind == "static":
        private.require(isinstance(fields["team"], str) and re.fullmatch(r"[A-Z0-9]{10}", fields["team"])
                        and type(fields["nested"]) is bool and type(fields["entitlements"]) is dict, "offline-static-policy")
    if spec.kind == "dependency":
        result = api.dependency_status(path)
        private.require(type(result) is dict and set(result) == {"revision", "clean"}
                        and isinstance(result["revision"], str) and re.fullmatch("[0-9a-f]{40}", result["revision"])
                        and result["clean"] is True, "offline-source-state")
        return result
    private.require(api.disable_interaction() is True, "offline-interaction-not-disabled")
    if spec.kind == "locked":
        handle = api.keychain_open(path)
        private.require(handle is not None, "offline-keychain-reference")
        try:
            status = api.keychain_status(handle)
            private.require(type(status) is int and 0 <= status <= 7 and not status & 1, "offline-keychain-not-locked")
        finally: api.release(handle)
        return {"locked": True}
    if spec.kind == "profile":
        decoded = api.cms_content(content)
        private.require(type(decoded) is bytes and decoded == embedded, "offline-cms-content-mismatch")
        return {"content": blob(decoded)}
    if spec.kind == "certificate":
        result = api.certificate_info(content)
        private.require(type(result) is dict and set(result) == {"commonName", "notBefore", "notAfter"}
                        and isinstance(result["commonName"], str) and len(result["commonName"]) <= 512
                        and all(type(result[k]) in (int, float) and math.isfinite(result[k]) for k in ("notBefore", "notAfter")),
                        "offline-certificate-info")
        return result
    flags = STATIC_FLAGS | (CHECK_NESTED if fields["nested"] else 0)
    requirement = requirement_for(fields["team"])
    handle = api.static_open(path)
    private.require(handle is not None, "offline-static-reference")
    try:
        # No default/allow-network/revocation fallback, including on API errors.
        private.require(api.static_validate(handle, flags, requirement) is True, "offline-static-invalid")
        info = api.static_info(handle)
        private.require(type(info) is dict and set(info) == {"identifier", "team", "flags", "timestamp", "entitlements"}, "offline-static-info")
        private.require(info["identifier"] == "dev.tryomarchy.kit" and info["team"] == fields["team"]
                        and type(info["flags"]) is int and 0 <= info["flags"] <= 0xffffffff
                        and info["flags"] & RUNTIME and not info["flags"] & ADHOC
                        and type(info["timestamp"]) in (int, float) and math.isfinite(info["timestamp"]) and info["timestamp"] > 0
                        and private.canonical(info["entitlements"]) == private.canonical(fields["entitlements"]), "offline-static-policy-failed")
    finally: api.release(handle)
    return {"valid": True, "validationFlags": flags}


if __name__ == "__main__":
    raise SystemExit("No native worker CLI or default API binding; trusted injected composition required.")
