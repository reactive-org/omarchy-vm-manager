"""Named material inspection only. No signing, keychain query or authorization CLI.

The default runner refuses before material IO. Callers must separately approve an
inspection request; a successful receipt never grants app signing/key use or guest
authority. Tests inject fake command runners and public-certificate decoders.
"""
from dataclasses import dataclass, asdict, replace
import os
from pathlib import Path
import plistlib
import re
import ssl
import stat
import threading
import time

import private_provisioning_package as private
from private_provisioning_inputs import ReviewedSourceInputs, SourceInputAdmission, _archive_files
from private_provisioning_signer import Command, Material, SystemRunner, TOOLS


@dataclass(frozen=True, repr=False)
class MaterialSelection:
    material: Material  # profile is the explicitly named source, before staging.
    public_certificate: Path  # DER public leaf, never a private key or P12.

    def __post_init__(self):
        private.require(type(self.material) is Material and isinstance(self.public_certificate, Path), "typed-material-selection-required")

    def __repr__(self): return "PrivateMaterialSelection(redacted)"

    def binding(self):
        return private.digest(private.canonical({"selectionVersion": 1, "material": self.material.binding(),
                                                 "publicCertificate": str(self.public_certificate)}))


@dataclass(frozen=True, repr=False)
class ReviewedMaterialInspection:
    sourceRequestSHA256: str
    selectionSHA256: str
    publicCertificateSHA256: str
    runtimeInspectorSHA256: str
    output: Path

    def __post_init__(self):
        private.require(all(private.sha256(getattr(self, key)) for key in
                            ("sourceRequestSHA256", "selectionSHA256", "publicCertificateSHA256", "runtimeInspectorSHA256")))
        private.require(isinstance(self.output, Path) and self.output.is_absolute(), "explicit-private-inspection-output-required")

    def __repr__(self): return "ReviewedMaterialInspection(redacted)"

    def request_digest(self):
        fields = asdict(self); fields["output"] = str(self.output)
        return private.digest(private.canonical({"materialInspectionVersion": 1, "review": fields}))


def _stamp_keychain(path):
    # Only named-file metadata: never open its contents, enumerate identities,
    # query locked state, import/unlock, change ACLs or alter search lists.
    private.private_directory(path.parent)
    info = path.lstat()
    private.require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
                    and stat.S_IMODE(info.st_mode) == 0o600 and info.st_nlink == 1, "unsafe-named-keychain")
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns, info.st_mode)


def _decode_public_certificate(path):
    # Local X509 parsing only. No trust store, network, Keychain or private key.
    return ssl._ssl._test_decode_cert(str(path))


@dataclass(frozen=True, repr=False)
class InspectedMaterial:
    material: Material
    inspectionRequestSHA256: str
    sourceRequestSHA256: str
    profileSHA256: str
    publicCertificateSHA256: str
    receiptSHA256: str
    test_double: bool

    def __repr__(self): return "InspectedMaterialNotSigningAuthority(redacted)"


class MaterialInspectionCaller:
    """One-shot bounded inspection; returned Material still needs signing approval."""
    def __init__(self, source_review, selection, review, runner=None, certificate_decoder=None):
        private.require(type(source_review) is ReviewedSourceInputs and type(selection) is MaterialSelection
                        and type(review) is ReviewedMaterialInspection, "typed-material-review-required")
        self.source_review, self.selection, self.review = source_review, selection, review
        self.runner = runner if runner is not None else SystemRunner()
        self.certificate_decoder = certificate_decoder or _decode_public_certificate
        self._lock, self._used = threading.Lock(), False
        self.events = []

    def __repr__(self): return "MaterialInspectionCaller(redacted)"

    def _check_files(self):
        self.admission.revalidate()
        private.require(_stamp_keychain(self.selection.material.keychain) == self.keychain_stamp, "named-keychain-replaced")
        for path, digest in self.frozen_files.items():
            private.require(private.digest(private.read(path, 1024 * 1024)) == digest, "inspection-material-changed")

    def _call(self, stage, argv):
        self.events.append(stage); self._check_files()
        command = Command(stage, "inspect", tuple(map(str, argv)), self.work, dict(self.environment),
                          self.review.request_digest(), self.source_review.scopeSHA256, self.selection.binding())
        try:
            result = self.runner.run(command)
            private.require(type(result.returncode) is int and result.returncode == 0
                            and isinstance(result.stdout, bytes) and isinstance(result.stderr, bytes)
                            and len(result.stdout) <= command.maximum and len(result.stderr) <= command.maximum)
        except Exception:
            raise private.Refused("material-inspection-command-failed") from None
        self._check_files()
        return result

    def _git(self, stage, folder, *args):
        return self._call(stage, [TOOLS["git"], "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-C", folder, *args])

    def _dependencies(self, stage):
        for name, (folder, revision) in self.dependencies.items():
            head = self._git(stage + "-revision-" + name, folder, "rev-parse", "HEAD").stdout.decode().strip()
            clean = self._git(stage + "-clean-" + name, folder, "status", "--porcelain=v1", "--untracked-files=all").stdout
            private.require(head == revision and not clean, "inspection-source-changed")

    def run(self, folder):
        with self._lock:
            private.require(not self._used, "material-inspection-caller-already-used")
            self._used = True
        try:
            return self._run(folder)
        except private.Refused:
            raise
        except Exception:
            raise private.Refused("material-inspection-refused") from None

    def _run(self, folder):
        self.admission = SourceInputAdmission.open(folder, self.source_review)
        self.request = self.admission.revalidate()
        m = self.selection.material
        private.require(self.review.sourceRequestSHA256 == self.admission.requestSHA256
                        and self.review.selectionSHA256 == self.selection.binding(), "inspection-review-binding-changed")
        private.require(isinstance(m.identity, str) and m.team == self.source_review.signingTeamID and m.signed_runtime == self.admission.folder / "runtime"
                        and m.identity.startswith("Developer ID Application: ") and m.identity.endswith("(" + m.team + ")")
                        and not any(ord(c) < 32 for c in m.identity), "inspection-selector-mismatch")
        # Mandatory before reading profile/certificate/keychain metadata or creating
        # staging. Ordinary signing authorization has a different request digest.
        self.runner.authorize(self.review.request_digest(), self.source_review.scopeSHA256, self.selection.binding())
        if isinstance(self.runner, SystemRunner):
            private.require(self.runner.authorization.effects == frozenset({"inspect"}), "inspection-only-authorization-required")
        private.require(type(self.runner.test_double) is bool and (self.runner.test_double or not self.source_review.fixture),
                        "fixture-inspection-cannot-execute")
        for path in (m.profile, m.keychain, m.signed_runtime, m.upstream, m.parser_checkout, self.selection.public_certificate):
            private.require(isinstance(path, Path) and path.is_absolute() and path.resolve() == path, "linked-inspection-material-refused")
        self.keychain_stamp = _stamp_keychain(m.keychain)
        self.inspector = m.upstream / "scripts/kit_signature.py"
        self.frozen_files = {m.profile: self.request["profileSHA256"],
                             self.selection.public_certificate: self.review.publicCertificateSHA256,
                             self.inspector: self.review.runtimeInspectorSHA256}
        self._check_files()
        private.require(re.fullmatch(r"[A-Za-z0-9 /_.-]+", str(self.review.output)), "unsafe-inspection-output")
        self.work = private.new_directory(self.review.output, self.admission.folder)
        home = self.work / "home"; home.mkdir(mode=0o700)
        self.environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(home), "TMPDIR": str(self.work),
                            "LC_ALL": "C", "LANG": "C", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
                            "GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "/usr/bin/false", "GIT_SSH_COMMAND": "/usr/bin/false"}
        try:
            files = _archive_files(private.read(self.admission.folder / "inputs/base-source.tar"))
            patch = private.decode(files["Config/TryOmarchyClipboardPatch.json"])
            resolved = private.decode(files["Package.resolved"])
            parser = [p for p in resolved["pins"] if p["identity"] == "tomldecoder"]
            private.require(len(parser) == 1)
            self.dependencies = {"upstream": (m.upstream, patch["commit"]),
                                 "parser": (m.parser_checkout, parser[0]["state"]["revision"])}
            self._dependencies("before-inspection")
            profile = self.work / "manager.provisionprofile"
            certificate = self.work / "public-certificate.der"
            private.write(profile, private.read(m.profile, 1024 * 1024))
            private.write(certificate, private.read(self.selection.public_certificate, 1024 * 1024))
            self.frozen_files[profile] = self.request["profileSHA256"]
            self.frozen_files[certificate] = self.review.publicCertificateSHA256
            pem = self.work / "public-certificate.pem"
            private.write(pem, ssl.DER_cert_to_PEM_cert(private.read(certificate)).encode("ascii"))
            self.frozen_files[pem] = private.digest(private.read(pem))
            decoded = plistlib.loads(self._call("decode-selected-profile", [TOOLS["security"], "cms", "-D", "-i", profile]).stdout)
            entitlements = private.keychain_profile.profile_entitlements(decoded, m.team, private.BUNDLE_ID)
            private.require(private.read(certificate) in decoded["DeveloperCertificates"], "selected-certificate-not-in-profile")
            details = self.certificate_decoder(pem)
            names = [v for row in details["subject"] for k, v in row if k == "commonName"]
            private.require(names == [m.identity] and ssl.cert_time_to_seconds(details["notBefore"]) <= time.time()
                            < ssl.cert_time_to_seconds(details["notAfter"]), "public-certificate-selector-or-dates-invalid")
            self._check_files()
            self._call("verify-selected-runtime-signatures", [TOOLS["python"], self.inspector, "verify", "--signature-only", "--team", m.team,
                                                              m.signed_runtime / "TryOmarchyKit.bundle"])
            self._dependencies("after-inspection")
            self._check_files()
            admitted = replace(m, profile=profile)
            receipt = {"format": 1, "status": "FAKE_MATERIAL_INSPECTION_ONLY" if self.runner.test_double else "MATERIAL_FILES_CHECKED_KEY_AVAILABILITY_UNPROVEN",
                       "inspectionRequestSHA256": self.review.request_digest(), "sourceRequestSHA256": self.admission.requestSHA256,
                       "selectionSHA256": self.selection.binding(), "stagedMaterialSHA256": admitted.binding(),
                       "profileSHA256": self.request["profileSHA256"], "publicCertificateSHA256": self.review.publicCertificateSHA256,
                       "runtimeInspectorSHA256": self.review.runtimeInspectorSHA256, "profileEntitlements": entitlements,
                       "profileAndPublicCertificateMatch": True, "namedKeychainMetadataUnchanged": True,
                       "privateKeyAvailability": "NOT_QUERIED", "keychainUnlocked": "NOT_CHECKED", "certificateTrust": "NOT_ESTABLISHED_BY_PUBLIC_PARSE",
                       "nativeRuntimeVerifierObserved": not self.runner.test_double, "processRunnerTestDouble": self.runner.test_double,
                       "signingAuthorized": False, "guestRunAuthorized": False, "notarization": "NOT_REQUESTED", "publication": "forbidden", "events": self.events}
            private.write_json(self.work / "material-inspection.json", receipt)
            return InspectedMaterial(admitted, self.review.request_digest(), self.admission.requestSHA256,
                                     self.request["profileSHA256"], self.review.publicCertificateSHA256,
                                     private.digest(private.read(self.work / "material-inspection.json")), self.runner.test_double)
        except Exception:
            try: private.write_json(self.work / "failure.json", {"status": "MATERIAL_INSPECTION_FAILED_OUTPUT_PRESERVED", "events": self.events,
                                                                 "automaticRetry": False, "signingAuthorized": False, "guestRunAuthorized": False})
            except OSError: pass
            raise private.Refused("material-inspection-failed") from None


if __name__ == "__main__":
    raise SystemExit("No material or signing CLI. Named inspection requires separate trusted authorization.")
