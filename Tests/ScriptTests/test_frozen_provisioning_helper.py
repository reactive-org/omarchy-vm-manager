"""Execute exact frozen helper bytes in disposable public-source fixtures only.

No candidate, runtime, keychain, compiler or signer is used. Child processes are
only the installed Python and filter-free local Git patch checks.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'Scripts'))
import provisioning_package as package
from private_provisioning_signer import Command
from command_failure_diagnostics import classify_failure

FROZEN=Path(__file__).parent/'Fixtures/frozen_provisioning_package.py'
FROZEN_SHA='d8dd52279c990c29925ac98761f4b8ad1f5ec6db88dd13cee15c7c15138df13f'


class FrozenHelperTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='frozen-helper-fixture-');self.addCleanup(self.temp.cleanup)
        self.base=Path(self.temp.name).resolve();self.candidate=self.base/'candidate';self.root=self.candidate/'source'
        self.root.mkdir(parents=True,mode=0o700)
        for name in ('Config','Scripts','Sources/OmarchyVMManagerCore'):(self.root/name).mkdir(parents=True,mode=0o700)
        self.assertEqual(hashlib.sha256(FROZEN.read_bytes()).hexdigest(),FROZEN_SHA)
        shutil.copy2(FROZEN,self.root/'Scripts/provisioning_package.py')
        shutil.copy2(package.ROOT/package.LOCK,self.root/package.LOCK)
        self.lock=json.loads((self.root/package.LOCK).read_bytes())
        shutil.copytree(package.ROOT/self.lock['package'],self.root/self.lock['package'])
        for patch in self.lock['integrationPatches']:
            path=self.root/patch['path'];path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
            shutil.copy2(package.ROOT/patch['path'],path)
        shutil.copy2(package.ROOT/'Sources/OmarchyVMManagerCore/ProvisioningPackagePin.swift',self.root/'Sources/OmarchyVMManagerCore/ProvisioningPackagePin.swift')
        (self.candidate/'home').mkdir(mode=0o700)
        self.environment={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','HOME':str(self.candidate/'home'),'TMPDIR':str(self.candidate),
            'LC_ALL':'C','LANG':'C','MACOSX_DEPLOYMENT_TARGET':'15.0','GIT_CONFIG_NOSYSTEM':'1','GIT_CONFIG_GLOBAL':'/dev/null',
            'GIT_TERMINAL_PROMPT':'0','HOMEBREW_NO_AUTO_UPDATE':'1','HOMEBREW_NO_ANALYTICS':'1'}

    def repository(self):
        result=subprocess.run(['/usr/bin/git','-c','core.hooksPath=/dev/null','-c','init.defaultBranch=fixture','init',str(self.base)],
            env=self.environment,stdin=subprocess.DEVNULL,capture_output=True,timeout=5)
        self.assertEqual(result.returncode,0)
        (self.base/'.gitignore').write_text('candidate/\n')

    def execute(self,ceiling):
        env=dict(self.environment)
        if ceiling:env['GIT_CEILING_DIRECTORIES']=str(self.candidate)
        command=(str(Path(sys.executable).resolve()),str(self.root/'Scripts/provisioning_package.py'))
        result=subprocess.run(command,cwd=self.root,env=env,stdin=subprocess.DEVNULL,capture_output=True,timeout=15)
        self.assertLessEqual(len(result.stdout),2097152);self.assertLessEqual(len(result.stderr),2097152)
        spec=Command('prepare-pinned-provisioning-source','build',command,self.root,env,'0'*64,'0'*64,'0'*64)
        diagnosis=classify_failure(spec,result.returncode,result.stderr,True) if result.returncode else None
        # Assertions expose only fixed classification, never child traceback/path.
        return result.returncode,diagnosis

    def assert_prepared(self):
        launcher=self.root/'.build/provisioning-launcher-source'
        self.assertEqual(package.files(launcher).keys(),{'Package.swift','Sources/main.c'})
        self.assertEqual((launcher/'Sources/main.c').read_bytes(),(self.root/self.lock['package']/'Sources/dev-vm-process-host/main.c').read_bytes())
        self.assertEqual(package.files(self.root/self.lock['package']),self.lock['files'])
        self.assertFalse((self.root/'Private Candidate.app').exists())

    def test_exact_frozen_helper_outside_repository_generates_only_expected_inputs(self):
        self.assertEqual(self.execute(False),(0,None));self.assert_prepared()

    def test_nested_ignored_checkout_reproduces_patch_base_failure_without_ceiling(self):
        self.repository();status,diagnosis=self.execute(False)
        self.assertEqual(status,1);self.assertEqual(diagnosis['code'],'provisioning-patch-base-mismatch')
        self.assertFalse((self.root/'.build/provisioning-launcher-source').exists())

    def test_private_ceiling_restores_nested_preparation_without_changing_pins(self):
        self.repository();lock=(self.root/package.LOCK).read_bytes();pin=(self.root/'Sources/OmarchyVMManagerCore/ProvisioningPackagePin.swift').read_bytes()
        self.assertEqual(self.execute(True),(0,None));self.assert_prepared()
        self.assertEqual((self.root/package.LOCK).read_bytes(),lock)
        self.assertEqual((self.root/'Sources/OmarchyVMManagerCore/ProvisioningPackagePin.swift').read_bytes(),pin)

    def test_ceiling_preserves_normal_outside_checkout_behavior_and_idempotence(self):
        self.assertEqual(self.execute(True),(0,None));self.assertEqual(self.execute(True),(0,None));self.assert_prepared()

    def test_changed_source_still_refuses_under_ceiling(self):
        self.repository();(self.root/self.lock['package']/'Package.swift').write_bytes(b'changed fixture')
        status,diagnosis=self.execute(True);self.assertEqual(status,1);self.assertEqual(diagnosis['code'],'provisioning-source-changed')

    def test_changed_patch_still_refuses_under_ceiling(self):
        path=self.root/self.lock['integrationPatches'][0]['path'];path.write_bytes(b'changed fixture')
        status,diagnosis=self.execute(True);self.assertEqual(status,1);self.assertEqual(diagnosis['code'],'provisioning-patch-changed')

    def test_unexpected_launcher_input_is_never_accepted(self):
        self.assertEqual(self.execute(True),(0,None))
        (self.root/'.build/provisioning-launcher-source/extra.c').write_bytes(b'not compiled')
        status,diagnosis=self.execute(True);self.assertEqual(status,1);self.assertEqual(diagnosis['code'],'provisioning-launcher-input')

    def test_optional_plugin_environment_stays_denied(self):
        self.environment['TOMLDECODER_DOCS']='1'
        status,diagnosis=self.execute(True);self.assertEqual(status,1);self.assertEqual(diagnosis['code'],'provisioning-optional-plugin')


class CommandDiagnosticTests(unittest.TestCase):
    def setUp(self):
        self.command=Command('prepare-pinned-provisioning-source','build',('/fixture/python','/fixture/helper'),Path('/fixture'),{},'0'*64,'0'*64,'0'*64)

    def test_only_exact_final_allowlisted_line_classifies(self):
        value=classify_failure(self.command,1,b'Traceback: secret path\nValueError: Provisioning patch base differs\n',True)
        self.assertEqual(value,{'format':1,'phase':'provisioning-prepare','code':'provisioning-patch-base-mismatch','stderrComplete':True})
        self.assertNotIn('secret',str(value))

    def test_embedded_or_suffixed_secret_and_partial_or_non_bytes_never_match(self):
        for data in (b'secret ValueError: Provisioning patch base differs\n',b'ValueError: Provisioning patch base differs: /secret\n',
                     b'ValueError: Provisioning patch base differs\nsecret tail',b'\xffsecret',{'secret':'not bytes'}):
            self.assertEqual(classify_failure(self.command,1,data,True)['code'],'command-exit-unclassified')
        self.assertEqual(classify_failure(self.command,1,b'ValueError: Provisioning patch base differs',False)['code'],'command-output-incomplete')

    def test_other_stages_and_signal_status_have_only_fixed_generic_tokens(self):
        from dataclasses import replace
        c=replace(self.command,stage='secret stage',effect='sign-with-timestamp')
        value=classify_failure(c,-9,b'ValueError: Provisioning patch base differs',True)
        self.assertEqual(value['code'],'command-signal');self.assertEqual(value['phase'],'sign');self.assertNotIn('secret',str(value))
        self.assertEqual(classify_failure(self.command,-9,b'ValueError: Provisioning patch base differs',True)['code'],'command-signal')


if __name__=='__main__':unittest.main()
