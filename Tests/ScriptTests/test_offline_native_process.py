"""Concrete launch/pipe/selector code against fake OS processes and fake FFI."""
import ctypes as C
import errno
import hashlib
import json
import os
from pathlib import Path
import selectors
import signal
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'Scripts'))
import private_provisioning_package as p
import private_provisioning_offline as offline
import offline_inspection_runner as supervisor
import offline_inspection_worker as worker
import offline_native_process as launch
import offline_native_worker as entry
import offline_macos_api as native
import test_private_provisioning_offline as fixture_tests
from test_private_provisioning_offline import PARSER_REVISION, TEAM
from test_offline_macos_bindings import FakeFFI


class FakeFile:
    def __init__(self,ops,process,name):
        self.ops,self.process,self.name=ops,process,name; self.fd=ops.next_fd(); self.closed=False; ops.files[self.fd]=self
    def fileno(self): return self.fd
    def close(self):
        self.closed=True
        if self.name=='stdin': self.process.input_closed()


class FakeSelector:
    def __init__(self,ops): self.ops=ops; self.keys={}; self.closed=False
    def register(self,fd,events,data): self.keys[fd]=SimpleNamespace(fd=fd,data=data)
    def unregister(self,fd): return self.keys.pop(fd)
    def select(self,timeout):
        self.ops.now+=121 if self.ops.mode=='hang' else 0.001
        return [(key,0) for key in list(self.keys.values()) if key.data=='stdin' or self.ops.files[key.fd].process.finished]
    def close(self): self.closed=True; self.keys.clear()


class FakePopen:
    def __init__(self,ops,argv,kwargs):
        self.ops=ops; self.argv=argv; self.kwargs=kwargs; self.pid=9000+len(ops.processes)
        self.stdin=FakeFile(ops,self,'stdin'); self.stdout=FakeFile(ops,self,'stdout'); self.stderr=FakeFile(ops,self,'stderr')
        self.request=bytearray(); self.output={'stdout':bytearray(),'stderr':bytearray()}; self.finished=False
        self.status=None; self.reaped=False; self.children=ops.mode=='descendants'; self.waits=[]
        self.permit=bytes(ops.pipes[kwargs['pass_fds'][0]])
    def input_closed(self):
        if self.finished or self.ops.mode=='hang': return
        try:
            result=entry.run_frame(self.permit,bytes(self.request),self.ops.parent_pid(),
                api_factory=lambda:native.MacOSAPI(self.ops.ffi.bindings,dependency_checker=self.ops.dependency),
                digest=lambda:self.ops.implementation)
            self.output['stdout'].extend(result); self.status=0
            if self.ops.mode=='overflow': self.output['stdout']=bytearray(b'x'*(supervisor.MAX_OUTPUT+1))
            if self.ops.mode=='bad-mode':
                value=p.decode(result); value['_offlineAPITestDouble']=False; self.output['stdout']=bytearray(p.canonical(value))
        except BaseException:
            self.output['stderr'].extend(b'offline-native-worker-refused'); self.status=1
        self.finished=True
    def wait(self,timeout):
        self.waits.append(timeout)
        if self.ops.mode=='wait-failure': raise TimeoutError('do-not-log')
        assert self.finished and not self.children
        self.reaped=True; self.ops.trace.append(('reap',self.pid)); return self.status


class FakeOps:
    test_double=True
    def __init__(self,fixture,implementation):
        self.fixture=fixture; self.implementation=implementation; self.now=0; self.fd=100; self.files={}; self.pipes={}; self.pair={}
        self.closed_fds=set(); self.processes=[]; self.trace=[]; self.mode=None; self.ffi=FakeFFI(); self.selectors=[]
        self.ffi.entitlements_for_path=lambda path: {'com.apple.security.hypervisor':True} if path.name in ('omarchy-vm-helper','TryOmarchyKit.bundle') else {}
    def next_fd(self): self.fd+=1; return self.fd
    def parent_pid(self): return 7000
    def nonce(self): return 'a'*64
    def clock(self): return self.now
    def pause(self,seconds): self.now+=seconds
    def dependency(self,path): return {'revision':PARSER_REVISION if path==self.fixture.material.parser_checkout else self.fixture.runtime['patchCommit'],'clean':True}
    def pipe(self):
        r,w=self.next_fd(),self.next_fd(); self.pipes[r]=bytearray(); self.pair[w]=r; return r,w
    def close_fd(self,fd): self.closed_fds.add(fd)
    def blocking(self,fd,enabled): assert enabled is False
    def write(self,fd,data):
        if fd in self.pair: self.pipes[self.pair[fd]].extend(data); return len(data)
        file=self.files[fd]; assert file.name=='stdin'
        if self.mode=='broken-input': raise BrokenPipeError()
        amount=min(len(data),17)  # Exercise partial nonblocking input writes.
        file.process.request.extend(data[:amount]); return amount
    def read(self,fd,maximum):
        file=self.files[fd]; data=file.process.output[file.name]
        result=bytes(data[:maximum]); del data[:maximum]; return result
    def selector(self):
        result=FakeSelector(self); self.selectors.append(result)
        if self.mode=='selector-failure': raise RuntimeError('do-not-log')
        return result
    def popen(self,argv,**kwargs):
        assert argv[1:3]==['-I','-B'] and argv[3].endswith('/offline_native_worker.py') and argv[4]=='--worker-fd'
        assert kwargs['start_new_session'] and kwargs['close_fds'] and kwargs['bufsize']==0
        assert kwargs['pass_fds']==(int(argv[-1]),)
        assert set(kwargs['env'])=={'PATH','HOME','TMPDIR','LC_ALL','PYTHONNOUSERSITE','PYTHONDONTWRITEBYTECODE'}
        if self.mode=='spawn-failure': raise OSError('do-not-log')
        process=FakePopen(self,argv,kwargs); self.processes.append(process); self.trace.append(('spawn',process.pid)); return process
    def find(self,pid): return next(proc for proc in self.processes if proc.pid==pid)
    def observe(self,pid):
        process=self.find(pid)
        if process.reaped: raise ChildProcessError('Already released root')
        return process.status if process.finished else None
    def group_members(self,pid):
        process=self.find(pid); assert not process.reaped
        return [pid]+([pid+100] if process.children else [])
    def kill_group(self,pid):
        process=self.find(pid); assert not process.reaped
        process.children=False
        if not process.finished: process.finished=True; process.status=-signal.SIGKILL
        self.trace.append(('kill-group',pid))


class NativeLaunchTests(unittest.TestCase):
    def setUp(self):
        # Reuse only synthetic input preparation, not that class's test methods.
        self.fixture_case=fixture_tests.OfflineTests(methodName='test_default_denial_precedes_all_source_and_material_io')
        self.fixture_case.setUp(); self.addCleanup(self.fixture_case.doCleanups)
        f=self.fixture_case; self.root=f.root; self.fixture=f.fixture; self.review=f.review; self.selection=f.selection
        self.ops=FakeOps(self.fixture,offline.implementation_digest())
        self.factory=launch.MacOSWorkerFactory(self.review,self.fixture.review.scopeSHA256,self.selection.binding(),True,self.ops)
        self.auth=supervisor.OfflineAuthorization(self.review.request_digest(),self.fixture.review.scopeSHA256,self.selection.binding(),self.review.implementationSHA256,frozenset({'offline-native-inspect'}))

    def caller(self):
        self.runner=supervisor.Runner(self.factory,self.auth,self.ops.clock)
        return offline.OfflineInspectionCaller(self.fixture.review,self.selection,self.review,self.runner,wall_clock=lambda:1_800_000_000)

    def test_full_adapter_through_concrete_launcher_and_bindings_uses_only_fake_primitives(self):
        before=p.tree(self.fixture.packet)
        result=self.caller().run(self.fixture.packet)
        self.assertEqual(result['status'],'FAKE_OFFLINE_INSPECTION_ONLY'); self.assertFalse(result['nativeValidationObserved'])
        self.assertTrue(result['cleanupConfirmed']); self.assertEqual(before,p.tree(self.fixture.packet))
        self.assertFalse(self.factory.pending_cleanup); self.assertFalse(self.ops.ffi.owned)
        self.assertTrue(all(proc.reaped and proc.stdin.closed and proc.stdout.closed and proc.stderr.closed for proc in self.ops.processes))
        self.assertTrue(all(sel.closed for sel in self.ops.selectors))
        self.assertEqual(len(self.ops.closed_fds),2*len(self.ops.processes))
        self.assertFalse(any(action=='kill-group' for action,_ in self.ops.trace))

    def test_factory_without_typed_authorization_has_no_fd_process_or_library_effect(self):
        with self.assertRaises(p.Refused): self.factory.spawn(worker.task('locked',path=str(self.fixture.material.keychain)))
        self.assertEqual(self.ops.processes,[]); self.assertEqual(self.ops.pipes,{}); self.assertEqual(self.ops.ffi.loads,[])
        with self.assertRaises(p.Refused): self.factory.bind_authorization({})

    def test_fixture_cannot_arm_default_real_factory(self):
        factory=launch.MacOSWorkerFactory(self.review,self.fixture.review.scopeSHA256,self.selection.binding(),True)
        with self.assertRaises(p.Refused): factory.bind_authorization(self.auth)

    def test_frame_requires_pipe_capability_parent_task_code_and_mode(self):
        body={'kind':'locked','fields':{'path':str(self.fixture.material.keychain)}}
        permit={'token':'a'*64,'taskSHA256':p.digest(p.canonical(body)),'implementationSHA256':self.review.implementationSHA256,'parent':7000,'testDouble':True}
        request=dict(body,token='a'*64)
        for name,value in (('token','b'*64),('parent',7001),('implementationSHA256','0'*64),('taskSHA256','0'*64),('testDouble',False)):
            altered=dict(permit,**{name:value})
            with self.subTest(name=name),self.assertRaises(p.Refused):
                entry.run_frame(p.canonical(altered),p.canonical(request),7000,api_factory=lambda:native.MacOSAPI(self.ops.ffi.bindings),digest=lambda:self.review.implementationSHA256)
        self.assertEqual(self.ops.ffi.loads,[])

    def test_duplicate_or_oversized_wire_refuses_before_api(self):
        for permit in (b'{"token":1,"token":2}',b'x'*(launch.PERMIT_LIMIT+1)):
            with self.assertRaises(p.Refused): entry.run_frame(permit,b'{}',7000)
        self.assertEqual(self.ops.ffi.loads,[])

    def test_live_failure_kills_active_groups_and_reaps_already_quiet_roots(self):
        for i,mode in enumerate(('overflow','broken-input','hang','bad-mode')):
            f=self.fixture_case
            review=offline.OfflineReview(self.review.sourceRequestSHA256,self.review.selectionSHA256,self.review.publicCertificateSHA256,self.review.implementationSHA256,self.review.helperEntitlementsSHA256,self.review.qemuEntitlementsSHA256,self.root/('failed-'+str(i)))
            ops=FakeOps(self.fixture,review.implementationSHA256); ops.mode=mode
            factory=launch.MacOSWorkerFactory(review,self.fixture.review.scopeSHA256,self.selection.binding(),True,ops)
            auth=supervisor.OfflineAuthorization(review.request_digest(),self.auth.scopeSHA256,self.auth.selectionSHA256,self.auth.implementationSHA256,self.auth.effects)
            caller=offline.OfflineInspectionCaller(self.fixture.review,self.selection,review,supervisor.Runner(factory,auth,ops.clock))
            with self.subTest(mode=mode),self.assertRaises(p.Refused): caller.run(self.fixture.packet)
            self.assertTrue(ops.processes[0].reaped)
            if mode in ('bad-mode','overflow'):
                self.assertNotIn(('kill-group',ops.processes[0].pid),ops.trace)
            else: self.assertIn(('kill-group',ops.processes[0].pid),ops.trace)
            self.assertFalse((review.output/'offline-inspection.json').exists())

    def test_root_is_not_reaped_while_descendants_remain(self):
        self.ops.mode='descendants'
        with self.assertRaises(p.Refused): self.caller().run(self.fixture.packet)
        self.assertEqual([name for name,_ in self.ops.trace],['spawn','kill-group','reap'])

    def test_setup_failure_after_spawn_kills_reaps_and_closes_all_streams(self):
        self.ops.mode='selector-failure'
        with self.assertRaises(p.Refused): self.caller().run(self.fixture.packet)
        proc=self.ops.processes[0]
        self.assertTrue(proc.reaped and proc.stdin.closed and proc.stdout.closed and proc.stderr.closed)
        self.assertEqual([name for name,_ in self.ops.trace],['spawn','kill-group','reap'])

    def test_failed_reap_retains_actionable_handle_and_blocks_further_spawn(self):
        self.ops.mode='wait-failure'
        with self.assertRaises(p.Refused): self.caller().run(self.fixture.packet)
        self.assertTrue(self.factory.pending_cleanup)
        self.assertFalse(self.runner.cleanup_confirmed)
        with self.assertRaises(p.Refused): self.factory.spawn(worker.task('locked',path=str(self.fixture.material.keychain)))
        self.assertEqual(len(self.ops.processes),1)

    def test_no_signal_or_group_query_after_releasing_root_identity(self):
        self.caller().run(self.fixture.packet)
        proc=self.ops.processes[0]
        handle=launch.ProcessHandle(proc,self.ops,b'')
        handle.reaped=handle.quiet=True; handle.status=0
        trace=list(self.ops.trace); handle.kill_group(); self.assertFalse(handle.group_alive())
        self.assertEqual(trace,self.ops.trace)

    def test_observation_uses_wnowait_without_reaping(self):
        ops=launch.ProcessOps()
        with patch('os.waitid',return_value=SimpleNamespace(si_code=getattr(os,'CLD_EXITED',1),si_status=0),create=True) as wait:
            self.assertEqual(ops.observe(12345),0)
            self.assertTrue(wait.call_args[0][2]&os.WNOWAIT)

    def test_darwin_waitid_binding_marshals_siginfo_without_reaping(self):
        class Fn:
            argtypes=restype=None
            code=1; child=12345; status=7; error=0
            def __call__(self,kind,pid,out,flags):
                self.args=(kind,pid,flags)
                if self.error: C.set_errno(self.error); return -1
                info=C.cast(out,C.POINTER(launch.SigInfo))[0]
                info.pid=self.child; info.code=self.code; info.status=self.status; return 0
        fn=Fn(); loaded=[]
        binding=launch.WaitBinding(lambda path:(loaded.append(path) or SimpleNamespace(waitid=fn)))
        self.assertEqual(binding.observe(12345),7)
        self.assertEqual(fn.args,(1,12345,37)); self.assertEqual(C.sizeof(launch.SigInfo),104)
        fn.code=2; self.assertEqual(binding.observe(12345),-7)
        fn.child=0; self.assertIsNone(binding.observe(12345))
        fn.error=errno.ECHILD
        with self.assertRaises(ChildProcessError): binding.observe(12345)
        self.assertEqual(loaded,['/usr/lib/libSystem.B.dylib'])

    def test_system_python_without_waitid_uses_injected_libc_binding(self):
        ops=launch.ProcessOps(); ops._wait=SimpleNamespace(observe=lambda pid:13)
        with patch('os.waitid',create=True):
            saved=os.waitid; del os.waitid
            try: self.assertEqual(ops.observe(12345),13)
            finally: os.waitid=saved

    def test_group_query_ffi_uses_byte_count_and_requires_owned_root(self):
        class Fn:
            argtypes=restype=None
            def __call__(self,kind,group,buffer,size):
                self.args=(kind,group,size)
                C.cast(buffer,C.POINTER(C.c_int))[0]=group
                return C.sizeof(C.c_int)
        fn=Fn(); ops=launch.ProcessOps()
        with patch('ctypes.CDLL',return_value=SimpleNamespace(proc_listpids=fn)) as loader:
            self.assertEqual(ops.group_members(12345),[12345])
            self.assertEqual(fn.args[:2],(2,12345)); loader.assert_called_once_with('/usr/lib/libproc.dylib')
            self.assertEqual(fn.argtypes,[C.c_uint32,C.c_uint32,C.c_void_p,C.c_int])
        ops._list_group=lambda *args:0
        with self.assertRaises(p.Refused): ops.group_members(12345)

    def test_lost_root_ownership_prevents_signaling_a_reused_group(self):
        proc=SimpleNamespace(pid=12345)
        ops=SimpleNamespace(observe=lambda _:(_ for _ in ()).throw(ChildProcessError()),kill_group=lambda _:self.fail('Must not signal unknown group'))
        handle=launch.ProcessHandle(SimpleNamespace(pid=12345,stdin=None,stdout=None,stderr=None),ops,b'')
        with self.assertRaises(ChildProcessError): handle.kill_group()

    def test_internal_entry_rejects_regular_file_or_stdio_as_capability(self):
        for fd in ('0','5'):
            with patch.object(sys,'argv',['worker','--worker-fd',fd]),patch('os.fstat',return_value=SimpleNamespace(st_mode=0o100600)),patch('os.read',side_effect=AssertionError('No reads')):
                with self.assertRaises(p.Refused): entry.main()

    def test_certificate_failure_crosses_authenticated_frame_as_fixed_diagnostic(self):
        self.ops.ffi.fail='SecCertificateCopyNotValidAfterDate'
        with self.assertRaises(p.Refused): self.caller().run(self.fixture.packet)
        evidence=p.decode(p.read(self.review.output/'failure.json'))
        record=evidence['workerEvidence'][-1]
        self.assertEqual(record['kind'],'certificate')
        self.assertEqual(record['exitStatus'],0)  # Envelope delivered, task refused.
        self.assertEqual(record['failureCategory'],'worker-diagnostic')
        self.assertEqual(record['diagnostic'],{'format':1,'code':'certificate-date-unavailable','phase':'certificate-after-date'})
        self.assertTrue(evidence['cleanupConfirmed']); self.assertEqual(evidence['unresolvedHandles'],0)
        self.assertFalse(any(name=='kill-group' for name,_ in self.ops.trace))
        self.assertTrue(all(r['rootReaped'] and r['groupQuietBeforeReap'] and r['descriptorsClosed'] for r in evidence['factoryCleanupEvidence']))
        self.assertNotIn(b'do-not-log',p.read(self.review.output/'failure.json'));self.assertFalse(self.ops.ffi.owned)

    def test_unframed_nonzero_exit_is_recorded_without_redundant_signal_to_quiet_root(self):
        popen=self.ops.popen
        def failed(*args,**kwargs):
            proc=popen(*args,**kwargs)
            def exit_early():
                proc.finished=True; proc.status=7; proc.output['stderr'].extend(b'private raw error')
            proc.input_closed=exit_early
            return proc
        self.ops.popen=failed
        with self.assertRaises(p.Refused): self.caller().run(self.fixture.packet)
        record=self.runner.worker_records[-1]
        self.assertEqual(record['exitStatus'],7);self.assertEqual(record['failureCategory'],'worker-exit')
        self.assertIsNone(record['diagnostic']); self.assertTrue(record['cleanupConfirmed'])
        self.assertNotIn('private raw error',str(record));self.assertFalse(any(name=='kill-group' for name,_ in self.ops.trace))

    def test_cleanup_timeout_is_latched_even_when_fallback_reaps_and_closes(self):
        popen=self.ops.popen
        def timeout_once(*args,**kwargs):
            proc=popen(*args,**kwargs);wait=proc.wait;first=[True]
            def transient(timeout):
                if first[0]:first[0]=False;raise TimeoutError('private cleanup error')
                return wait(timeout)
            proc.wait=transient;return proc
        self.ops.popen=timeout_once
        with self.assertRaises(p.Refused): self.caller().run(self.fixture.packet)
        record=self.runner.worker_records[-1]
        self.assertFalse(record['cleanupConfirmed']);self.assertFalse(self.factory.pending_cleanup)
        self.assertIn({'operation':'wait-primary','result':'timeout'},record['cleanupOperations'])
        self.assertIn({'operation':'wait-fallback','result':'ok'},record['cleanupOperations'])
        self.assertTrue(record['handle']['rootReaped']);self.assertTrue(record['handle']['descriptorsClosed'])
        self.assertNotIn('private cleanup error',str(record))

    def test_cleanup_permission_error_retains_reason_despite_later_clean_handle(self):
        write=self.ops.write
        def broken(fd,data):
            if fd in self.ops.files and self.ops.files[fd].name=='stdin':
                proc=self.ops.files[fd].process;proc.finished=True;proc.status=1
                raise BrokenPipeError('private pipe error')
            return write(fd,data)
        self.ops.write=broken
        self.ops.kill_group=lambda _:(_ for _ in ()).throw(PermissionError('private permission error'))
        with self.assertRaises(p.Refused): self.caller().run(self.fixture.packet)
        record=self.runner.worker_records[-1]
        self.assertIn({'operation':'kill-primary','result':'permission'},record['cleanupOperations'])
        self.assertFalse(record['cleanupConfirmed']);self.assertFalse(self.factory.pending_cleanup)
        self.assertTrue(record['handle']['rootReaped']);self.assertTrue(record['handle']['descriptorsClosed'])
        self.assertNotIn('private permission error',str(record));self.assertNotIn('private pipe error',str(record))

    def test_failure_envelope_extra_data_is_refused_without_persisting_payload(self):
        popen=self.ops.popen
        def corrupted(*args,**kwargs):
            proc=popen(*args,**kwargs);close=proc.input_closed
            def output():
                close()
                proc.output['stdout']=bytearray(p.canonical({'_offlineAPITestDouble':True,
                    'offlineFailure':{'format':1,'code':'native-status','phase':'certificate'},'raw':'private secret'}))
            proc.input_closed=output;return proc
        self.ops.popen=corrupted
        with self.assertRaises(p.Refused):self.caller().run(self.fixture.packet)
        record=self.runner.worker_records[-1]
        self.assertEqual(record['failureCategory'],'worker-diagnostic-invalid');self.assertIsNone(record['diagnostic'])
        self.assertNotIn(b'private secret',p.read(self.review.output/'failure.json'))

    def test_factory_retains_failed_handoff_evidence_and_pending_handle(self):
        self.ops.mode='wait-failure'
        with self.assertRaises(p.Refused): self.caller().run(self.fixture.packet)
        self.assertFalse(self.runner.cleanup_confirmed)
        self.assertTrue(self.factory.cleanup_records);self.assertTrue(self.factory.pending_cleanup)
        self.assertFalse(self.factory.cleanup_records[-1]['rootReaped'])
        self.assertTrue(self.factory.cleanup_records[-1]['descriptorsClosed'])

    def test_worker_count_bound_precedes_any_spawn_or_scratch_directory(self):
        self.factory.bind_authorization(self.auth);self.factory.serial=supervisor.MAX_WORKERS
        with self.assertRaises(p.Refused):self.factory.spawn(worker.task('locked',path=str(self.fixture.material.keychain)))
        self.assertEqual(self.ops.processes,[]);self.assertFalse(self.review.output.exists())

    def test_mode_proof_and_failure_schema_are_required_before_diagnostic_storage(self):
        for bad in ({'format':1,'code':'secret-certificate-subject','phase':'certificate'},
                    {'format':True,'code':'native-status','phase':'certificate'},
                    {'format':1,'code':'native-status','phase':'/secret/path'},
                    {'format':1,'code':'native-status','phase':'certificate','raw':'secret'}):
            with self.subTest(bad=bad),self.assertRaises(p.Refused):worker.validate_failure(bad)

    def test_unknown_native_exception_text_never_enters_failure_frame(self):
        body={'kind':'certificate','fields':{'content':worker.blob(b'synthetic')}}
        permit={'token':'a'*64,'taskSHA256':p.digest(p.canonical(body)),'implementationSHA256':self.review.implementationSHA256,'parent':7000,'testDouble':True}
        api=SimpleNamespace(test_double=True,phase='certificate',disable_interaction=lambda:True,
                            certificate_info=lambda _:(_ for _ in ()).throw(RuntimeError('secret subject /private/key')))
        raw=entry.run_frame(p.canonical(permit),p.canonical(dict(body,token='a'*64)),7000,api_factory=lambda:api,digest=lambda:self.review.implementationSHA256)
        self.assertNotIn(b'secret',raw);self.assertNotIn(b'/private/key',raw)
        self.assertEqual(p.decode(raw)['offlineFailure'],{'format':1,'code':'internal-error','phase':'certificate'})


class GitFile:
    def __init__(self,ops,raw): self.fd=len(ops.files)+200; self.raw=bytearray(raw); self.closed=False; ops.files[self.fd]=self
    def fileno(self): return self.fd
    def close(self): self.closed=True


class GitProcess:
    def __init__(self,ops,raw): self.stdout=GitFile(ops,raw); self.stderr=GitFile(ops,b''); self.killed=False; self.reaped=False
    def wait(self,timeout): self.reaped=True; return 0
    def kill(self): self.killed=True


class GitSelector:
    def __init__(self,ops): self.ops=ops; self.keys={}; self.closed=False
    def register(self,fd,event,name): self.keys[fd]=SimpleNamespace(fd=fd,data=name)
    def unregister(self,fd): self.keys.pop(fd)
    def select(self,timeout): self.ops.now+=11 if self.ops.hang else 0.001; return [] if self.ops.hang else [(key,0) for key in list(self.keys.values())]
    def close(self): self.closed=True


class GitFakeOps:
    test_double=True
    def __init__(self,rows): self.rows=list(rows); self.files={}; self.commands=[]; self.processes=[]; self.now=0; self.hang=False
    def popen(self,argv,**kwargs):
        assert argv[0]=='/usr/bin/git' and kwargs['start_new_session'] is False and kwargs['close_fds']
        assert 'core.fsmonitor=false' in argv and 'core.hooksPath=/dev/null' in argv
        assert kwargs['env']['GIT_CONFIG_GLOBAL']=='/dev/null' and kwargs['env']['GIT_SSH_COMMAND']=='/usr/bin/false'
        self.commands.append(argv); process=GitProcess(self,self.rows.pop(0)); self.processes.append(process); return process
    def selector(self): return GitSelector(self)
    def blocking(self,fd,value): assert value is False
    def read(self,fd,maximum):
        file=self.files[fd]; raw=bytes(file.raw[:maximum]); del file.raw[:maximum]; return raw
    def clock(self): return self.now


class GitBoundaryTests(unittest.TestCase):
    def setUp(self):
        import tempfile
        self.temp=tempfile.TemporaryDirectory(prefix='filter-free-git-fixture-'); self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name).resolve(); self.raw=b'plain source fixture\n'; (self.root/'source.txt').write_bytes(self.raw); (self.root/'source.txt').chmod(0o600)
        self.sha=hashlib.sha1(b'blob '+str(len(self.raw)).encode()+b'\0'+self.raw).hexdigest().encode()
        self.rows=[b'1'*40+b'\n',b'100644 blob '+self.sha+b'\tsource.txt\0',b'',b'100644 '+self.sha+b' 0\tsource.txt\0']
        for name in ('subprocess.Popen','subprocess.run','ctypes.CDLL','socket.socket'):
            guard=patch(name,side_effect=AssertionError('Only fake Git/process/FFI allowed')); guard.start(); self.addCleanup(guard.stop)

    def test_filter_free_metadata_and_raw_worktree_index_comparison(self):
        ops=GitFakeOps(self.rows); result=entry.bounded_git(self.root,ops)
        self.assertTrue(result['clean']); self.assertEqual(result['revision'],'1'*40)
        self.assertEqual(len(ops.commands),4)
        self.assertFalse(any('status' in c or 'diff-index' in c or 'hash-object' in c for c in ops.commands))
        self.assertTrue(all(proc.reaped and proc.stdout.closed and proc.stderr.closed for proc in ops.processes))

    def test_dirty_worktree_index_and_untracked_files_refuse_clean_proof(self):
        (self.root/'source.txt').write_bytes(b'changed')
        self.assertFalse(entry.bounded_git(self.root,GitFakeOps(self.rows))['clean'])
        (self.root/'source.txt').write_bytes(self.raw)
        for index,raw in ((2,b'untracked\0'),(3,b'')):
            rows=list(self.rows); rows[index]=raw
            self.assertFalse(entry.bounded_git(self.root,GitFakeOps(rows))['clean'])

    def test_git_overflow_and_timeout_kill_and_reap_without_raw_diagnostics(self):
        for hang in (False,True):
            ops=GitFakeOps([b'x'*(supervisor.MAX_OUTPUT+1)]); ops.hang=hang
            with self.assertRaisesRegex(p.Refused,'offline-git-refused'): entry.bounded_git(self.root,ops)
            self.assertTrue(ops.processes[0].killed and ops.processes[0].reaped)
            self.assertTrue(ops.processes[0].stdout.closed and ops.processes[0].stderr.closed)

    def test_git_credentials_and_traversal_are_rejected_before_content_reads(self):
        for path in (b'identity.p12',b'../outside',b'.git/config'):
            rows=list(self.rows); rows[1]=b'100644 blob '+self.sha+b'\t'+path+b'\0'; rows[3]=b'100644 '+self.sha+b' 0\t'+path+b'\0'
            with patch.object(p,'read',side_effect=AssertionError('No file contents')),self.assertRaises(p.Refused): entry.bounded_git(self.root,GitFakeOps(rows))


if __name__=='__main__': unittest.main()
