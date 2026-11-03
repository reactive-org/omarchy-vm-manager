"""Nonpublishing signer adapter. No CLI, credential importer or network fetcher.

An explicit runner is required. The system runner refuses all work without a
trusted in-memory execution authorization; tests inject a fake command runner.
Neither authorization nor build metadata is an application/guest approval loader.
"""
from dataclasses import dataclass
import io
import os
from pathlib import Path
import plistlib
import re
import shlex
import signal
import subprocess
import sys
import tarfile
import tempfile

import private_provisioning_package as private

TOOLS = {"git": "/usr/bin/git", "make": "/usr/bin/make", "swift": "/usr/bin/swift",
         "codesign": "/usr/bin/codesign", "security": "/usr/bin/security",
         "python": str(Path(sys.executable).resolve())}
MACHO = {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"}
OLD_INSPECTION = '''        var signatureRefused = false
        do { _ = try ProvisioningHelperLaunchAdmission(layout: layout, policy: .sameApplicationTeam) }
        catch ProvisioningHelperIPCFailure.authentication { signatureRefused = true }
        guard signatureRefused else { throw ProvisioningJobFailure.invalidRequest }
'''
NEW_INSPECTION = '''        let productionSigningAdmission: String
        #if SIGNED_PRERELEASE
        _ = try ProvisioningHelperLaunchAdmission(layout: layout, policy: .sameApplicationTeam)
        productionSigningAdmission = "PASSED_STATIC_SAME_TEAM"
        #else
''' + OLD_INSPECTION + '''        productionSigningAdmission = "BLOCKED_EXPECTED_AD_HOC"
        #endif
'''


@dataclass(frozen=True, repr=False)
class Material:
    team: str
    identity: str
    profile: Path
    keychain: Path
    signed_runtime: Path
    upstream: Path
    parser_checkout: Path

    def __repr__(self): return "PrivateSigningMaterial(redacted)"

    def binding(self):
        return private.digest(private.canonical({k: str(v) for k, v in vars(self).items()}))


@dataclass(frozen=True, repr=False)
class Command:
    stage: str
    effect: str
    argv: tuple
    cwd: Path
    environment: dict
    requestSHA256: str
    scopeSHA256: str
    materialSHA256: str
    timeout: int = 120
    maximum: int = 2 * 1024 * 1024

    def __repr__(self): return "PrivateSigningCommand(redacted)"


@dataclass(frozen=True, repr=False)
class Result:
    returncode: int = 0
    stdout: bytes = b""
    stderr: bytes = b""

    def __repr__(self): return "PrivateSigningResult(redacted)"


@dataclass(frozen=True, repr=False)
class ExecutionAuthorization:
    """Trusted caller composition after human approval; never decoded from input.

    Signing includes secure timestamp requests in the sign-with-timestamp effect.
    No notarization/submission/publishing effect is supported.
    This object cannot grant provisioning, guest or macOS permission authority.
    """
    requestSHA256: str
    scopeSHA256: str
    materialSHA256: str
    effects: frozenset

    def __repr__(self): return "PrivateSigningExecutionAuthorization(redacted)"


class SystemRunner:
    test_double = False

    def __init__(self, authorization=None): self.authorization = authorization

    def authorize(self, request, scope, material):
        a = self.authorization
        private.require(isinstance(a, ExecutionAuthorization)
                        and (a.requestSHA256, a.scopeSHA256, a.materialSHA256) == (request, scope, material),
                        "private-signing-execution-not-authorized")

    def run(self, command):
        self.authorize(command.requestSHA256, command.scopeSHA256, command.materialSHA256)
        private.require(command.effect in self.authorization.effects
                        and command.effect in {"build", "inspect", "sign-with-timestamp"},
                        "private-signing-effect-not-authorized")
        private.require(0 < command.timeout <= 1200 and 0 < command.maximum <= 2*1024*1024)
        program, arguments = command.argv[0], command.argv[1:]
        if program == TOOLS["security"]:
            private.require(arguments[:3] == ("cms", "-D", "-i"))
        elif program == TOOLS["codesign"]:
            private.require(arguments[0] in ("--verify", "--display", "--force"))
            if arguments[0] == "--force":
                private.require(command.effect == "sign-with-timestamp" and "--keychain" in arguments
                                and "--timestamp" in arguments and "--options" in arguments)
        elif program == TOOLS["git"]:
            private.require(command.effect in ("build", "inspect"))
        elif program in (TOOLS["make"], TOOLS["swift"], TOOLS["python"]):
            private.require(command.effect in ("build", "inspect"))
        else:
            # Only the built app's fixed offline diagnostics may execute here.
            private.require(program.endswith("/Contents/MacOS/OmarchyVMManager")
                            and arguments == ("--verify-bundle-json",) and command.effect == "inspect")
        # Anonymous private files avoid unbounded memory capture and raw logs.
        # Own the process group through timeout/interruption. Failed jobs are
        # private and never automatically replayed.
        with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as error:
            process = None
            try:
                process = subprocess.Popen(command.argv, cwd=command.cwd, env=command.environment,
                                           stdin=subprocess.DEVNULL, stdout=output, stderr=error,
                                           start_new_session=True)
                process.wait(timeout=command.timeout)
            except BaseException:
                if process is not None:
                    try: os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError: pass
                    process.wait()
                raise private.Refused("private-command-failed") from None
            output.seek(0); error.seek(0)
            stdout, stderr = output.read(command.maximum+1), error.read(command.maximum+1)
        private.require(len(stdout) <= command.maximum and len(stderr) <= command.maximum,
                        "private-command-output-too-large")
        return Result(process.returncode, stdout, stderr)


def _extract_source(raw, destination):
    private.archive_profile_pin(raw)  # Bounded names/types, no links/disks/duplicates.
    destination.mkdir(mode=0o700)
    with tarfile.open(fileobj=io.BytesIO(raw), mode="r:") as archive:
        for entry in archive:
            name = entry.name.rstrip("/"); private.relative(name)
            path = destination / name
            if entry.isdir(): path.mkdir(parents=True, exist_ok=True, mode=0o700)
            else:
                path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                private.write(path, archive.extractfile(entry).read(), executable=bool(entry.mode & 0o111))


def _macho_paths(folder):
    return {name for name in private.tree(folder) if private.read(folder / name)[:4] in MACHO}


def _signature_fields(result):
    text = (result.stdout + result.stderr).decode("utf-8", "strict")
    lines = text.splitlines()
    fields = {}
    for line in lines:
        if line.startswith("CodeDirectory "): fields["CodeDirectory"] = line
        if "=" in line:
            key, value = line.split("=", 1)
            if key in {"Authority", "TeamIdentifier", "Timestamp", "Signature", "CDHash"}:
                fields.setdefault(key, value)  # The leaf Authority precedes its chain.
    return fields


def _guard_signature(fields, team):
    private.require(fields.get("TeamIdentifier") == team and fields.get("Signature") != "adhoc"
                    and fields.get("Authority", "").startswith("Developer ID Application: ")
                    and re.search(r"flags=0x[0-9a-f]+\([^)]*\bruntime\b", fields.get("CodeDirectory", ""))
                    and fields.get("Timestamp") and re.fullmatch("[0-9a-f]{40,64}", fields.get("CDHash", "")),
                    "private-signature-requirements-failed")


class Adapter:
    """Actual command adapter with mandatory injected runner; no publication API.

    Runtime signing stays with the upstream kit pipeline. This adapter consumes a
    local signed-runtime artifact with the exact reviewed development-kit origin;
    it never downloads, rebuilds QEMU, imports keys or changes a keychain search list.
    """
    def __init__(self, runner, material):
        self.runner, self.material = runner, material
        self.events = []

    def _call(self, stage, effect, argv, cwd=None, timeout=120):
        self.events.append(stage)
        private.load_handoff(self.handoff, self.expected)
        spec = Command(stage, effect, tuple(map(str, argv)), cwd or self.work, dict(self.environment),
                       self.expected, self.request["scopeSHA256"], self.material.binding(), timeout)
        try:
            result = self.runner.run(spec)
            private.require(type(result.returncode) is int and result.returncode == 0
                            and isinstance(result.stdout, bytes) and isinstance(result.stderr, bytes)
                            and len(result.stdout) <= spec.maximum and len(result.stderr) <= spec.maximum,
                            "private-command-failed")
        except Exception:
            raise private.Refused("private-command-failed") from None
        private.load_handoff(self.handoff, self.expected)
        return result

    def _git(self, stage, directory, *args):
        return self._call(stage, "build", [TOOLS["git"], "-c", "core.fsmonitor=false",
                         "-c", "core.hooksPath=/dev/null", "-C", directory, *args])

    def _validate_material(self):
        m = self.material
        private.require(re.fullmatch("[A-Z0-9]{10}", m.team)
                        and m.identity.startswith("Developer ID Application: ")
                        and m.identity.endswith("(" + m.team + ")")
                        and not any(ord(c) < 32 for c in m.identity), "invalid-private-signing-material")
        for path in (m.profile, m.keychain, m.signed_runtime, m.upstream, m.parser_checkout):
            private.require(path.is_absolute() and path.resolve() == path, "linked-signing-material-refused")
        private.private_directory(m.profile.parent); private.private_directory(m.keychain.parent)
        key = m.keychain.lstat()
        import stat
        private.require(stat.S_ISREG(key.st_mode) and key.st_uid == os.getuid()
                        and stat.S_IMODE(key.st_mode) == 0o600 and key.st_nlink == 1,
                        "unsafe-explicit-keychain")
        # Keychain bytes are never read here. The caller supplies an already
        # unlocked isolated keychain after separate signing authorization.
        raw = private.read(m.profile, 1024*1024)
        private.require(private.digest(raw) == self.request["profileSHA256"], "profile-binding-changed")
        self.profile = self.work / "profile.provisionprofile"; private.write(self.profile, raw)
        result = self._call("decode-pinned-profile", "inspect", [TOOLS["security"], "cms", "-D", "-i", self.profile])
        self.decoded_profile = plistlib.loads(result.stdout)
        self.entitlements = private.keychain_profile.profile_entitlements(self.decoded_profile, m.team, private.BUNDLE_ID)
        self.profile_raw = raw

    def _runtime(self):
        m = self.material
        private.private_directory(m.signed_runtime)
        raw = private.read(m.signed_runtime / "TryOmarchySignedRuntime.lock.json", 65536)
        signed = private.decode(raw)
        original_raw = private.read(self.handoff / "inputs/Config/TryOmarchyRuntime.lock.json", 65536)
        original = private.decode(original_raw)
        private.validate_signed_lock(signed, original, private.digest(original_raw), m.team)
        require_archive = private.read(m.signed_runtime / "TryOmarchyKit.zip")
        private.require(private.digest(require_archive) == signed["kitSHA256"], "signed-runtime-archive-changed")
        source = self.handoff / "inputs/TryOmarchyKit.bundle"
        private.validate_payload(original["files"], signed["files"], _macho_paths(source))
        self.runtime = self.work / "runtime"; self.runtime.mkdir(mode=0o700)
        private.copy_tree(m.signed_runtime / "TryOmarchyKit.bundle", self.runtime / "TryOmarchyKit.bundle", signed["files"])
        self.runtime_raw, self.runtime_lock = raw, signed
        self.runtime_path = self.runtime / "TryOmarchySignedRuntime.lock.json"
        private.write(self.runtime_path, raw)
        self.original_raw = original_raw

    def _reconstruct(self):
        inputs = self.handoff / "inputs"
        self.source = self.work / "source"
        _extract_source(private.read(inputs / "base-source.tar"), self.source)
        evidence = private.decode(private.read(inputs / "source-evidence.json", 65536))
        for item in evidence["overlayFiles"]:
            name = item["path"]; private.relative(name)
            if item["beforeSHA256"] is not None:
                private.require(private.digest(private.read(self.source / name)) == item["beforeSHA256"], "source-base-changed")
        patch = inputs / "candidate-overlay.patch"
        self._call("check-original-overlay", "build", [TOOLS["git"], "apply", "--check", patch], cwd=self.source)
        self._call("apply-original-overlay", "build", [TOOLS["git"], "apply", patch], cwd=self.source)
        for item in evidence["overlayFiles"]:
            private.require(private.digest(private.read(self.source / item["path"])) == item["afterSHA256"], "source-overlay-changed")
        literal = self.source / "Sources/OmarchyVMManagerCore/PrivateM6Acceptance.swift"
        text = private.read(literal).decode()
        scope = private.decode(private.read(inputs / "scope.json", 65536))
        for key in ("vmID", "root", "device", "inode", "markerSHA256", "scopeSHA256"):
            private.require(str(scope[key]) in text, "original-scope-not-in-source")
        before_scope = text.split("public enum PrivateM6CandidateInspection", 1)[0]
        private.require("fatalError(" in before_scope and "return nil" not in before_scope)
        private.require(text.count(OLD_INSPECTION) == 1
                        and text.count('"productionSigningAdmission": "BLOCKED_EXPECTED_AD_HOC"') == 1,
                        "unsupported-private-inspection-source")
        text = text.replace(OLD_INSPECTION, NEW_INSPECTION).replace(
            '"productionSigningAdmission": "BLOCKED_EXPECTED_AD_HOC"',
            '"productionSigningAdmission": productionSigningAdmission')
        private.require(text.split("public enum PrivateM6CandidateInspection", 1)[0] == before_scope,
                        "scope-definition-changed")
        literal.write_text(text)
        core = self.source / "Sources/OmarchyVMManagerCore"
        (core / "RuntimePin.swift").write_text('public enum RuntimePin {\n    public static let lockSHA256 = "' + private.digest(self.runtime_raw) + '"\n}\n')
        values = {"signingTeamID": self.material.team,
                  "sourceKitSHA256": self.runtime_lock["sourceKitSHA256"],
                  "sourceLockSHA256": self.runtime_lock["sourceLockSHA256"]}
        (core / "SignedBuildPin.swift").write_text('enum SignedBuildPin {\n' + ''.join(
            '    static let ' + key + ' = "' + value + '"\n' for key, value in values.items()) + '}\n')
        self.source_inventory = private.tree(self.source)
        self.scope_prefix = before_scope
        self.scope_source = literal

    def _check_source(self):
        current = {}
        for path in self.source.iterdir():
            if path.name == ".build": continue
            if path.is_dir() and not path.is_symlink():
                current.update({path.name + "/" + name: sha for name, sha in private.tree(path).items()})
            else: current[path.name] = private.digest(private.read(path))
        private.require(current == self.source_inventory, "build-source-changed")
        private.require(private.read(self.scope_source).decode().split("public enum PrivateM6CandidateInspection", 1)[0]
                        == self.scope_prefix, "original-scope-definition-changed")

    def _local_dependencies(self):
        patch = private.decode(private.read(self.source / "Config/TryOmarchyClipboardPatch.json", 65536))
        private.require(patch["commit"] == self.runtime_lock["patchCommit"])
        resolved = private.decode(private.read(self.source / "Package.resolved", 65536))
        parser = [p for p in resolved["pins"] if p["identity"] == "tomldecoder"]
        private.require(len(parser) == 1)
        commits = {"client": patch["commit"], "parser": parser[0]["state"]["revision"]}
        dependencies = self.work / "dependencies"; dependencies.mkdir(mode=0o700)
        for label, origin in (("client", self.material.upstream), ("parser", self.material.parser_checkout)):
            expected = commits[label]; private.require(re.fullmatch("[0-9a-f]{40}", expected))
            head = self._git("check-local-" + label, origin, "rev-parse", "HEAD").stdout.decode().strip()
            clean = self._git("check-clean-" + label, origin, "status", "--porcelain=v1", "--untracked-files=all").stdout
            private.require(head == expected and not clean, "local-dependency-changed")
            destination = dependencies / label
            self._call("copy-local-" + label, "build", [TOOLS["git"], "-c", "core.hooksPath=/dev/null", "clone",
                       "--local", "--no-hardlinks", "--no-checkout", "--", origin, destination])
            self._git("checkout-local-" + label, destination, "checkout", "--detach", expected)
            head = self._git("verify-local-" + label, destination, "rev-parse", "HEAD").stdout.decode().strip()
            private.require(head == expected, "local-dependency-changed")
        self.upstream = dependencies / "client"
        build = self.source / ".build"; build.mkdir(mode=0o700, exist_ok=True)
        (build / "runtime-source").symlink_to(self.upstream, target_is_directory=True)
        checkouts = build / "checkouts"; checkouts.mkdir(mode=0o700)
        (dependencies / "parser").rename(checkouts / "TOMLDecoder")
        self.dependency_checkouts = (("client", self.upstream, commits["client"]),
                                    ("parser", checkouts / "TOMLDecoder", commits["parser"]))
        # SwiftPM's pinned existing-workspace representation; no resolution/fetch.
        refs = []
        for identity, name, path in (("dev-vm", "DevVMProvisioning", self.source / "Vendor/dev-vm"),
                                     ("macos", "OmarchyVMHelper", build / "runtime-source/macos"),
                                     ("swiftterm", "SwiftTerm", self.source / "Vendor/SwiftTerm")):
            refs.append({"basedOn": None, "packageRef": {"identity": identity, "kind": "fileSystem", "location": str(path), "name": name},
                         "state": {"name": "fileSystem", "path": str(path)}, "subpath": identity})
        refs.append({"basedOn": None, "packageRef": {"identity": "tomldecoder", "kind": "remoteSourceControl",
                     "location": parser[0]["location"], "name": "TOMLDecoder"},
                     "state": {"name": "sourceControlCheckout", "checkoutState": {"revision": commits["parser"]}}, "subpath": "TOMLDecoder"})
        private.write_json(build / "workspace-state.json", {"version": 7, "object": {"artifacts": [], "dependencies": refs, "prebuilts": []}})
        self._call("prepare-pinned-provisioning-source", "build", [TOOLS["python"], self.source / "Scripts/provisioning_package.py"], cwd=self.source)
        self._check_source()
        self._call("verify-local-runtime-signatures", "inspect", [TOOLS["python"], self.upstream / "scripts/kit_signature.py",
                   "verify", "--signature-only", "--team", self.material.team, self.runtime / "TryOmarchyKit.bundle"])

    def _flags(self):
        flags = ["--disable-sandbox", "--skip-update", "--disable-automatic-resolution",
                 "--cache-path", str(self.source / ".build/swiftpm-cache"), "--config-path", str(self.source / ".build/swiftpm-configuration"),
                 "--security-path", str(self.source / ".build/swiftpm-security")]
        return flags

    def _check_dependencies(self, stage):
        for label, folder, expected in self.dependency_checkouts:
            head = self._git(stage + "-revision-" + label, folder, "rev-parse", "HEAD").stdout.decode().strip()
            clean = self._git(stage + "-clean-" + label, folder, "status", "--porcelain=v1", "--untracked-files=all").stdout
            private.require(head == expected and not clean, "private-dependency-changed")

    def _build(self):
        # Skip only the global-source preparation recipe; exact local dependencies
        # and package pins have just been installed/verified in this private tree.
        self._check_dependencies("before-build")
        flags = " ".join(shlex.quote(s) for s in self._flags()).replace("$", "$$")
        self._call("build-scoped-signed-prerelease", "build", [TOOLS["make"], "-o", "prepare-source", "build-signed",
                   "SWIFT_FLAGS=" + flags], cwd=self.source, timeout=1200)
        self._check_source()
        self._check_dependencies("after-build")
        result = self._call("locate-built-binaries", "build", [TOOLS["swift"], "build", *self._flags(), "-c", "release", "--show-bin-path"], cwd=self.source)
        self.binaries = Path(result.stdout.decode().strip()).resolve()
        private.require((self.source / ".build").resolve() in self.binaries.parents, "unexpected-build-location")
        launcher_source = self.source / ".build/provisioning-launcher-source"
        result = self._call("locate-built-launcher", "build", [TOOLS["swift"], "build", *self._flags(), "--package-path", launcher_source,
                            "--scratch-path", self.source / ".build/provisioning-launcher", "-c", "release", "--show-bin-path"], cwd=self.source)
        self.launcher = Path(result.stdout.decode().strip()).resolve()
        private.require((self.source / ".build/provisioning-launcher").resolve() in self.launcher.parents, "unexpected-build-location")
        for name in (private.MAIN, "OmarchyVMProvisioningHelper"):
            binary = private.read(self.binaries / name)
            private.require(binary[:4] in MACHO and self.request["scopeSHA256"].encode() in binary,
                            "compiled-scope-marker-missing")

    def _assemble(self):
        self.app = self.work / "Private Candidate.app"
        contents = self.app / "Contents"
        for name in ("MacOS", "Resources", "Helpers"): (contents / name).mkdir(parents=True, mode=0o700)
        for name in (private.MAIN, *private.CHILDREN):
            source = (self.launcher if name == "dev-vm-process-host" else self.binaries) / name
            private.require(private.read(source)[:4] in MACHO, "unexpected-build-binary")
            private.write(contents / "MacOS" / name, private.read(source), executable=True)
        core = "OmarchyVMManager_OmarchyVMManagerCore.bundle"
        private.copy_tree(self.binaries / core, contents / "Resources" / core, private.tree(self.binaries / core))
        private.copy_tree(self.binaries / private.package.BUNDLE, contents / "Resources" / private.package.BUNDLE,
                          private.tree(self.handoff / "inputs" / private.package.BUNDLE))
        private.copy_tree(self.runtime / "TryOmarchyKit.bundle", contents / "Helpers/TryOmarchyKit.bundle", self.runtime_lock["files"])
        for name, data in (("DevVMProvisioning.lock.json", private.read(self.handoff / "inputs/Config/DevVMProvisioning.lock.json")),
                           ("TryOmarchyRuntime.lock.json", self.runtime_raw)):
            private.write(contents / "Resources" / name, data)
        info = plistlib.loads(private.read(self.source / "App/Info.plist", 65536))
        private.require(info["CFBundleIdentifier"] == private.BUNDLE_ID and info["CFBundleExecutable"] == private.MAIN)
        private.write(contents / "Info.plist", plistlib.dumps(info))
        for stem in ("OmarchyVMManager", "OmarchyGuest"):
            for ext in ("icns", "png"):
                private.write(contents / "Resources" / (stem + "." + ext), private.read(self.source / "App/Assets" / (stem + "." + ext)))
        for name in ("LICENSE", "THIRD_PARTY_NOTICES.md"):
            private.write(contents / "Resources" / name, private.read(self.source / name))
        private.write(contents / "Resources/TryOmarchy-THIRD_PARTY_NOTICES.md", private.read(self.upstream / "THIRD_PARTY_NOTICES.md"))
        private.write(contents / "embedded.provisionprofile", self.profile_raw)
        entitlements = plistlib.loads(private.read(self.source / "App/OmarchyVMManager.entitlements", 65536))
        private.require(not {"get-task-allow", "com.apple.security.get-task-allow", "keychain-access-groups"}.intersection(entitlements))
        entitlements.update(self.entitlements)
        self.entitlements_path = self.work / "manager.entitlements.plist"
        private.write(self.entitlements_path, plistlib.dumps(entitlements))
        self.manager_entitlements = entitlements

    def _sign(self):
        base = [TOOLS["codesign"], "--force", "--sign", self.material.identity, "--keychain", self.material.keychain,
                "--options", "runtime", "--timestamp"]
        for name in private.CHILDREN:
            identifier = {"OmarchyVMStorageHelper": "dev.omarchy.vm-manager.storage", "omarchy-vm": "dev.omarchy.vm-manager.cli"}.get(name, "dev.omarchy.vm-manager." + name)
            self._call("sign-child-" + name, "sign-with-timestamp", [*base, "--identifier", identifier, self.app / "Contents/MacOS" / name])
        private.package.seal(self.app / "Contents", root=self.handoff / "inputs")
        self.events.append("seal-post-sign-helper-digests")
        before = private.tree(self.app)
        self._call("sign-outer-app", "sign-with-timestamp", [*base, "--identifier", private.BUNDLE_ID,
                   "--entitlements", self.entitlements_path, self.app])
        after = private.tree(self.app)
        changed = {p for p in before.keys() | after.keys() if before.get(p) != after.get(p)}
        private.require(changed <= {"Contents/MacOS/OmarchyVMManager", "Contents/_CodeSignature/CodeResources"},
                        "outer-signing-changed-private-payload")

    def _verify(self, app, stage):
        before = private.tree(app)
        for name in (private.MAIN, "OmarchyVMProvisioningHelper"):
            private.require(self.request["scopeSHA256"].encode() in private.read(app / "Contents/MacOS" / name),
                            "signed-scope-marker-missing")
        private.package.verify(app / "Contents", root=self.handoff / "inputs")
        private.require(private.tree(app / "Contents/Helpers/TryOmarchyKit.bundle") == self.runtime_lock["files"]
                        and private.read(app / "Contents/Resources/TryOmarchyRuntime.lock.json") == self.runtime_raw
                        and private.read(app / "Contents/embedded.provisionprofile") == self.profile_raw,
                        "private-runtime-or-profile-changed")
        self._call(stage + "-deep-signatures", "inspect", [TOOLS["codesign"], "--verify", "--deep", "--strict", app])
        identities = {}
        for name, target in [("app", app)] + [(n, app / "Contents/MacOS" / n) for n in (private.MAIN, *private.CHILDREN)]:
            details = self._call(stage + "-signature-" + name, "inspect", [TOOLS["codesign"], "--display", "--verbose=4", target])
            fields = _signature_fields(details); _guard_signature(fields, self.material.team)
            self._call(stage + "-validity-" + name, "inspect", [TOOLS["codesign"], "--verify", "--strict", target])
            raw = self._call(stage + "-entitlements-" + name, "inspect", [TOOLS["codesign"], "--display", "--entitlements", ":-", target]).stdout
            actual = plistlib.loads(raw) if raw.strip() else {}
            expected = self.manager_entitlements if name in ("app", private.MAIN) else {}
            private.require(actual == expected, "private-signature-entitlements-changed")
            identities[name] = fields["CDHash"]
        prefix = self.work / (stage + "-public-certificate-")
        self._call(stage + "-profile-certificate", "inspect", [TOOLS["codesign"], "--display", "--extract-certificates=" + str(prefix), app])
        private.require(private.read(Path(str(prefix) + "0"), 1024*1024) in self.decoded_profile["DeveloperCertificates"],
                        "profile-does-not-authorize-signing-certificate")
        diagnostic = self._call(stage + "-offline-bundle-contract", "inspect", [app / "Contents/MacOS/OmarchyVMManager", "--verify-bundle-json"])
        data = private.decode(diagnostic.stdout)
        private.require(data["touchIDProtectedStorageAvailable"] is True and data["developmentKeychainCompatibility"] is False
                        and data["hostPreflightPerformed"] is False and data["vmLaunchEnabled"] is False,
                        "signed-build-diagnostic-contract-failed")
        private.require(private.tree(app) == before, "private-verification-mutated-app")
        self._check_source()
        self._check_dependencies(stage)
        return identities

    def run(self, handoff, output, expected):
        private.private_context()
        self.handoff, self.expected = Path(handoff), expected
        self.request = private.load_handoff(self.handoff, expected)
        # Mandatory before reading any profile/keychain material or creating jobs.
        self.runner.authorize(expected, self.request["scopeSHA256"], self.material.binding())
        private.require(type(self.runner.test_double) is bool)
        private.require(self.runner.test_double or not self.request["simulationFixture"], "synthetic-request-cannot-be-signed")
        private.require(re.fullmatch(r"[A-Za-z0-9 /_.-]+", str(Path(output).absolute())), "unsafe-private-build-path")
        self.work = private.new_directory(output, self.handoff)
        home = self.work / "home"; home.mkdir(mode=0o700)
        self.environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(home), "TMPDIR": str(self.work),
                            "LC_ALL": "C", "LANG": "C", "MACOSX_DEPLOYMENT_TARGET": "15.0",
                            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0",
                            "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1"}
        try:
            self._validate_material(); self._runtime(); self._reconstruct(); self._local_dependencies(); self._build(); self._assemble(); self._sign()
            first = self._verify(self.app, "staged")
            archive = self.work / ("PROCESS-RUNNER-TEST-ONLY.zip" if self.runner.test_double else "Private-Candidate-SIGNED-NOT-NOTARIZED.zip")
            private.archive_local(self.app, archive)
            archive_sha = private.digest(private.read(archive))
            self.events.append("archive-private-only")
            private.extract_local(archive, self.work / "roundtrip")
            extracted = self.work / "roundtrip" / self.app.name
            private.require(private.tree(extracted) == private.tree(self.app), "private-archive-changed")
            second = self._verify(extracted, "roundtrip")
            private.require(first == second and private.digest(private.read(archive)) == archive_sha, "private-archive-identity-changed")
            result = {"format": 1, "status": "FAKE_RUNNER_ONLY" if self.runner.test_double else "SIGNED_STATIC_CHECKS_ONLY",
                      "handoffSHA256": expected, "scopeSHA256": self.request["scopeSHA256"],
                      "sourceProjection": self.source_inventory, "identities": first, "archiveSHA256": archive_sha,
                      "processRunnerTestDouble": self.runner.test_double, "productionCryptographyObserved": not self.runner.test_double,
                      "notarization": "NOT_REQUESTED_NOT_ESTABLISHED", "localScopeValidation": "PENDING_ORIGINAL_MAC",
                      "loadedChildAdmission": "NOT_RUN", "guestRunAuthorized": False, "publication": "forbidden", "events": self.events}
            private.write_json(self.work / "signer-result.json", result)
            return result
        except Exception:
            try:
                private.write_json(self.work / "failure.json", {"status": "PRIVATE_SIGNER_FAILED_OUTPUT_PRESERVED", "events": self.events,
                                                                "publication": "forbidden", "guestRunAuthorized": False,
                                                                "originalMacValidation": "NOT_RUN", "automaticRetry": False})
            except OSError:
                pass  # Failure-record IO must not expose backend or private paths.
            raise private.Refused("private-signer-adapter-failed") from None


if __name__ == "__main__":
    raise SystemExit("No signing CLI. Explicit private authorization and a runner are required.")
