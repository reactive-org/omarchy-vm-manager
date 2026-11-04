"""Versioned offline inspection orchestration. No native APIs/processes selected.

The injected worker facade/factory is the platform boundary. This module never
uses the upstream verifier, executes runtime code, opens keychain contents, or
loads an authorization from a packet, environment variable or CLI.
"""
from dataclasses import dataclass, asdict, replace
from pathlib import Path
import plistlib
import re
import threading
import time

import private_provisioning_package as private
from private_provisioning_inputs import ReviewedSourceInputs, SourceInputAdmission, _archive_files
from private_provisioning_materials import MaterialSelection, _stamp_keychain
from offline_inspection_runner import Runner
from offline_inspection_worker import task, blob, unblob, signed_content, STATIC_FLAGS, CHECK_NESTED

IMPLEMENTATION_FILES = ("private_provisioning_offline.py", "offline_inspection_runner.py", "offline_inspection_worker.py",
                        "private_provisioning_inputs.py", "private_provisioning_materials.py", "private_provisioning_signer.py",
                        "private_provisioning_package.py", "provisioning_package.py", "keychain_profile.py",
                        "signed_prerelease.py", "fetch_runtime_kit.py")
MACHO = {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"}
HELPER_ENTITLEMENTS = "macos/omarchy-vm-helper.entitlements"
QEMU_ENTITLEMENTS = "macos/qemu-hvf.entitlements"


def implementation_digest():
    root = Path(__file__).resolve().parent
    return private.digest(private.canonical({name: private.digest(private.read(root / name, 1024 * 1024)) for name in IMPLEMENTATION_FILES}))


@dataclass(frozen=True, repr=False)
class OfflineReview:
    sourceRequestSHA256: str
    selectionSHA256: str
    publicCertificateSHA256: str
    implementationSHA256: str
    helperEntitlementsSHA256: str
    qemuEntitlementsSHA256: str
    output: Path

    def __post_init__(self):
        private.require(all(private.sha256(getattr(self, name)) for name in vars(self) if name != "output"), "offline-review-digests")
        private.require(isinstance(self.output, Path) and self.output.is_absolute(), "offline-private-output-required")

    def __repr__(self): return "OfflineInspectionReviewV1(redacted)"

    def request_digest(self):
        fields = asdict(self); fields["output"] = str(self.output)
        return private.digest(private.canonical({"offlineNativeInspectionVersion": 1, "review": fields}))


def static_targets(bundle):
    inventory = private.tree(bundle)  # <= 4096 files/1 GiB, no linked/writable payloads.
    return [bundle / name for name in sorted(inventory) if private.read(bundle / name)[:4] in MACHO]


class OfflineInspectionCaller:
    def __init__(self, source_review, selection, review, runner=None, wall_clock=time.time):
        private.require(type(source_review) is ReviewedSourceInputs and type(selection) is MaterialSelection
                        and type(review) is OfflineReview, "typed-offline-review-required")
        self.source_review, self.selection, self.review = source_review, selection, review
        self.runner = runner if runner is not None else Runner()
        self.wall_clock = wall_clock
        self._lock = threading.Lock(); self._used = False
        self.events = []

    def __repr__(self): return "OneShotOfflineInspectionCaller(redacted)"

    def _check(self):
        self.runner.check(self.cancel)
        private.require(implementation_digest() == self.review.implementationSHA256, "offline-implementation-changed")
        self.admission.revalidate()
        private.require(_stamp_keychain(self.selection.material.keychain) == self.keychain_stamp, "offline-keychain-replaced")
        for path, digest in self.frozen.items():
            private.require(private.digest(private.read(path, 1024 * 1024)) == digest, "offline-input-changed")
        self.runner.check(self.cancel)

    def _call(self, stage, spec):
        self.events.append(stage)
        return self.runner.run(spec, self._check, self.cancel)

    def _dependencies(self, stage):
        for name, (path, revision) in self.dependencies.items():
            value = self._call(stage + "-" + name, task("dependency", path=str(path)))
            private.require(set(value) == {"revision", "clean"} and value["revision"] == revision
                            and value["clean"] is True, "offline-source-state-changed")

    def _locked(self, stage):
        value = self._call(stage, task("locked", path=str(self.selection.material.keychain)))
        private.require(value == {"locked": True} and type(value["locked"]) is bool, "offline-keychain-not-locked")

    def run(self, folder, cancel=None):
        with self._lock:
            private.require(not self._used, "offline-caller-already-used"); self._used = True
        self.cancel = cancel
        try: return self._run(folder)
        except BaseException:
            if hasattr(self, "work"):
                try:
                    private.write_json(self.work / "failure.json", {"status": "OFFLINE_INSPECTION_FAILED_OUTPUT_PRESERVED",
                        "events": self.events, "cleanupConfirmed": self.runner.cleanup_confirmed,
                        "automaticRetry": False, "signingAuthorized": False, "guestRunAuthorized": False})
                except OSError: pass
            raise private.Refused("offline-inspection-refused") from None

    def _run(self, folder):
        m = self.selection.material
        private.require(self.review.sourceRequestSHA256 == self.source_review.request_digest()
                        and self.review.selectionSHA256 == self.selection.binding(), "offline-review-binding-changed")
        private.require(m.team == self.source_review.signingTeamID and m.signed_runtime == Path(folder) / "runtime"
                        and isinstance(m.identity, str) and m.identity.startswith("Developer ID Application: ")
                        and m.identity.endswith("(" + m.team + ")") and not any(ord(c) < 32 for c in m.identity), "offline-selector-mismatch")
        bindings = (self.review.request_digest(), self.source_review.scopeSHA256, self.selection.binding(), self.review.implementationSHA256)
        # This precedes profile/certificate/keychain metadata IO or output creation.
        self.runner.authorize(*bindings)
        private.require(self.runner.test_double or not self.source_review.fixture, "offline-fixture-cannot-run-native")
        self.runner.start(bindings)
        self.runner.check(self.cancel)
        self.admission = SourceInputAdmission.open(folder, self.source_review)
        request = self.admission.revalidate()
        self.runner.check(self.cancel)
        private.require(implementation_digest() == self.review.implementationSHA256, "offline-implementation-changed")
        for path in (m.profile, m.keychain, m.signed_runtime, m.upstream, m.parser_checkout, self.selection.public_certificate):
            parts = tuple(part.casefold() for part in Path(path).parts)
            private.require(not any(parts[i:i + 2] == ("omarchy vm manager", "vms") for i in range(len(parts) - 1)), "offline-guest-path-refused")
            private.require(isinstance(path, Path) and path.is_absolute() and path.resolve() == path, "offline-linked-material")
        self.keychain_stamp = _stamp_keychain(m.keychain)
        self.frozen = {m.profile: request["profileSHA256"], self.selection.public_certificate: self.review.publicCertificateSHA256,
                       m.upstream / HELPER_ENTITLEMENTS: self.review.helperEntitlementsSHA256,
                       m.upstream / QEMU_ENTITLEMENTS: self.review.qemuEntitlementsSHA256}
        self._check()
        # Reject unsafe CMS before any API worker is launched, not just in worker.
        signed_content(private.read(m.profile, 1024 * 1024))
        private.require(re.fullmatch(r"[A-Za-z0-9 /_.-]+", str(self.review.output)), "offline-output-path")
        self.work = private.new_directory(self.review.output, self.admission.folder)
        profile = self.work / "manager.provisionprofile"; certificate = self.work / "public-certificate.der"
        private.write(profile, private.read(m.profile, 1024 * 1024))
        private.write(certificate, private.read(self.selection.public_certificate, 1024 * 1024))
        self.frozen.update({profile: request["profileSHA256"], certificate: self.review.publicCertificateSHA256})
        files = _archive_files(private.read(self.admission.folder / "inputs/base-source.tar"))
        revision = private.decode(files["Config/TryOmarchyClipboardPatch.json"])["commit"]
        parser = [pin for pin in private.decode(files["Package.resolved"])["pins"] if pin["identity"] == "tomldecoder"]
        private.require(len(parser) == 1)
        self.dependencies = {"upstream": (m.upstream, revision), "parser": (m.parser_checkout, parser[0]["state"]["revision"])}
        self._dependencies("before"); self._locked("locked-before")
        encoded = self._call("profile-content", task("profile", content=blob(private.read(profile, 1024 * 1024))))
        private.require(set(encoded) == {"content"}, "offline-profile-response")
        content = unblob(encoded["content"])
        private.require(content == signed_content(private.read(profile, 1024 * 1024)), "offline-profile-content-changed")
        decoded = plistlib.loads(content)
        entitlements = private.keychain_profile.profile_entitlements(decoded, m.team, private.BUNDLE_ID)
        private.require(private.read(certificate, 1024 * 1024) in decoded["DeveloperCertificates"], "offline-profile-leaf-mismatch")
        leaf = self._call("public-certificate", task("certificate", content=blob(private.read(certificate, 1024 * 1024))))
        private.require(set(leaf) == {"commonName", "notBefore", "notAfter"} and leaf["commonName"] == m.identity
                        and leaf["notBefore"] <= self.wall_clock() < leaf["notAfter"], "offline-certificate-selector-or-expiry")
        expected_helper = plistlib.loads(private.read(m.upstream / HELPER_ENTITLEMENTS, 1024 * 1024))
        expected_qemu = plistlib.loads(private.read(m.upstream / QEMU_ENTITLEMENTS, 1024 * 1024))
        private.require(type(expected_helper) is dict and type(expected_qemu) is dict)
        bundle = m.signed_runtime / "TryOmarchyKit.bundle"
        targets = static_targets(bundle)
        private.require(bundle / "Contents/MacOS/omarchy-vm-helper" in targets, "offline-runtime-helper-missing")
        for path in targets + [bundle]:
            expected = expected_helper if path in (bundle, bundle / "Contents/MacOS/omarchy-vm-helper") else (
                expected_qemu if path == bundle / "Contents/Resources/runtime/bin/Try Omarchy" else {})
            value = self._call("static-code", task("static", path=str(path), team=m.team, nested=path == bundle, entitlements=expected))
            flags = STATIC_FLAGS | (CHECK_NESTED if path == bundle else 0)
            private.require(set(value) == {"valid", "validationFlags"} and value["valid"] is True
                            and type(value["validationFlags"]) is int and value["validationFlags"] == flags, "offline-static-response")
        self._dependencies("after"); self._locked("locked-after"); self._check()
        staged = replace(m, profile=profile)
        receipt = {"format": 1, "status": "FAKE_OFFLINE_INSPECTION_ONLY" if self.runner.test_double else "OFFLINE_STATIC_INSPECTION_ONLY",
                   "requestSHA256": self.review.request_digest(), "sourceRequestSHA256": self.admission.requestSHA256,
                   "scopeSHA256": self.source_review.scopeSHA256, "selectionSHA256": self.selection.binding(),
                   "implementationSHA256": self.review.implementationSHA256, "stagedMaterialSHA256": staged.binding(),
                   "profileSHA256": request["profileSHA256"], "publicCertificateSHA256": self.review.publicCertificateSHA256,
                   "profileEntitlements": entitlements, "profileSignerAuthenticity": "NOT_ESTABLISHED", "certificateTrust": "NOT_EVALUATED",
                   "privateKeyAvailability": "NOT_QUERIED", "keychainLocked": True, "daemonCheck": "NOT_RUN",
                   "onlineRevocation": "NOT_CHECKED", "notarization": "NOT_REQUESTED", "codeValidationFlags": STATIC_FLAGS,
                   "staticCodeChecks": len(targets) + 1, "nativeValidationObserved": not self.runner.test_double,
                   "cleanupConfirmed": self.runner.cleanup_confirmed, "events": self.events,
                   "signingAuthorized": False, "guestRunAuthorized": False, "publication": "forbidden"}
        self.runner.check(self.cancel)
        private.write_json(self.work / "offline-inspection.json", receipt)
        return receipt


if __name__ == "__main__":
    raise SystemExit("No authorization loader, native API binding or process launcher. Inject trusted composition.")
