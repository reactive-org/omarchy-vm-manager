"""Read-only version 2 source admission; never signing or guest authorization.

Consumes the existing version 1 PRIVATE_INTEGRATED_CANDIDATE_INPUTS packet without
rewriting it. A trusted caller supplies independently reviewed bindings in memory.
The gate JSON, checksum sidecar, environment and CLI cannot supply that review.
"""
from dataclasses import dataclass, asdict
import io
import os
from pathlib import Path
import re
import tarfile

import private_provisioning_package as private
from fetch_runtime_kit import archive_manifest

LITERAL = "Sources/OmarchyVMManagerCore/PrivateM6Acceptance.swift"
MACHO = {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"}
FIELDS = set("format kind status sourceCommit scopeSHA256 scopeBytesSHA256 originalScopeSourceCommit priorRequestSHA256 applicationBuilt applicationSigned guestRunAuthorized executionAuthorized legacyAdapterCompatible publication inputs runtime lineage sourceArchiveSHA256 overlaySHA256 developmentLockSHA256 signedRuntimeLockSHA256 signedRuntimeArchiveSHA256 runtimeArtifactTag artifactContainer signedRuntimeSource scopedSourceSHA256".split())
EVIDENCE = set("format baseCommit baseArchiveSHA256 overlaySHA256 originalScopeSourceCommit scopeSHA256 scopeBytesSHA256 scopeDefinitionCopiedVerbatim ordinaryGateUnchanged productionSigningPolicyUnchanged applicationBuilt overlayFiles".split())


@dataclass(frozen=True, repr=False)
class ReviewedSourceInputs:
    candidateInputsSHA256: str
    sourceCommit: str
    scopeSHA256: str
    scopeBytesSHA256: str
    priorRequestSHA256: str
    preservedScopeSourceSHA256: str
    sourceArchiveSHA256: str
    overlaySHA256: str
    signingTeamID: str
    fixture: bool = False

    def __post_init__(self):
        private.require(all(private.sha256(getattr(self, k)) for k in
                            ("candidateInputsSHA256", "scopeSHA256", "scopeBytesSHA256",
                             "priorRequestSHA256", "preservedScopeSourceSHA256",
                             "sourceArchiveSHA256", "overlaySHA256")))
        private.require(isinstance(self.sourceCommit, str) and re.fullmatch("[0-9a-f]{40}", self.sourceCommit)
                        and isinstance(self.signingTeamID, str) and re.fullmatch("[A-Z0-9]{10}", self.signingTeamID)
                        and type(self.fixture) is bool, "invalid-source-input-review")

    def __repr__(self): return "ReviewedSourceInputs(redacted)"

    def request_digest(self):
        # Domain/version and fixture mode cannot be confused with a legacy request
        # or changed while keeping the same execution authorization.
        return private.digest(private.canonical({"admissionVersion": 2, "review": asdict(self)}))


def _archive_files(raw):
    private.archive_profile_pin(raw)  # Reject duplicate/linked/unsafe/oversize entries.
    with tarfile.open(fileobj=io.BytesIO(raw), mode="r:") as archive:
        return {item.name: archive.extractfile(item).read() for item in archive if item.isfile()}


def _admit(folder, review):
    private.private_context()
    parts = tuple(p.casefold() for p in Path(folder).parts)
    private.require(not any(parts[i:i+2] == ("omarchy vm manager", "vms") for i in range(len(parts)-1)),
                    "guest-storage-source-refused")
    folder = private.private_directory(folder)
    private.require(not any(os.path.lexists(folder / n)
                            for n in ("failure.json", "request.json", "request.sha256.json")),
                    "ambiguous-or-failed-source-packet")
    raw = private.read(folder / "candidate-inputs.json", 1024 * 1024)
    private.require(private.digest(raw) == review.candidateInputsSHA256, "source-input-binding-changed")
    value = private.decode(raw)
    private.require(set(value) == FIELDS and type(value["format"]) is int and value["format"] == 1
                    and value["kind"] == "PRIVATE_INTEGRATED_CANDIDATE_INPUTS"
                    and value["status"] == "PREPARED_INPUTS_ONLY_NOT_AUTHORIZED", "unsupported-source-input-version")
    private.require(all(value[k] is False for k in ("applicationBuilt", "applicationSigned", "guestRunAuthorized",
                                                   "executionAuthorized", "legacyAdapterCompatible"))
                    and value["publication"] == "forbidden", "source-packet-cannot-grant-authority")
    private.require(value["sourceCommit"] == review.sourceCommit
                    and value["scopeSHA256"] == review.scopeSHA256
                    and value["scopeBytesSHA256"] == review.scopeBytesSHA256
                    and value["priorRequestSHA256"] == review.priorRequestSHA256
                    and value["sourceArchiveSHA256"] == review.sourceArchiveSHA256
                    and value["overlaySHA256"] == review.overlaySHA256, "source-review-changed")
    for name in ("inputs", "runtime", "lineage"):
        private.require(isinstance(value[name], dict) and private.tree(folder / name) == value[name],
                        "source-input-inventory-changed")
    inputs = folder / "inputs"
    required = {"base-source.tar", "candidate-overlay.patch", "source-evidence.json", "scope.json",
                "root-preparation-receipt.json", "Config/DevVMProvisioning.lock.json",
                "Config/TryOmarchyRuntime.lock.json", "Config/TouchIDProfile.lock.json"}
    private.require(set(value["inputs"]) == required | {
        p for p in value["inputs"] if p.startswith(("TryOmarchyKit.bundle/", private.package.BUNDLE + "/"))})
    private.require(set(value["lineage"]) == {"previous-request.json"})
    scope_raw = private.read(inputs / "scope.json", 65536)
    private.require(private.digest(scope_raw) == review.scopeBytesSHA256, "historical-scope-bytes-changed")
    scope = private.decode(scope_raw); private.validate_scope(scope)
    private.require(scope["scopeSHA256"] == review.scopeSHA256
                    and scope["sourceCommit"] == value["originalScopeSourceCommit"], "historical-scope-changed")
    receipt = private.read(inputs / "root-preparation-receipt.json", 256 * 1024)
    private.require(private.digest(receipt) == scope["receiptSHA256"])
    receipt_data = private.decode(receipt)
    private.require(all(receipt_data[k] == scope[k] for k in ("vmID", "root", "device", "inode", "markerSHA256")))
    prior_raw = private.read(folder / "lineage/previous-request.json", 1024 * 1024)
    private.require(private.digest(prior_raw) == review.priorRequestSHA256, "source-lineage-changed")
    prior = private.decode(prior_raw)
    private.require(type(prior["format"]) is int and prior["format"] == 1
                    and prior["status"] == "PRIVATE_REQUEST_ONLY_NOT_SIGNED" and prior["publication"] == "forbidden"
                    and prior["guestRunAuthorized"] is False and prior["scopeSHA256"] == review.scopeSHA256
                    and prior["sourceCommit"] == scope["sourceCommit"]
                    and prior["inputs"]["scope.json"] == review.scopeBytesSHA256
                    and prior["inputs"]["root-preparation-receipt.json"] == scope["receiptSHA256"], "historical-request-mismatch")
    archive = private.read(inputs / "base-source.tar")
    private.require(private.digest(archive) == value["sourceArchiveSHA256"])
    files = _archive_files(archive)
    for name in ("DevVMProvisioning.lock.json", "TryOmarchyRuntime.lock.json", "TouchIDProfile.lock.json"):
        private.require(files["Config/" + name] == private.read(inputs / "Config" / name), "source-config-changed")
    evidence = private.decode(private.read(inputs / "source-evidence.json", 65536))
    private.require(set(evidence) == EVIDENCE and type(evidence["format"]) is int and evidence["format"] == 1
                    and evidence["baseCommit"] == review.sourceCommit
                    and evidence["baseArchiveSHA256"] == value["sourceArchiveSHA256"]
                    and evidence["overlaySHA256"] == value["overlaySHA256"]
                    and evidence["originalScopeSourceCommit"] == scope["sourceCommit"]
                    and evidence["scopeSHA256"] == review.scopeSHA256
                    and evidence["scopeBytesSHA256"] == review.scopeBytesSHA256
                    and all(evidence[k] is True for k in ("scopeDefinitionCopiedVerbatim", "ordinaryGateUnchanged", "productionSigningPolicyUnchanged"))
                    and evidence["applicationBuilt"] is False, "source-evidence-changed")
    overlay = private.read(inputs / "candidate-overlay.patch", 1024 * 1024)
    private.require(private.digest(overlay) == value["overlaySHA256"])
    rows = evidence["overlayFiles"]
    private.require(len(rows) == len(private.OVERLAY_PATHS) and {r["path"] for r in rows} == private.OVERLAY_PATHS)
    scoped_inventory = {n: private.digest(b) for n, b in files.items()}
    for row in rows:
        private.require(set(row) == {"path", "beforeSHA256", "afterSHA256"}
                        and private.sha256(row["afterSHA256"])
                        and row["beforeSHA256"] == (private.digest(files[row["path"]]) if row["path"] in files else None))
        scoped_inventory[row["path"]] = row["afterSHA256"]
    private.require(next(r for r in rows if r["path"] == LITERAL)["afterSHA256"] == review.preservedScopeSourceSHA256,
                    "preserved-scope-source-changed")
    private.require(private.digest(private.canonical(scoped_inventory)) == value["scopedSourceSHA256"], "scoped-source-inventory-changed")
    package = private.decode(files["Config/DevVMProvisioning.lock.json"])
    private.package.read_lock(inputs)
    prefix = "Vendor/dev-vm/"
    exported = {n[len(prefix):]: private.digest(b) for n, b in files.items() if n.startswith(prefix)}
    private.require(exported == package["files"], "archived-provisioning-source-changed")
    private.require(package["sourceSnapshotSHA256"] == private.digest(private.canonical(package["files"])),
                    "archived-package-index-changed")
    private.require(private.package.files(private.package.resource_directory(inputs / private.package.BUNDLE))
                    == private.package.resource_files(package), "provisioning-resources-changed")
    engine = "Sources/DevVMProvisioningCore/Resources/engine-identity.json"
    private.require(package["engineSHA256"] == package["files"][engine])
    dev_raw = files["Config/TryOmarchyRuntime.lock.json"]; dev = private.decode(dev_raw)
    private.require(private.digest(dev_raw) == value["developmentLockSHA256"]
                    and private.tree(inputs / "TryOmarchyKit.bundle") == dev["files"])
    runtime = folder / "runtime"
    signed_raw = private.read(runtime / "TryOmarchySignedRuntime.lock.json", 65536); signed = private.decode(signed_raw)
    private.require(private.digest(signed_raw) == value["signedRuntimeLockSHA256"])
    private.validate_signed_lock(signed, dev, private.digest(dev_raw), review.signingTeamID)
    code = {n for n in dev["files"] if private.read(inputs / "TryOmarchyKit.bundle" / n)[:4] in MACHO}
    private.validate_payload(dev["files"], signed["files"], code)
    private.require(private.tree(runtime / "TryOmarchyKit.bundle") == signed["files"]
                    and value["signedRuntimeArchiveSHA256"] == signed["kitSHA256"]
                    and value["runtimeArtifactTag"] == signed["artifactTag"])
    private.require(set(value["runtime"]) == {"TryOmarchyKit.zip", "TryOmarchySignedRuntime.lock.json"}
                    | {"TryOmarchyKit.bundle/" + n for n in signed["files"]})
    archive_manifest(runtime / "TryOmarchyKit.zip", signed)
    profile = private.decode(files["Config/TouchIDProfile.lock.json"])
    private.require(type(profile["format"]) is int and profile["format"] == 1)
    private.require(private.read(folder / "candidate-inputs.json", 1024 * 1024) == raw
                    and all(private.tree(folder / n) == value[n] for n in ("inputs", "runtime", "lineage")),
                    "source-packet-changed-during-admission")
    return {"format": 2, "kind": "ADMITTED_SOURCE_INPUTS", "sourceCommit": review.sourceCommit,
            "scopeSHA256": review.scopeSHA256, "profileSHA256": profile["profileSHA256"],
            "overlaySHA256": value["overlaySHA256"], "scopedSourceSHA256": value["scopedSourceSHA256"],
            "signedRuntimeLockSHA256": value["signedRuntimeLockSHA256"],
            "signedRuntimeArchiveSHA256": value["signedRuntimeArchiveSHA256"],
            "signingTeamID": review.signingTeamID,
            "simulationFixture": review.fixture, "guestRunAuthorized": False, "publication": "forbidden"}


@dataclass(frozen=True, repr=False)
class SourceInputAdmission:
    folder: Path
    review: ReviewedSourceInputs

    @classmethod
    def open(cls, folder, review):
        private.require(type(review) is ReviewedSourceInputs, "typed-source-review-required")
        admission = cls(Path(folder), review)
        admission.revalidate()
        return admission

    def __repr__(self): return "SourceInputAdmissionV2(redacted)"

    @property
    def requestSHA256(self): return self.review.request_digest()

    def revalidate(self):
        try: return _admit(self.folder, self.review)
        except Exception:
            raise private.Refused("source-input-admission-refused") from None

    def validate_reconstruction(self, source):
        request = self.revalidate()
        private.require(private.digest(private.canonical(private.tree(source))) == request["scopedSourceSHA256"],
                        "reconstructed-source-changed")
        private.require(private.digest(private.read(source / LITERAL)) == self.review.preservedScopeSourceSHA256,
                        "reconstructed-historical-scope-changed")


if __name__ == "__main__":
    raise SystemExit("No signing CLI. Source admission requires a trusted typed review.")
