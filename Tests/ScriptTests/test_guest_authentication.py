"""Exercise the pinned upstream guest verifier with disposable software keys."""
import base64
import hashlib
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
BROKER = ROOT / '.build/runtime-source/guest/package/try-omarchy/files/usr/lib/try-omarchy/native-authentication-broker'


class GuestAuthenticationVerifierTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        loader = importlib.machinery.SourceFileLoader('reviewed_guest_authentication_broker', str(BROKER))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        cls.broker = importlib.util.module_from_spec(spec)
        loader.exec_module(cls.broker)
        cls.temporary = tempfile.TemporaryDirectory(prefix='manager-authentication-fixture-')
        cls.key = Path(cls.temporary.name) / 'software-fixture.pem'
        cls.openssl('ecparam', '-name', 'prime256v1', '-genkey', '-noout', '-out', str(cls.key))
        cls.key.chmod(0o600)
        der = cls.openssl('pkey', '-in', str(cls.key), '-pubout', '-outform', 'DER')
        assert der.startswith(cls.broker.P256_SPKI_PREFIX) and len(der) == len(cls.broker.P256_SPKI_PREFIX) + 65
        cls.public_key = der[len(cls.broker.P256_SPKI_PREFIX):]

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    @staticmethod
    def openssl(*arguments, payload=None):
        return subprocess.run(['/usr/bin/openssl', *arguments], input=payload, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, env={'PATH': '/usr/bin'}, check=True).stdout

    def approval(self):
        request = self.broker.make_request('sudo', guest_id='ef' * 32, user='fixture',
                                           requesting_user='fixture', tty='/dev/pts/4')
        response = dict(request, type='authorization-result', approved=True, issuedAt=1_800_000_000,
                        expiresAt=1_800_000_015, keyId=hashlib.sha256(self.public_key).hexdigest(),
                        publicKey=base64.b64encode(self.public_key).decode(), signature='')
        signature = self.openssl('dgst', '-sha256', '-sign', str(self.key),
                                 payload=self.broker.authorization_payload(request, response))
        response['signature'] = base64.b64encode(signature).decode()
        decoded = self.broker.decode_response(json.dumps(response).encode(), request)
        return request, decoded

    def test_signed_approval_is_bound_to_every_guest_context_field(self):
        request, response = self.approval()
        self.assertEqual(self.broker.verify_approval(request, response, pinned_public_key=self.public_key,
                                                    now=1_800_000_001), self.public_key)
        changes = {'guestId': 'ab' * 32, 'operation': 'enroll',
                   'requestId': '00000000-0000-4000-8000-000000000001', 'challenge': 'cd' * 32,
                   'user': 'root', 'requestingUser': 'other', 'service': 'other', 'tty': '/dev/pts/5'}
        for field, value in changes.items():
            with self.subTest(field=field), self.assertRaises(self.broker.AuthorizationError):
                self.broker.verify_approval(dict(request, **{field: value}), response, now=1_800_000_001)
        for field in ('issuedAt', 'expiresAt', 'keyId'):
            altered = dict(response)
            altered[field] = response[field] + 1 if field != 'keyId' else 'ab' * 32
            with self.subTest(field=field), self.assertRaises(self.broker.AuthorizationError):
                self.broker.verify_approval(request, altered, now=1_800_000_001)

    def test_expired_late_approval_and_future_issuance_are_rejected(self):
        request, response = self.approval()
        for now in (1_800_000_016, 1_799_999_994):
            with self.subTest(now=now), self.assertRaises(self.broker.AuthorizationError):
                self.broker.verify_approval(request, response, now=now)

    def test_replay_for_another_request_and_unsigned_booleans_are_rejected(self):
        request, response = self.approval()
        newer = self.broker.make_request('sudo', guest_id=request['guestId'], user='fixture',
                                         requesting_user='fixture', tty='/dev/pts/4')
        with self.assertRaises(self.broker.StaleResponseError):
            self.broker.decode_response(json.dumps(response).encode(), newer)
        with self.assertRaises(self.broker.AuthorizationError):
            self.broker.decode_response(json.dumps(dict(response, signature='')).encode(), request)
        with self.assertRaises(self.broker.AuthorizationError):
            self.broker.verify_approval(request, dict(response, approved=False), now=1_800_000_001)

    def test_enrollment_pin_rejects_another_hosts_key(self):
        request, response = self.approval()
        with self.assertRaises(self.broker.AuthorizationError):
            self.broker.verify_approval(request, response, pinned_public_key=b'\x04' + b'k' * 64,
                                        now=1_800_000_001)
