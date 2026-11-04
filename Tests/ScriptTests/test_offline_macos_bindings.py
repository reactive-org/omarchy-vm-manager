"""Concrete ctypes marshalling exercised through fake symbols, never a dylib."""
import ctypes as C
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Scripts"))
import private_provisioning_package as p
import offline_macos_api as native
import offline_inspection_worker as worker
from test_private_provisioning_offline import cms, CERT
from test_private_provisioning_package import FakeSigner, TEAM


def set_out(pointer, value, kind=native.REF): C.cast(pointer, C.POINTER(kind))[0] = kind(value)


class Function:
    def __init__(self, ffi, name): self.ffi, self.name = ffi, name; self.argtypes = self.restype = None
    def __call__(self, *args):
        assert len(args) == len(self.argtypes)
        self.ffi.calls.append((self.name, args)); return self.ffi.call(self.name, *args)


class Library:
    def __init__(self, ffi): self.ffi = ffi
    def __getattr__(self, name):
        if name not in self.ffi.functions: self.ffi.functions[name] = Function(self.ffi, name)
        return self.ffi.functions[name]


class FakeFFI:
    types = {"Data": 1, "String": 2, "Dictionary": 3, "Number": 4, "Date": 5, "Boolean": 6, "Code": 7, "Error": 8, "Keychain": 9, "Decoder": 10, "Requirement": 11, "URL": 12}

    def __init__(self):
        self.heap = {}; self.owned = set(); self.counter = 100; self.calls = []; self.loads = []; self.functions = {}; self.buffers = []
        self.fail = None; self.overrides = {}; self.keychain_status = 6
        self.certificate_dates = {"SecCertificateCopyNotValidBeforeDate": ("Date", 0),
                                  "SecCertificateCopyNotValidAfterDate": ("Date", 3_000_000_000)}
        self.entitlements_for_path = lambda path: {}
        self.bindings = native.Bindings(self.load, self.constant)

    def node(self, kind, value, owned=True):
        self.counter += 1; self.heap[self.counter] = (kind, value)
        if owned: self.owned.add(self.counter)
        return self.counter

    def load(self, path):
        assert path in ('/System/Library/Frameworks/Security.framework/Security', '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
        self.loads.append(path); return Library(self)

    def constant(self, lib, name):
        assert name in native.CONSTANTS
        return self.node("String", name, False)

    def value(self, ref): return self.heap[ref][1]
    def data(self, raw, owned=True): return self.node("Data", raw, owned)
    def string(self, text, owned=True): return self.node("String", text, owned)
    def dictionary(self, fields, owned=True):
        values = {}
        for key, value in fields.items():
            if isinstance(value, tuple): kind, value = value
            else: kind = "String"
            values[key] = self.node(kind, value, False)
        return self.node("Dictionary", values, owned)

    def call(self, name, *a):
        if name == "CFRelease":
            assert a[0] in self.owned, 'Only owned refs may be released'
            self.owned.remove(a[0]); return None
        if name.endswith("GetTypeID"):
            return self.types[self.heap[a[0]][0]] if name == "CFGetTypeID" else self.types[name[2:-9]]
        if name == "CFDataCreate": return self.data(C.string_at(a[1], a[2]))
        if name == "CFDataGetLength": return len(self.value(a[0]))
        if name == "CFDataGetBytePtr":
            buf = C.create_string_buffer(self.value(a[0])); self.buffers.append(buf); return C.addressof(buf)
        if name in ("CFStringCreateWithBytes", "CFURLCreateFromFileSystemRepresentation"):
            text = C.string_at(a[1], a[2]).decode()
            return self.node("String" if name.startswith("CFString") else "URL", text)
        if name == "CFStringGetLength": return len(self.value(a[0]).encode('utf-16-le'))//2
        if name == "CFStringGetMaximumSizeForEncoding": return a[0] * 4
        if name == "CFStringGetCString": C.memmove(a[1], self.value(a[0]).encode() + b"\0", len(self.value(a[0]).encode()) + 1); return 1
        if name == "CFDictionaryGetValue": return self.value(a[0]).get(self.value(a[1]), 0)
        if name == "CFNumberGetValue": assert a[1] == 4; set_out(a[2], self.value(a[0]), C.c_int64); return 1
        if name == "CFDateGetAbsoluteTime": return self.value(a[0])
        if name == "CFPropertyListCreateData":
            assert a[2:4] == (100, 0)
            return self.data(plistlib.dumps(self.value(a[1])))
        if name == "SecKeychainSetUserInteractionAllowed": assert a == (0,); return -50 if self.fail == name else 0
        if name == "SecKeychainOpen":
            set_out(a[-1], self.node("Keychain", a[0])); return -50 if self.fail == name else 0
        if name == "SecKeychainGetStatus": set_out(a[-1], self.keychain_status, native.U32); return -50 if self.fail == name else 0
        if name == "CMSDecoderCreate": set_out(a[0], self.node("Decoder", b"")); return -50 if self.fail == name else 0
        if name == "CMSDecoderUpdateMessage": self.heap[a[0]] = ("Decoder", C.string_at(a[1], a[2])); return -50 if self.fail == name else 0
        if name == "CMSDecoderFinalizeMessage": return -50 if self.fail == name else 0
        if name == "CMSDecoderCopyContent":
            set_out(a[-1], self.data(worker.signed_content(self.value(a[0])))); return -50 if self.fail == name else 0
        if name == "SecCertificateCreateWithData": return self.node("Code", self.value(a[1]))
        if name == "SecCertificateCopyCommonName": set_out(a[-1], self.string('Developer ID Application: Fixture Only (' + TEAM + ')')); return -50 if self.fail == name else 0
        if name in self.certificate_dates:
            if self.fail == name: return 0
            kind, value = self.certificate_dates[name]
            return self.node(kind, value)
        if name == "SecStaticCodeCreateWithPath": set_out(a[-1], self.node('Code', self.value(a[0]))); return -50 if self.fail == name else 0
        if name == "SecRequirementCreateWithString": set_out(a[-1], self.node('Requirement', self.value(a[0]))); return -50 if self.fail == name else 0
        if name == "SecStaticCodeCheckValidityWithErrors":
            assert a[1] in (worker.STATIC_FLAGS, worker.STATIC_FLAGS | worker.CHECK_NESTED)
            assert self.value(a[2]) == worker.requirement_for(TEAM)
            if self.fail == name: set_out(a[-1], self.node('Error', 'not logged')); return -67061
            return 0
        if name == "SecCodeCopySigningInformation":
            assert a[1] == native.SIGNING_INFORMATION
            fields = {'kSecCodeInfoIdentifier': 'dev.tryomarchy.kit', 'kSecCodeInfoTeamIdentifier': TEAM,
                      'kSecCodeInfoFlags': ('Number', worker.RUNTIME), 'kSecCodeInfoTimestamp': ('Date', 500_000_000),
                      'kSecCodeInfoEntitlementsDict': ('Dictionary', self.entitlements_for_path(Path(self.value(a[0]))))}
            fields.update(self.overrides); fields = {k:v for k,v in fields.items() if v is not None}
            set_out(a[-1], self.dictionary(fields)); return -50 if self.fail == name else 0
        raise AssertionError('Unexpected FFI symbol: ' + name)


class BindingsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='fake-native-ffi-'); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve(); self.ffi = FakeFFI(); self.api = native.MacOSAPI(self.ffi.bindings)
        for name in ('ctypes.CDLL','subprocess.Popen','subprocess.run','socket.socket'):
            guard = patch(name, side_effect=AssertionError('No real FFI/process/network permitted'))
            guard.start(); self.addCleanup(guard.stop)

    def test_lazy_construction_and_closed_symbol_surface(self):
        native.MacOSAPI(); native.Bindings()
        self.assertEqual(self.ffi.loads, [])
        for symbol in ('SecTrustEvaluate','SecItemCopyMatching','SecKeychainUnlock','SecCodeSignerAddSignature','SecCertificateCopyValues'):
            with self.assertRaises(p.Refused): self.ffi.bindings.call(symbol)
        with self.assertRaises(p.Refused): self.ffi.bindings.constant('kSecCodeInfoTime')

    def test_locked_status_and_abi_out_pointers_balance_owned_references(self):
        result = worker.perform(worker.task('locked', path=str(self.root/'isolated.keychain-db')), self.api)
        self.assertEqual(result, {'locked':True}); self.assertFalse(self.ffi.owned)
        fn = self.ffi.functions['SecKeychainGetStatus']
        self.assertEqual(fn.argtypes, [native.REF, C.POINTER(native.U32)])
        self.assertEqual(fn.restype, native.STATUS)

    def test_keychain_error_and_unlocked_status_release_partial_outputs(self):
        for fault in ('SecKeychainOpen','SecKeychainGetStatus',None):
            self.ffi.fail = fault; self.ffi.keychain_status = 7
            with self.assertRaises(p.Refused): worker.perform(worker.task('locked', path=str(self.root/'keychain')), self.api)
            self.assertFalse(self.ffi.owned)

    def test_cms_content_only_no_signer_trust_symbols_and_cleanup_on_errors(self):
        raw = cms(plistlib.dumps(FakeSigner().profile()[2]))
        for fault in (None,'CMSDecoderCreate','CMSDecoderUpdateMessage','CMSDecoderFinalizeMessage','CMSDecoderCopyContent'):
            self.ffi.fail = fault
            if fault:
                with self.assertRaises(p.Refused): worker.perform(worker.task('profile',content=worker.blob(raw)),self.api)
            else: self.assertEqual(worker.unblob(worker.perform(worker.task('profile',content=worker.blob(raw)),self.api)['content']),worker.signed_content(raw))
            self.assertFalse(self.ffi.owned)
        self.assertFalse(any('Trust' in name or 'SignerStatus' in name for name,_ in self.ffi.calls))

    def test_malformed_or_encrypted_cms_never_initializes_frameworks(self):
        for raw in (b'invalid',cms(b'not a plist'),cms(plistlib.dumps({}),outer=bytes.fromhex('2a864886f70d010703'))):
            with self.assertRaises(p.Refused): worker.perform(worker.task('profile',content=worker.blob(raw)),self.api)
        self.assertEqual(self.ffi.loads, [])

    def test_public_certificate_conversion_has_no_trust_or_identity_lookup(self):
        value = worker.perform(worker.task('certificate',content=worker.blob(CERT)),self.api)
        self.assertEqual(value['notBefore'],native.UNIX_EPOCH)
        self.assertEqual(value['notAfter'],3_000_000_000+native.UNIX_EPOCH)
        self.assertIn(TEAM,value['commonName']); self.assertFalse(self.ffi.owned)
        self.assertFalse(any('Trust' in n or 'Identity' in n for n,_ in self.ffi.calls))

    def test_certificate_errors_release_all_owned_output_and_error_refs(self):
        for fault in ('SecCertificateCopyCommonName','SecCertificateCopyNotValidBeforeDate','SecCertificateCopyNotValidAfterDate'):
            self.ffi.fail = fault
            with self.assertRaises(p.Refused): worker.perform(worker.task('certificate',content=worker.blob(CERT)),self.api)
            self.assertFalse(self.ffi.owned)

    def test_typed_date_getters_have_exact_abi_and_no_property_dictionary_fallback(self):
        worker.perform(worker.task('certificate',content=worker.blob(CERT)),self.api)
        for name in self.ffi.certificate_dates:
            self.assertEqual(self.ffi.functions[name].argtypes,[native.REF])
            self.assertEqual(self.ffi.functions[name].restype,native.REF)
        self.assertNotIn('SecCertificateCopyValues',native.PROTOTYPES)
        self.assertFalse(any('kSecOIDX509' in name for name in native.CONSTANTS))

    def test_invalid_typed_dates_refuse_with_fixed_phase_and_release_partial_refs(self):
        before='SecCertificateCopyNotValidBeforeDate'; after='SecCertificateCopyNotValidAfterDate'
        for symbol,variant,expected in ((before,('Number',0),'native-value-type'),
                                        (after,('String','secret'),'native-value-type'),
                                        (before,('Date',float('nan')),'native-date-nonfinite'),
                                        (after,('Date',float('inf')),'native-date-nonfinite'),
                                        (after,('Date',-1),'certificate-date-order')):
            ffi=FakeFFI(); ffi.certificate_dates[symbol]=variant; api=native.MacOSAPI(ffi.bindings)
            with self.subTest(symbol=symbol,variant=variant),self.assertRaises(worker.WorkerFailure) as caught:
                worker.perform(worker.task('certificate',content=worker.blob(CERT)),api)
            self.assertEqual(caught.exception.code,expected)
            self.assertIn(caught.exception.phase,worker.FAILURE_PHASES)
            self.assertNotIn('secret',str(caught.exception.record())); self.assertFalse(ffi.owned)

    def test_missing_typed_date_symbol_is_fixed_and_never_uses_legacy_values(self):
        call=self.ffi.call
        def missing(name,*args):
            if name=='SecCertificateCopyNotValidAfterDate': raise AttributeError('secret native symbol error')
            return call(name,*args)
        self.ffi.call=missing
        with self.assertRaises(worker.WorkerFailure) as caught:
            worker.perform(worker.task('certificate',content=worker.blob(CERT)),self.api)
        self.assertEqual(caught.exception.record(),{'format':1,'code':'symbol-unavailable','phase':'certificate-after-date'})
        self.assertFalse(self.ffi.owned)

    def test_static_validation_uses_explicit_flags_and_existing_certified_timestamp(self):
        result=worker.perform(worker.task('static',path=str(self.root/'code'),team=TEAM,nested=True,entitlements={}),self.api)
        self.assertEqual(result['validationFlags'],worker.STATIC_FLAGS|worker.CHECK_NESTED)
        self.assertFalse(self.ffi.owned)
        self.assertFalse(any(name=='kSecCodeInfoTime' for name in self.ffi.functions))

    def test_static_api_errors_and_error_refs_never_fallback(self):
        for fault in ('SecStaticCodeCreateWithPath','SecRequirementCreateWithString','SecStaticCodeCheckValidityWithErrors','SecCodeCopySigningInformation'):
            self.ffi.fail=fault
            with self.assertRaises(p.Refused): worker.perform(worker.task('static',path=str(self.root/'code'),team=TEAM,nested=False,entitlements={}),self.api)
            self.assertFalse(self.ffi.owned)

    def test_missing_secure_timestamp_or_wrong_cf_types_fail_closed(self):
        for override in ({'kSecCodeInfoTimestamp':None,'kSecCodeInfoTime':('Date',10)},
                         {'kSecCodeInfoTimestamp':'not a CFDate'}, {'kSecCodeInfoFlags':('Boolean',True)},
                         {'kSecCodeInfoFlags':('Number',-65536)}, {'kSecCodeInfoIdentifier':'dev.tryomarchy.kit\0extra'}):
            self.ffi.overrides=override
            with self.assertRaises(p.Refused): worker.perform(worker.task('static',path=str(self.root/'code'),team=TEAM,nested=False,entitlements={}),self.api)
            self.assertFalse(self.ffi.owned)

    def test_default_network_flags_and_arbitrary_requirements_refuse_before_validation(self):
        self.api.disable_interaction(); handle=self.api.static_open(self.root/'code')
        try:
            for flags,requirement in ((0,worker.requirement_for(TEAM)),(worker.STATIC_FLAGS|32,worker.requirement_for(TEAM)),(worker.STATIC_FLAGS,'always true')):
                with self.assertRaises(p.Refused): self.api.static_validate(handle,flags,requirement)
            self.assertFalse(any(n=='SecStaticCodeCheckValidityWithErrors' for n,_ in self.ffi.calls))
        finally: self.api.release(handle)
        self.assertFalse(self.ffi.owned)

    def test_metadata_before_validity_and_double_release_are_refused(self):
        self.api.disable_interaction(); handle=self.api.static_open(self.root/'code')
        with self.assertRaises(p.Refused): self.api.static_info(handle)
        self.api.release(handle)
        with self.assertRaises(p.Refused): self.api.release(handle)
        self.assertFalse(self.ffi.owned)

    def test_failed_revalidation_revokes_previous_metadata_access(self):
        self.api.disable_interaction(); handle=self.api.static_open(self.root/'code')
        try:
            self.assertTrue(self.api.static_validate(handle,worker.STATIC_FLAGS,worker.requirement_for(TEAM)))
            self.ffi.fail='SecStaticCodeCheckValidityWithErrors'
            self.assertFalse(self.api.static_validate(handle,worker.STATIC_FLAGS,worker.requirement_for(TEAM)))
            with self.assertRaises(p.Refused): self.api.static_info(handle)
        finally: self.api.release(handle)
        self.assertFalse(self.ffi.owned)


if __name__=='__main__': unittest.main()
