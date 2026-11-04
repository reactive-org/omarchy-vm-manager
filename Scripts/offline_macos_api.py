"""Lazy explicit Security/CoreFoundation bindings; importing loads no library."""
import ctypes as C
from dataclasses import dataclass
import plistlib
import re
import math

import private_provisioning_package as p
from offline_inspection_worker import STATIC_FLAGS, CHECK_NESTED, LIMIT, signed_content, requirement_for, blob

REF = C.c_void_p
OUT = C.POINTER(REF)
INDEX = C.c_long
STATUS = C.c_int32
U32 = C.c_uint32
BOOL = C.c_ubyte
UTF8 = 0x08000100
UNIX_EPOCH = 978307200
SIGNING_INFORMATION = 1 << 1

# Closed symbols exclude explicit SecTrust/CMS signer evaluation and key use.
PROTOTYPES = {
    "SecKeychainSetUserInteractionAllowed": ("Security", STATUS, [BOOL]),
    "SecKeychainOpen": ("Security", STATUS, [C.c_char_p, OUT]),
    "SecKeychainGetStatus": ("Security", STATUS, [REF, C.POINTER(U32)]),
    "CMSDecoderCreate": ("Security", STATUS, [OUT]),
    "CMSDecoderUpdateMessage": ("Security", STATUS, [REF, REF, C.c_size_t]),
    "CMSDecoderFinalizeMessage": ("Security", STATUS, [REF]),
    "CMSDecoderCopyContent": ("Security", STATUS, [REF, OUT]),
    "SecCertificateCopyData": ("Security", REF, [REF]),
    "SecCertificateGetTypeID": ("Security", C.c_ulong, []),
    "CFArrayGetCount": ("CoreFoundation", INDEX, [REF]),
    "CFArrayGetValueAtIndex": ("CoreFoundation", REF, [REF, INDEX]),
    "SecCertificateCreateWithData": ("Security", REF, [REF, REF]),
    "SecCertificateCopyCommonName": ("Security", STATUS, [REF, OUT]),
    "SecCertificateCopyNotValidBeforeDate": ("Security", REF, [REF]),
    "SecCertificateCopyNotValidAfterDate": ("Security", REF, [REF]),
    "SecStaticCodeCreateWithPath": ("Security", STATUS, [REF, U32, OUT]),
    "SecRequirementCreateWithString": ("Security", STATUS, [REF, U32, OUT]),
    "SecStaticCodeCheckValidityWithErrors": ("Security", STATUS, [REF, U32, REF, OUT]),
    "SecCodeCopySigningInformation": ("Security", STATUS, [REF, U32, OUT]),
    "CFRelease": ("CoreFoundation", None, [REF]),
    "CFDataCreate": ("CoreFoundation", REF, [REF, REF, INDEX]),
    "CFDataGetLength": ("CoreFoundation", INDEX, [REF]),
    "CFDataGetBytePtr": ("CoreFoundation", REF, [REF]),
    "CFStringCreateWithBytes": ("CoreFoundation", REF, [REF, REF, INDEX, U32, BOOL]),
    "CFStringGetLength": ("CoreFoundation", INDEX, [REF]),
    "CFStringGetMaximumSizeForEncoding": ("CoreFoundation", INDEX, [INDEX, U32]),
    "CFStringGetCString": ("CoreFoundation", BOOL, [REF, REF, INDEX, U32]),
    "CFURLCreateFromFileSystemRepresentation": ("CoreFoundation", REF, [REF, REF, INDEX, BOOL]),
    "CFGetTypeID": ("CoreFoundation", C.c_ulong, [REF]),
    "CFDictionaryGetValue": ("CoreFoundation", REF, [REF, REF]),
    "CFNumberGetValue": ("CoreFoundation", BOOL, [REF, C.c_int, REF]),
    "CFDateGetAbsoluteTime": ("CoreFoundation", C.c_double, [REF]),
    "CFPropertyListCreateData": ("CoreFoundation", REF, [REF, REF, INDEX, C.c_ulong, OUT]),
}
for _kind in ("Data", "String", "Dictionary", "Number", "Date", "Array"):
    PROTOTYPES["CF" + _kind + "GetTypeID"] = ("CoreFoundation", C.c_ulong, [])
CONSTANTS = frozenset({"kSecCodeInfoIdentifier", "kSecCodeInfoTeamIdentifier", "kSecCodeInfoFlags",
    "kSecCodeInfoTimestamp", "kSecCodeInfoEntitlementsDict", "kSecCodeInfoUnique", "kSecCodeInfoCertificates"})


class Bindings:
    def __init__(self, loader=None, constant_reader=None):
        p.require((loader is None) == (constant_reader is None), "offline-ffi-injection")
        self.test_double = loader is not None
        self.loader = loader or C.CDLL
        self.constant_reader = constant_reader or (lambda lib, name: REF.in_dll(lib, name).value)
        self.libraries = {}; self.functions = {}

    def _library(self, name):
        if name not in self.libraries:
            self.libraries[name] = self.loader("/System/Library/Frameworks/" + name + ".framework/" + name)
        return self.libraries[name]

    def call(self, name, *args):
        p.require(name in PROTOTYPES, "offline-ffi-symbol")
        if name not in self.functions:
            library, result, arguments = PROTOTYPES[name]
            fn = getattr(self._library(library), name); fn.restype = result; fn.argtypes = arguments
            self.functions[name] = fn
        return self.functions[name](*args)

    def constant(self, name):
        p.require(name in CONSTANTS, "offline-ffi-constant")
        result = self.constant_reader(self._library("Security"), name)
        p.require(result, "offline-ffi-missing-constant")
        return result


@dataclass(frozen=True, repr=False)
class Handle:
    kind: str
    address: int

    def __repr__(self): return "OfflineNativeHandle(redacted)"


class MacOSAPI:
    def __init__(self, ffi=None, dependency_checker=None):
        self.ffi = ffi; self.test_double = ffi.test_double if ffi is not None else False
        self.dependency_checker = dependency_checker
        self.handles = set(); self.validated = set(); self.interaction_disabled = False
        self.phase = "not-started"

    def __repr__(self): return "OfflineMacOSAPI(redacted)"

    def _call(self, name, *args):
        if self.ffi is None: self.ffi = Bindings()
        return self.ffi.call(name, *args)

    def _drop(self, value):
        value = value.value if isinstance(value, REF) else value
        if value: self._call("CFRelease", value)

    def _status_ref(self, name, *args):
        result = REF()
        try: status = self._call(name, *args, C.byref(result))
        except BaseException:
            self._drop(result); raise
        if status != 0:
            self._drop(result); raise p.Refused("offline-native-status")
        p.require(result.value, "offline-native-null-reference")
        return result.value

    def _buffer(self, raw): return C.create_string_buffer(raw, max(1, len(raw)))

    def _data(self, raw):
        p.require(type(raw) is bytes and len(raw) <= LIMIT)
        buffer = self._buffer(raw); ref = self._call("CFDataCreate", None, C.cast(buffer, REF), len(raw))
        p.require(ref, "offline-native-null-data"); return ref

    def _string_ref(self, text):
        raw = text.encode("utf-8"); p.require(len(raw) <= 4096)
        buffer = self._buffer(raw)
        ref = self._call("CFStringCreateWithBytes", None, C.cast(buffer, REF), len(raw), UTF8, 0)
        p.require(ref, "offline-native-null-string"); return ref

    def _type(self, value, kind):
        p.require(value and self._call("CFGetTypeID", value) == self._call("CF" + kind + "GetTypeID"), "offline-native-value-type")

    def _bytes(self, ref):
        self._type(ref, "Data"); size = self._call("CFDataGetLength", ref)
        p.require(type(size) is int and 0 <= size <= LIMIT, "offline-native-data-bound")
        address = self._call("CFDataGetBytePtr", ref)
        p.require(address or size == 0, "offline-native-data-pointer")
        return C.string_at(address, size) if size else b""

    def _string(self, ref):
        self._type(ref, "String"); count = self._call("CFStringGetLength", ref)
        p.require(0 <= count <= 512, "offline-native-string-bound")
        maximum = self._call("CFStringGetMaximumSizeForEncoding", count, UTF8) + 1
        p.require(0 < maximum <= 4096, "offline-native-string-bound")
        buffer = C.create_string_buffer(maximum)
        p.require(self._call("CFStringGetCString", ref, C.cast(buffer, REF), maximum, UTF8), "offline-native-string")
        text = buffer.value.decode("utf-8", errors="strict")
        p.require(len(text.encode("utf-16-le")) // 2 == count, "offline-native-truncated-string")
        return text

    def _value(self, dictionary, key):
        self._type(dictionary, "Dictionary")
        return self._call("CFDictionaryGetValue", dictionary, self.ffi.constant(key))

    def _date(self, value):
        self._type(value, "Date")
        result = self._call("CFDateGetAbsoluteTime", value) + UNIX_EPOCH
        p.require(math.isfinite(result), "offline-native-date-nonfinite")
        return result

    def _owned(self, kind, value):
        handle = Handle(kind, value); self.handles.add(handle); return handle

    def _handle(self, handle, kind):
        p.require(type(handle) is Handle and handle in self.handles and handle.kind == kind, "offline-native-handle")
        p.require(self.interaction_disabled, "offline-native-interaction"); return handle.address

    def disable_interaction(self):
        self.interaction_disabled = self._call("SecKeychainSetUserInteractionAllowed", 0) == 0
        return self.interaction_disabled

    def dependency_status(self, path):
        p.require(self.dependency_checker is not None, "offline-source-checker-required")
        return self.dependency_checker(path)

    def keychain_open(self, path):
        p.require(self.interaction_disabled)
        return self._owned("keychain", self._status_ref("SecKeychainOpen", bytes(path)))

    def keychain_status(self, handle):
        status = U32()
        p.require(self._call("SecKeychainGetStatus", self._handle(handle, "keychain"), C.byref(status)) == 0, "offline-keychain-status")
        return status.value

    def release(self, handle):
        p.require(handle in self.handles, "offline-native-release")
        self.validated.discard(handle); self.handles.remove(handle); self._drop(handle.address)

    def cms_content(self, raw):
        embedded = signed_content(raw); p.require(self.interaction_disabled)
        decoder = content = None
        try:
            decoder = self._status_ref("CMSDecoderCreate"); buffer = self._buffer(raw)
            p.require(self._call("CMSDecoderUpdateMessage", decoder, C.cast(buffer, REF), len(raw)) == 0)
            p.require(self._call("CMSDecoderFinalizeMessage", decoder) == 0)
            content = self._status_ref("CMSDecoderCopyContent", decoder)
            result = self._bytes(content); p.require(result == embedded, "offline-native-cms-content")
            return result
        finally: self._drop(content); self._drop(decoder)

    def certificate_info(self, raw):
        p.require(self.interaction_disabled)
        data = certificate = name = before = after = None
        try:
            self.phase = "certificate-create"
            data = self._data(raw); certificate = self._call("SecCertificateCreateWithData", None, data)
            p.require(certificate, "offline-native-certificate")
            self.phase = "certificate-name"
            name = self._status_ref("SecCertificateCopyCommonName", certificate)
            common_name = self._string(name)
            self.phase = "certificate-before-date"
            before = self._call("SecCertificateCopyNotValidBeforeDate", certificate)
            p.require(before, "offline-certificate-date-unavailable")
            not_before = self._date(before)
            self.phase = "certificate-after-date"
            after = self._call("SecCertificateCopyNotValidAfterDate", certificate)
            p.require(after, "offline-certificate-date-unavailable")
            not_after = self._date(after)
            self.phase = "certificate-date-order"
            p.require(not_before < not_after, "offline-certificate-date-order")
            return {"commonName": common_name, "notBefore": not_before, "notAfter": not_after}
        finally:
            for ref in (after, before, name, certificate, data): self._drop(ref)

    def static_open(self, path):
        p.require(self.interaction_disabled)
        raw = bytes(path); buffer = self._buffer(raw)
        url = self._call("CFURLCreateFromFileSystemRepresentation", None, C.cast(buffer, REF), len(raw), 0)
        p.require(url, "offline-native-url")
        try: return self._owned("static", self._status_ref("SecStaticCodeCreateWithPath", url, 0))
        finally: self._drop(url)

    def static_validate(self, handle, flags, requirement):
        code = self._handle(handle, "static")
        self.validated.discard(handle)
        p.require(type(flags) is int and flags in (STATIC_FLAGS, STATIC_FLAGS | CHECK_NESTED), "offline-native-no-network-flags")
        match = re.search(r'OU\] = "([A-Z0-9]{10})"$', requirement)
        identifier = re.search(r'identifier "([A-Za-z0-9.-]+)"', requirement)
        p.require(match and identifier and requirement == requirement_for(match[1], identifier[1]), "offline-native-requirement")
        text = req = None; error = REF()
        try:
            text = self._string_ref(requirement); req = self._status_ref("SecRequirementCreateWithString", text, 0)
            status = self._call("SecStaticCodeCheckValidityWithErrors", code, flags, req, C.byref(error))
            valid = status == 0 and not error.value
            if valid: self.validated.add(handle)
            return valid
        finally:
            for ref in (error, req, text): self._drop(ref)

    def static_info(self, handle, evidence=False):
        code = self._handle(handle, "static"); p.require(handle in self.validated, "offline-native-not-validated")
        info = data = None; error = REF()
        try:
            info = self._status_ref("SecCodeCopySigningInformation", code, SIGNING_INFORMATION)
            flags = self._value(info, "kSecCodeInfoFlags"); self._type(flags, "Number"); number = C.c_int64()
            p.require(self._call("CFNumberGetValue", flags, 4, C.byref(number)), "offline-native-number")
            p.require(0 <= number.value <= 0xffffffff, "offline-native-flags-range")
            entitlements = self._value(info, "kSecCodeInfoEntitlementsDict"); decoded = {}
            if entitlements:
                self._type(entitlements, "Dictionary")
                data = self._call("CFPropertyListCreateData", None, entitlements, 100, 0, C.byref(error))
                p.require(data and not error.value, "offline-native-entitlements")
                decoded = plistlib.loads(self._bytes(data)); p.require(type(decoded) is dict)
            result = {"identifier": self._string(self._value(info, "kSecCodeInfoIdentifier")),
                    "team": self._string(self._value(info, "kSecCodeInfoTeamIdentifier")), "flags": number.value,
                    "timestamp": self._date(self._value(info, "kSecCodeInfoTimestamp")), "entitlements": decoded}
            if evidence:
                result["CDHash"] = self._bytes(self._value(info, "kSecCodeInfoUnique")).hex()
                certificates = self._value(info, "kSecCodeInfoCertificates"); self._type(certificates, "Array")
                p.require(0 < self._call("CFArrayGetCount", certificates) <= 16, "offline-native-certificate-chain")
                leaf = self._call("CFArrayGetValueAtIndex", certificates, 0)
                p.require(leaf and self._call("CFGetTypeID", leaf) == self._call("SecCertificateGetTypeID"), "offline-native-certificate-type")
                public = self._call("SecCertificateCopyData", leaf)
                try: result["certificate"] = blob(self._bytes(public))
                finally: self._drop(public)
            return result
        finally:
            for ref in (error, data, info): self._drop(ref)

    def candidate_info(self, handle): return self.static_info(handle, evidence=True)
