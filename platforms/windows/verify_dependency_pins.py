"""Read-only exact distribution-metadata preflight, using the standard library.

No native package import, entry-point loading, installation or network access.
Metadata agreement does not prove loaded DLL identity, licensing or runtime
functionality. Requirements support only simple canonical exact pins, not pip's
full requirements language; unsupported syntax is an explicit failure.
"""
from __future__ import annotations

import argparse
from importlib import metadata
import json
from pathlib import Path
import re


_NAME = r'[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?'
# Canonical numeric release / a,b,rc / .post / .dev / local version forms.
# No ranges, arbitrary === labels, wildcards, markers, extras or URLs.
_VERSION = (r'(?:[0-9]+!)?[0-9]+(?:\.[0-9]+)*'
            r'(?:(?:a|b|rc)[0-9]+)?(?:\.post[0-9]+)?(?:\.dev[0-9]+)?'
            r'(?:\+[a-z0-9]+(?:[._-][a-z0-9]+)*)?')
_PIN = re.compile(rf'({_NAME})\s*==\s*({_VERSION})', re.ASCII)


def normalize_name(name):
    return re.sub(r'[-_.]+', '-', name).lower()


def verify_pins(requirement_files, *, version_provider=None):
    """Return all metadata mismatches/errors without mutating files or runtime.

    version_provider is injectable for pure tests; default is metadata.version.
    Versions are compared as exact strings, never normalized into equivalence.
    Duplicate normalized names across any files fail even for identical pins.
    """
    provider = metadata.version if version_provider is None else version_provider
    errors, packages, seen = [], [], {}
    files = [str(path) for path in requirement_files]
    if not files:
        errors.append({'type': 'requirements', 'message': 'At least one requirements file is required.'})
    for source in files:
        try:
            content = Path(source).read_text(encoding='utf-8')
        except (OSError, UnicodeError) as error:
            errors.append({'type': 'requirements_read', 'source': source, 'message': str(error)})
            continue
        pin_count, syntax_error = 0, False
        for line_number, raw in enumerate(content.splitlines(), 1):
            line = raw.strip()
            if not line or line.startswith('#'):
                continue
            # A whitespace-separated inline comment is allowed. A # inside a
            # token is not silently reinterpreted as valid requirement syntax.
            line = re.split(r'\s+#', line, maxsplit=1)[0].rstrip()
            match = _PIN.fullmatch(line)
            if match is None:
                syntax_error = True
                errors.append({'type': 'requirements_syntax', 'source': source,
                    'line': line_number, 'message': 'Expected one simple exact name==version pin; ranges, markers, extras and URLs are unsupported.'})
                continue
            pin_count += 1
            name, expected = match.groups()
            normalized = normalize_name(name)
            if normalized in seen:
                previous = seen[normalized]
                errors.append({'type': 'duplicate', 'name': normalized, 'source': source,
                    'line': line_number, 'expected': expected,
                    'previousSource': previous['source'], 'previousLine': previous['line'],
                    'previousExpected': previous['expected'],
                    'message': 'Duplicate normalized distribution name.'})
                continue
            package = {'name': name, 'normalizedName': normalized, 'expected': expected,
                'actual': None, 'status': 'pending', 'source': source, 'line': line_number}
            seen[normalized] = package
            packages.append(package)
        if pin_count == 0 and not syntax_error:
            errors.append({'type': 'requirements_empty', 'source': source,
                'message': 'Requirements file declares no exact dependency pins.'})
    for package in packages:
        name = package['normalizedName']
        try:
            actual = provider(name)
        except metadata.PackageNotFoundError:
            package['status'] = 'missing'
            errors.append({'type': 'missing', 'name': name, 'expected': package['expected'],
                'actual': None, 'message': 'Distribution metadata is not installed.'})
            continue
        except Exception as error:
            package['status'] = 'metadata_error'
            errors.append({'type': 'metadata_error', 'name': name, 'expected': package['expected'],
                'actual': None, 'message': str(error)})
            continue
        if type(actual) is not str or not actual:
            package['status'] = 'metadata_error'
            errors.append({'type': 'metadata_error', 'name': name, 'expected': package['expected'],
                'actual': None, 'message': 'Version provider returned invalid metadata.'})
            continue
        package['actual'] = actual
        if actual != package['expected']:
            package['status'] = 'mismatch'
            errors.append({'type': 'mismatch', 'name': name, 'expected': package['expected'],
                'actual': actual, 'message': 'Installed distribution version differs from exact pin.'})
        else:
            package['status'] = 'match'
    ok = not errors
    return {'ok': ok, 'exitCode': 0 if ok else 1, 'scope': 'distribution-metadata-only',
        'nativePackagesImported': False, 'runtimeFunctionalityVerified': False,
        'requirements': files, 'packages': packages, 'errors': errors}


def main(argv=None, *, version_provider=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--requirements', action='append', required=True,
        help='Exact requirements file; repeat for runtime and packaging pins.')
    args = parser.parse_args(argv)
    report = verify_pins(args.requirements, version_provider=version_provider)
    print(json.dumps(report, ensure_ascii=False, sort_keys=True))
    return report['exitCode']


if __name__ == '__main__':
    raise SystemExit(main())
