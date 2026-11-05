"""Receipt-bound private candidate build/signing. No CLI or approval-file loader.

A historical offline receipt is evidence, never execution authority. Real work
requires an exact typed review, signing/key/timestamp authorization and explicit
bounded process and no-network verifier composition. Constructors do no IO.
"""
from dataclasses import dataclass, asdict
from pathlib import Path
import plistlib
import threading
import time

import private_provisioning_package as p
from private_provisioning_inputs import ReviewedSourceInputs, SourceInputAdmission
from private_provisioning_signer import Adapter, Material
from private_provisioning_materials import _stamp_keychain
from private_provisioning_offline import OfflineReview, implementation_digest, static_targets, HELPER_ENTITLEMENTS, QEMU_ENTITLEMENTS
from offline_inspection_worker import task, blob, unblob, signed_content, STATIC_FLAGS, CHECK_NESTED, candidate_identifier
from offline_inspection_runner import Runner, OfflineAuthorization
from offline_native_process import MacOSWorkerFactory
from bounded_signing_process import SigningRunner


@dataclass(frozen=True, repr=False)
class SigningReview:
    sourceRequestSHA256: str
    scopeSHA256: str
    offlineRequestSHA256: str
    offlineImplementationSHA256: str
    receiptSHA256: str
    materialSHA256: str
    publicCertificateSHA256: str
    implementationSHA256: str
    receipt: Path
    publicCertificate: Path
    output: Path
    fixture: bool = False

    def __post_init__(self):
        p.require(all(p.sha256(getattr(self,k)) for k in vars(self) if k.endswith('SHA256')), 'signing-review-digest')
        p.require(all(isinstance(getattr(self,k),Path) and getattr(self,k).is_absolute() for k in ('receipt','publicCertificate','output'))
                  and type(self.fixture) is bool, 'signing-review-path')

    def __repr__(self): return 'ReceiptBoundSigningReview(redacted)'

    def request_digest(self):
        value=asdict(self)
        for key in ('receipt','publicCertificate','output'): value[key]=str(value[key])
        return p.digest(p.canonical({'receiptBoundSigningVersion':1,'review':value}))


@dataclass(frozen=True, repr=False)
class SigningAuthorization:
    requestSHA256: str
    effects: frozenset

    def __repr__(self): return 'ReceiptBoundSigningAuthorization(redacted)'


class NativeTasks:
    """Explicit reuse of capability workers, narrowed to the signing job budget."""
    def __init__(self, review, historical, ops=None):
        self.review,self.historical,self.ops=review,historical,ops
        self.test_double=ops.test_double if ops is not None else False
        self.records=[];self.factory=None

    def open(self, context):
        p.require(type(context) is ReceiptBoundCaller and type(context.runner) is SigningRunner, 'signing-native-context')
        context.runner.authorize(*context.runner.bindings)
        self.context=context; p.require(self.review==context.review and self.historical==context.historical
                                      and self.test_double is context.review.fixture, 'signing-verifier-mode')
        output=context.review.output/'validation'
        p.new_directory(output)
        r=OfflineReview(context.review.sourceRequestSHA256,context.review.materialSHA256,
            context.review.publicCertificateSHA256,context.review.implementationSHA256,
            self.historical.helperEntitlementsSHA256,self.historical.qemuEntitlementsSHA256,output)
        self.factory=MacOSWorkerFactory(r,context.review.scopeSHA256,context.review.materialSHA256,context.review.fixture,self.ops)
        self.offline_review=r

    def run(self, spec):
        c=self.context;c.runner.authorize(*c.runner.bindings);c.check()
        r=self.offline_review
        a=OfflineAuthorization(r.request_digest(),c.review.scopeSHA256,c.review.materialSHA256,r.implementationSHA256,frozenset({'offline-native-inspect'}))
        runner=Runner(self.factory,a,clock=c.runner.clock)
        runner.start((a.requestSHA256,a.scopeSHA256,a.selectionSHA256,a.implementationSHA256))
        runner.deadline=min(runner.deadline,c.runner.deadline)
        try:return runner.run(spec,c.check,c.cancel)
        finally:self.records.extend(runner.worker_records)

    def cleanup_ok(self):
        return self.factory is not None and not self.factory.pending_cleanup and all(r['cleanupConfirmed'] for r in self.records)


class CandidateVerifier:
    def __init__(self, tasks):
        self.tasks=tasks; self.test_double=tasks.test_double

    def open(self, context): self.context=context;self.tasks.open(context)

    def call(self, spec):
        self.context.check()
        result=self.tasks.run(spec)
        self.context.check()
        return result

    def dependency(self, path, revision):
        p.require(self.call(task('dependency',path=str(path)))=={'revision':revision,'clean':True}, 'signing-dependency-changed')

    def certificate(self):
        c=self.context;raw=p.read(c.review.publicCertificate,1024*1024)
        value=self.call(task('certificate',content=blob(raw)))
        p.require(set(value)=={'commonName','notBefore','notAfter'} and value['commonName']==c.material.identity
                  and value['notBefore']<=time.time()<value['notAfter'], 'signing-certificate-expired-or-selector')

    def runtime(self, bundle):
        c=self.context
        helper=plistlib.loads(p.read(c.material.upstream/HELPER_ENTITLEMENTS,1024*1024))
        qemu=plistlib.loads(p.read(c.material.upstream/QEMU_ENTITLEMENTS,1024*1024))
        for path in static_targets(bundle)+[bundle]:
            expected=helper if path in (bundle,bundle/'Contents/MacOS/omarchy-vm-helper') else (qemu if path==bundle/'Contents/Resources/runtime/bin/Try Omarchy' else {})
            value=self.call(task('static',path=str(path),team=c.material.team,nested=path==bundle,entitlements=expected))
            p.require(value=={'valid':True,'validationFlags':STATIC_FLAGS|(CHECK_NESTED if path==bundle else 0)}, 'signing-runtime-static')

    def candidate(self, path, identifier, entitlements, nested=False):
        c=self.context
        value=self.call(task('candidate-code',path=str(path),identifier=identifier,team=c.material.team,nested=nested,entitlements=entitlements))
        p.require(set(value)=={'valid','validationFlags','CDHash','certificate'} and value['valid'] is True
                  and value['validationFlags']==STATIC_FLAGS|(CHECK_NESTED if nested else 0)
                  and unblob(value['certificate'])==p.read(c.review.publicCertificate,1024*1024), 'signing-output-certificate')
        return value['CDHash']


class ReceiptAdapter(Adapter):
    def __init__(self, context):
        super().__init__(context.runner,context.material);self.context=context

    def _command_request(self):return self.context.review.request_digest()
    def _authorize(self):self.runner.authorize(*self.runner.bindings)

    def _revalidate_inputs(self):
        self.context.check()
        return self.source_admission.revalidate() if self.source_admission is not None else self.context.admission.revalidate()

    def _validate_material(self):
        c=self.context
        self.profile_raw=p.read(c.material.profile,1024*1024)
        self.decoded_profile=plistlib.loads(signed_content(self.profile_raw))
        self.entitlements=p.keychain_profile.profile_entitlements(self.decoded_profile,c.material.team,p.BUNDLE_ID)
        p.require(p.read(c.review.publicCertificate,1024*1024) in self.decoded_profile['DeveloperCertificates'], 'signing-profile-leaf')
        self.profile=self.work/'profile.provisionprofile';p.write(self.profile,self.profile_raw)
        c.verifier.open(c);c.verifier.certificate()

    def _dependency_state(self,label,origin,expected):self.context.verifier.dependency(origin,expected)

    def _check_dependencies(self, stage):
        for _,folder,expected in self.dependency_checkouts:self.context.verifier.dependency(folder,expected)

    def _validate_runtime_signatures(self):self.context.verifier.runtime(self.runtime/'TryOmarchyKit.bundle')

    def _verify(self, app, stage):
        before=p.tree(app)
        self._verify_provisioning_resources(app)
        for name in (p.MAIN,'OmarchyVMProvisioningHelper'):
            p.require(self.request['scopeSHA256'].encode() in p.read(app/'Contents/MacOS'/name), 'signed-scope-marker-missing')
        p.package.verify(app/'Contents',root=self.handoff/'inputs')
        p.require(p.tree(app/'Contents/Helpers/TryOmarchyKit.bundle')==self.runtime_lock['files']
                  and p.read(app/'Contents/Resources/TryOmarchyRuntime.lock.json')==self.runtime_raw
                  and p.read(app/'Contents/embedded.provisionprofile')==self.profile_raw,'signing-payload-changed')
        identities={}
        for name,path in [('app',app)]+[(n,app/'Contents/MacOS'/n) for n in (p.MAIN,*p.CHILDREN)]:
            main=name in ('app',p.MAIN)
            identities[name]=self.context.verifier.candidate(path,p.BUNDLE_ID if main else candidate_identifier(name),self.manager_entitlements if main else {},nested=name=='app')
        p.require(p.tree(app)==before,'signing-verification-mutated-app')
        self._check_source();self._check_dependencies(stage)
        return identities

    def _result_fields(self):
        c=self.context;c.check()
        p.require(c.runner.cleanup_confirmed and c.verifier.tasks.cleanup_ok(), 'signing-cleanup-unconfirmed')
        return {'status':'FAKE_RECEIPT_BOUND_SIGNER_ONLY' if c.review.fixture else 'SIGNED_OFFLINE_STATIC_CHECKS_ONLY',
            'signingReviewSHA256':c.review.request_digest(),'offlineReceiptSHA256':c.review.receiptSHA256,
            'implementationSHA256':c.review.implementationSHA256,'commandEvidence':c.runner.worker_records,
            'nativeEvidence':c.verifier.tasks.records,'cleanupConfirmed':True,'appDiagnostic':'NOT_RUN',
            'daemonCheck':'NOT_RUN','orchestratorKeychainUnlockPerformed':False,'loadedChildAdmission':'NOT_RUN'}


class ReceiptBoundCaller:
    def __init__(self, source, historical, material, review, runner=None, verifier=None):
        p.require(type(source) is ReviewedSourceInputs and type(historical) is OfflineReview and type(material) is Material
                  and type(review) is SigningReview,'typed-receipt-signing-inputs')
        self.source,self.historical,self.material,self.review=source,historical,material,review
        self.runner,self.verifier=runner,verifier;self._used=False;self._lock=threading.Lock()

    def __repr__(self):return 'OneShotReceiptBoundSigningCaller(redacted)'

    def check(self):
        self.runner.check(self.cancel)
        p.require(implementation_digest()==self.review.implementationSHA256,'signing-implementation-changed')
        self.admission.revalidate()
        p.require(p.digest(p.read(self.review.receipt,2*1024*1024))==self.review.receiptSHA256,'signing-receipt-changed')
        p.require(p.digest(p.read(self.material.profile,1024*1024))==self.receipt['profileSHA256']
                  and p.digest(p.read(self.review.publicCertificate,1024*1024))==self.review.publicCertificateSHA256,'signing-public-input-changed')
        p.require(_stamp_keychain(self.material.keychain)==self.keychain_stamp,'signing-keychain-replaced')
        for path,digest in self.entitlements.items():p.require(p.digest(p.read(path,1024*1024))==digest,'signing-entitlement-changed')
        self.runner.check(self.cancel)

    def run(self, folder, cancel=None):
        with self._lock:p.require(not self._used,'receipt-signing-caller-used');self._used=True
        self.cancel=cancel
        try:return self._run(folder)
        except BaseException:
            if getattr(self,'output_created',False):
                try:
                    p.write_json(self.review.output/'receipt-bound-failure.json',{'status':'RECEIPT_BOUND_SIGNING_REFUSED',
                        'commandEvidence':self.runner.worker_records,'factoryCleanupEvidence':self.runner.factory.cleanup_records,
                        'cleanupConfirmed':self.runner.cleanup_confirmed,'nativeEvidence':self.verifier.tasks.records,
                        'nativeCleanupConfirmed':self.verifier.tasks.cleanup_ok(),
                        'nativeFactoryCleanupEvidence':getattr(getattr(self.verifier.tasks,'factory',None),'cleanup_records',[]),
                        'nativeUnresolvedHandles':len(getattr(getattr(self.verifier.tasks,'factory',None),'pending_cleanup',[])),'automaticRetry':False,'guestRunAuthorized':False})
                except OSError: pass  # Keep fixed refusal even if private evidence IO fails.
            raise p.Refused('receipt-bound-signing-refused') from None

    def _run(self, folder):
        r=self.review;h=self.historical;m=self.material
        # No source/material/output IO precedes exact typed execution authority.
        p.require(type(self.runner) is SigningRunner and type(self.verifier) is CandidateVerifier,'receipt-signing-backends-required')
        p.require(r.fixture is self.source.fixture and self.verifier.test_double is r.fixture,'receipt-signing-mode')
        self.runner.start()
        p.require(r.fixture or type(self.verifier.tasks) is NativeTasks,'signing-native-verifier-required')
        p.require(r.output != h.output and h.output not in r.output.parents and r.output not in h.output.parents,'signing-evidence-output-overlap')
        p.require(r.sourceRequestSHA256==self.source.request_digest() and r.scopeSHA256==self.source.scopeSHA256
                  and r.offlineRequestSHA256==h.request_digest() and r.offlineImplementationSHA256==h.implementationSHA256
                  and r.materialSHA256==m.binding() and h.sourceRequestSHA256==r.sourceRequestSHA256
                  and r.receipt==h.output/'offline-inspection.json' and m.profile==h.output/'manager.provisionprofile'
                  and r.publicCertificate==h.output/'public-certificate.der','receipt-signing-input-binding')
        p.require(r.implementationSHA256==implementation_digest(),'signing-implementation-changed')
        self.admission=SourceInputAdmission.open(folder,self.source);request=self.admission.revalidate()
        self.receipt=p.decode(p.read(r.receipt,2*1024*1024));v=self.receipt
        p.require(p.digest(p.read(r.receipt,2*1024*1024))==r.receiptSHA256,'signing-receipt-binding')
        p.require(v['status']==('FAKE_OFFLINE_INSPECTION_ONLY' if r.fixture else 'OFFLINE_STATIC_INSPECTION_ONLY')
                  and v['nativeValidationObserved'] is (not r.fixture) and v['cleanupConfirmed'] is True
                  and type(v['unresolvedHandles']) is int and v['unresolvedHandles']==0 and v['keychainLocked'] is True
                  and v['requestSHA256']==r.offlineRequestSHA256 and v['implementationSHA256']==r.offlineImplementationSHA256
                  and v['sourceRequestSHA256']==r.sourceRequestSHA256 and v['scopeSHA256']==r.scopeSHA256
                  and v['selectionSHA256']==h.selectionSHA256 and v['stagedMaterialSHA256']==m.binding()
                  and v['profileSHA256']==request['profileSHA256'] and v['publicCertificateSHA256']==r.publicCertificateSHA256
                  and type(v['codeValidationFlags']) is int and v['codeValidationFlags']==STATIC_FLAGS
                  and v['publication']=='forbidden' and v['daemonCheck']=='NOT_RUN' and v['signingAuthorized'] is False and v['guestRunAuthorized'] is False,
                  'signing-receipt-policy')
        count=len(static_targets(m.signed_runtime/'TryOmarchyKit.bundle'))+1
        p.require(type(v['staticCodeChecks']) is int and v['staticCodeChecks']==count and type(v['workerEvidence']) is list and len(v['workerEvidence'])==count+8,'signing-receipt-incomplete')
        for row in v['workerEvidence']:
            handle=row['handle']
            p.require(row['status']=='COMPLETED' and type(row['exitStatus']) is int and row['exitStatus']==0 and row['diagnostic'] is None and row['cleanupConfirmed'] is True
                      and handle['rootReaped'] is True and handle['groupQuietBeforeReap'] is True and handle['descriptorsClosed'] is True,
                      'signing-receipt-cleanup')
        for path in (m.profile,m.keychain,m.signed_runtime,m.upstream,m.parser_checkout,r.receipt,r.publicCertificate,r.output):
            parts=tuple(s.casefold() for s in path.parts)
            p.require(path.is_absolute() and path.resolve()==path and not any(parts[i:i+2]==('omarchy vm manager','vms') for i in range(len(parts)-1)), 'signing-path')
        p.require(m.team==self.source.signingTeamID and m.identity.startswith('Developer ID Application: ') and m.identity.endswith('('+m.team+')') and not any(ord(ch)<32 for ch in m.identity)
                  and m.signed_runtime==Path(folder)/'runtime','signing-material')
        self.keychain_stamp=_stamp_keychain(m.keychain)
        self.entitlements={m.upstream/HELPER_ENTITLEMENTS:h.helperEntitlementsSHA256,m.upstream/QEMU_ENTITLEMENTS:h.qemuEntitlementsSHA256}
        self.check()
        self.runner.revalidate=self.check;self.runner.cancel=self.cancel
        # Adapter creates the output once. Mark it only after creation, including
        # a failure during assembly; do not overwrite preexisting outputs.
        adapter=ReceiptAdapter(self)
        try:return adapter.run_source_inputs(folder,r.output,self.source)
        finally:self.output_created=hasattr(adapter,'work')


if __name__=='__main__':raise SystemExit('No approval loader or signing CLI. Explicit trusted composition required.')
