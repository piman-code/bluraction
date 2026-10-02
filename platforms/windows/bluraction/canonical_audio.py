"""Private MOV asset-scheduled PCM candidate; no audio device/mix/export policy.

The explicit clock declaration is provisional: FFmpeg has ALREADY applied the
edit list. Neither mediaStart nor a guessed origin is subtracted again. Actual
decoded samples/PTS/format/layout and meaningful plane bytes are conserved in a
private spool before exact integer-sample clipping. Decoder priming/skip handling
is observed, not reconstructed from encoded packet counts. Missing content is a
review hold, never manufactured silence. Empty edits and asset suffix are tags;
this module does not infer an audible hold, generate a device clock or resample.

All descriptor audio IDs must be decoded to normal EOF. Repeated media, changing
PCM format/rate/layout, non-unit rates and non-sample-aligned clipping are explicit
temporary review holds, not final exclusions from application format support.
All opens use the PyAV19 latched local secondary-IO denial boundary and owned
bounded readonly descriptors. This is not a native-call deadline/OS sandbox or
generic MOV/native Windows/P1 proof. Caller retains authorization/publication.

Memory: one native AudioFrame plus bounded 64KiB writes/1MiB query result;
metadata <=16 tracks/4096 segments each, fixed disk records, no frame list. Disk
budgets are explicit and configurable. No source, project, UI or output changes.
PyAV19 AudioFrame.samples is samples PER CHANNEL; format.bytes is bytes/sample:
https://pyav.basswood.io/docs/stable/api/audio.html
FFmpeg9 skip/discard updates actual nb_samples and timestamps/duration before
the frame is returned; this provider never reapplies those packet skip counts:
https://github.com/FFmpeg/FFmpeg/blob/n9.0.2/libavcodec/decode.c
"""
from __future__ import annotations

from dataclasses import dataclass
from fractions import Fraction
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import sys
import tempfile
from threading import RLock

from shared.source_identity import stat_snapshot, same_domain, path_matches_descriptor
from shared.video_timeline import encode_rational, rational, validate_timeline
from .asset_timeline import inspect_asset_timeline
from .frame_inventory import (_BoundedInput, _cancel, _generation, _exact_fraction,
                              _pack_fraction, _unpack_fraction, INT64_MAX)
from .local_decoder import open_local_decoder
from .media import _capture_identity, _check_identity, fingerprint

_OPTIONS = {'advanced_editlist': '1', 'ignore_editlist': '0'}
_RECORD = struct.Struct('<32s32s7q')
_BUFFER = 64 * 1024
_READ = 1024 * 1024


class CanonicalAudioReview(ValueError):
    """검증되지 않은 오디오 시간축/PCM은 현재 세션에 적용하지 않습니다."""


@dataclass(frozen=True)
class AudioLimits:
    max_frames: int = 10_000_000
    max_spool_bytes: int = 8 * 1024 ** 3
    max_frame_bytes: int = 16 * 1024 ** 2
    max_query_bytes: int = _READ

    def __post_init__(self):
        if any(type(v) is not int or not 0 < v <= INT64_MAX for v in self.__dict__.values()):
            raise CanonicalAudioReview('PCM budgets must be positive signed64 integers')
        if self.max_query_bytes > _READ:
            raise CanonicalAudioReview('PCM query memory budget cannot exceed 1MiB')


@dataclass(frozen=True)
class PCMFormat:
    name: str
    bytes_per_sample: int
    planar: bool
    sample_rate: int
    layout: str
    channels: tuple[str, ...]
    byte_order: str

    @property
    def bytes_per_time_sample(self):
        return self.bytes_per_sample * len(self.channels)


@dataclass(frozen=True)
class PCMObservation:
    """Raw decoder observation; sample duration is exactly samples/sample_rate."""
    pts: Fraction
    time_base: Fraction
    raw_pts: int
    raw_duration: int | None
    samples: int
    byte_offset: int
    clip_first: int
    clip_stop: int
    segment_index: int


@dataclass(frozen=True)
class AudioTrackInfo:
    track_id: int
    format: PCMFormat
    raw_frame_count: int
    decoded_samples: int
    scheduled_samples: int


@dataclass(frozen=True)
class CanonicalPCM:
    presence: str
    track_id: int
    requested_time: Fraction
    interval_start: Fraction
    interval_end: Fraction
    asset_pts: Fraction | None
    source_frame_index: int | None
    source_sample_offset: int | None
    samples: int
    format: PCMFormat
    planes: tuple[bytes, ...]
    source_sha256: str
    descriptor_sha256: str
    generation: int


def clip_samples(pts, samples, sample_rate, content_start, content_end):
    """Exact intersection, no clock offset. None means wholly outside content.

    Returns source sample [first, stop); fractional sample boundaries hold for
    review. This primitive does not establish descriptor coverage/decoder policy.
    """
    if any(type(v) is not Fraction for v in (pts, content_start, content_end)):
        raise CanonicalAudioReview('exact PCM and content Fractions required')
    if (type(samples) is not int or not 0 < samples <= INT64_MAX or
            type(sample_rate) is not int or not 0 < sample_rate <= INT64_MAX or
            content_start < 0 or content_end <= content_start):
        raise CanonicalAudioReview('positive PCM count/rate and content interval required')
    start, end = max(pts, content_start), min(pts + Fraction(samples, sample_rate), content_end)
    if start >= end:
        return None
    first, stop = (start-pts)*sample_rate, (end-pts)*sample_rate
    if first.denominator != 1 or stop.denominator != 1:
        raise CanonicalAudioReview('content clipping crosses a fractional PCM sample boundary')
    return first.numerator, stop.numerator


def _descriptor(asset):
    asset.require_mappable()
    if any(not track.enabled for track in asset.tracks):
        raise CanonicalAudioReview('disabled audio/video track policy requires review')
    value = dict(version=1, basis='asset-presentation', assetDuration=encode_rational(asset.asset_duration),
        tracks=[dict(id=t.track_id, kind=t.kind, mediaTimescale=t.media_timescale,
            segments=[dict(assetStart=encode_rational(s.asset_start),
                assetDuration=encode_rational(s.asset_duration),
                mediaStart=None if s.media_start is None else encode_rational(s.media_start),
                rate=encode_rational(s.rate)) for s in t.segments])
            for t in sorted(asset.tracks, key=lambda t:t.track_id)])
    validate_timeline(value)
    return value


def _segments(track):
    segments = tuple((rational(s['assetStart']), rational(s['assetStart'])+rational(s['assetDuration']),
                      None if s['mediaStart'] is None else rational(s['mediaStart']))
                     for s in track['segments'])
    if any(rational(s['rate']) != 1 for s in track['segments']):
        raise CanonicalAudioReview('non-unit audio edit rate requires review')
    media = sorted((m, m+end-start) for start,end,m in segments if m is not None)
    if any(a[1] > b[0] for a,b in zip(media,media[1:])):
        raise CanonicalAudioReview('repeated/overlapping audio media occurrence requires review')
    return segments


def _format(frame):
    rate, samples = frame.sample_rate, frame.samples
    if any(type(v) is not int or not 0 < v <= INT64_MAX for v in (rate,samples)):
        raise CanonicalAudioReview('actual positive PCM sample count/rate required')
    name, width, planar = frame.format.name, frame.format.bytes, frame.format.is_planar
    # This is a raw byte contract, not a lossy numpy/float conversion.
    widths = {'u8':1,'s16':2,'s32':4,'s64':8,'flt':4,'dbl':8}
    base = name[:-1] if type(name) is str and name.endswith('p') else name
    if (base not in widths or width != widths[base] or type(width) is not int or
            type(planar) is not bool or planar != name.endswith('p')):
        raise CanonicalAudioReview('unverified raw PCM format requires review')
    layout = frame.layout.name
    channels = tuple(channel.name for channel in frame.layout.channels)
    if (type(layout) is not str or not 0 < len(layout) <= 256 or
            not 1 <= len(channels) <= 64 or
            any(type(c) is not str or not 0 < len(c) <= 64 for c in channels)):
        raise CanonicalAudioReview('actual named PCM layout/channels required')
    return PCMFormat(name,width,planar,rate,layout,channels,sys.byteorder)


class _Track:
    def __init__(self, identity, segments):
        self.id, self.segments = identity, segments
        self.format = None
        self.count = self.decoded = self.scheduled = 0
        self.pcm = self.records = None

    def open_spools(self, directory):
        # The provider registers this empty owner BEFORE either open. If the
        # second open fails, its error remains primary and even a failing first
        # close retains the handle on that provider for explicit cleanup retry.
        self.pcm = open(Path(directory)/f'{self.id}.pcm','w+b',buffering=_BUFFER)
        self.records = open(Path(directory)/f'{self.id}.index','w+b',buffering=_BUFFER)


class OwnedCanonicalAudioProvider:
    """New owned transaction only; complete EOF precedes all usable reads."""
    def __init__(self):
        raise TypeError('use OwnedCanonicalAudioProvider.build')

    @classmethod
    def build(cls, path, *, expected_sha256, generation, decoder_clock_mode=None,
              current_generation=None, cancel=None, limits=None, expected_timeline=None):
        if decoder_clock_mode != 'ffmpeg-editlist-applied':
            raise CanonicalAudioReview('explicit observed ffmpeg-editlist-applied clock required; no origin guess')
        if type(expected_sha256) is not str or re.fullmatch('[0-9a-f]{64}',expected_sha256) is None:
            raise CanonicalAudioReview('exact source SHA256 required')
        limits = AudioLimits() if limits is None else limits
        if type(limits) is not AudioLimits:
            raise CanonicalAudioReview('AudioLimits required')
        result = object.__new__(cls)
        result._lock, result._closed, result._complete = RLock(), False, False
        result._tracks, result._directory = {}, None
        result._path, result._sha = Path(path).absolute(), expected_sha256
        result._generation, result._current_generation = generation, current_generation
        result._cancel, result._limits, result._disk_bytes, result._frames = cancel, limits, 0, 0
        result._identity = _capture_identity(result._path)
        try:
            result._guard(hash_source=True)
            descriptor = _descriptor(inspect_asset_timeline(result._path,cancel=result._check))
            if expected_timeline is not None:
                validate_timeline(expected_timeline)
                if descriptor != expected_timeline:
                    raise CanonicalAudioReview('independently inspected descriptor differs from caller binding')
            result._timeline_json = json.dumps(descriptor,sort_keys=True,separators=(',',':')).encode('ascii')
            result._descriptor_sha = hashlib.sha256(result._timeline_json).hexdigest()
            result._duration = rational(descriptor['assetDuration'])
            result._all_ids = tuple(t['id'] for t in descriptor['tracks'])
            # Validate every track even if it contains no audio; unsupported
            # runtime metadata must not be quietly normalized by this provider.
            audio = []
            for track in descriptor['tracks']:
                segments = _segments(track)
                if track['kind'] == 'audio': audio.append((track['id'],segments))
            result._guard(hash_source=True)
            result._directory = tempfile.TemporaryDirectory(prefix='bluraction-canonical-pcm-')
            for identity,segments in audio:
                result._check()
                candidate = _Track(identity,segments)
                result._tracks[identity] = candidate
                candidate.open_spools(result._directory.name)
            for candidate in result._tracks.values():
                result._decode_track(candidate)
            # No-audio descriptors still independently open/audit track identity.
            if not audio:
                with result._decoder() as container: result._match_streams(container)
            for track in result._tracks.values():
                track.pcm.flush(); track.records.flush()
            result._guard(hash_source=True)
            result._complete = True
            return result
        except BaseException as error:
            result._discard(error)
            raise

    def _check(self):
        if self._closed:
            raise CanonicalAudioReview('canonical PCM candidate closed or invalidated')
        _cancel(self._cancel); _generation(self._generation,self._current_generation)
        return False

    def _guard(self, *, hash_source=False):
        self._check(); _check_identity(self._path,self._identity)
        if hash_source:
            if fingerprint(self._path,max_bytes=self._identity.metadata[3],cancel=self._check) != self._sha:
                raise CanonicalAudioReview('source PCM SHA changed; no candidate publication')
            _check_identity(self._path,self._identity)
        self._check()

    def _decoder(self):
        # Local import keeps context construction private and prevents a raw
        # container/opener from escaping the latched secondary-IO boundary.
        from contextlib import contextmanager
        @contextmanager
        def owned():
            self._guard()
            fd = os.open(self._path,os.O_RDONLY|getattr(os,'O_BINARY',0)|getattr(os,'O_NOFOLLOW',0)|getattr(os,'O_NONBLOCK',0))
            try:
                with os.fdopen(fd,'rb') as source:
                    fd = None
                    before = stat_snapshot(os.fstat(source.fileno()),domain='descriptor')
                    if not path_matches_descriptor(self._identity.stat_snapshot,before):
                        raise CanonicalAudioReview('PCM source descriptor changed before decode')
                    bounded = _BoundedInput(source,self._identity.metadata[3],before,self._check)
                    with open_local_decoder(bounded,options=_OPTIONS,check=self._check) as container:
                        yield container
                    if not same_domain(before,stat_snapshot(os.fstat(source.fileno()),domain='descriptor')):
                        raise CanonicalAudioReview('PCM source descriptor changed during decode')
                    self._guard()
            finally:
                if fd is not None: os.close(fd)
        return owned()

    def _match_streams(self, container):
        if 'mov' not in container.format.name.split(','):
            raise CanonicalAudioReview('MOV clock witness required; other formats remain integration work')
        streams = tuple(container.streams)
        ids = tuple(sorted(stream.id for stream in streams
                           if type(stream.id) is int and stream.type in ('video','audio')))
        if len(ids) != len(streams) or ids != self._all_ids:
            raise CanonicalAudioReview('all decoder track identities must match inspected descriptor')
        audio_ids = tuple(sorted(stream.id for stream in streams if stream.type == 'audio'))
        if audio_ids != tuple(sorted(self._tracks)):
            raise CanonicalAudioReview('decoder audio tracks differ; no silently dropped track')
        return streams

    def _reserve(self, size):
        self._check()
        if self._disk_bytes+size > self._limits.max_spool_bytes:
            raise CanonicalAudioReview('PCM spool budget exceeded; no partial result')
        self._disk_bytes += size

    def _decode_track(self, track):
        coverage = [start for start,end,media in track.segments]
        previous_end = None
        with self._decoder() as container:
            streams = self._match_streams(container)
            stream = next(s for s in streams if s.id == track.id and s.type == 'audio')
            base = _exact_fraction(stream.time_base,'audio stream time_base')
            if base <= 0: raise CanonicalAudioReview('positive observed audio stream time_base required')
            for frame in container.decode(stream):
                self._guard()
                if frame.is_corrupt:
                    raise CanonicalAudioReview('corrupt PCM frame requires review')
                pcm_format = _format(frame)
                if track.format is None: track.format = pcm_format
                if track.format != pcm_format:
                    raise CanonicalAudioReview('changing PCM rate/format/layout requires review')
                raw_pts, raw_duration = frame.pts, frame.duration
                time_base = _exact_fraction(frame.time_base,'audio frame time_base')
                if (type(raw_pts) is not int or not -(1<<63) <= raw_pts <= INT64_MAX or
                        time_base <= 0 or time_base != base):
                    raise CanonicalAudioReview('exact observed audio PTS/time_base required')
                if raw_duration is not None and (type(raw_duration) is not int or not 0 <= raw_duration <= INT64_MAX):
                    raise CanonicalAudioReview('invalid raw PCM frame duration')
                pts = raw_pts*time_base
                end = pts+Fraction(frame.samples,pcm_format.sample_rate)
                if raw_duration and raw_duration*time_base != end-pts:
                    raise CanonicalAudioReview('audio frame duration disagrees with actual sample count/rate')
                if previous_end is not None and pts < previous_end:
                    raise CanonicalAudioReview('overlapping/nonincreasing decoded PCM frame intervals')
                previous_end = end
                first = stop = segment_index = -1
                for index,(start,finish,media) in enumerate(track.segments):
                    if media is None: continue
                    intersection = clip_samples(pts,frame.samples,pcm_format.sample_rate,start,finish)
                    if intersection is None: continue
                    if segment_index != -1:
                        raise CanonicalAudioReview('one PCM frame intersects multiple content occurrences')
                    first,stop = intersection; segment_index = index
                    actual_start = pts+Fraction(first,pcm_format.sample_rate)
                    if actual_start != coverage[index]:
                        raise CanonicalAudioReview('missing/overlapping PCM content coverage; silence is not inferred')
                    coverage[index] = pts+Fraction(stop,pcm_format.sample_rate)
                size = frame.samples*pcm_format.bytes_per_time_sample
                if size > self._limits.max_frame_bytes:
                    raise CanonicalAudioReview('native PCM frame exceeds explicit memory budget')
                self._frames += 1
                if self._frames > self._limits.max_frames:
                    raise CanonicalAudioReview('PCM frame budget exceeded')
                offset = track.pcm.tell()
                self._reserve(size+_RECORD.size)
                planes = frame.planes
                plane_size = frame.samples*pcm_format.bytes_per_sample*(1 if pcm_format.planar else len(pcm_format.channels))
                expected_planes = len(pcm_format.channels) if pcm_format.planar else 1
                if len(planes) != expected_planes:
                    raise CanonicalAudioReview('PCM plane count differs from actual format/layout')
                for plane in planes:
                    view = memoryview(plane).cast('B')
                    try:
                        if len(view) < plane_size:
                            raise CanonicalAudioReview('PCM plane shorter than actual samples; no padding inference')
                        for position in range(0,plane_size,_BUFFER):
                            self._check()
                            chunk = view[position:min(position+_BUFFER,plane_size)]
                            try:
                                if track.pcm.write(chunk) != len(chunk): raise OSError('short PCM spool write')
                            finally: chunk.release()
                    finally: view.release()
                record = _RECORD.pack(_pack_fraction(pts),_pack_fraction(time_base),raw_pts,
                    -1 if raw_duration is None else raw_duration,frame.samples,offset,first,stop,segment_index)
                if track.records.write(record) != len(record): raise OSError('short PCM metadata write')
                track.count += 1; track.decoded += frame.samples
                track.scheduled += 0 if first == -1 else stop-first
            # EOF and native close/check must BOTH succeed before publishing.
        if track.format is None:
            raise CanonicalAudioReview('declared audio track decoded no PCM frames')
        if any(coverage[i] != end for i,(start,end,media) in enumerate(track.segments) if media is not None):
            raise CanonicalAudioReview('EOF missing PCM content coverage; no invented suffix content')

    def _record(self, track, index):
        if not 0 <= index < track.count: raise IndexError('PCM observation index')
        track.records.seek(index*_RECORD.size)
        data = track.records.read(_RECORD.size)
        if len(data) != _RECORD.size: raise CanonicalAudioReview('private PCM index truncated')
        pts,base,raw_pts,raw_duration,samples,offset,first,stop,segment = _RECORD.unpack(data)
        return PCMObservation(_unpack_fraction(pts),_unpack_fraction(base),raw_pts,
            None if raw_duration == -1 else raw_duration,samples,offset,first,stop,segment)

    def _ready(self):
        self._guard()
        if not self._complete: raise CanonicalAudioReview('complete PCM EOF transaction required')

    def _read(self, action):
        with self._lock:
            try:
                self._ready(); result = action(); self._guard(); return result
            except BaseException as error:
                self._discard(error); raise

    @property
    def tracks(self):
        return self._read(lambda:tuple(AudioTrackInfo(t.id,t.format,t.count,t.decoded,t.scheduled)
                                      for t in self._tracks.values()))

    @property
    def timeline(self): return self._read(lambda:json.loads(self._timeline_json))

    @property
    def descriptor_sha256(self): return self._read(lambda:self._descriptor_sha)

    @property
    def asset_duration(self): return self._read(lambda:self._duration)

    def observation(self, track_id, index):
        """Lazy immutable raw observation, not a reconstructed encoded packet."""
        return self._read(lambda:self._record(self._track(track_id),index))

    def _track(self, identity):
        if type(identity) is not int or identity not in self._tracks:
            raise CanonicalAudioReview('declared audio track ID required')
        return self._tracks[identity]

    def read_samples(self, track_id, time, max_samples=4096):
        """Original-source-verified query; use only in an IO worker."""
        return self._read_samples(track_id,time,max_samples,verify_hash=True)

    def read_snapshot_samples(self, track_id, time, max_samples=4096):
        """Completed private PCM snapshot with metadata/generation guards.

        Build requires full original SHA before/after complete decode/EOF/close.
        These spools are owned, not lazy reads from the original. Playback reads
        avoid rehashing GB sources per sample block; every query still checks
        captured original identity before/after, generation and cancellation.
        Save/export and explicit source verification must revalidate full SHA.
        NEVER call this disk-reading API in an audio-device or GUI callback.
        """
        return self._read_samples(track_id,time,max_samples,verify_hash=False)

    def validate_source(self):
        """Explicit full SHA transaction, only on an IO worker."""
        return self._read(lambda:self._guard(hash_source=True))

    def snapshot_anchor(self, track_id, time):
        """First scheduled sample at/after an arbitrary seek target.

        This reports an actual sample-grid anchor, never modifies project
        ranges or pretends a fractional PCM sample exists. Empty edits use
        their declared start/grid; content uses the observed frame's grid.
        Missing content or a non-aligned empty edit remains a review hold.
        """
        def anchor():
            track=self._track(track_id)
            if type(time) is not Fraction or not 0<=time<=self._duration:
                raise CanonicalAudioReview('exact bounded asset seek required')
            if time==self._duration: return time
            segment=next(((i,s,e,m) for i,(s,e,m) in enumerate(track.segments) if s<=time<e),None)
            if segment is None: return time  # Explicit suffix; no content made.
            segment_id,start,end,media=segment
            rate=track.format.sample_rate
            if media is None:
                if ((end-start)*rate).denominator!=1:
                    raise CanonicalAudioReview('empty edit is not on an integer PCM sample grid')
                units=(time-start)*rate
                return min(end,start+Fraction(-(-units.numerator//units.denominator),rate))
            lo,hi=0,track.count
            while lo<hi:
                middle=(lo+hi)//2
                if self._record(track,middle).pts<=time: lo=middle+1
                else: hi=middle
            if lo==0: raise CanonicalAudioReview('content has no observed seek sample')
            row=self._record(track,lo-1)
            units=(time-row.pts)*rate
            index=-(-units.numerator//units.denominator)
            if row.segment_index!=segment_id or index<row.clip_first:
                raise CanonicalAudioReview('content seek lacks observed PCM presence')
            if index<row.clip_stop: return row.pts+Fraction(index,rate)
            boundary=row.pts+Fraction(row.clip_stop,rate)
            if boundary==end: return boundary
            if lo>=track.count: raise CanonicalAudioReview('content seek passes complete PCM EOF')
            following=self._record(track,lo)
            next_start=following.pts+Fraction(following.clip_first,rate)
            if following.segment_index!=segment_id or next_start!=boundary:
                raise CanonicalAudioReview('content seek crosses unobserved PCM')
            return next_start
        return self._read(anchor)

    def _read_samples(self, track_id, time, max_samples, *, verify_hash):
        """Read at most one observed frame, <=1MiB, at exact sample boundary.

        Silence tags have zero samples/planes; consumers schedule the explicit
        interval, not a guessed sample-count or held prior decoded chunk.
        """
        def read():
            track = self._track(track_id)
            if type(time) is not Fraction or time < 0 or time > self._duration:
                raise CanonicalAudioReview('exact asset time within duration required')
            if type(max_samples) is not int or not 0 < max_samples <= INT64_MAX:
                raise CanonicalAudioReview('positive integer PCM query count required')
            if time == self._duration:
                kind,start,end = 'EOF',time,time
            else:
                segment = next(((i,s,e,m) for i,(s,e,m) in enumerate(track.segments) if s <= time < e),None)
                if segment is None: kind,start,end = 'suffix',track.segments[-1][1],self._duration
                else:
                    segment_id,start,end,media = segment
                    kind = 'empty' if media is None else 'content'
            if kind != 'content':
                return CanonicalPCM(kind,track_id,time,start,end,None,None,None,0,track.format,(),
                                    self._sha,self._descriptor_sha,self._generation)
            self._guard(hash_source=verify_hash)
            lo,hi = 0,track.count
            while lo < hi:
                middle = (lo+hi)//2
                if self._record(track,middle).pts <= time: lo = middle+1
                else: hi = middle
            if lo == 0: raise CanonicalAudioReview('content lacks observed PCM; no future-first sample')
            index = lo-1; observation = self._record(track,index)
            relative = (time-observation.pts)*track.format.sample_rate
            if relative.denominator != 1:
                raise CanonicalAudioReview('PCM query must be on an exact observed sample boundary')
            first = relative.numerator
            if observation.segment_index != segment_id or not observation.clip_first <= first < observation.clip_stop:
                raise CanonicalAudioReview('content lacks exact PCM presence')
            samples = min(max_samples,observation.clip_stop-first,
                          self._limits.max_query_bytes//track.format.bytes_per_time_sample)
            if samples <= 0: raise CanonicalAudioReview('PCM query budget cannot hold one time sample')
            width,channels = track.format.bytes_per_sample,len(track.format.channels)
            stride = width if track.format.planar else width*channels
            planes = []
            for plane in range(channels if track.format.planar else 1):
                self._check()
                plane_offset = plane*observation.samples*width if track.format.planar else 0
                track.pcm.seek(observation.byte_offset+plane_offset+first*stride)
                data = track.pcm.read(samples*stride)
                if len(data) != samples*stride: raise CanonicalAudioReview('private PCM data truncated')
                planes.append(data)
            self._guard(hash_source=verify_hash)
            return CanonicalPCM('content',track_id,time,time,time+Fraction(samples,track.format.sample_rate),
                observation.pts,index,first,samples,track.format,tuple(planes),
                self._sha,self._descriptor_sha,self._generation)
        return self._read(read)

    def close(self):
        """Invalidate first; Windows handles close before unlink, failures retry."""
        with self._lock:
            self._closed, self._complete = True, False
            primary = None
            for track in self._tracks.values():
                for name in ('records','pcm'):
                    stream = getattr(track,name)
                    if stream is None: continue
                    try: stream.close()
                    except BaseException as error:
                        if primary is None: primary = error
                        elif error is not primary:
                            primary.add_note(f'PCM handle cleanup also failed: {error!r}')
                            if primary.__cause__ is None: primary.__cause__ = error
                        if stream.closed: setattr(track,name,None)
                    else: setattr(track,name,None)
            if self._directory is not None and all(t.pcm is None and t.records is None for t in self._tracks.values()):
                try: self._directory.cleanup()
                except BaseException as error:
                    if primary is None: primary = error
                    elif error is not primary:
                        primary.add_note(f'PCM private directory cleanup also failed: {error!r}')
                        if primary.__cause__ is None: primary.__cause__ = error
                else: self._directory = None
            if primary is not None: raise primary

    def _discard(self, primary):
        try: self.close()
        except BaseException as error:
            if error is not primary:
                primary.add_note(f'PCM transaction cleanup also failed: {error!r}')
                if primary.__cause__ is None: primary.__cause__ = error
            primary.retry_canonical_audio_close = self.close

    def __enter__(self):
        return self._read(lambda:self)

    def __exit__(self, kind, primary, traceback):
        if primary is not None: self._discard(primary)
        else: self.close()
        return False

    def __del__(self):
        try: self.close()
        except BaseException: pass
