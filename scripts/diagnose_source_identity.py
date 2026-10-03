"""Observe stat domains on fixed synthetic inputs; no media decoder or OS input.

Raw fields diagnose platform differences. Exit zero means observations completed,
not successful source-integrity or media validation. No original user input paths
are accepted. A temporary synthetic file is removed by TemporaryDirectory only.
"""
from pathlib import Path
import json
import os
import platform
import sys
import tempfile

FIELDS = ('st_dev', 'st_ino', 'st_mode', 'st_size', 'st_mtime_ns', 'st_ctime_ns',
          'st_birthtime_ns', 'st_file_attributes', 'st_reparse_tag')
LEGACY_FIELDS = FIELDS[:6]
ROOT = Path(__file__).resolve().parent.parent


def fields(info):
    return {field: getattr(info, field, None) for field in FIELDS}


def observe(path, label):
    before = fields(path.lstat())
    with path.open('rb') as stream:
        opened = fields(os.fstat(stream.fileno()))
        after_fd = fields(os.fstat(stream.fileno()))
    after = fields(path.lstat())
    return {'label': label, 'pathBefore': before, 'openedFD': opened,
            'pathAfter': after, 'fdAfter': after_fd,
            'pathStable': before == after, 'fdStable': opened == after_fd,
            'legacyCrossDomainDifferences': [key for key in LEGACY_FIELDS if before[key] != opened[key]]}


def main():
    observations = [observe(ROOT / relative, relative) for relative in (
        'shared/fixtures/pdf-geometry/generated/zero-r0.pdf',
        'shared/fixtures/manual-os/synthetic-01.png')]
    with tempfile.TemporaryDirectory(prefix='bluraction-stat-domain-') as folder:
        path = Path(folder) / 'synthetic.bin'
        path.write_bytes(b'BlurAction synthetic stat-domain witness\n')
        # Change LastWriteTime before taking either baseline. No observed-source
        # mutation occurs during a comparison. Windows creation/change differ.
        os.utime(path, ns=(1_700_000_000_123456700, 1_700_000_000_123456700))
        observations.append(observe(path, 'temporary-synthetic-after-utime'))
    print(json.dumps({'status': 'completed-observations-only', 'python': sys.version,
                      'host': platform.platform(), 'actualWindows': os.name == 'nt',
                      'integrityValidationPassed': False, 'observations': observations}, indent=2))


if __name__ == '__main__':
    main()
