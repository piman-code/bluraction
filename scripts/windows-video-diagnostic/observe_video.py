"""Owned synthetic MOV decode observations; no product oracle or state changes."""
from __future__ import annotations
import argparse
from fractions import Fraction
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import re
import sys

KINDS = ('gap0-vfr', 'nonzero-origin', 'audio-earlier-gap', 'audio-later-gap',
         'video0-audio-negative-quarter', 'video-negative-twelfth-audio0',
         'video-negative-twelfth-audio-negative-quarter', 'video-negative-twelfth-noaudio')
MANIFEST_SHA = 'f1779cbc24d9f7a0451b182e028f587db1113f5f605ae80f22b6efa0d5a45f0f'
MAX_FRAMES = 128
MAX_SOURCE_BYTES = 64 * 1024 * 1024
OPTIONS = {'advanced_editlist': '1', 'ignore_editlist': '0'}


def sha(path):
    if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_SOURCE_BYTES:
        raise ValueError('Expected bounded plain authored source')
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        while block := stream.read(65536):
            digest.update(block)
    return digest.hexdigest()


def ratio(value):
    if value is None:
        return None
    # PyAV rational adapters expose integers; never infer from float/FPS.
    numerator, denominator = value.numerator, value.denominator
    if type(numerator) is not int or type(denominator) is not int or denominator <= 0:
        raise ValueError('Invalid exact native rational')
    return str(Fraction(numerator, denominator))


def save_json(path, value):
    with path.open('x', encoding='utf-8') as stream:
        json.dump(value, stream, ensure_ascii=False, sort_keys=True, indent=2)
        stream.write('\n')


def save_bytes(directory, name, data):
    path = directory / name
    with path.open('xb') as stream:
        stream.write(data)
    return {'file': name, 'bytes': len(data), 'SHA256': hashlib.sha256(data).hexdigest()}


def visible_plane(plane, bytes_per_pixel):
    width, height, stride = plane.width, plane.height, plane.line_size
    visible = width * bytes_per_pixel
    if (type(width) is not int or type(height) is not int or
            not 0 < width <= 192 or not 0 < height <= 128 or stride < visible or
            plane.buffer_size < stride * height):
        raise ValueError('Unsupported controlled plane layout')
    memory = memoryview(plane)
    return b''.join(bytes(memory[y * stride:y * stride + visible]) for y in range(height))


def marker(rgb):
    code, patches = 0, []
    for bit in range(8):
        sums = [sum(rgb[(y * 192 + x) * 3 + c]
                    for y in range(44, 52) for x in range(20 + bit * 20, 28 + bit * 20))
                for c in range(3)]
        patches.append(sums)
        if min(sums) > 192 * 64:
            code |= 1 << bit
        elif max(sums) >= 64 * 64:
            return {'status': 'ambiguous-observation', 'patchSumsRGB': patches}
    return {'status': 'known-marker' if 17 <= code <= 24 else 'unknown-marker-observation',
            'code': code, 'patchSumsRGB': patches}


def observe_case(repo, output, case):
    from shared.source_identity import (stat_snapshot, same_domain,
                                       same_path_binding, path_matches_descriptor)
    from platforms.windows.bluraction.frame_inventory import _BoundedInput
    from platforms.windows.bluraction.local_decoder import open_local_decoder
    from shared.video_timeline import rational
    from av.video.reformatter import Interpolation, VideoReformatter
    path = repo / 'shared/fixtures/video-timelines' / case['file']
    canonical = str(path.resolve(strict=True))
    baseline = stat_snapshot(path.lstat(), domain='path')
    expected = case['sourceSHA256']
    if sha(path) != expected:
        raise ValueError('Authored source baseline mismatch')
    def check():
        if path.is_symlink() or not same_path_binding(baseline,
                stat_snapshot(path.lstat(), domain='path'), canonical, str(path.resolve(strict=True))):
            raise ValueError('Authored path identity changed')
    directory = output / case['kind']
    directory.mkdir(mode=0o700, exist_ok=False)
    row = {'kind': case['kind'], 'sourceSHA256': expected, 'demuxOptions': OPTIONS,
           'frames': [], 'completeEOF': False, 'nativeCloseCompleted': False}
    save_json(directory / 'started.json', {'kind': case['kind'], 'sourceSHA256': expected})
    flags = os.O_RDONLY | getattr(os, 'O_BINARY', 0) | getattr(os, 'O_NOFOLLOW', 0)
    with os.fdopen(os.open(path, flags), 'rb') as stream:
        descriptor = stat_snapshot(os.fstat(stream.fileno()), domain='descriptor')
        if not path_matches_descriptor(baseline, descriptor):
            raise ValueError('Authored descriptor differs from path')
        bounded = _BoundedInput(stream, baseline.metadata[3], descriptor, check)
        with open_local_decoder(bounded, options=OPTIONS, check=check) as container:
            videos = list(container.streams.video)
            if len(videos) != 1:
                raise ValueError('Expected one authored video stream')
            video = videos[0]
            row['stream'] = {'index': video.index, 'containerID': video.id,
                'timeBase': ratio(video.time_base), 'startTime': video.start_time,
                'duration': video.duration, 'SAR': ratio(video.sample_aspect_ratio),
                'codecSAR': ratio(video.codec_context.sample_aspect_ratio),
                'codec': video.codec_context.name, 'format': container.format.name}
            previous = None
            for index, frame in enumerate(container.decode(video)):
                check()
                if index >= MAX_FRAMES:
                    raise ValueError('Frame census exceeds budget before EOF')
                if (frame.width, frame.height) != (192, 128) or frame.is_corrupt:
                    raise ValueError('Unexpected authored frame geometry or corruption')
                if type(frame.pts) is not int or type(frame.duration) is not int:
                    raise ValueError('Missing exact authored frame timestamp')
                tb = ratio(frame.time_base)
                if tb is None:
                    raise ValueError('Missing exact authored time base')
                pts, duration = frame.pts * Fraction(tb), frame.duration * Fraction(tb)
                if duration <= 0 or previous is not None and pts <= previous:
                    raise ValueError('Incomplete or unordered raw observations')
                previous = pts
                if (frame.format.name not in ('yuv420p', 'yuvj420p') or len(frame.planes) != 3
                        or any(c.bits != 8 for c in frame.format.components)):
                    raise ValueError('Controlled diagnostic expects three 8-bit YUV420 planes')
                prefix = f'frame-{index:03d}'
                observation = {'index': index, 'rawPTS': frame.pts, 'rawDuration': frame.duration,
                    'timeBase': tb, 'PTS': str(pts), 'duration': str(duration),
                    'format': frame.format.name, 'width': frame.width, 'height': frame.height,
                    'rotation': frame.rotation, 'planes': [],
                    'colorMetadata': {k: getattr(frame, k, None) for k in
                        ('colorspace', 'color_range', 'color_trc', 'color_primaries', 'chroma_location')}}
                for plane_index, plane in enumerate(frame.planes):
                    blob = save_bytes(directory, f'{prefix}-yuv-plane-{plane_index}.bin',
                                      visible_plane(plane, 1))
                    blob.update(index=plane_index, width=plane.width, height=plane.height,
                                lineSize=plane.line_size, bufferSize=plane.buffer_size)
                    observation['planes'].append(blob)
                # Preserve the actual production conversion before independent variants.
                production_rgb = frame.to_image().convert('RGB').tobytes()
                default = frame.reformat(format='rgb24')
                default_rgb = visible_plane(default.planes[0], 3)
                exact = VideoReformatter().reformat(frame, format='rgb24',
                    interpolation=Interpolation.BILINEAR | Interpolation.BITEXACT)
                exact_rgb = visible_plane(exact.planes[0], 3)
                accurate = VideoReformatter().reformat(frame, format='rgb24',
                    interpolation=Interpolation.BILINEAR | Interpolation.BITEXACT | Interpolation.ACCURATE_RND)
                accurate_rgb = visible_plane(accurate.planes[0], 3)
                if any(len(b) != 192 * 128 * 3 for b in (production_rgb, default_rgb, exact_rgb, accurate_rgb)):
                    raise ValueError('RGB visible buffer size mismatch')
                observation['productionToImageRGB'] = save_bytes(directory, f'{prefix}-production-rgb.bin', production_rgb)
                observation['defaultRGB24'] = save_bytes(directory, f'{prefix}-default-rgb.bin', default_rgb)
                observation['bitexactBilinearRGB24'] = save_bytes(directory, f'{prefix}-bitexact-rgb.bin', exact_rgb)
                observation['accurateBitexactBilinearRGB24'] = save_bytes(directory, f'{prefix}-accurate-rgb.bin', accurate_rgb)
                observation['accurateFlags'] = int(Interpolation.BILINEAR | Interpolation.BITEXACT | Interpolation.ACCURATE_RND)
                observation['bitexactFlags'] = int(Interpolation.BILINEAR | Interpolation.BITEXACT)
                observation['marker'] = marker(production_rgb)
                matches = [f for f in case['frames'] if rational(f['pts']) == pts]
                observation['historicalMacOracleAtPTS'] = matches
                observation['historicalRGBMatches'] = (len(matches) == 1 and
                    observation['productionToImageRGB']['SHA256'] == matches[0]['visibleRGB8SHA256'])
                observation['defaultVersusBitexact'] = {
                    'unequalBytes': sum(a != b for a, b in zip(default_rgb, exact_rgb)),
                    'maxAbsoluteByteDifference': max(abs(a-b) for a, b in zip(default_rgb, exact_rgb))}
                save_json(directory / f'{prefix}.json', observation)
                row['frames'].append(observation)
                del frame, default, exact, accurate
            row['completeEOF'] = True
        row['nativeCloseCompleted'] = True
        check()
        if not same_domain(descriptor, stat_snapshot(os.fstat(stream.fileno()), domain='descriptor')):
            raise ValueError('Authored descriptor changed after native close')
    check()
    if sha(path) != expected:
        raise ValueError('Authored source bytes changed')
    if not row['frames']:
        raise ValueError('No actual decoded frames')
    row['sourcePreserved'] = True
    save_json(directory / 'report.json', row)
    return row


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--repository', type=Path, required=True)
    parser.add_argument('--output-directory', type=Path, required=True)
    args = parser.parse_args()
    repo = args.repository.resolve(strict=True)
    if repo != Path(__file__).resolve().parents[2]:
        raise ValueError('This reviewed repository only')
    output = args.output_directory.absolute()
    parent = output.parent
    if (output.name != 'observations' or parent.parent != repo / '.build' or
            not re.fullmatch(r'video-decoder-diagnostic-[0-9a-f-]{36}', parent.name) or
            parent.is_symlink() or parent.resolve(strict=True) != parent):
        raise ValueError('Fresh owned diagnostic output only')
    output.mkdir(mode=0o700, exist_ok=False)
    sys.path.insert(0, str(repo))
    manifest_path = repo / 'shared/fixtures/video-timelines/manifest.json'
    if sha(manifest_path) != MANIFEST_SHA:
        raise ValueError('Reviewed synthetic manifest changed')
    manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
    if (manifest['syntheticOnly'] is not True or manifest['schemaVersion'] != 1 or
            [c['kind'] for c in manifest['cases']] != list(KINDS) or
            any(c['file'] != c['kind'] + '.mov' for c in manifest['cases'])):
        raise ValueError('Fixed authored fixture whitelist required')
    report = {'status': 'failed-or-incomplete', 'actualHost': sys.platform,
        'actualWindows': sys.platform == 'win32', 'machine': platform.machine(),
        'manifestSHA256': MANIFEST_SHA, 'cases': [], 'fullGoalComplete': False,
        'RGBParityProven': False, 'OSInput': False, 'QtImported': False,
        'limits': {'maxFramesPerCase': MAX_FRAMES, 'width': 192, 'height': 128}}
    status = 1
    try:
        import av
        if av.__version__ != '19.0.0':
            raise ValueError('Exact reviewed PyAV19.0.0 required')
        report['runtime'] = {'python': platform.python_version(), 'av': av.__version__,
            'Pillow': importlib.metadata.version('Pillow'),
            'libraryVersions': av.library_versions}
        for case in manifest['cases']:
            report['cases'].append(observe_case(repo, output, case))
        if sha(manifest_path) != MANIFEST_SHA:
            raise ValueError('Authored manifest changed during census')
        report.update(status='observations-complete-not-product-pass', sourcesPreserved=True)
        status = 0
    except BaseException as error:
        report['errorType'] = type(error).__name__
        # No arbitrary native URI/path/error strings in public diagnostic output.
        report['error'] = str(error) if type(error) is ValueError else 'Native observation failed; partial owned files retained'
    finally:
        save_json(output / 'report.json', report)
    return status


if __name__ == '__main__':
    raise SystemExit(main())
