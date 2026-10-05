"""Actual disposable Windows MF H264 + PCM/VFR decode probe; no app/OS input."""
from fractions import Fraction
import ctypes
from ctypes import wintypes
import hashlib
import json
import os
from pathlib import Path
import shlex
import sys


LIBRARIES = frozenset(('libavutil', 'libavcodec', 'libavformat', 'libavdevice',
                       'libavfilter', 'libswscale', 'libswresample'))


def validate_metadata(metadata, public_versions):
    """Pinned PyAV19 internal metadata must agree with its public versions."""
    if not isinstance(metadata, dict) or not isinstance(public_versions, dict) or \
            set(metadata) != LIBRARIES or set(public_versions) != LIBRARIES:
        raise ValueError('complete seven-library PyAV19 metadata/version census required')
    for name, entry in metadata.items():
        if not isinstance(entry, dict) or set(entry) != {'version', 'configuration', 'license'}:
            raise ValueError('exact PyAV19 library metadata structure required')
        version = entry['version']
        public = public_versions[name]
        if any(not isinstance(v, tuple) or len(v) != 3 or
               any(type(n) is not int or n < 0 for n in v) for v in (version, public)) or version != public:
            raise ValueError('loaded FFmpeg metadata/public library_versions mismatch')
        configuration = entry['configuration']
        if not isinstance(configuration, str):
            raise ValueError('loaded FFmpeg configuration must be an explicit string')
        flags = set(shlex.split(configuration))
        if not {'--enable-gpl', '--enable-version3'} <= flags or \
                flags & {'--disable-gpl', '--disable-version3'}:
            raise ValueError('loaded FFmpeg GPL/version3 configuration missing')
        if entry['license'] != 'GPL version 3 or later':
            raise ValueError('loaded FFmpeg GPL version 3 license mismatch')


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def modules():
    """Current process loaded DLL census, not only import-table guesses."""
    psapi = ctypes.WinDLL('psapi', use_last_error=True)
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.GetCurrentProcess.restype = wintypes.HANDLE
    psapi.EnumProcessModulesEx.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.HMODULE),
                                           wintypes.DWORD, ctypes.POINTER(wintypes.DWORD), wintypes.DWORD]
    psapi.EnumProcessModulesEx.restype = wintypes.BOOL
    psapi.GetModuleFileNameExW.argtypes = [wintypes.HANDLE, wintypes.HMODULE, wintypes.LPWSTR, wintypes.DWORD]
    psapi.GetModuleFileNameExW.restype = wintypes.DWORD
    entries = (wintypes.HMODULE * 2048)()
    needed = wintypes.DWORD()
    process = kernel.GetCurrentProcess()
    if not psapi.EnumProcessModulesEx(process, entries, ctypes.sizeof(entries), ctypes.byref(needed), 3):
        raise ctypes.WinError(ctypes.get_last_error())
    if needed.value > ctypes.sizeof(entries) or needed.value % ctypes.sizeof(wintypes.HMODULE):
        raise ValueError('finite complete module census unavailable')
    result = []
    for handle in entries[:needed.value // ctypes.sizeof(wintypes.HMODULE)]:
        buffer = ctypes.create_unicode_buffer(32768)
        length = psapi.GetModuleFileNameExW(process, handle, buffer, len(buffer))
        if not 0 < length < len(buffer):
            raise ValueError('loaded DLL path incomplete')
        path = Path(buffer.value)
        result.append({'name': path.name, 'path': str(path), 'sha256': digest(path)})
    return sorted(result, key=lambda x: x['path'].lower())


def main(arguments=None):
    arguments = sys.argv[1:] if arguments is None else arguments
    if len(arguments) != 1:
        raise ValueError("one owned candidate root required")
    root = Path(arguments[0]).absolute()
    report = {'actualWindows': sys.platform == 'win32',
              'appExecuted': False, 'OSInput': False, 'releaseApproved': False,
              'timelineP1Closed': False, 'allFormatsVerified': False}
    status = 1
    try:
        if sys.platform != 'win32' or not (root / 'owned.json').is_file():
            raise ValueError('owned actual Windows PyAV19 required')
        report['phase'] = 'pyav-import'
        import av
        report['PyAVVersion'] = av.__version__
        if av.__version__ != '19.0.0':
            raise ValueError('owned actual Windows PyAV19 required')
        # __init__.py exports library_versions, but not library_meta in pinned19.
        # Keep both native imports inside the report-preserving try/finally.
        report['phase'] = 'library-metadata'
        from av._core import library_meta
        report['libraryMeta'] = {str(k): {str(a): str(b) for a, b in v.items()}
                                 for k, v in library_meta.items()}
        report['libraryVersions'] = {str(k): str(v) for k, v in av.library_versions.items()}
        validate_metadata(library_meta, av.library_versions)
        report['libraryMetadataValidated'] = True
        report['phase'] = 'mf-registration'
        if 'h264_mf' not in av.codecs_available:
            raise ValueError('MF registration unavailable; no silent substitute')
        report['phase'] = 'mf-encode'
        target = root / 'authored-mf-vfr-pcm.mov'
        ticks = [0, 1, 3, 6]
        with av.open(str(target), 'w', format='mov') as output:
            video = output.add_stream('h264_mf', rate=24, options={'hw_encoding': '0'})
            video.width, video.height, video.pix_fmt = 96, 64, 'nv12'
            video.time_base = Fraction(1, 24)
            audio = output.add_stream('pcm_s16le', rate=8000)
            audio.layout = 'mono'
            for index, tick in enumerate(ticks):
                frame = av.VideoFrame(96, 64, 'yuv420p')
                for plane_index, plane in enumerate(frame.planes):
                    plane.update(bytes([50 + index * 35 if plane_index == 0 else 128]) * plane.buffer_size)
                frame.pts, frame.time_base = tick, Fraction(1, 24)
                encoded_input = frame.reformat(format='nv12')
                # Keep authored exact timing explicit across format conversion;
                # never manufacture decoder timestamps from the selected rate.
                encoded_input.pts, encoded_input.time_base = tick, Fraction(1, 24)
                for packet in video.encode(encoded_input):
                    output.mux(packet)
            for packet in video.encode(None):
                output.mux(packet)
            sound = av.AudioFrame(format='s16', layout='mono', samples=4000)
            sound.sample_rate, sound.pts, sound.time_base = 8000, 0, Fraction(1, 8000)
            sound.planes[0].update(bytes(sound.planes[0].buffer_size))
            for packet in audio.encode(sound): output.mux(packet)
            for packet in audio.encode(None): output.mux(packet)
        before = digest(target)
        report['phase'] = 'native-video-pcm-readback'
        video_pts, means = [], []
        with av.open(str(target), 'r') as source:
            for frame in source.decode(video=0):
                if len(video_pts) >= 16 or frame.pts is None:
                    raise ValueError('finite actual decoded frame count/PTS required')
                video_pts.append(frame.pts * Fraction(frame.time_base.numerator, frame.time_base.denominator))
                image = frame.reformat(format='gray')
                plane = image.planes[0]
                data = bytes(plane)
                visible = [data[y * plane.line_size + x] for y in range(64) for x in range(96)]
                means.append(sum(visible) / len(visible))
        audio_samples = 0
        with av.open(str(target), 'r') as source:
            for frame in source.decode(audio=0):
                audio_samples += frame.samples
                if audio_samples > 4000: raise ValueError('unexpected PCM sample count')
        # Container time-base conversion uses exact Fraction. Do not add epsilon or
        # alter source periods to make MF/CFR rewriting disappear from the report.
        expected = [Fraction(x, 24) for x in ticks]
        report.update({'expectedPTS': [str(x) for x in expected], 'actualPTS': [str(x) for x in video_pts],
                       'actualGrayMeans': means, 'audioSamples': audio_samples,
                       'originalSHA256': before, 'originalPreserved': before == digest(target),
                       'loadedModules': modules()})
        if video_pts != expected or len(means) != 4 or any(b <= a + 10 for a, b in zip(means, means[1:])):
            raise ValueError('MF actual VFR/ordered authored brightness mismatch')
        if audio_samples != 4000 or before != digest(target):
            raise ValueError('authored PCM/source preservation mismatch')
        # Verify actual MP4 packaging separately; this preserves exact encoded video
        # packets and does not assert a second MF encode or arbitrary audio codec.
        report['phase'] = 'mp4-remux'
        mp4 = root / 'authored-mf-video.mp4'
        with av.open(str(target), 'r') as source, av.open(str(mp4), 'w', format='mp4') as output:
            incoming = source.streams.video[0]
            outgoing = output.add_stream_from_template(incoming)
            for packet in source.demux(incoming):
                if packet.dts is None: continue
                packet.stream = outgoing
                output.mux(packet)
        with av.open(str(mp4), 'r') as source:
            pts = [f.pts * Fraction(f.time_base.numerator, f.time_base.denominator) for f in source.decode(video=0)]
        if pts != expected: raise ValueError('actual MP4 remux PTS mismatch')
        report['MP4PTS'] = [str(x) for x in pts]
        report['phase'] = 'completed'
        report['status'] = 'actual-MF-core-smoke-pass-not-full-product'
        status = 0
    except BaseException as error:
        report.update({'status': 'actual-smoke-failed', 'errorType': type(error).__name__, 'error': str(error)})
    finally:
        with (root / 'reports' / 'smoke.json').open('x', encoding='utf-8') as stream:
            json.dump(report, stream, ensure_ascii=False, sort_keys=True, indent=2)
            stream.write('\n')
    return status


if __name__ == "__main__":
    raise SystemExit(main())
