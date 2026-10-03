#!/usr/bin/env python3
"""Root-run synthetic-only child diagnostics. No original document input.

Each encode is a fresh owned process group. Partial outputs, native signal,
timeout and logs are retained; only complete cases count. This is not an app
test, does not close HDR/full HEIC compatibility, and never publishes a binary.
"""
import argparse
import hashlib
import json
import os
import platform
from pathlib import Path
import signal
import subprocess
import sys
import uuid
from owned_process import finish_owned_group


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def write_new(path, data):
    with path.open('xb') as stream:
        stream.write(data)


def child(args, directory, input_file=None, timeout=30):
    with (directory / 'stdout.txt').open('xb') as stdout, (directory / 'stderr.txt').open('xb') as stderr:
        stream = input_file.open('rb') if input_file else subprocess.DEVNULL
        try:
            process = subprocess.Popen(args, stdin=stream, stdout=stdout, stderr=stderr,
                                       start_new_session=True)
            timed_out = False
            try:
                exit_code = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                timed_out = True
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                exit_code = process.wait()
            except BaseException:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
                raise
            return {'exitCode': exit_code, 'timedOut': timed_out}
        finally:
            try:
                if 'process' in locals():
                    finish_owned_group(process)
            finally:
                if input_file:
                    stream.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--helper', required=True, type=Path)
    parser.add_argument('--helper-sha256', required=True)
    parser.add_argument('--parent', required=True, type=Path)
    parser.add_argument('--imageio-reader', type=Path)
    parser.add_argument('--imageio-reader-sha256')
    args = parser.parse_args()
    if sys.platform != 'darwin' or sha(args.helper) != args.helper_sha256:
        raise ValueError('actual Mac and exact owned helper required')
    if args.imageio_reader and sha(args.imageio_reader) != args.imageio_reader_sha256:
        raise ValueError('exact independent native reader required')
    parent = args.parent.absolute()
    if not parent.is_dir() or parent.resolve() != parent:
        raise ValueError('plain approved parent required')
    root = parent / ('mac-heic-cpu-' + str(uuid.uuid4()))
    root.mkdir(mode=0o700)
    cases = []
    for width, height in [(48, 32), (96, 64), (256, 128)]:
        for alpha in (False, True):
            directory = root / f'{width}x{height}-{"alpha" if alpha else "opaque"}'
            directory.mkdir(mode=0o700)
            raw = bytearray()
            for y in range(height):
                for x in range(width):
                    # Authored corners + gradient, wide flattened black cover.
                    color = [int(x * 255 / (width - 1)), int(y * 255 / (height - 1)), 83, 255]
                    if width // 3 <= x < width * 2 // 3 and height // 3 <= y < height * 2 // 3:
                        color[:3] = [0, 0, 0]
                    if alpha and x < width // 4 and y < height // 4:
                        color = [0, 0, 0, 0]
                    elif alpha and x >= width * 3 // 4 and y < height // 4:
                        color = [160, 100, 40, 128]
                    raw.extend(color)
            source = directory / 'authored.rgba'; write_new(source, raw)
            source_sha = sha(source)
            execution = child([str(args.helper), str(width), str(height), '90', str(directory)], directory, source)
            checks = {'sourceBytesUnchanged': sha(source) == source_sha,
                      'helperUnchanged': sha(args.helper) == args.helper_sha256}
            observations = {}
            if execution['exitCode'] == 0 and not execution['timedOut']:
                report = json.loads((directory / 'report.json').read_text())
                decoded = (directory / 'decoded.rgba').read_bytes()
                checks.update({'completeReport': report['status'] == 'candidate-readback-complete',
                               'dimensionsExact': (report['width'], report['height']) == (width, height),
                               'decodedBytesBoundedExactSize': len(decoded) == len(raw),
                               'alphaAllBytesExact': decoded[3::4] == raw[3::4],
                               'newNCLX': report['nclx'] == [1, 13, 6, 1],
                               'noSourceMetadata': report['sourceMetadataCopied'] is False})
                # Finite interior black samples farther from 420 cover edges.
                center = ((height // 2) * width + width // 2) * 4
                observations['coverCenterRGB'] = list(decoded[center:center + 3])
                # Exact privacy interior oracle; do not accept a residual based
                # on a newly invented global lossy tolerance.
                checks['coverCenterExactlyBlack'] = decoded[center:center + 3] == b'\0\0\0'
                observations['rgbMetrics'] = {key: report[key] for key in ('rgbMeanAbsoluteDifference', 'rgbMaximumAbsoluteDifference')}
                observations['candidateSHA256'] = sha(directory / 'candidate.heic')
                if args.imageio_reader:
                    reader_dir = directory / 'imageio'; reader_dir.mkdir(mode=0o700)
                    native = child([str(args.imageio_reader), str(directory / 'candidate.heic'), str(reader_dir)], reader_dir)
                    observations['imageIOExecution'] = native
                    if native['exitCode'] == 0 and not native['timedOut']:
                        native_report = json.loads((reader_dir / 'native-report.json').read_text())
                        checks['nativeReadbackComplete'] = native_report['status'] == 'native-readback-complete'
                        checks['nativeTypeHEIC'] = native_report['type'] == 'public.heic'
                        checks['nativeDimensions'] = (native_report['width'], native_report['height']) == (width, height)
                        native_bytes = (reader_dir / 'native-premultiplied.rgba').read_bytes()
                        checks['nativeRGBAExactSize'] = len(native_bytes) == len(raw)
                        checks['nativeAlphaAllBytesExact'] = native_bytes[3::4] == raw[3::4]
                        checks['nativeCoverCenterExactlyBlack'] = native_bytes[center:center + 3] == b'\0\0\0'
                        checks['nativeCandidateBytesUnchanged'] = native_report['sourceBytesUnchanged'] and \
                            native_report['sourceSHA256'] == observations['candidateSHA256'] == sha(directory / 'candidate.heic')
                        checks['nativeMetadataAbsent'] = native_report['sourceMetadataAbsent']
                        observations['nativeColorSpace'] = native_report['colorSpaceName']
                    else:
                        checks['nativeReadbackComplete'] = False
                else:
                    checks['nativeReadbackComplete'] = False
                    observations['nativeImageIOReadback'] = 'unverified: reader not supplied'
            else:
                checks['encodeReadbackComplete'] = False
            cases.append({'case': directory.name, 'execution': execution, 'checks': checks,
                          'observations': observations, 'sourceSHA256': source_sha})
            # Publish an immutable completed-case journal immediately; later
            # native crash does not erase prior observations.
            write_new(directory / 'execution.json', (json.dumps(cases[-1], indent=2) + '\n').encode())
    all_checks = all(all(case['checks'].values()) for case in cases)
    report = {'status': 'candidate-checks-complete' if all_checks else 'failed-or-needs-review',
              'cases': cases, 'host': sys.platform, 'macOS': platform.mac_ver()[0], 'darwinKernel': os.uname().release,
              'actualImageIOReadback': bool(args.imageio_reader),
              'eightBitSDROnly': True, 'HDRVerified': False, 'appIntegrated': False,
              'installedAppVerified': False, 'fullHEICCompatibilityClosed': False,
              'releaseApproved': False}
    write_new(root / 'summary.json', (json.dumps(report, indent=2) + '\n').encode())
    print(root / 'summary.json')
    return 0 if all_checks else 3


if __name__ == '__main__':
    def terminate(_signum, _frame):
        raise KeyboardInterrupt('supervisor cancelled owned diagnostic')
    signal.signal(signal.SIGTERM, terminate)
    raise SystemExit(main())
