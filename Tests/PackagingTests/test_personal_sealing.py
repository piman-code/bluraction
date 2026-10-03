import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

from scripts.seal_personal_installer import seal


class PersonalSealingTests(unittest.TestCase):
    def test_payload_uses_exact_recorded_bytes_even_when_inputs_change(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            exe, record, cert = (root / n for n in ('candidate.exe', 'record.json', 'public.pem'))
            original = b'authored fixture, not a Windows executable'
            exe.write_bytes(original)
            row = dict(state='personal-test-installer-compiled-not-installed', licenseReview='pending',
                       redistributionApproved=False, userAcceptanceVerified=False, installerVerified=False,
                       installer=exe.name, installer_sha256=hashlib.sha256(original).hexdigest())
            record.write_text(json.dumps(row))
            cert.write_bytes(b'-----BEGIN CERTIFICATE-----\nfixture\n')
            def encrypt(args, **kwargs):
                exe.write_bytes(b'replaced after capture')
                cert.write_bytes(b'replaced certificate')
                Path(args[args.index('-out') + 1]).write_bytes(b'authored sealed fixture')
            with patch('scripts.seal_personal_installer.subprocess.run', side_effect=encrypt):
                result = seal(exe, record, cert, root / 'delivery', Path('openssl'))
            with zipfile.ZipFile(root / 'delivery/personal-installer.zip') as archive:
                self.assertEqual(set(archive.namelist()), {exe.name, 'installer-record.json'})
                self.assertEqual(archive.read(exe.name), original)
            self.assertEqual(result['installer_sha256'], row['installer_sha256'])
            self.assertTrue((root / 'delivery/recipient.pem').read_bytes().startswith(b'-----BEGIN CERTIFICATE-----'))
            with self.assertRaises(ValueError):
                seal(exe, record, cert, root / 'changed', Path('openssl'))
            self.assertFalse((root / 'changed').exists())

    def test_never_accepts_private_key_as_recipient(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            for name, data in [('app.exe', b'fixture'), ('record.json', b'{}'),
                               ('cert.pem', b'-----BEGIN PRIVATE KEY-----')]:
                (root / name).write_bytes(data)
            with self.assertRaises(ValueError):
                seal(root/'app.exe', root/'record.json', root/'cert.pem', root/'out', Path('openssl'))
            self.assertFalse((root/'out').exists())
