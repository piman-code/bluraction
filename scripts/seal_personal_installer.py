"""Encrypt a personal installer for the local recipient; never publish plaintext."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import zipfile

if __package__ in (None, ''):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from shared import windows_package_receipt as files


def read_input(path):
    with files.stable_read(path) as stream:
        data = stream.read(files.MAX_FILE + 1)
    if len(data) > files.MAX_FILE:
        raise ValueError('Bounded input required')
    return data


def seal(installer, record, certificate, output, openssl):
    installer, record, certificate = map(Path, (installer, record, certificate))
    for path in (installer, record, certificate):
        if path.is_symlink() or not path.is_file():
            raise ValueError('Regular inputs required')
    installer_bytes, record_bytes, certificate_bytes = map(read_input, (installer, record, certificate))
    if b'PRIVATE KEY' in certificate_bytes or b'BEGIN CERTIFICATE' not in certificate_bytes:
        raise ValueError('Public recipient certificate required')
    data = json.loads(record_bytes.decode('utf-8-sig'))
    if (data.get('state') != 'personal-test-installer-compiled-not-installed' or
            data.get('licenseReview') != 'pending' or
            any(data.get(k) is not False for k in
                ('redistributionApproved', 'userAcceptanceVerified', 'installerVerified'))):
        raise ValueError('Explicit personal-test compilation record required')
    digest = hashlib.sha256(installer_bytes).hexdigest()
    if data['installer_sha256'] != digest or data['installer'] != installer.name:
        raise ValueError('Installer differs from compilation record')
    output = Path(output)
    output.mkdir()  # Never overwrite a previous delivery.
    payload = output / 'personal-installer.zip'
    with zipfile.ZipFile(payload, 'x', zipfile.ZIP_STORED) as archive:
        archive.writestr(installer.name, installer_bytes)
        archive.writestr('installer-record.json', record_bytes)
    pinned_certificate = output / 'recipient.pem'
    pinned_certificate.write_bytes(certificate_bytes)
    envelope = output / 'personal-installer.p7m'
    subprocess.run([str(openssl), 'cms', '-encrypt', '-binary', '-aes-256-cbc',
                    '-in', str(payload), '-out', str(envelope), '-outform', 'DER',
                    str(pinned_certificate)], check=True, timeout=300)
    report = {'purpose': 'personal-test-not-for-redistribution',
              'installer': installer.name, 'installer_sha256': digest,
              'certificate_sha256': hashlib.sha256(certificate_bytes).hexdigest(),
              'envelope_sha256': hashlib.sha256(envelope.read_bytes()).hexdigest(),
              'plaintext_zip_sha256': hashlib.sha256(payload.read_bytes()).hexdigest(),
              'redistributionApproved': False, 'userAcceptanceVerified': False}
    (output / 'delivery.json').write_text(json.dumps(report, indent=2) + '\n')
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('installer', 'record', 'certificate', 'output', 'openssl'):
        parser.add_argument('--' + name, required=True, type=Path)
    print(json.dumps(seal(**vars(parser.parse_args())), sort_keys=True))
