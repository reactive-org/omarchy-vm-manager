"""Receipt-bound flow through concrete supervision with fake OS/FFI only."""
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'Scripts'))
import private_provisioning_package as p
import private_provisioning_signer as legacy
import private_provisioning_offline as offline
import receipt_bound_signing as signing
import bounded_signing_process as bounded
import offline_inspection_worker as worker
import offline_macos_api as native
import test_offline_native_process as launch_tests
from test_offline_native_process import FakeOps, FakeFile, FakePopen
from test_offline_macos_bindings import FakeFFI
from test_private_provisioning_inputs import SourceCommands


class Tasks:
    test_double=True
    def __init__(self,fixture):self.fixture=fixture;self.records=[];self.specs=[];self.ffi=FakeFFI();self.fault=None
    def open(self,c):self.context=c
    def cleanup_ok(self):return True
    def run(self,spec):
        fields=spec.decode();self.specs.append(spec)
        f=self.fixture
        def identifier(path):
            return p.BUNDLE_ID if path.name in (p.MAIN,'Private Candidate.app') else (worker.candidate_identifier(path.name) if path.name in p.CHILDREN else 'dev.tryomarchy.kit')
        def entitlements(path):
            if path.name in (p.MAIN,'Private Candidate.app'):
                return {'com.apple.application-identifier':f.material.team+'.'+p.BUNDLE_ID,'com.apple.developer.team-identifier':f.material.team}
            return {'com.apple.security.hypervisor':True} if path.name in ('TryOmarchyKit.bundle','omarchy-vm-helper') else {}
        self.ffi.identifier_for_path=identifier;self.ffi.entitlements_for_path=entitlements
        self.ffi.fail=self.fault
        if self.fault=='leaf':self.ffi.public_leaf=b'wrong public certificate'
        api=native.MacOSAPI(self.ffi.bindings,dependency_checker=lambda path:{'revision':('1'*40 if path.name in ('parser','TOMLDecoder') else f.runtime['patchCommit']),'clean':True})
        result=worker.perform(spec,api)
        self.records.append({'kind':spec.kind,'cleanupConfirmed':True})
        assert not self.ffi.owned
        return result


class CommandProcess(FakePopen):
    def __init__(self,ops,argv,kwargs):
        self.ops=ops;self.argv=argv;self.kwargs=kwargs;self.pid=19000+len(ops.processes)
        self.stdin=FakeFile(ops,self,'stdin');self.stdout=FakeFile(ops,self,'stdout');self.stderr=FakeFile(ops,self,'stderr')
        self.request=bytearray();self.output={'stdout':bytearray(),'stderr':bytearray()};self.finished=False
        self.status=None;self.reaped=False;self.children=ops.mode=='descendants';self.waits=[]
    def input_closed(self):
        if self.finished or self.ops.mode=='hang':return
        try:
            result=self.ops.commands.run(self.ops.command)
            self.status=result.returncode;self.output['stdout'].extend(result.stdout);self.output['stderr'].extend(result.stderr)
            if self.ops.callback:self.ops.callback(self.ops.command)
            if self.ops.mode=='overflow':self.output['stdout']=bytearray(b'x'*(2*1024*1024+1))
            if self.ops.mode=='stderr-overflow':self.output['stderr']=bytearray(b'x'*(2*1024*1024+1))
        except BaseException:self.status=1;self.output['stderr'].extend(b'private failure do not log')
        self.finished=True


class Commands(FakeOps):
    def __init__(self,fixture):
        super().__init__(fixture,offline.implementation_digest());self.commands=SourceCommands(fixture);self.callback=None
    def popen(self,argv,**kwargs):
        assert kwargs['pass_fds']==() and kwargs['close_fds'] and kwargs['start_new_session'] and kwargs['bufsize']==0
        proc=CommandProcess(self,argv,kwargs);self.processes.append(proc);self.trace.append(('spawn',proc.pid));return proc


class Factory(bounded.CommandFactory):
    def validate(self,c):super().validate(c);self.ops.command=c


class ReceiptSigningTests(unittest.TestCase):
    def setUp(self):
        self.seed=launch_tests.NativeLaunchTests(methodName='test_full_adapter_through_concrete_launcher_and_bindings_uses_only_fake_primitives')
        self.seed.setUp();self.addCleanup(self.seed.doCleanups)
        self.fixture=self.seed.fixture;self.root=self.seed.root
        self.receipt=self.seed.caller().run(self.fixture.packet)
        self.historical=self.seed.review
        self.material=replace(self.seed.selection.material,profile=self.historical.output/'manager.provisionprofile')
        self.public=self.historical.output/'public-certificate.der'
        self.receipt_path=self.historical.output/'offline-inspection.json'
        self.review=signing.SigningReview(self.fixture.review.request_digest(),self.fixture.review.scopeSHA256,
            self.historical.request_digest(),self.historical.implementationSHA256,p.digest(p.read(self.receipt_path)),
            self.material.binding(),p.digest(p.read(self.public)),offline.implementation_digest(),self.receipt_path,self.public,self.root/'signed',True)

    def caller(self,review=None,auth=True):
        r=review or self.review;self.ops=Commands(self.fixture);self.factory=Factory(r,self.material,self.ops)
        a=signing.SigningAuthorization(r.request_digest(),bounded.EFFECTS) if auth is True else auth
        self.runner=bounded.SigningRunner(r,self.material,self.factory,a,clock=self.ops.clock)
        self.tasks=Tasks(self.fixture);self.verifier=signing.CandidateVerifier(self.tasks)
        return signing.ReceiptBoundCaller(self.fixture.review,self.historical,self.material,r,self.runner,self.verifier)

    def test_end_to_end_private_roundtrip_is_fake_and_avoids_all_legacy_verifiers(self):
        before=p.tree(self.fixture.packet);caller=self.caller();value=caller.run(self.fixture.packet)
        self.assertEqual(value['status'],'FAKE_RECEIPT_BOUND_SIGNER_ONLY');self.assertFalse(value['productionCryptographyObserved'])
        self.assertEqual(value['offlineReceiptSHA256'],self.review.receiptSHA256);self.assertTrue(value['cleanupConfirmed'])
        self.assertEqual(value['daemonCheck'],'NOT_RUN');self.assertEqual(value['appDiagnostic'],'NOT_RUN')
        self.assertEqual(p.tree(self.fixture.packet),before);self.assertFalse(Path(self.fixture.scope['root']).exists())
        self.assertFalse(self.factory.pending_cleanup);self.assertTrue(all(r['handle']['rootReaped'] for r in value['commandEvidence']))
        stages=[c.stage for c in self.ops.commands.commands]
        self.assertNotIn('decode-pinned-profile',stages);self.assertNotIn('verify-local-runtime-signatures',stages)
        self.assertFalse(any('security'==Path(c.argv[0]).name or '--verify-bundle-json' in c.argv for c in self.ops.commands.commands))
        self.assertTrue(all(c.environment['GIT_CEILING_DIRECTORIES']==str(self.review.output) for c in self.ops.commands.commands))
        self.assertTrue(any(s.kind=='candidate-code' for s in self.tasks.specs))
        self.assertEqual(p.tree(self.review.output/'Private Candidate.app'),p.tree(self.review.output/'roundtrip/Private Candidate.app'))

    def test_default_and_json_env_authority_deny_before_input_io(self):
        caller=signing.ReceiptBoundCaller(self.fixture.review,self.historical,self.material,self.review)
        with patch.object(p,'read',side_effect=AssertionError('No IO before authority')),self.assertRaises(p.Refused):caller.run(self.fixture.packet)
        for a in ({'approved':True},legacy.ExecutionAuthorization(self.review.request_digest(),self.review.scopeSHA256,self.material.binding(),bounded.EFFECTS)):
            caller=self.caller(auth=a)
            with patch.object(p,'read',side_effect=AssertionError('No IO before authority')),self.assertRaises(p.Refused):caller.run(self.fixture.packet)
        self.assertFalse(self.review.output.exists());self.assertEqual(self.ops.processes,[])

    def test_factory_and_native_tasks_are_default_denied_without_signing_authority(self):
        self.caller()
        c=legacy.Command('build','build',('/usr/bin/false',),self.root,{},self.review.request_digest(),self.review.scopeSHA256,self.material.binding())
        with self.assertRaises(p.Refused):self.factory.spawn(c)
        self.assertEqual(self.ops.processes,[])
        tasks=signing.NativeTasks(self.review,self.historical)
        with self.assertRaises(p.Refused):tasks.open(SimpleNamespace(review=self.review))
        self.assertFalse(self.review.output.exists())

    def test_complete_flow_through_capability_worker_factory_and_fake_ffi(self):
        caller=self.caller()
        self.tasks.run(worker.task('certificate',content=worker.blob(b'fake certificate')))
        native_ops=launch_tests.FakeOps(self.fixture,offline.implementation_digest());native_ops.ffi=self.tasks.ffi
        native_ops.dependency=lambda path:{'revision':('1'*40 if path.name in ('parser','TOMLDecoder') else self.fixture.runtime['patchCommit']),'clean':True}
        native_tasks=signing.NativeTasks(self.review,self.historical,native_ops)
        caller.verifier=signing.CandidateVerifier(native_tasks)
        result=caller.run(self.fixture.packet)
        self.assertEqual(result['status'],'FAKE_RECEIPT_BOUND_SIGNER_ONLY')
        self.assertTrue(result['nativeEvidence']);self.assertTrue(native_tasks.cleanup_ok())
        self.assertTrue(all(proc.reaped for proc in native_ops.processes))
        self.assertTrue(all(r['handle']['descriptorsClosed'] for r in native_tasks.records))
        self.assertFalse(native_ops.ffi.owned)

    def test_missing_key_or_timestamp_approval_cannot_dispatch(self):
        for effect in bounded.EFFECTS:
            auth=signing.SigningAuthorization(self.review.request_digest(),bounded.EFFECTS-{effect})
            with self.subTest(effect=effect),self.assertRaises(p.Refused):self.caller(auth=auth).run(self.fixture.packet)
            self.assertEqual(self.ops.processes,[])

    def test_output_receipt_code_and_material_are_bound(self):
        for field,value in (('output',self.root/'other'),('receiptSHA256','0'*64),('implementationSHA256','0'*64),('materialSHA256','0'*64)):
            r=replace(self.review,**{field:value});a=signing.SigningAuthorization(self.review.request_digest(),bounded.EFFECTS)
            with self.subTest(field=field),self.assertRaises(p.Refused):self.caller(r,a).run(self.fixture.packet)
            self.assertFalse(r.output.exists())

    def test_historical_receipt_implementation_is_bound_independently_from_new_tooling(self):
        h=replace(self.historical,implementationSHA256='a'*64)
        value=dict(self.receipt,implementationSHA256=h.implementationSHA256,requestSHA256=h.request_digest())
        self.receipt_path.write_bytes(p.canonical(value))
        r=replace(self.review,offlineImplementationSHA256=h.implementationSHA256,offlineRequestSHA256=h.request_digest(),receiptSHA256=p.digest(p.read(self.receipt_path)))
        caller=self.caller(r);caller.historical=h
        self.assertEqual(caller.run(self.fixture.packet)['status'],'FAKE_RECEIPT_BOUND_SIGNER_ONLY')

    def test_bad_partial_or_unclean_receipt_refuses_without_output(self):
        for field,value in (('status','OFFLINE_STATIC_INSPECTION_ONLY'),('cleanupConfirmed',False),('unresolvedHandles',1),('staticCodeChecks',0),('nativeValidationObserved',True),('keychainLocked',False)):
            current=dict(self.receipt,**{field:value});self.receipt_path.write_bytes(p.canonical(current))
            r=replace(self.review,receiptSHA256=p.digest(p.read(self.receipt_path)))
            with self.subTest(field=field),self.assertRaises(p.Refused):self.caller(r).run(self.fixture.packet)
            self.assertFalse(r.output.exists())

    def test_fixture_never_enters_native_backend(self):
        caller=self.caller();self.factory.test_double=False
        with self.assertRaises(p.Refused):caller.run(self.fixture.packet)
        self.assertEqual(self.ops.processes,[])

    def test_staged_profile_public_leaf_and_receipt_mutations_abort_without_rebinding(self):
        for path in (self.material.profile,self.public,self.receipt_path):
            data=path.read_bytes();path.write_bytes(b'mutated')
            with self.subTest(path=path.name),self.assertRaises(p.Refused):self.caller().run(self.fixture.packet)
            path.write_bytes(data)
        self.assertFalse(self.review.output.exists())

    def test_callback_receipt_mutation_kills_reaps_and_keeps_private_evidence(self):
        caller=self.caller();self.ops.callback=lambda _:self.receipt_path.write_bytes(b'changed during build')
        with self.assertRaises(p.Refused):caller.run(self.fixture.packet)
        self.assertTrue(all(p.reaped for p in self.ops.processes));self.assertFalse(self.factory.pending_cleanup)
        self.assertFalse(p.decode(p.read(self.review.output/'receipt-bound-failure.json'))['automaticRetry'])

    def test_failure_evidence_io_error_cannot_expose_raw_path_or_error(self):
        caller=self.caller();self.ops.callback=lambda _:self.receipt_path.write_bytes(b'changed')
        write=p.write_json
        def unavailable(path,value):
            if Path(path).name=='receipt-bound-failure.json':raise OSError('private sensitive path')
            return write(path,value)
        with patch.object(p,'write_json',side_effect=unavailable),self.assertRaisesRegex(p.Refused,'^receipt-bound-signing-refused$'):
            caller.run(self.fixture.packet)
        self.assertTrue(all(proc.reaped for proc in self.ops.processes))

    def test_failed_root_is_drained_before_fixed_helper_classification(self):
        caller=self.caller();run=self.ops.commands.run
        error=b'Traceback with private path and token\nValueError: Provisioning patch base differs\n'
        def failing(c):
            if c.stage=='prepare-pinned-provisioning-source':return legacy.Result(1,b'',error)
            return run(c)
        self.ops.commands.run=failing;read=self.ops.read
        self.ops.read=lambda fd,maximum:read(fd,min(maximum,7))
        with self.assertRaises(p.Refused):caller.run(self.fixture.packet)
        record=self.runner.worker_records[-1]
        self.assertEqual(record['handle']['stderrBytes'],len(error))
        self.assertEqual(record['commandDiagnostic'],{'format':1,'phase':'provisioning-prepare','code':'provisioning-patch-base-mismatch','stderrComplete':True})
        self.assertTrue(record['cleanupConfirmed']);self.assertNotIn(b'private path',p.read(self.review.output/'receipt-bound-failure.json'))

    def test_overflowed_helper_stderr_is_never_classified_from_partial_text(self):
        caller=self.caller();run=self.ops.commands.run
        def failing(c):
            if c.stage=='prepare-pinned-provisioning-source':return legacy.Result(1,b'',b'x'*(2*1024*1024+1))
            return run(c)
        self.ops.commands.run=failing
        with self.assertRaises(p.Refused):caller.run(self.fixture.packet)
        record=self.runner.worker_records[-1]
        self.assertEqual(record['commandDiagnostic']['code'],'command-output-incomplete')
        self.assertFalse(record['commandDiagnostic']['stderrComplete']);self.assertTrue(record['cleanupConfirmed'])

    def test_no_keychain_content_read_and_no_secret_environment_inherited(self):
        caller=self.caller();read=p.read
        def guarded(path,*args):
            self.assertNotEqual(Path(path),self.material.keychain)
            return read(path,*args)
        with patch.object(p,'read',side_effect=guarded):caller.run(self.fixture.packet)
        self.assertTrue(all('MACOS_CERTIFICATE_PASSWORD' not in c.environment for c in self.ops.commands.commands))

    def test_live_overflow_timeout_descendants_and_wait_failure_remain_bounded(self):
        for i,mode in enumerate(('overflow','stderr-overflow','hang','descendants','wait-failure')):
            r=replace(self.review,output=self.root/('failure-'+str(i)));caller=self.caller(r);self.ops.mode=mode
            with self.subTest(mode=mode),self.assertRaises(p.Refused):caller.run(self.fixture.packet)
            self.assertFalse((r.output/'signer-result.json').exists())
            self.assertTrue(self.ops.processes)
            if mode=='wait-failure':self.assertTrue(self.factory.pending_cleanup);self.assertFalse(self.runner.cleanup_confirmed)
            else:self.assertTrue(all(p.reaped for p in self.ops.processes))

    def test_cancel_and_shared_job_timeout_do_not_reset_per_command(self):
        caller=self.caller();self.ops.callback=lambda _:setattr(self.ops,'now',2401)
        with self.assertRaises(p.Refused):caller.run(self.fixture.packet)
        self.assertTrue(all(p.reaped for p in self.ops.processes))
        r=replace(self.review,output=self.root/'cancelled');caller=self.caller(r);cancel=[False]
        self.ops.callback=lambda _:cancel.__setitem__(0,True)
        with self.assertRaises(p.Refused):caller.run(self.fixture.packet,cancel=lambda:cancel[0])
        self.assertTrue(all(p.reaped for p in self.ops.processes))

    def test_one_shot_and_no_output_reuse_even_after_failure(self):
        caller=self.caller();caller.run(self.fixture.packet)
        with self.assertRaises(p.Refused):caller.run(self.fixture.packet)
        with self.assertRaises(p.Refused):self.caller().run(self.fixture.packet)

    def test_wrong_signing_leaf_and_static_error_do_not_fallback(self):
        for i,fault in enumerate(('leaf','SecStaticCodeCheckValidityWithErrors')):
            r=replace(self.review,output=self.root/('static-fail-'+str(i)));caller=self.caller(r);self.tasks.fault=fault
            with self.subTest(fault=fault),self.assertRaises(p.Refused):caller.run(self.fixture.packet)
            self.assertFalse((r.output/'signer-result.json').exists())
            self.assertFalse(any('security'==Path(c.argv[0]).name for c in self.ops.commands.commands))

    def test_command_policy_denies_private_tools_credentials_runtime_and_env(self):
        caller=self.caller();caller.run(self.fixture.packet)
        valid=self.ops.commands.commands[0]
        bad=[replace(valid,argv=('/usr/bin/security','unlock-keychain')),replace(valid,argv=('/usr/bin/ssh','host')),
             replace(valid,argv=(str(self.review.output/'Private Candidate.app/Contents/MacOS/OmarchyVMManager'),'--verify-bundle-json')),
             replace(valid,environment=dict(valid.environment,DYLD_INSERT_LIBRARIES='secret')),
             replace(valid,environment={k:v for k,v in valid.environment.items() if k!='GIT_CEILING_DIRECTORIES'}),
             replace(valid,environment=dict(valid.environment,GIT_CEILING_DIRECTORIES=str(self.material.upstream))),
             replace(valid,argv=(legacy.TOOLS['git'],'-c','core.fsmonitor=false','-c','core.hooksPath=/dev/null','-C',str(self.material.upstream),'checkout','--detach','1'*40)),
             replace(valid,stage='build-scoped-signed-prerelease',argv=(legacy.TOOLS['make'],'-o','prepare-source','build-signed','SWIFT_FLAGS=--disable-automatic-resolution; forbidden-command'))]
        for c in bad:
            with self.subTest(argv=c.argv),self.assertRaises(p.Refused):self.factory.validate(c)

    def test_candidate_api_requires_exact_identifier_flags_and_public_leaf(self):
        ffi=FakeFFI();ffi.identifier_for_path=lambda _:p.BUNDLE_ID
        api=native.MacOSAPI(ffi.bindings)
        spec=worker.task('candidate-code',path=str(self.root),identifier=p.BUNDLE_ID,team=self.material.team,nested=True,entitlements={})
        result=worker.perform(spec,api)
        self.assertEqual(result['validationFlags'],worker.STATIC_FLAGS|worker.CHECK_NESTED)
        self.assertEqual(worker.unblob(result['certificate']),ffi.public_leaf);self.assertFalse(ffi.owned)
        with self.assertRaises(p.Refused):worker.perform(worker.task('candidate-code',path=str(self.root),identifier='arbitrary.app',team=self.material.team,nested=True,entitlements={}),api)


if __name__=='__main__':unittest.main()
