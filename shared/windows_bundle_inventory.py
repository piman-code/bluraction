"""Read-only, bounded candidate PE/provider observations, never release approval."""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import struct
import sys
import zipfile
try:
    from . import windows_package_receipt as receipt_tools
except ImportError:
    import windows_package_receipt as receipt_tools


def machine(path):
    with receipt_tools.stable_read(path) as stream:
        header = stream.read(64)
        if header[:2] != b'MZ':
            return 'not-pe'
        if len(header) < 64:
            return 'invalid-pe'
        offset = struct.unpack_from('<I', header, 60)[0]
        if offset > min(receipt_tools.MAX_JSON, path.stat().st_size - 6):
            return 'invalid-pe'
        stream.seek(offset)
        signature = stream.read(6)
        if len(signature) != 6 or signature[:4] != b'PE\0\0':
            return 'invalid-pe'
        value = struct.unpack('<H', signature[4:])[0]
        return {0x8664: 'amd64', 0xaa64: 'arm64', 0x14c: 'x86'}.get(value, f'unknown-{value:04x}')


def inspect(bundle, manifest_path, receipt_path, artifacts_root):
    r = receipt_tools
    manifest_hash, input_hash = r.sha(manifest_path), r.sha(receipt_path)
    manifest, receipt = r.read_json(manifest_path), r.read_json(receipt_path)
    actual = r.tree_files(bundle)
    if type(manifest) is not list or not 0 < len(manifest) <= r.MAX_ROWS:
        raise ValueError('bounded nonempty manifest required')
    expected = {}
    for row in manifest:
        if type(row) is not dict:
            raise ValueError('manifest row required')
        name = r.canonical(row.get('path', '').replace('\\', '/'))
        if not name.startswith('BlurAction/'):
            raise ValueError('exact manifest root required')
        name = name[len('BlurAction/'):].lower()
        if name in expected or name not in actual:
            raise ValueError('duplicate or absent manifest entry')
        expected[name] = r.hash_value(row.get('sha256'))
    if expected.keys() != actual.keys():
        raise ValueError('manifest must cover every bundle file')
    observations = []
    for name, (relative, path) in sorted(actual.items()):
        digest = r.sha(path)
        if digest != expected[name]:
            raise ValueError('bundle differs from manifest')
        kind = machine(path)
        if kind != 'not-pe' or path.suffix.lower() in ('.dll', '.pyd', '.exe'):
            observations.append({'path': relative, 'bytes': path.stat().st_size,
                                 'sha256': digest, 'machine': kind})
    wanted = {item['sha256'] for item in observations}
    matches = {digest: [] for digest in wanted}
    rows = receipt.get('artifacts') if type(receipt) is dict else None
    if type(rows) is not list or not 0 < len(rows) <= r.MAX_ROWS:
        raise ValueError('bounded artifact list required')
    identities, artifact_paths = set(), set()
    match_count = 0
    for row in rows:
        if type(row) is not dict:
            raise ValueError('artifact object required')
        identity = r.normalize(row.get('id'))
        if identity in identities or row.get('path', '').lower() in artifact_paths:
            raise ValueError('duplicate artifact identity/path')
        identities.add(identity)
        artifact_paths.add(row.get('path', '').lower())
        origin = r.file_row(artifacts_root, row)
        if row.get('kind') == 'runtime':
            if row['sha256'] in wanted:
                match_count += 1
                if match_count > r.MAX_ROWS:
                    raise ValueError('bounded provider matches required')
                matches[row['sha256']].append({'artifact_id': identity, 'kind': 'runtime'})
        elif row.get('kind') == 'wheel':
            r.wheel_identity(origin, row)
            with r.stable_read(origin) as stream, zipfile.ZipFile(stream) as archive:
                for member in r.zip_members(archive).values():
                    if member.is_dir():
                        continue
                    # Hash only potential native entries, including extensionless MZ.
                    with archive.open(member) as member_stream:
                        magic = member_stream.read(2)
                    if magic != b'MZ' and Path(member.filename).suffix.lower() not in ('.dll', '.pyd', '.exe'):
                        continue
                    digest = r.member_sha(archive, member)
                    if digest in wanted:
                        match_count += 1
                        if match_count > r.MAX_ROWS:
                            raise ValueError('bounded provider matches required')
                        matches[digest].append({'artifact_id': identity, 'kind': 'wheel',
                                                'member': member.filename})
        elif row.get('kind') != 'evidence':
            raise ValueError('unsupported artifact kind')
    for item in observations:
        item['provider_matches'] = matches[item['sha256']]
        item['provider_status'] = ('exact' if len(item['provider_matches']) == 1 else
                                   'ambiguous' if item['provider_matches'] else 'unresolved')
        item['generated_product_executable'] = item['path'].lower() == 'bluraction.exe'
    # Check repeat reads and the exact census; never emit an observation after drift.
    for row in rows:
        r.file_row(artifacts_root, row)
    if actual.keys() != r.tree_files(bundle).keys():
        raise ValueError('bundle census changed')
    for name, (_, path) in actual.items():
        if r.sha(path) != expected[name]:
            raise ValueError('bundle bytes changed')
    if r.sha(manifest_path) != manifest_hash or r.sha(receipt_path) != input_hash:
        raise ValueError('manifest/receipt changed')
    # Filename leads only, never a classification of the actual module license.
    leads = [item['path'] for item in observations if any(
        token in item['path'].lower() for token in ('pdf', 'charts', 'datavisualization', 'virtualkeyboard', 'quick3d'))]
    return {'schema_version': 1, 'status': 'candidate-static-inventory',
            'bundle_manifest_sha256': manifest_hash, 'input_receipt_sha256': input_hash,
            'bundle_file_count': len(actual), 'native_file_count': len(observations),
            'native_files': observations, 'qt_license_review_filename_leads': leads,
            'filename_leads_are_license_findings': False,
            'native_code_executed': False, 'receipt_finalized': False,
            'redistribution_approved': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('bundle', 'bundle-manifest', 'receipt', 'artifacts-root', 'output'):
        parser.add_argument('--' + name, required=True)
    args = parser.parse_args()
    output = Path(args.output).absolute()
    receipt_tools.plain(output.parent, directory=True)
    if output.exists() or output.is_symlink():
        parser.error('output must be fresh')
    try:
        report = inspect(args.bundle, args.bundle_manifest, args.receipt, args.artifacts_root)
    except (ValueError, OSError, KeyError, TypeError, zipfile.BadZipFile):
        # Do not expose absolute paths, archive content, or exception messages.
        print('Candidate inventory rejected; inspect inputs locally.', file=sys.stderr)
        return 1
    payload = json.dumps(report, ensure_ascii=True, indent=2) + '\n'
    if len(payload.encode('utf-8')) > receipt_tools.MAX_JSON:
        print('Candidate inventory exceeds bounded report size.', file=sys.stderr)
        return 1
    with output.open('x', encoding='utf-8') as stream:
        stream.write(payload)
    print('Candidate static inventory written; no redistribution approval.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
