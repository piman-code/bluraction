"""Actual disposable Windows MF H264 + PCM/VFR decode probe; no app/OS input."""
from fractions import Fraction
import ctypes
from ctypes import wintypes
import hashlib
import json
import os
from pathlib import Path
import sys

import av


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


root = Path(sys.argv[1]).absolute()
report = {'actualWindows': sys.platform == 'win32', 'PyAVVersion': av.__version__,
          'appExecuted': False, 'OSInput': False, 'releaseApproved': False,
          'timelineP1Closed': False, 'allFormatsVerified': False}
status = 1
try:
    if sys.platform != 'win32' or av.__version__ != '19.0.0' or not (root / 'owned.json').is_file():
        raise ValueError('owned actual Windows PyAV19 required')
    report['libraryMeta'] = {str(k): {str(a): str(b) for a, b in v.items()}
                             for k, v in av.library_meta.items()}
    configurations = [str(x.get('configuration', '')) for x in av.library_meta.values()]
    if not configurations or not all('--enable-gpl' in c and '--enable-version3' in c for c in configurations):
        raise ValueError('loaded FFmpeg GPL/version3 configuration missing')
    if 'h264_mf' not in av.codecs_available:
        raise ValueError('MF registration unavailable; no silent substitute')
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
    report['status'] = 'actual-MF-core-smoke-pass-not-full-product'
    status = 0
except BaseException as error:
    report.update({'status': 'actual-smoke-failed', 'errorType': type(error).__name__, 'error': str(error)})
finally:
    with (root / 'reports' / 'smoke.json').open('x', encoding='utf-8') as stream:
        json.dump(report, stream, ensure_ascii=False, sort_keys=True, indent=2)
        stream.write('\n')
raise SystemExit(status)
