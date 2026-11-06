"""Explicit bounded build/sign process factory. No CLI or default activation."""
from pathlib import Path
import subprocess
import re
import shlex
import threading

import private_provisioning_package as p
from private_provisioning_signer import Command, TOOLS
from offline_inspection_runner import Runner, MAX_WORKERS
from offline_native_process import ProcessHandle, ProcessOps
from offline_inspection_worker import candidate_identifier

EFFECTS = frozenset({'build', 'inspect', 'selected-key-use', 'secure-key-ui', 'apple-timestamp'})


class CommandHandle(ProcessHandle):
    def prepare(self):
        super().prepare()
        self._close_stream('stdin')  # Commands never receive secrets or a task frame.


class CommandFactory:
    def __init__(self, review, material, ops=None):
        self.review, self.material = review, material
        self.ops = ops if ops is not None else ProcessOps()
        self.test_double = self.ops.test_double
        self.pending_cleanup = []; self.cleanup_records = []; self.serial = 0
        self.authorization = None

    def bind_authorization(self, a):
        from receipt_bound_signing import SigningAuthorization
        p.require(type(a) is SigningAuthorization and type(a.effects) is frozenset and a.effects == EFFECTS
                  and a.requestSHA256 == self.review.request_digest()
                  and self.material.binding() == self.review.materialSHA256
                  and self.test_double is self.review.fixture
                  and self.implementationSHA256 == self.review.implementationSHA256, 'signing-factory-authority')
        p.require(self.authorization is None or self.authorization == a,'signing-factory-rebinding')
        self.authorization=a

    @property
    def implementationSHA256(self):
        from private_provisioning_offline import implementation_digest
        return implementation_digest()

    def validate(self, c):
        p.require(type(c) is Command and c.cwd.is_absolute() and c.cwd.resolve() == c.cwd
                  and (c.cwd == self.review.output or self.review.output in c.cwd.parents), 'signing-command-cwd')
        expected = {'PATH':'/usr/bin:/bin:/usr/sbin:/sbin', 'HOME':str(self.review.output/'home'),
            'TMPDIR':str(self.review.output), 'LC_ALL':'C', 'LANG':'C', 'MACOSX_DEPLOYMENT_TARGET':'15.0',
            'GIT_CONFIG_NOSYSTEM':'1', 'GIT_CONFIG_GLOBAL':'/dev/null', 'GIT_TERMINAL_PROMPT':'0',
            'GIT_CEILING_DIRECTORIES':str(self.review.output),
            'HOMEBREW_NO_AUTO_UPDATE':'1', 'HOMEBREW_NO_ANALYTICS':'1'}
        p.require(c.environment == expected and type(c.argv) is tuple and len(c.argv)>0 and all(type(a) is str for a in c.argv), 'signing-command-environment')
        args = c.argv; source = self.review.output/'source'
        if c.effect == 'sign-with-timestamp':
            prefix = (TOOLS['codesign'], '--force', '--sign', self.material.identity, '--keychain', str(self.material.keychain), '--options','runtime','--timestamp')
            app = self.review.output/'Private Candidate.app'
            if c.stage == 'sign-outer-app':
                expected_args = prefix + ('--identifier',p.BUNDLE_ID,'--entitlements',str(self.review.output/'manager.entitlements.plist'),str(app))
            else:
                name = c.stage.removeprefix('sign-child-') if hasattr(str,'removeprefix') else c.stage[len('sign-child-'):]
                p.require(c.stage.startswith('sign-child-') and name in p.CHILDREN, 'signing-command-stage')
                expected_args = prefix + ('--identifier',candidate_identifier(name),str(app/'Contents/MacOS'/name))
            p.require(args == expected_args, 'signing-command-key-scope')
        else:
            p.require(c.effect == 'build', 'signing-command-effect')
            flags=['--disable-sandbox','--skip-update','--disable-automatic-resolution',
                '--cache-path',str(source/'.build/swiftpm-cache'),'--config-path',str(source/'.build/swiftpm-configuration'),
                '--security-path',str(source/'.build/swiftpm-security')]
            if args[0] == TOOLS['git']:
                patch=self.material.signed_runtime.parent/'inputs/candidate-overlay.patch'
                if c.stage in ('check-original-overlay','apply-original-overlay'):
                    expected_args=(TOOLS['git'],'apply',*(('--check',) if c.stage=='check-original-overlay' else ()),str(patch))
                    p.require(args==expected_args and c.cwd==source,'signing-git-policy')
                elif c.stage in ('copy-local-client','copy-local-parser'):
                    label=c.stage[len('copy-local-'):]
                    origin=self.material.upstream if label=='client' else self.material.parser_checkout
                    p.require(args==(TOOLS['git'],'-c','core.hooksPath=/dev/null','clone','--local','--no-hardlinks','--no-checkout','--',str(origin),str(self.review.output/'dependencies'/label)),'signing-git-policy')
                else:
                    p.require(args[1:6]==('-c','core.fsmonitor=false','-c','core.hooksPath=/dev/null','-C') and len(args)>=8,'signing-git-policy')
                    target=Path(args[6]); operation=args[7:]
                    private=target in (self.review.output/'dependencies/client',self.review.output/'dependencies/parser')
                    if operation==('rev-parse','HEAD'):
                        p.require(private or target in (self.material.upstream,self.material.parser_checkout),'signing-git-policy')
                    else:
                        p.require(private and len(operation)==3 and operation[:2]==('checkout','--detach') and re.fullmatch('[0-9a-f]{40}',operation[2]),'signing-git-policy')
            elif args[0] == TOOLS['python']:
                p.require(c.stage == 'prepare-pinned-provisioning-source' and args == (TOOLS['python'],str(source/'Scripts/provisioning_package.py')) and c.cwd==source, 'signing-python-policy')
            elif args[0] == TOOLS['make']:
                value=' '.join(shlex.quote(x) for x in flags).replace('$','$$')
                p.require(c.stage == 'build-scoped-signed-prerelease' and args==(TOOLS['make'],'-o','prepare-source','build-signed','SWIFT_FLAGS='+value) and c.cwd==source,'signing-make-policy')
            elif args[0] == TOOLS['swift']:
                launcher=('--package-path',str(source/'.build/provisioning-launcher-source'),'--scratch-path',str(source/'.build/provisioning-launcher')) if c.stage=='locate-built-launcher' else ()
                p.require(c.stage in ('locate-built-binaries','locate-built-launcher') and args==(TOOLS['swift'],'build',*flags,*launcher,'-c','release','--show-bin-path') and c.cwd==source,'signing-swift-policy')
            else: raise p.Refused('signing-program-denied')

    def _closed(self, h):
        self.cleanup_records.append(h.evidence())
        if not (h.reaped and h.quiet and h.clean_descriptors):
            if h not in self.pending_cleanup: self.pending_cleanup.append(h)
        elif h in self.pending_cleanup: self.pending_cleanup.remove(h)

    def spawn(self, c):
        p.require(self.authorization is not None, 'signing-factory-not-authorized')
        self.bind_authorization(self.authorization)
        p.require((c.requestSHA256,c.scopeSHA256,c.materialSHA256)==
                  (self.review.request_digest(),self.review.scopeSHA256,self.review.materialSHA256),'signing-command-binding')
        p.require(not self.pending_cleanup and self.serial < MAX_WORKERS, 'signing-cleanup-or-count')
        self.validate(c)
        if hasattr(self.ops,'preflight'): self.ops.preflight()
        self.serial += 1; handle = None
        try:
            process = self.ops.popen(c.argv,cwd=c.cwd,env=c.environment,stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,stderr=subprocess.PIPE,bufsize=0,close_fds=True,pass_fds=(),start_new_session=True)
            handle = CommandHandle(process,self.ops,b'',self._closed); handle.prepare(); return handle
        except BaseException:
            if handle is not None:
                try: handle.kill_group()
                except BaseException: pass
                try: handle.wait(timeout=5)
                except BaseException: pass
                try: handle.close()
                except BaseException: pass
            raise p.Refused('signing-process-handoff-failed') from None


class SigningRunner(Runner):
    def __init__(self, review, material, factory=None, authorization=None, clock=None):
        super().__init__(factory,authorization,**({'clock':clock} if clock is not None else {}))
        self.review, self.material = review, material
        self.revalidate = None; self.cancel = None

    def authorize(self, request, scope, material, implementation=None):
        from receipt_bound_signing import SigningAuthorization, SigningReview
        a = self.authorization
        p.require(type(self.review) is SigningReview and type(a) is SigningAuthorization and a.effects == EFFECTS
                  and type(a.effects) is frozenset and a.requestSHA256 == self.review.request_digest(), 'receipt-signing-not-authorized')
        p.require((request,scope,material,implementation or self.review.implementationSHA256) ==
                  (a.requestSHA256,self.review.scopeSHA256,self.review.materialSHA256,self.review.implementationSHA256), 'receipt-signing-authority-binding')
        p.require(self.factory is not None and type(self.factory.test_double) is bool
                  and self.factory.test_double is self.review.fixture and self.material.binding()==material
                  and self.factory.review == self.review and self.factory.material.binding()==material
                  and self.factory.implementationSHA256 == self.review.implementationSHA256, 'receipt-signing-factory-binding')
        self.factory.bind_authorization(a)

    def start(self):
        self.bindings=(self.review.request_digest(),self.review.scopeSHA256,self.review.materialSHA256,self.review.implementationSHA256)
        self.authorize(*self.bindings)
        with self._lock:
            p.require(not self._used,'receipt-signing-runner-used'); self._used=True
        self.deadline=self.clock()+2400

    def run(self, c):
        self.authorize(c.requestSHA256,c.scopeSHA256,c.materialSHA256)
        p.require(c.effect in ('build','sign-with-timestamp') and c.timeout <= (1200 if c.effect=='build' else 120), 'receipt-signing-command-effect')
        self.factory.validate(c)
        return self.run_command(c,self.revalidate,self.cancel)
