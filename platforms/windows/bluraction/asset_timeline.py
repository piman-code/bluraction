"""Bounded, dependency-free ISO BMFF/QuickTime asset timeline inspection.

Clock domains are distinct: mvhd/tkhd and elst segment_duration describe movie
asset presentation; mdhd and elst media_time describe media composition; stts
describes media DECODE durations, never composition PTS. A decoder may already
apply elst and preroll. This parser does NOT establish raw decoder PTS offsets,
decode a frame, select an origin, modify a project, or certify native playback.
Callers still need source SHA/identity and actual demux/native frame witnesses.

Public APIs: parse_asset_timeline(immutable_bytes), inspect_asset_timeline(path).
The file API seeks past mdat without reading/hash-copying media payload, limits
metadata/table/box counts, checks cancellation and regular-file identity, and
does not return source path, private handler names, or arbitrary metadata.
Rate-one edit mappings are exact Fractions. Empty edits return None; repeated
media has ALL asset matches. Unsupported rates/fragmented/inconsistent/unknown
timelines explicitly cannot map. No-elst identity is labeled, never hidden.

Public primary references (format concepts/layout, not copied implementation):
https://www.w3.org/TR/mse-byte-stream-format-isobmff/#initialization-segments
https://developer.apple.com/documentation/quicktime-file-format/edit_list_atom
https://developer.apple.com/documentation/quicktime-file-format/playing_with_edit_lists
https://developer.apple.com/documentation/quicktime-file-format/time-to-sample_atom
https://github.com/FFmpeg/FFmpeg/blob/n9.0.2/libavformat/mov.c
W3C defines composition-to-presentation edit offsets; FFmpeg's public v0/v1
mvhd/mdhd/tkhd/elst layouts were independently cross-read from official9.0.2
source. Apple references are public QuickTime format documentation, not an ISO
conformance certificate. Fragment sample timing, ctts/cslg/sample groups, data
references, codecs and sample byte offsets are outside this inspector's proof.
"""
from __future__ import annotations

from dataclasses import dataclass
from fractions import Fraction
import os
from pathlib import Path
import stat
import struct
from shared.source_identity import (SourceIdentityError, stat_snapshot, same_domain,
                                    path_matches_descriptor, same_path_binding)

UINT64_MAX = (1 << 64) - 1
ASSET_PRESENTATION = 'asset-presentation'
MEDIA_COMPOSITION = 'media-composition'
MEDIA_DECODE = 'media-decode'
DECODER_RAW_RELATION = 'unproven; parsed edits do not prove decoder PTS policy'


class AssetTimelineError(ValueError):
    """Invalid or unavailable local asset timeline; messages contain no paths."""


class TimelineParseError(AssetTimelineError):
    """Malformed structural bounds, duplicate identity or impossible field."""


class TimelineCannotMap(AssetTimelineError):
    """Valid/unknown metadata cannot establish this inspector's rate-one map."""


class TimelineLimitError(AssetTimelineError):
    """Explicit bounded-inspection resource limit, never a partial mapping."""


class TimelineCancelled(AssetTimelineError):
    """Cancellation returns no partially inspected timeline."""


def _cancel(token):
    if token is None:
        return
    check = getattr(token, 'is_set', None)
    if not callable(check):
        check = token if callable(token) else None
    if check is None:
        raise AssetTimelineError('cancellation token must be callable or Event-like')
    value = check()
    if type(value) is not bool:
        raise AssetTimelineError('cancellation callback must return bool')
    if value:
        raise TimelineCancelled('asset timeline inspection cancelled')


@dataclass(frozen=True)
class TimelineLimits:
    max_metadata_bytes: int = 32 * 1024 * 1024
    max_boxes: int = 10_000
    max_tracks: int = 128
    max_edits_per_track: int = 4096
    max_stts_entries_per_track: int = 100_000
    max_total_table_entries: int = 200_000
    max_depth: int = 8

    def __post_init__(self):
        for value in self.__dict__.values():
            if type(value) is not int or value <= 0:
                raise TimelineLimitError('inspection limits must be positive integers')


@dataclass(frozen=True)
class EditSegment:
    asset_start: Fraction
    asset_duration: Fraction
    media_start: Fraction | None
    rate: Fraction

    @property
    def asset_end(self):
        return self.asset_start + self.asset_duration

    @property
    def media_end(self):
        return None if self.media_start is None else self.media_start + self.asset_duration * self.rate


@dataclass(frozen=True)
class TimeToSampleEntry:
    count: int
    delta: int


@dataclass(frozen=True)
class TrackTimeline:
    track_id: int
    handler: str
    kind: str
    enabled: bool
    movie_timescale: int
    track_duration_ticks: int | None
    media_timescale: int
    media_duration_ticks: int | None
    segments: tuple[EditSegment, ...]
    edit_list_present: bool
    stts: tuple[TimeToSampleEntry, ...] | None
    mapping_issues: tuple[str, ...] = ()
    unparsed_sample_timing_boxes: tuple[str, ...] = ()

    @property
    def track_duration(self):
        return None if self.track_duration_ticks is None else Fraction(self.track_duration_ticks, self.movie_timescale)

    @property
    def media_duration(self):
        return None if self.media_duration_ticks is None else Fraction(self.media_duration_ticks, self.media_timescale)

    @property
    def sample_count(self):
        return None if self.stts is None else sum(entry.count for entry in self.stts)

    @property
    def decode_duration(self):
        return None if self.stts is None else Fraction(sum(entry.count * entry.delta for entry in self.stts), self.media_timescale)

    @property
    def mapping_basis(self):
        return 'explicit-edit-list' if self.edit_list_present else 'implicit-identity-without-edit-list'

    def require_mappable(self):
        """Require a finite supported affine edit model, NOT actual frame presence.

        mdhd/stts duration is insufficient to bound composition samples when
        ctts/cslg/preroll are involved. No clamp or synthetic frames are added.
        Callers must witness the requested composition frame with the decoder.
        """
        if self.mapping_issues:
            raise TimelineCannotMap('cannot map track timeline: ' + ', '.join(self.mapping_issues))
        if any(segment.rate != 1 or segment.asset_duration <= 0 for segment in self.segments):
            raise TimelineCannotMap('only positive-duration rate-one segments can map')

    def asset_to_media(self, asset_time: Fraction) -> Fraction | None:
        """Exact half-open asset segment -> media composition; empty -> None.

        At track EOF/outside the track this raises; it never guesses a held last
        frame. Native/decoder EOF frame selection belongs to the actual index.
        """
        self.require_mappable()
        if type(asset_time) is not Fraction or asset_time < 0:
            raise TimelineCannotMap('asset time must be a nonnegative exact Fraction')
        for segment in self.segments:
            if segment.asset_start <= asset_time < segment.asset_end:
                return None if segment.media_start is None else segment.media_start + asset_time - segment.asset_start
        raise TimelineCannotMap('asset time is outside this track presentation')

    def media_to_asset(self, media_time: Fraction) -> tuple[Fraction, ...]:
        """All exact asset matches for a media composition time, possibly none.

        Repeated edits deliberately have multiple matches; choosing one requires
        a native segment/frame witness. Raw demux PTS are NOT accepted by name.
        """
        self.require_mappable()
        if type(media_time) is not Fraction or media_time < 0:
            raise TimelineCannotMap('media composition time must be a nonnegative exact Fraction')
        return tuple(segment.asset_start + media_time - segment.media_start for segment in self.segments
                     if segment.media_start is not None and segment.media_start <= media_time < segment.media_end)


@dataclass(frozen=True)
class AssetTimeline:
    movie_timescale: int
    movie_duration_ticks: int | None
    tracks: tuple[TrackTimeline, ...]
    mapping_issues: tuple[str, ...] = ()
    decoder_raw_relation: str = DECODER_RAW_RELATION

    @property
    def asset_duration(self):
        return None if self.movie_duration_ticks is None else Fraction(self.movie_duration_ticks, self.movie_timescale)

    def track(self, track_id: int) -> TrackTimeline:
        if type(track_id) is not int or track_id <= 0:
            raise TimelineCannotMap('track identity must be a positive integer')
        matches = [track for track in self.tracks if track.track_id == track_id]
        if len(matches) != 1:
            raise TimelineCannotMap('track identity is missing or ambiguous')
        return matches[0]

    def require_mappable(self):
        if self.mapping_issues:
            raise TimelineCannotMap('cannot map asset timeline: ' + ', '.join(self.mapping_issues))
        for track in self.tracks:
            track.require_mappable()


@dataclass(frozen=True)
class _Box:
    kind: bytes
    body: int
    end: int


class _Reader:
    def __init__(self, size, read_at, limits, cancel):
        self.size, self.read_at, self.limits, self.cancel = size, read_at, limits, cancel
        self.bytes_read = self.box_count = self.table_entries = 0

    def read(self, offset, length):
        _cancel(self.cancel)
        if offset < 0 or length < 0 or offset + length > self.size:
            raise TimelineParseError('asset metadata read exceeds file bounds')
        if self.bytes_read + length > self.limits.max_metadata_bytes:
            raise TimelineLimitError('asset metadata read budget exceeded')
        self.bytes_read += length
        data = self.read_at(offset, length)
        if len(data) != length:
            raise TimelineParseError('truncated asset metadata')
        _cancel(self.cancel)
        return data

    def boxes(self, start, end, depth=0):
        if depth > self.limits.max_depth:
            raise TimelineLimitError('asset box depth limit exceeded')
        offset = start
        while offset < end:
            _cancel(self.cancel)
            if end - offset < 8:
                raise TimelineParseError('truncated box header')
            size, kind = struct.unpack('>I4s', self.read(offset, 8))
            header = 8
            if size == 1:
                if end - offset < 16:
                    raise TimelineParseError('truncated extended box header')
                size = struct.unpack('>Q', self.read(offset + 8, 8))[0]
                header = 16
            elif size == 0:
                # size0 means FILE EOF, never manufacture a containing-box end.
                size = self.size - offset
            if kind == b'uuid':
                header += 16
            if size < header or offset + size > end or offset + size > UINT64_MAX:
                raise TimelineParseError('box size exceeds enclosing bounds')
            self.box_count += 1
            if self.box_count > self.limits.max_boxes:
                raise TimelineLimitError('asset box count limit exceeded')
            yield _Box(kind, offset + header, offset + size)
            offset += size

    def children(self, box, depth):
        return tuple(self.boxes(box.body, box.end, depth))

    def prefix(self, box, count):
        if box.end - box.body < count:
            raise TimelineParseError('truncated required timeline box')
        return self.read(box.body, count)

    def entries(self, count, per_table):
        if count > per_table or self.table_entries + count > self.limits.max_total_table_entries:
            raise TimelineLimitError('asset table entry count limit exceeded')
        self.table_entries += count


def _only(boxes, kind, required=True):
    matches = [box for box in boxes if box.kind == kind]
    if len(matches) > 1:
        raise TimelineParseError('duplicate required timeline box')
    if not matches and required:
        raise TimelineParseError('missing required timeline box')
    return matches[0] if matches else None


def _version(reader, box, versions, allow_flags=False):
    prefix = reader.prefix(box, 4)
    version = prefix[0]
    flags = int.from_bytes(prefix[1:4], 'big')
    if version not in versions:
        raise TimelineCannotMap('unsupported timeline box version')
    if flags and not allow_flags:
        raise TimelineCannotMap('unsupported timeline box flags')
    return version, flags


def _duration(value, version):
    return None if value == ((1 << (64 if version else 32)) - 1) else value


def _time_header(reader, box, movie=False):
    version, _ = _version(reader, box, (0, 1))
    data = reader.prefix(box, (112 if version else 100) if movie else (36 if version else 24))
    offset = 20 if version else 12
    timescale = struct.unpack_from('>I', data, offset)[0]
    ticks = struct.unpack_from('>Q' if version else '>I', data, offset + 4)[0]
    if not timescale:
        raise TimelineParseError('zero timeline timescale')
    return timescale, _duration(ticks, version)


def _track_header(reader, box):
    version, flags = _version(reader, box, (0, 1), allow_flags=True)
    data = reader.prefix(box, 96 if version else 84)
    offset = 20 if version else 12
    identity = struct.unpack_from('>I', data, offset)[0]
    ticks = struct.unpack_from('>Q' if version else '>I', data, offset + 8)[0]
    if not identity:
        raise TimelineParseError('zero track identity')
    return identity, _duration(ticks, version), bool(flags & 1)


def _stts(reader, box):
    if box is None:
        return None
    _version(reader, box, (0,))
    count = struct.unpack_from('>I', reader.prefix(box, 8), 4)[0]
    reader.entries(count, reader.limits.max_stts_entries_per_track)
    if box.end - box.body != 8 + count * 8:
        raise TimelineParseError('stts entry count differs from box length')
    data = reader.read(box.body + 8, count * 8)
    entries = []
    sample_count = total_ticks = 0
    for i in range(count):
        _cancel(reader.cancel)
        samples, delta = struct.unpack_from('>II', data, i * 8)
        if not samples or not delta:
            raise TimelineCannotMap('zero stts sample count/delta cannot establish finite sample timing')
        sample_count += samples
        total_ticks += samples * delta
        if sample_count > UINT64_MAX or total_ticks > UINT64_MAX:
            raise TimelineParseError('stts cumulative count/duration overflow')
        entries.append(TimeToSampleEntry(samples, delta))
    return tuple(entries)


def _edits(reader, box, movie_scale, media_scale):
    version, _ = _version(reader, box, (0, 1))
    count = struct.unpack_from('>I', reader.prefix(box, 8), 4)[0]
    reader.entries(count, reader.limits.max_edits_per_track)
    stride = 20 if version else 12
    if box.end - box.body != 8 + count * stride:
        raise TimelineParseError('elst entry count differs from box length')
    data = reader.read(box.body + 8, count * stride)
    segments = []
    accumulated = 0
    issues = []
    for i in range(count):
        _cancel(reader.cancel)
        duration, media = struct.unpack_from('>Qq' if version else '>Ii', data, i * stride)
        rate_raw = struct.unpack_from('>i', data, i * stride + (16 if version else 8))[0]
        if media < -1:
            raise TimelineParseError('invalid negative edit media time')
        rate = Fraction(rate_raw, 65536)
        if rate != 1:
            issues.append('unsupported_edit_rate')
        if duration == 0:
            issues.append('zero_duration_edit_requires_additional_policy')
        segments.append(EditSegment(Fraction(accumulated, movie_scale), Fraction(duration, movie_scale),
            None if media == -1 else Fraction(media, media_scale), rate))
        accumulated += duration
        if accumulated > UINT64_MAX:
            raise TimelineParseError('edit cumulative asset duration overflow')
    if not count:
        issues.append('empty_edit_list_requires_additional_policy')
    return tuple(segments), tuple(dict.fromkeys(issues)), accumulated


def _parse(reader):
    top = tuple(reader.boxes(0, reader.size))
    moov = _only(top, b'moov')
    if moov.end - moov.body > reader.limits.max_metadata_bytes:
        raise TimelineLimitError('movie metadata size limit exceeded')
    children = reader.children(moov, 1)
    if _only(children, b'cmov', False):
        raise TimelineCannotMap('compressed movie metadata is unsupported')
    movie_scale, movie_ticks = _time_header(reader, _only(children, b'mvhd'), movie=True)
    fragmented = any(box.kind == b'moof' for box in top) or any(box.kind == b'mvex' for box in children)
    track_boxes = [box for box in children if box.kind == b'trak']
    if not track_boxes:
        raise TimelineParseError('asset contains no tracks')
    if len(track_boxes) > reader.limits.max_tracks:
        raise TimelineLimitError('asset track count limit exceeded')
    global_issues = tuple(issue for condition, issue in
        ((fragmented, 'fragmented_movie_not_mapped'), (movie_ticks is None, 'unknown_movie_duration')) if condition)
    tracks = []
    identities = set()
    for track_box in track_boxes:
        track_children = reader.children(track_box, 2)
        identity, track_ticks, enabled = _track_header(reader, _only(track_children, b'tkhd'))
        if identity in identities:
            raise TimelineParseError('duplicate track identity')
        identities.add(identity)
        mdia = reader.children(_only(track_children, b'mdia'), 3)
        media_scale, media_ticks = _time_header(reader, _only(mdia, b'mdhd'))
        handler_box = _only(mdia, b'hdlr')
        _version(reader, handler_box, (0,))
        handler_bytes = reader.prefix(handler_box, 24)[8:12]
        try:
            handler = handler_bytes.decode('ascii')
        except UnicodeDecodeError:
            raise TimelineParseError('invalid handler code') from None
        kind = {b'vide': 'video', b'soun': 'audio'}.get(handler_bytes, 'other')
        minf = _only(mdia, b'minf', False)
        stbl = _only(reader.children(minf, 4), b'stbl', False) if minf else None
        sample_boxes = reader.children(stbl, 5) if stbl else ()
        stts = _stts(reader, _only(sample_boxes, b'stts', False))
        unparsed = tuple(box.kind.decode('ascii') for box in sample_boxes
                         if box.kind in (b'ctts', b'cslg', b'sgpd', b'sbgp'))
        edts = _only(track_children, b'edts', False)
        edit_box = _only(reader.children(edts, 3), b'elst') if edts else None
        issues = list(global_issues)
        if track_ticks is None:
            issues.append('unknown_track_duration')
        if media_ticks is None:
            issues.append('unknown_media_duration')
        if kind == 'other':
            issues.append('unsupported_track_handler')
        if edit_box:
            segments, edit_issues, cumulative = _edits(reader, edit_box, movie_scale, media_scale)
            issues.extend(edit_issues)
            if track_ticks is not None and cumulative != track_ticks:
                issues.append('edit_duration_differs_from_track_duration')
        elif track_ticks is not None:
            segments = (EditSegment(Fraction(0), Fraction(track_ticks, movie_scale), Fraction(0), Fraction(1)),)
            if not track_ticks:
                issues.append('zero_track_duration')
        else:
            segments = ()
        if movie_ticks is not None and track_ticks is not None and track_ticks > movie_ticks:
            issues.append('track_extends_beyond_movie_duration')
        tracks.append(TrackTimeline(identity, handler, kind, enabled, movie_scale, track_ticks,
            media_scale, media_ticks, segments, edit_box is not None, stts, tuple(dict.fromkeys(issues)), unparsed))
    _cancel(reader.cancel)
    return AssetTimeline(movie_scale, movie_ticks, tuple(tracks), global_issues)


def parse_asset_timeline(data: bytes, *, limits=None, cancel=None) -> AssetTimeline:
    """Inspect an immutable in-memory file snapshot; never execute its contents."""
    _cancel(cancel)
    if type(data) is not bytes:
        raise AssetTimelineError('asset snapshot must be immutable bytes')
    limits = TimelineLimits() if limits is None else limits
    if type(limits) is not TimelineLimits:
        raise TimelineLimitError('limits must be a TimelineLimits value')
    return _parse(_Reader(len(data), lambda offset, count: data[offset:offset + count], limits, cancel))


def inspect_asset_timeline(path, *, limits=None, cancel=None) -> AssetTimeline:
    """Seek-only regular-file inspection; mdat is skipped, source is never written.

    Authorized input paths/roots are the caller's gate; this API does not choose
    a user file or impose an approved-root policy. Reject leaf symlinks/retarget/replacement/metadata changes; capture and recheck
    fd/path/canonical identity. This is NOT full content SHA validation; caller
    retains source hash guards before/after actual decoding and publication.
    """
    _cancel(cancel)
    limits = TimelineLimits() if limits is None else limits
    if type(limits) is not TimelineLimits:
        raise TimelineLimitError('limits must be a TimelineLimits value')
    fd = None
    try:
        try:
            path = Path(path)
        except TypeError:
            raise AssetTimelineError('timeline input path type is unsupported') from None
        before = path.lstat()
        if not stat.S_ISREG(before.st_mode):
            raise AssetTimelineError('timeline input must be a regular nonsymlink file')
        path_baseline = stat_snapshot(before, domain='path')
        canonical = path.resolve(strict=True)
        flags = os.O_RDONLY | getattr(os, 'O_BINARY', 0) | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_NONBLOCK', 0)
        fd = os.open(path, flags)
        opened = os.fstat(fd)
        descriptor_baseline = stat_snapshot(opened, domain='descriptor')
        if not path_matches_descriptor(path_baseline, descriptor_baseline):
            raise AssetTimelineError('timeline input identity changed before inspection')
        with os.fdopen(fd, 'rb') as source:
            fd = None
            opened_path = stat_snapshot(path.lstat(), domain='path')
            if (not same_path_binding(path_baseline, opened_path, str(canonical), str(path.resolve(strict=True)))
                    or not path_matches_descriptor(opened_path, descriptor_baseline)):
                raise AssetTimelineError('timeline input path changed before inspection')
            def read_at(offset, count):
                source.seek(offset)
                return source.read(count)
            result = _parse(_Reader(opened.st_size, read_at, limits, cancel))
            _cancel(cancel)
            after_fd, after_path = os.fstat(source.fileno()), path.lstat()
            descriptor_current = stat_snapshot(after_fd, domain='descriptor')
            path_current = stat_snapshot(after_path, domain='path')
            if (not same_domain(descriptor_baseline, descriptor_current)
                    or not same_path_binding(path_baseline, path_current, str(canonical), str(path.resolve(strict=True)))
                    or not path_matches_descriptor(path_current, descriptor_current)):
                raise AssetTimelineError('timeline input identity changed during inspection')
            _cancel(cancel)
            return result
    except (OSError, RuntimeError, SourceIdentityError) as error:
        raise AssetTimelineError('cannot read stable local asset metadata') from None
    finally:
        if fd is not None:
            os.close(fd)
