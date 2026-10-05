"""Read PyInstaller 6.22.3 literal TOCs; never execute them or certify licenses."""
from __future__ import annotations
import argparse
import ast
import json
import os
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from shared import windows_package_receipt as guards
from shared.windows_bundle_inventory import machine

MAX_TOC = 16 * 1024**2
MAX_AST_NODES = 500000
MAX_AST_DEPTH = 64
SCHEMA = 'PyInstaller-6.22.3-Analysis20-binaries15-COLLECT1'
# Schema read from the acquired wheel, without importing it.
SCHEMA_WHEEL_SHA256 = '500bd58c7bf7e584a8435adccbd763a0b918d5c12b08d74ff50fd79b2915458b'


def literal(path):
    path = guards.plain(path)
    if not 0 < path.stat().st_size <= MAX_TOC:
        raise ValueError('bounded TOC required')
    with guards.stable_read(path) as stream:
        text = stream.read(MAX_TOC + 1)
    if len(text) > MAX_TOC:
        raise ValueError('bounded TOC required')
    tree = ast.parse(text.decode('utf-8-sig'), mode='eval')
    pending, count = [(tree, 0)], 0
    while pending:
        node, depth = pending.pop()
        count += 1
        if count > MAX_AST_NODES or depth > MAX_AST_DEPTH:
            raise ValueError('bounded literal structure required')
        if not isinstance(node, (ast.Expression, ast.Tuple, ast.List, ast.Dict, ast.Set,
                                 ast.Constant, ast.Load, ast.UnaryOp, ast.USub, ast.UAdd)):
            raise ValueError('literal TOC only')
        pending.extend((child, depth + 1) for child in ast.iter_child_nodes(node))
    return ast.literal_eval(tree)


def triples(rows):
    if type(rows) not in (tuple, list) or len(rows) > guards.MAX_ROWS:
        raise ValueError('bounded TOC triples required')
    found = {}
    for row in rows:
        if type(row) not in (tuple, list) or len(row) != 3 or any(type(x) is not str for x in row):
            raise ValueError('TOC triple required')
        dest, source, code = row
        dest = guards.canonical(dest.replace('\\', '/'))
        if dest.lower() in found:
            raise ValueError('duplicate TOC destination')
        if not source or len(source) > 4096 or '\0' in source or not code or len(code) > 64:
            raise ValueError('bounded source/type required')
        found[dest.lower()] = (dest, source, code)
    return found


def source_label(path, roots):
    # Prefer the most specific matching trusted root (venv commonly nests in base).
    for kind, root in sorted(roots.items(), key=lambda item: len(str(item[1])), reverse=True):
        try:
            relative = path.relative_to(Path(root).absolute()).as_posix()
            return {'classification': kind, 'relative_path': guards.canonical(relative)}
        except ValueError:
            pass
    return {'classification': 'other', 'basename': path.name}


def default_roots():
    roots = {'python-base': sys.base_prefix}
    if sys.prefix != sys.base_prefix:
        roots['venv'] = sys.prefix
    if os.environ.get('SystemRoot'):
        roots['SystemRoot'] = os.environ['SystemRoot']
    return roots


def observe(analysis, bundle, *, roots=None):
    analysis = guards.plain(analysis)
    analysis_hash = guards.sha(analysis)
    data = literal(analysis)
    if type(data) is not tuple or len(data) != 20:
        raise ValueError('expected pinned Analysis schema')
    analysis_rows = triples(data[15])
    collect = analysis.with_name('COLLECT-00.toc')
    toc_hashes = {'Analysis-00.toc': analysis_hash}
    if collect.exists():
        collect_hash = guards.sha(collect)
        value = literal(collect)
        if type(value) is not tuple or len(value) != 1:
            raise ValueError('expected pinned COLLECT schema')
        rows = triples(value[0])
        toc_hashes['COLLECT-00.toc'] = collect_hash
        authority = 'COLLECT-00.toc'
    else:
        rows, authority = analysis_rows, 'Analysis-00.toc'
    actual = guards.tree_files(bundle)
    roots = default_roots() if roots is None else roots
    result, source_checks, bundle_checks = [], {}, {}
    mapped = {}
    for key, (dest, source, code) in rows.items():
        # This CLI targets existing onedir packages with standard _internal layout.
        name = dest if code in ('EXECUTABLE', 'PKG') else '_internal/' + dest
        if name.lower() in mapped:
            raise ValueError('duplicate mapped bundle destination')
        mapped[name.lower()] = (key, source, code)
    for name, (relative, path) in sorted(actual.items()):
        digest = guards.sha(path)
        bundle_checks[name] = digest
        pe_machine = machine(path)
        if pe_machine == 'not-pe' and path.suffix.lower() not in ('.dll', '.pyd', '.exe'):
            continue
        item = {'path': relative, 'bytes': path.stat().st_size, 'sha256': digest,
                'machine': pe_machine, 'source_status': 'no-toc-entry'}
        if name in mapped:
            key, source, code = mapped[name]
            origin = Path(source)
            if not origin.is_absolute():
                raise ValueError('absolute observed TOC source required')
            item.update({'toc': authority, 'typecode': code, 'source': source_label(origin, roots)})
            if key in analysis_rows:
                item['analysis_source_agrees'] = analysis_rows[key][1] == source
            try:
                original_hash = guards.sha(origin)
                item.update({'source_sha256': original_hash,
                             'source_machine': machine(origin),
                             'source_status': 'exact-bytes' if original_hash == digest else 'different-bytes'})
                source_checks[source] = original_hash
            except (OSError, ValueError):
                item['source_status'] = 'source-unavailable-or-rejected'
        result.append(item)
    for path, digest in source_checks.items():
        if guards.sha(path) != digest:
            raise ValueError('source changed during observation')
    if actual.keys() != guards.tree_files(bundle).keys():
        raise ValueError('bundle census changed')
    for name, (_, path) in actual.items():
        if guards.sha(path) != bundle_checks[name]:
            raise ValueError('bundle changed during observation')
    if guards.sha(analysis) != analysis_hash or ('COLLECT-00.toc' in toc_hashes and guards.sha(collect) != toc_hashes['COLLECT-00.toc']):
        raise ValueError('TOC changed during observation')
    return {'schema_version': 1, 'status': 'observed-build-toc-origins', 'schema': SCHEMA,
            'schema_reference_wheel_sha256': SCHEMA_WHEEL_SHA256, 'toc_sha256': toc_hashes,
            'authority': authority, 'contents_directory': '_internal', 'native_files': result,
            'native_file_count': len(result), 'code_executed': False,
            'provenance_is_redistribution_permission': False, 'receipt_finalized': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('analysis', 'bundle', 'output'):
        parser.add_argument('--' + name, required=True)
    args = parser.parse_args()
    try:
        output = Path(args.output).absolute()
        guards.plain(output.parent, directory=True)
        if output.exists() or output.is_symlink():
            raise ValueError('fresh output required')
        data = observe(args.analysis, args.bundle)
        payload = json.dumps(data, ensure_ascii=True, indent=2) + '\n'
        if len(payload.encode('utf-8')) > MAX_TOC:
            raise ValueError('bounded report required')
        with output.open('x', encoding='utf-8') as stream:
            stream.write(payload)
    except (OSError, ValueError, TypeError, SyntaxError, MemoryError, RecursionError):
        print('Bundle origin observation rejected; inspect local inputs.', file=sys.stderr)
        return 1
    print('Bundle origin report written; no redistribution permission asserted.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
