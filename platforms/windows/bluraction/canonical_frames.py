"""Provisional exact MOV presence view over a borrowed, complete inventory.

The caller must establish that this particular decoder applied the edit list,
independently inspect the source-bound descriptor, and guard source identity/SHA
before/after its transaction. Merely declaring this mode is not that evidence.
FFmpeg MOV defaults ignore_editlist=0, advanced_editlist=1 modify decoded timing:
https://ffmpeg.org/ffmpeg-formats.html#mov_002fmp4_002f3gp
Consequently this view never subtracts an origin or maps mediaStart a second time.

Memory is bounded descriptor metadata plus one observed frame; no per-frame
array, decoded image, new spool, or inferred FPS/duration. The caller owns the
inventory, including cleanup on failed candidate preparation. Closing this view
NEVER closes it. Empty/suffix/EOF yield no sample, not a display hold/black rule.
This is not generic format support, audio scheduling or production P1 closure.
"""
from __future__ import annotations

from bisect import bisect_right
from dataclasses import dataclass
from fractions import Fraction
import hashlib
import json
from threading import RLock

from shared.video_timeline import validate_timeline, rational
from .frame_inventory import FrameInventory, FrameObservation, _cancel, _generation


class CanonicalFramesReview(ValueError):
    """A complete canonical presence view cannot be safely published."""


@dataclass(frozen=True)
class CanonicalSample:
    source_index: int
    asset_pts: Fraction
    interval_start: Fraction
    interval_end: Fraction
    segment_index: int
    observation: FrameObservation


@dataclass(frozen=True)
class FramePresence:
    kind: str  # content, content-no-sample, empty, suffix, EOF
    requested_time: Fraction
    sample: CanonicalSample | None


@dataclass(frozen=True)
class _Segment:
    start: Fraction
    end: Fraction
    content: bool


def descriptor_sha256(timeline):
    """Canonical JSON binding, with the same strict metadata validation."""
    validate_timeline(timeline)
    return hashlib.sha256(json.dumps(timeline, sort_keys=True, separators=(',', ':'),
                                     ensure_ascii=True).encode('ascii')).hexdigest()


class CanonicalFrameIndex:
    """Read-only mapping; candidate publication and inventory ownership are external."""

    def __init__(self):
        raise TypeError('use CanonicalFrameIndex.build')

    @classmethod
    def build(cls, inventory, *, source_sha256, generation, timeline,
              decoder_clock_mode, container_format, current_generation=None, cancel=None):
        result = object.__new__(cls)
        result._lock = RLock()
        result._closed = True
        result._inventory = inventory
        result._sha = source_sha256
        result._generation = generation
        result._current_generation = current_generation
        result._cancel = cancel
        # Strict metadata is bounded (17 tracks, 4096 segments/track). Serializing
        # before parsing makes our immutable snapshot independent of later edits.
        result._descriptor_sha = descriptor_sha256(timeline)
        snapshot = json.loads(json.dumps(timeline, sort_keys=True, separators=(',', ':')))
        if descriptor_sha256(snapshot) != result._descriptor_sha:
            raise CanonicalFramesReview('timeline changed while capturing descriptor')
        if type(inventory) is not FrameInventory or not inventory.complete:
            raise CanonicalFramesReview('completed EOF FrameInventory required')
        inventory.require_binding(source_sha256=source_sha256, generation=generation)
        _generation(generation, current_generation)
        _cancel(cancel)
        if decoder_clock_mode != 'ffmpeg-editlist-applied' or container_format != 'mov':
            raise CanonicalFramesReview('explicit verified MOV edit-list-applied clock required; other policies need review')
        decoder = inventory.decoder
        options = dict(decoder.demux_options)
        if options.get('ignore_editlist', '0') != '0' or options.get('advanced_editlist', '1') != '1':
            raise CanonicalFramesReview('decoder options do not apply the complete MOV edit list')
        for track in snapshot['tracks']:
            if any(rational(s['rate']) != 1 for s in track['segments']):
                raise CanonicalFramesReview('non-unit asset rate requires independent mapping review')
        video = next(t for t in snapshot['tracks'] if t['kind'] == 'video')
        if type(decoder.stream_id) is not int or decoder.stream_id != video['id']:
            raise CanonicalFramesReview('decoded container track ID does not match video descriptor')
        result._segments = tuple(_Segment(rational(s['assetStart']),
            rational(s['assetStart']) + rational(s['assetDuration']), s['mediaStart'] is not None)
            for s in video['segments'])
        result._starts = tuple(s.start for s in result._segments)
        result._duration = rational(snapshot['assetDuration'])
        result._track_end = result._segments[-1].end
        result._raw_count = len(inventory)
        result._sample_count = 0
        result._closed = False
        try:
            last_end = None
            seen_segments = set()  # bounded by descriptor's 4096 segment cap
            for source_index in range(result._raw_count):
                sample = result.sample_for_source_index(source_index)
                if sample is None:
                    continue
                if last_end is not None and sample.interval_start < last_end:
                    raise CanonicalFramesReview('overlapping decoded presentation intervals are ambiguous')
                last_end = sample.interval_end
                seen_segments.add(sample.segment_index)
                result._sample_count += 1
            required = {i for i, s in enumerate(result._segments) if s.content}
            if seen_segments != required:
                raise CanonicalFramesReview('content segment has no observed applied-clock sample; repeated/trimmed content needs review')
            result._guard()
            return result
        except BaseException:
            result.close()  # borrowed inventory remains valid and caller-owned
            raise

    def _guard(self):
        if self._closed:
            raise CanonicalFramesReview('canonical frame view closed')
        try:
            _cancel(self._cancel)
            _generation(self._generation, self._current_generation)
            self._inventory.require_binding(source_sha256=self._sha, generation=self._generation)
            if not self._inventory.complete:
                raise CanonicalFramesReview('borrowed inventory no longer complete')
        except BaseException:
            # Once stale/cancelled, this candidate cannot resurrect if a caller
            # restores an old generation number or clears its cancellation token.
            self._closed = True
            raise

    def _read(self, index):
        self._guard()
        try:
            row = self._inventory[index]
        except BaseException:
            self._closed = True
            raise
        self._guard()
        return row

    def _sample(self, index, row):
        start, end = row.pts, row.pts + row.duration
        # Locate the first descriptor segment potentially intersecting this row.
        position = max(0, bisect_right(self._starts, start) - 1)
        selected = None
        while position < len(self._segments) and self._segments[position].start < end:
            segment = self._segments[position]
            left, right = max(start, segment.start), min(end, segment.end)
            if segment.content and left < right:
                if selected is not None:
                    raise CanonicalFramesReview('one raw sample intersects multiple content occurrences')
                if start < segment.start:
                    raise CanonicalFramesReview('sample starts before content boundary; clipped-start presence is unproven')
                selected = CanonicalSample(index, start, left, right, position, row)
            position += 1
        return selected

    def sample_for_source_index(self, index):
        with self._lock:
            self._guard()
            if type(index) is not int or not 0 <= index < self._raw_count:
                raise IndexError('source index outside inventory')
            sample = self._sample(index, self._read(index))
            self._guard()
            return sample

    def presence(self, time):
        with self._lock:
            self._guard()
            if type(time) is not Fraction or not 0 <= time <= self._duration:
                raise CanonicalFramesReview('query requires exact Fraction in the asset interval')
            if time == self._duration:
                self._guard()
                return FramePresence('EOF', time, None)
            if time >= self._track_end:
                self._guard()
                return FramePresence('suffix', time, None)
            segment = self._segments[bisect_right(self._starts, time) - 1]
            if not segment.content:
                self._guard()
                return FramePresence('empty', time, None)
            # Last observed PTS <= request, using exact comparisons. Never pick
            # a future-first frame or continue past its observed/clipped end.
            low, high = 0, self._raw_count
            while low < high:
                middle = (low + high) // 2
                if self._read(middle).pts <= time:
                    low = middle + 1
                else:
                    high = middle
            sample = self.sample_for_source_index(low - 1) if low else None
            if sample is not None and not sample.interval_start <= time < sample.interval_end:
                sample = None
            self._guard()
            return FramePresence('content' if sample is not None else 'content-no-sample', time, sample)

    def sample_at(self, time):
        return self.presence(time).sample

    def iter_samples(self):
        # Lazy, no list/tuple sized by frame count. Each resume rechecks binding.
        for index in range(self.raw_count):
            sample = self.sample_for_source_index(index)
            if sample is not None:
                yield sample

    def require_binding(self, *, source_sha256, generation, descriptor_sha256):
        with self._lock:
            self._guard()
            if (source_sha256 != self._sha or type(generation) is not int or
                    generation != self._generation or descriptor_sha256 != self._descriptor_sha):
                raise CanonicalFramesReview('canonical source/generation/descriptor binding changed')

    @property
    def raw_count(self):
        with self._lock:
            self._guard(); return self._raw_count

    @property
    def sample_count(self):
        with self._lock:
            self._guard(); return self._sample_count

    @property
    def descriptor_sha256(self):
        with self._lock:
            self._guard(); return self._descriptor_sha

    @property
    def asset_duration(self):
        with self._lock:
            self._guard(); return self._duration

    def close(self):
        with self._lock:
            self._closed = True

    def __enter__(self):
        with self._lock:
            self._guard(); return self

    def __exit__(self, *args):
        self.close()
