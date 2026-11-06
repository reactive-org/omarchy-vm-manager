#!/usr/bin/env python3
"""Deploy explicitly selected home files without overwriting unreviewed edits."""

import argparse
import hashlib
import json
import os
import shutil
import stat
import sys
import tempfile
import uuid
from pathlib import Path, PurePosixPath


def relative_target(value):
    if not isinstance(value, str):
        raise ValueError("Dotfile targets must be home-relative strings")
    value = value.removeprefix("~/")
    path = PurePosixPath(value)
    if (not value or path.is_absolute() or any(part in ("", ".", "..") for part in value.split("/"))
            or any(ord(c) < 32 for c in value) or "\\" in value or value.startswith("~")):
        raise ValueError("Dotfile targets must be explicit paths inside the guest home")
    if path.parts[0] in (".ssh", ".gnupg", ".aws", ".git") or value.startswith(".local/state/dev-vm"):
        raise ValueError("Credential directories and dev-vm state cannot be dotfile targets")
    return str(path)


def safe_path(home, relative):
    path = home
    for part in PurePosixPath(relative).parts:
        path = path / part
        if path.is_symlink():
            raise ValueError(f"Refusing symlink in dotfile destination: {relative}")
    return path


def fingerprint(path):
    if not path.exists():
        return None
    if not path.is_file():
        raise ValueError(f"Dotfile destination is not a regular file: {path.name}")
    return {"sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "mode": stat.S_IMODE(path.stat().st_mode)}


def deploy(home, setup_id, entries, *, check=False, conflict="fail"):
    home = Path(home).resolve(strict=True)
    state_path = safe_path(home, ".local/state/dev-vm/dotfiles.json")
    state = json.loads(state_path.read_text()) if state_path.exists() else {}
    if (not isinstance(state, dict) or any(not isinstance(record, dict)
            or set(record) != {"owner", "sha256", "mode"} for record in state.values())):
        raise ValueError("Invalid dotfile ownership state")
    actions, targets = [], set()
    for entry in entries:
        relative = relative_target(entry["target"])
        if relative in targets or any(relative.startswith(t + "/") or t.startswith(relative + "/") for t in targets):
            raise ValueError(f"Overlapping dotfile destination: {relative}")
        targets.add(relative)
        destination = safe_path(home, relative)
        for parent in destination.parents:
            if parent == home:
                break
            if parent.exists() and not parent.is_dir():
                raise ValueError(f"Dotfile parent is not a directory: {relative}")
        source = Path(entry["source"])
        desired = {"sha256": entry["sha256"], "mode": entry["mode"]}
        observed_source = None if source.is_symlink() else fingerprint(source)
        if observed_source is None or observed_source["sha256"] != desired["sha256"]:
            raise ValueError(f"Dotfile input changed: {relative}")
        current = fingerprint(destination)
        previous = state.get(relative)
        if previous and previous.get("owner") != setup_id:
            raise ValueError(f"Dotfile belongs to another setup: {relative}")
        record = {"owner": setup_id, **desired}
        if current == desired:
            if previous != record:
                actions.append((relative, source, destination, desired, False, "adopt"))
            continue
        edited = current is not None and (previous is None or current != {k: previous[k] for k in desired})
        if edited and conflict != "backup":
            raise ValueError(f"Dotfile conflict: {relative}; review it or explicitly select backup-and-replace")
        actions.append((relative, source, destination, desired, edited, "copy"))

    # All destinations and conflicts are checked before the first write.
    reports = []
    for relative, source, destination, desired, backup, action in actions:
        report = {"target": relative, "action": action, "backup": backup}
        reports.append(report)
        if check:
            continue
        if action == "copy":
            destination.parent.mkdir(parents=True, exist_ok=True)
            if backup:
                backup_path = destination.with_name(destination.name + ".dev-vm-backup-" + uuid.uuid4().hex)
                shutil.copy2(destination, backup_path)
                report["backup_path"] = str(backup_path)
            descriptor, temporary = tempfile.mkstemp(prefix=".dev-vm-", dir=destination.parent)
            try:
                with os.fdopen(descriptor, "wb") as stream:
                    stream.write(source.read_bytes())
                    os.fchmod(stream.fileno(), desired["mode"])
                os.replace(temporary, destination)
            finally:
                if os.path.exists(temporary):
                    os.unlink(temporary)
        state[relative] = {"owner": setup_id, **desired}
    if actions and not check:
        state_path.parent.mkdir(parents=True, exist_ok=True)
        descriptor, temporary = tempfile.mkstemp(prefix=".dotfiles-", dir=state_path.parent)
        try:
            with os.fdopen(descriptor, "w") as stream:
                json.dump(state, stream, indent=2)
            os.replace(temporary, state_path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
    return {"changed": bool(actions), "actions": reports}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    try:
        value = json.load(sys.stdin)
        print(json.dumps(deploy(Path(value["home"]), value["id"], value["files"], check=args.check,
                                conflict=value["conflict"])))
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"Dotfile deployment failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
