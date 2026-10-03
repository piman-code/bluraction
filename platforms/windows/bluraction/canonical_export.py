"""Asset-presentation export in an exclusively owned native worker.

Source PTS/sample membership comes from completed canonical providers. Empty
video intervals have an explicit opaque-black scene, sampled at 60 Hz only for
that synthetic scene; content VFR timestamps are never resampled. MOV writes
PCM without sample conversion, MP4 writes AAC with an explicit delay/trim check.
No publication, source mutation, GUI, device audio or encoder fallback occurs
here. The parent owns a whole-operation deadline, process reap and publication.
"""
from __future__ import annotations

from dataclasses import dataclass
from contextlib import contextmanager
from fractions import Fraction
import hashlib
import heapq
import json
import math
import os
import struct
from pathlib import Path

from PIL import Image
from PySide6.QtGui import QImage
from shared.video_timeline import rational, encode_rational
from .frame_inventory import _exact_fraction, _BoundedInput
from .media import check_cancel, fingerprint, _capture_identity, _check_identity, _cleanup_preserving_primary
from .renderer import render, to_pillow


class CanonicalExportError(ValueError):
    pass


@dataclass(frozen=True)
class SceneFrame:
    time: Fraction
    end: Fraction
    image: QImage
    source_index: int | None
    presence: str


def exact_ticks(value, time_base):
    if type(value) is not Fraction:
        raise CanonicalExportError('exact rational output clock required')
    # PyAV19 getters return native AVRational even after a Fraction setter.
    # Admit only the actual pinned native class through the existing exact
    # integer adapter; floats/bools/duck-rationals remain invalid.
    time_base = _exact_fraction(time_base, 'output time base')
    if time_base <= 0:
        raise CanonicalExportError('positive exact output clock required')
    ticks = value / time_base
    if ticks.denominator != 1 or not -(1 << 63) <= ticks.numerator < (1 << 63):
        raise CanonicalExportError('output time cannot be represented exactly')
    return ticks.numerator


def output_time_base(video):
    """Bounded streaming LCM, not guessed source FPS or rounded PTS."""
    denominator = 60  # Explicit synthetic-scene output cadence only.
    for value in (video.asset_duration,):
        denominator = math.lcm(denominator, value.denominator)
    for sample in video._index.iter_samples():
        denominator = math.lcm(denominator, sample.asset_pts.denominator,
                               sample.interval_end.denominator)
        if denominator > (1 << 31) - 1:
            raise CanonicalExportError('native rational output time base exceeds signed32')
    for track in video.timeline['tracks']:
        for segment in track['segments']:
            denominator = math.lcm(denominator, rational(segment['assetStart']).denominator,
                                   rational(segment['assetDuration']).denominator)
            if denominator > (1 << 31) - 1:
                raise CanonicalExportError('asset boundary time base exceeds native signed32')
    return Fraction(1, denominator)


def iter_scenes(video, state, size):
    """Every content interval plus descriptor-proven empty/suffix intervals.

    A hole inside content is an error, never substituted black. One decoded
    image and one rendered image are live; iteration retains no frame list.
    """
    black = QImage(size[0], size[1], QImage.Format.Format_RGBA8888)
    black.fill(0xff000000)
    cursor = Fraction(0)
    content = video.iter_content()

    def blank_until(end):
        nonlocal cursor
        while cursor < end:
            presence = video._index.presence(cursor)
            if presence.kind not in ('empty', 'suffix'):
                raise CanonicalExportError('unobserved content interval cannot become black output')
            finish = min(end, cursor + Fraction(1, 60))
            # Synthetic scene PTS are explicit output records, not decoded PTS.
            yield SceneFrame(cursor, finish, render(black, state, time=float(cursor)),
                             None, presence.kind)
            cursor = finish

    failure = None
    try:
        for pixels in content:
            if pixels.interval_start != pixels.asset_pts or pixels.interval_end <= pixels.asset_pts:
                raise CanonicalExportError('canonical content interval is not proven')
            yield from blank_until(pixels.asset_pts)
            if cursor != pixels.asset_pts:
                raise CanonicalExportError('canonical content intervals overlap')
            yield SceneFrame(pixels.asset_pts, pixels.interval_end,
                render(pixels.image, state, time=float(pixels.asset_pts)),
                pixels.source_index, 'content')
            cursor = pixels.interval_end
        yield from blank_until(video.asset_duration)
        if cursor != video.asset_duration:
            raise CanonicalExportError('export does not cover complete asset duration')
    except BaseException as error:
        failure = error
        raise
    finally:
        try: content.close()
        except BaseException as cleanup:
            if failure is not None:
                failure.add_note(f'content cursor cleanup also failed: {cleanup!r}')
                if cleanup is failure: raise failure
                raise failure from cleanup
            raise


def _write_record(stream, scene):
    row = dict(pts=encode_rational(scene.time), duration=encode_rational(scene.end-scene.time),
               sourceIndex=scene.source_index, presence=scene.presence)
    stream.write(json.dumps(row, separators=(',', ':')).encode('ascii') + b'\n')


def _pcm_frame(av, chunk):
    fmt = chunk.format
    frame = av.AudioFrame(format=fmt.name, layout=fmt.layout, samples=chunk.samples)
    if tuple(c.name for c in frame.layout.channels) != fmt.channels:
        raise CanonicalExportError('encoder input changed channel layout')
    frame.sample_rate = fmt.sample_rate
    frame.time_base = Fraction(1, fmt.sample_rate)
    frame.pts = exact_ticks(chunk.requested_time, frame.time_base)
    if len(frame.planes) != len(chunk.planes):
        raise CanonicalExportError('PCM planar/packed shape changed')
    for plane, data in zip(frame.planes, chunk.planes):
        if len(data) > plane.buffer_size:
            raise CanonicalExportError('meaningful PCM exceeds allocated audio plane')
        plane.update(data + b'\0' * (plane.buffer_size-len(data)))
    return frame


_PCM_CODECS = {'u8': 'pcm_u8', 's16': 'pcm_s16le', 's32': 'pcm_s32le',
               's64': 'pcm_s64le', 'flt': 'pcm_f32le', 'dbl': 'pcm_f64le'}


def encode_from_providers(video, audio, state, output_path, decoder_metadata,
                          quality, encoder, *, progress=None, cancel=None):
    """Whole private export transaction; completed providers are borrowed.

    The native worker owns them and closes them after this operation. Production
    passes the registered native H264 encoder; MPEG4 is a test-only explicit
    caller selection, never an automatic failure fallback.
    """
    from .video import _av, output_bit_rate
    av = _av()
    from av.stream import Disposition
    path = Path(output_path)
    if path.exists() or path.is_symlink() or path.suffix.lower() not in ('.mov', '.mp4', '.m4v'):
        raise CanonicalExportError('exclusive new private MOV/MP4 output required')
    video._guard(hash_source=True); audio.validate_source(); check_cancel(cancel)
    if audio.descriptor_sha256 != video.descriptor_sha256:
        raise CanonicalExportError('audio and video descriptor differ')
    first = next(video._index.iter_samples(), None)
    if first is None:
        raise CanonicalExportError('completed source has no content frame')
    image = video.frame_at(first.asset_pts).image
    size = (image.width(), image.height())
    if size[0] % 2 or size[1] % 2:
        raise CanonicalExportError('encoder requires even dimensions; no crop')
    base = output_time_base(video)
    records_path = path.with_suffix(path.suffix + '.video-records.jsonl')
    report = dict(sourceSHA256=video._sha, descriptorSHA256=video.descriptor_sha256,
                  assetDuration=encode_rational(video.asset_duration), contentFrames=0,
                  syntheticSceneFrames=0, syntheticSceneCadence=encode_rational(Fraction(1, 60)),
                  videoFrames=0, width=size[0], height=size[1], audioTracks=[], encoder=encoder, outputVerified=False,
                  pixelContract='same-canonical-preview-converter', audioPolicy='MOV-PCM' if path.suffix == '.mov' else 'MP4-AAC')
    iterators = []
    try:
        with records_path.open('xb') as records, av.open(str(path), 'w',
                options={'avoid_negative_ts': 'disabled', 'movie_timescale': str(base.denominator),
                         'video_track_timescale': str(base.denominator), 'use_editlist': '1'}) as output:
            hint = decoder_metadata.get('averageRate')
            stream = output.add_stream(encoder, rate=hint)
            stream.width, stream.height = size
            stream.pix_fmt = 'nv12' if encoder == 'h264_mf' else 'yuv420p'
            stream.time_base = stream.codec_context.time_base = base
            stream.codec_context.max_b_frames = 0
            stream.codec_context.sample_aspect_ratio = Fraction(1)
            stream.set_display_rotation(0)
            stream.bit_rate = output_bit_rate(quality, decoder_metadata.get('bitRate', 0),
                float(hint) if hint is not None else 0, *size)
            pending_durations = {}
            sound = []
            audio_hashes = []
            audio_packets = {}
            for info in audio.tracks:
                fmt = info.format
                name = _PCM_CODECS.get(fmt.name.removesuffix('p')) if path.suffix == '.mov' else 'aac'
                if name is None:
                    raise CanonicalExportError('PCM codec preservation needs implementation; track not dropped')
                target = output.add_stream(name, rate=fmt.sample_rate)
                target.layout = fmt.layout
                # Providers reject disabled source tracks. All observed active
                # audio tracks must stay enabled in the MOV tkhd as well; the
                # stock muxer otherwise auto-enables only its first audio.
                target.disposition = Disposition.default
                target.time_base = target.codec_context.time_base = Fraction(1, fmt.sample_rate)
                target.codec_context.format = 'fltp' if name == 'aac' else fmt.name.removesuffix('p')
                if name == 'aac':
                    target.bit_rate = max(128000, 64000 * len(fmt.channels))
                sound.append((info, target, av.AudioResampler(format=target.codec_context.format.name,
                    layout=fmt.layout, rate=fmt.sample_rate)))
                audio_hashes.append(hashlib.sha256())
                report['audioTracks'].append(dict(sourceTrackID=info.track_id, samples=0,
                    contentSamples=0, emptySamples=0, sampleRate=fmt.sample_rate,
                    channels=list(fmt.channels), start=None, end=None, codec=name,
                    packedFormat=fmt.name.removesuffix('p'), bytesPerSample=fmt.bytes_per_sample))
            output.start_encoding()

            def mux_video(packets):
                for packet in packets:
                    if type(packet.pts) is not int or packet.time_base is None:
                        raise CanonicalExportError('encoder omitted exact output scene timestamp')
                    stamp = Fraction(packet.pts) * _exact_fraction(packet.time_base, 'encoded time base')
                    duration = pending_durations.pop(stamp, None)
                    if duration is None:
                        raise CanonicalExportError('encoder changed/lost exact scene PTS')
                    packet.duration = exact_ticks(duration, _exact_fraction(packet.time_base, 'packet time base'))
                    output.mux(packet)

            def mux_audio(index, packets):
                # Retain only the last packet of each stream: the final packet
                # needs exact sample-grid end duration/encoder padding metadata.
                for packet in packets:
                    previous = audio_packets.get(index)
                    if previous is not None: output.mux(previous)
                    audio_packets[index] = packet

            scenes = iter(iter_scenes(video, state, size)); iterators.append(scenes)
            heap = []
            first_scene = next(scenes, None)
            if first_scene is None: raise CanonicalExportError('no output scene')
            heapq.heappush(heap, (first_scene.time, 0, first_scene))
            for index, (info, target, resampler) in enumerate(sound, 1):
                iterator = iter(audio.iter_asset_pcm(info.track_id)); iterators.append(iterator)
                chunk = next(iterator, None)
                if chunk is not None: heapq.heappush(heap, (chunk.requested_time, index, chunk))
            while heap:
                check_cancel(cancel); video._guard(); audio._guard()
                stamp, index, value = heapq.heappop(heap)
                if index == 0:
                    scene = value
                    if (scene.image.width(),scene.image.height()) != size:
                        raise CanonicalExportError('normalized scene size changed; no implicit resize')
                    frame = av.VideoFrame.from_image(to_pillow(scene.image).convert('RGB'))
                    frame.time_base, frame.pts = base, exact_ticks(scene.time, base)
                    frame.duration = exact_ticks(scene.end-scene.time, base)
                    pending_durations[scene.time] = scene.end-scene.time
                    if len(pending_durations) > 256:
                        raise CanonicalExportError('encoder buffering exceeded bounded scene budget')
                    mux_video(stream.encode(frame))
                    _write_record(records, scene)
                    report['videoFrames'] += 1
                    key = 'contentFrames' if scene.source_index is not None else 'syntheticSceneFrames'
                    report[key] += 1
                else:
                    info, target, resampler = sound[index-1]
                    chunk = value
                    stats = report['audioTracks'][index-1]
                    from .canonical_transport import packed_pcm
                    from dataclasses import replace
                    audio_hashes[index-1].update(packed_pcm(replace(chunk, presence='content')))
                    for frame in resampler.resample(_pcm_frame(av, chunk)):
                        mux_audio(index-1, target.encode(frame))
                    stats['samples'] += chunk.samples
                    stats['contentSamples' if chunk.presence == 'content' else 'emptySamples'] += chunk.samples
                    if stats['start'] is None: stats['start'] = encode_rational(chunk.requested_time)
                    stats['end'] = encode_rational(chunk.interval_end)
                next_value = next(iterators[index], None)
                if next_value is not None:
                    next_time = next_value.time if index == 0 else next_value.requested_time
                    heapq.heappush(heap, (next_time, index, next_value))
                if progress is not None: progress(min(.90, float(stamp/video.asset_duration)*.90))
            mux_video(stream.encode(None))
            if pending_durations:
                raise CanonicalExportError('encoder omitted output scenes')
            for index, (info, target, resampler) in enumerate(sound):
                for frame in resampler.resample(None):
                    mux_audio(index, target.encode(frame))
                mux_audio(index, target.encode(None))
                stats = report['audioTracks'][index]
                packet = audio_packets.pop(index, None)
                if packet is None or stats['end'] is None:
                    raise CanonicalExportError('audio encoder produced no scheduled samples')
                if type(packet.pts) is not int or packet.time_base is None:
                    raise CanonicalExportError('audio encoder omitted final exact timestamp')
                packet_base = _exact_fraction(packet.time_base, 'audio encoded time base')
                packet_start = Fraction(packet.pts) * packet_base
                length = rational(stats['end']) - packet_start
                if length <= 0:
                    raise CanonicalExportError('audio encoder produced packet beyond scheduled EOF')
                if stats['codec'] == 'aac':
                    frame_size = target.codec_context.frame_size
                    if type(frame_size) is not int or not 0 < frame_size < (1 << 32):
                        raise CanonicalExportError('AAC encoder sample frame size unavailable')
                    emitted = max(packet.duration * packet_base, Fraction(frame_size,stats['sampleRate']))
                    discard = max(Fraction(0), emitted-length) * stats['sampleRate']
                    if discard.denominator != 1 or discard >= (1 << 32):
                        raise CanonicalExportError('AAC end padding is not an exact sample count')
                    old = packet.get_sidedata('skip_samples')
                    if old and len(bytes(old)) != 10:
                        raise CanonicalExportError('unrecognized encoder skip-samples data')
                    before, after, why_before, why_after = struct.unpack('<IIBB', bytes(old)) if old else (0,0,0,0)
                    if after + discard.numerator >= (1 << 32):
                        raise CanonicalExportError('AAC discard sample count overflow')
                    data = av.packet.PacketSideData(av.packet.packet_sidedata_type_from_literal('skip_samples'),10)
                    data.update(struct.pack('<IIBB', before, after+discard.numerator, why_before, why_after))
                    packet.set_sidedata(data)
                packet.duration = exact_ticks(length, packet_base)
                output.mux(packet)
                stats['inputPCM_SHA256'] = audio_hashes[index].hexdigest()
            records.flush()
        video._guard(hash_source=True); audio.validate_source(); check_cancel(cancel)
        verify_output(path, records_path, report, cancel=cancel)
        report['outputSHA256'] = fingerprint(path, max_bytes=path.stat().st_size, cancel=cancel)
        report['outputVerified'] = True
        if progress is not None: progress(.98)
        return report
    finally:
        # Generator.close tears down sequential native cursors without closing
        # the borrowed providers. Preserve the original exception on double fail.
        from .media import _cleanup_preserving_primary
        for iterator in reversed(iterators):
            close = getattr(iterator, 'close', None)
            if close is not None: _cleanup_preserving_primary(close, 'export cursor cleanup')


@contextmanager
def _decoded(container,stream):
    iterator=iter(container.decode(stream))
    try: yield iterator
    finally:
        close=getattr(iterator,'close',None)
        if close is not None: _cleanup_preserving_primary(close,'output EOF iterator close')


@contextmanager
def _open_output(path,cancel):
    """Generated-file EOF readback still rejects every secondary native IO."""
    from shared.source_identity import stat_snapshot,path_matches_descriptor,same_domain
    from .local_decoder import open_local_decoder
    identity=_capture_identity(path)
    flags=os.O_RDONLY|getattr(os,'O_BINARY',0)|getattr(os,'O_NOFOLLOW',0)
    def guard():
        check_cancel(cancel); _check_identity(path,identity)
        return False
    with os.fdopen(os.open(path,flags),'rb') as stream:
        before=stat_snapshot(os.fstat(stream.fileno()),domain='descriptor')
        if not path_matches_descriptor(identity.stat_snapshot,before):
            raise CanonicalExportError('output descriptor replaced before EOF verification')
        bounded=_BoundedInput(stream,identity.metadata[3],before,guard)
        with open_local_decoder(bounded,mode='r',options={'ignore_editlist':'0','advanced_editlist':'1'}) as container:
            yield container
        if not same_domain(before,stat_snapshot(os.fstat(stream.fileno()),domain='descriptor')):
            raise CanonicalExportError('output descriptor changed during EOF verification')
        guard()


def verify_output(path, records_path, report, *, cancel=None):
    """Actual fresh EOF readback; no original-source SHA equality claim for H264."""
    from .video import _av
    av = _av()
    duration = rational(report['assetDuration'])
    with _open_output(path,cancel) as container, Path(records_path).open('rb') as expected:
        videos = list(container.streams.video)
        if len(videos) != 1 or len(container.streams.audio) != len(report['audioTracks']):
            raise CanonicalExportError('output dropped/added media tracks')
        count = 0
        with _decoded(container,videos[0]) as frames:
            for frame in frames:
                check_cancel(cancel)
                line = expected.readline(1025)
                if not line or len(line) > 1024:
                    raise CanonicalExportError('additional output frame or malformed expected record')
                row = json.loads(line)
                pts = Fraction(frame.pts) * _exact_fraction(frame.time_base, 'output video time base')
                length = frame.duration * _exact_fraction(frame.time_base, 'output video time base')
                if pts != rational(row['pts']) or length != rational(row['duration']):
                    raise CanonicalExportError('output frame PTS/duration differs from exact asset schedule')
                if (frame.width,frame.height) != (report['width'],report['height']):
                    raise CanonicalExportError('output frame geometry changed')
                count += 1
        if expected.read(1) or count != report['videoFrames']:
            raise CanonicalExportError('output missed scene frames')
    # Each stream is freshly opened: prior video EOF must not consume audio.
    for index, stats in enumerate(report['audioTracks']):
        with _open_output(path,cancel) as container:
            stream = list(container.streams.audio)[index]
            first = end = None; count = 0
            pcm_hash = hashlib.sha256()
            with _decoded(container,stream) as frames:
                for frame in frames:
                    check_cancel(cancel)
                    pts = Fraction(frame.pts) * _exact_fraction(frame.time_base, 'output PCM time base')
                    finish = pts + Fraction(frame.samples, frame.sample_rate)
                    if frame.sample_rate != stats['sampleRate'] or tuple(c.name for c in frame.layout.channels) != tuple(stats['channels']):
                        raise CanonicalExportError('output audio sample rate/layout changed')
                    if end is not None and pts != end:
                        raise CanonicalExportError('output PCM has an unexpected gap or overlap')
                    if stats['codec'] != 'aac':
                        width, channels = stats['bytesPerSample'], len(stats['channels'])
                        if frame.format.name.removesuffix('p') != stats['packedFormat']:
                            raise CanonicalExportError('MOV PCM sample representation changed')
                        if frame.format.is_planar:
                            planes = [bytes(p)[:frame.samples*width] for p in frame.planes]
                            pcm_hash.update(b''.join(p[s*width:(s+1)*width]
                                for s in range(frame.samples) for p in planes))
                        else:
                            pcm_hash.update(bytes(frame.planes[0])[:frame.samples*width*channels])
                    first = pts if first is None else first; end = finish; count += frame.samples
            if stats['start'] is None or first != rational(stats['start']) or end != rational(stats['end']) or count != stats['samples']:
                raise CanonicalExportError('output audio priming/trim/sample coverage differs from asset schedule')
            if stats['codec'] != 'aac' and pcm_hash.hexdigest() != stats['inputPCM_SHA256']:
                raise CanonicalExportError('MOV output meaningful PCM bytes changed')
    from .asset_timeline import inspect_asset_timeline
    observed = inspect_asset_timeline(path, cancel=cancel)
    if any(not track.enabled for track in observed.tracks):
        raise CanonicalExportError('output disabled a previously active source track')
    if observed.asset_duration != duration:
        raise CanonicalExportError('fresh output movie duration differs from full asset duration')
    report['verifiedVideoFrames'] = report['videoFrames']
    report['verifiedAudioTracks'] = len(report['audioTracks'])
    report['verifiedAllTracksEnabled'] = True
