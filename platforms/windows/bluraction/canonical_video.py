"""Owned candidate for provisional MOV asset-clock pixels, not app integration.

There is deliberately NO default decoder opener. A caller must supply audited
access covering BOTH inventory construction and pixel decoding, including nested
IO denial. A callback declaration is not that audit or generic MOV-clock proof.
The current app, Qt audio, exports, non-MOV support and P1 remain separate work.

This provider owns only its newly transferred inventory/view, readonly source
handles, one cached normalized image and at most one live decoded frame. Caller
retains path authorization, source-policy evidence and a native decode deadline.
All decoder opens use captured, bounded descriptors; no pathname is given to
the pixel decoder. Exact Fractions are never converted to an inferred origin.
"""
from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass
from fractions import Fraction
import json
import os
from pathlib import Path
import re
from threading import RLock

from PySide6.QtGui import QImage
from shared.source_identity import stat_snapshot, same_domain, path_matches_descriptor
from shared.video_timeline import encode_rational, validate_timeline
from .asset_timeline import inspect_asset_timeline
from .canonical_frames import CanonicalFrameIndex
from .frame_inventory import (FrameInventory, InventoryLimits, _BoundedInput,
                              _observe, _exact_fraction, _generation, _cancel)
from .media import _capture_identity, _check_identity, fingerprint
from .video import _display_image
from .local_decoder import LocalDecoderError, SecondaryIODenied


_OPTIONS = (('advanced_editlist', '1'), ('ignore_editlist', '0'))


class CanonicalVideoReview(ValueError):
    """Candidate unavailable; do not substitute old normalized-clock pixels."""


@dataclass(frozen=True)
class DecoderAccess:
    """Caller-supplied implementation boundary, not a permission or audit record.

    build_inventory(path, expected_sha256=..., generation=..., demux_options=...,
    cancel=..., current_generation=...) transfers a NEW complete FrameInventory.
    It must enforce audited local-only decoder IO and clean its partial failures.
    open_decoder(bounded_file, mode='r', options=...) returns a context-managed
    decoder enforcing the SAME nested IO policy. Neither callback may reuse an
    active session's inventory/container. Missing access always needs review.
    """
    build_inventory: object
    open_decoder: object

    def __post_init__(self):
        if not callable(self.build_inventory) or not callable(self.open_decoder):
            raise CanonicalVideoReview('both audited decoder implementation boundaries are required')


@dataclass(frozen=True)
class CanonicalPixels:
    presence: str
    requested_time: Fraction
    asset_pts: Fraction | None
    interval_start: Fraction | None
    interval_end: Fraction | None
    source_index: int | None
    image: QImage | None
    source_sha256: str
    descriptor_sha256: str
    generation: int


class _SeekUnavailable(Exception):
    pass


def _descriptor(asset):
    asset.require_mappable()
    if any(not track.enabled for track in asset.tracks):
        raise CanonicalVideoReview('disabled track policy requires explicit review')
    result = dict(version=1, basis='asset-presentation',
        assetDuration=encode_rational(asset.asset_duration), tracks=[dict(
            id=track.track_id, kind=track.kind, mediaTimescale=track.media_timescale,
            segments=[dict(assetStart=encode_rational(segment.asset_start),
                assetDuration=encode_rational(segment.asset_duration),
                mediaStart=None if segment.media_start is None else encode_rational(segment.media_start),
                rate=encode_rational(segment.rate)) for segment in track.segments])
            for track in sorted(asset.tracks, key=lambda track: track.track_id)])
    validate_timeline(result)
    return result


class OwnedCanonicalVideoProvider:
    """Transactional private candidate. No UI, history, state or output mutation."""

    def __init__(self):
        raise TypeError('use OwnedCanonicalVideoProvider.build')

    @classmethod
    def build(cls, path, *, expected_sha256, generation, decoder_access=None,
              current_generation=None, cancel=None, limits=None):
        if type(decoder_access) is not DecoderAccess:
            raise CanonicalVideoReview('nested decoder IO audit pending for inventory AND pixels; no default opener')
        limits = InventoryLimits() if limits is None else limits
        if type(limits) is not InventoryLimits:
            raise CanonicalVideoReview('explicit InventoryLimits required')
        if type(expected_sha256) is not str or re.fullmatch('[0-9a-f]{64}', expected_sha256) is None:
            raise CanonicalVideoReview('exact lower-case source SHA256 baseline required')
        _generation(generation, current_generation)
        _cancel(cancel)
        result = object.__new__(cls)
        result._lock = RLock()
        result._closed = False
        result._inventory = result._index = None
        result._cached_index = result._cached_image = None
        result._path = Path(path).absolute()
        result._generation = generation
        result._current_generation = current_generation
        result._cancel = cancel
        result._access = decoder_access
        result._limits = limits
        result._identity = _capture_identity(result._path)
        result._sha = expected_sha256
        try:
            result._guard(hash_source=True)
            descriptor = _descriptor(inspect_asset_timeline(result._path, cancel=result._check))
            # Immutable validated storage; public DTO reads allocate independent
            # copies rather than exposing a mutable source-bound contract.
            result._timeline_json = json.dumps(descriptor, sort_keys=True,
                separators=(',', ':'), ensure_ascii=True).encode('ascii')
            result._guard(hash_source=True)
            # Explicit transfer of this attempt's NEW inventory; never infer
            # that an arbitrary callback or default av.open denies nested IO.
            candidate = decoder_access.build_inventory(result._path,
                expected_sha256=expected_sha256, generation=generation,
                demux_options=dict(_OPTIONS), cancel=result._check,
                current_generation=current_generation, limits=limits)
            if type(candidate) is not FrameInventory:
                raise CanonicalVideoReview('inventory builder violated new FrameInventory transfer contract')
            result._inventory = candidate
            if not result._inventory.complete:
                raise CanonicalVideoReview('decoder did not return complete EOF inventory')
            result._inventory.require_binding(source_sha256=expected_sha256, generation=generation)
            if result._inventory.source_identity != result._identity:
                raise CanonicalVideoReview('inventory is not bound to this captured source identity')
            if result._inventory.decoder.demux_options != _OPTIONS:
                raise CanonicalVideoReview('inventory must record both explicit complete-edit-list options')
            result._index = CanonicalFrameIndex.build(result._inventory,
                source_sha256=expected_sha256, generation=generation, timeline=descriptor,
                decoder_clock_mode='ffmpeg-editlist-applied', container_format='mov',
                current_generation=current_generation, cancel=result._check)
            result._descriptor_sha = result._index.descriptor_sha256
            result._duration = result._index.asset_duration
            result._guard(hash_source=True)
            return result
        except BaseException as error:
            result._discard(error)
            raise

    def _check(self):
        if self._closed:
            raise CanonicalVideoReview('canonical video candidate closed or invalidated')
        _cancel(self._cancel)
        _generation(self._generation, self._current_generation)
        return False  # Event-compatible callback; exceptions propagate unchanged.

    def _guard(self, *, hash_source=False):
        self._check()
        _check_identity(self._path, self._identity)
        if self._inventory is not None:
            self._inventory.require_binding(source_sha256=self._sha, generation=self._generation)
        if self._index is not None:
            self._index.require_binding(source_sha256=self._sha, generation=self._generation,
                                        descriptor_sha256=self._descriptor_sha)
        if hash_source:
            if fingerprint(self._path, max_bytes=self._identity.metadata[3], cancel=self._check) != self._sha:
                raise CanonicalVideoReview('original video SHA changed; candidate cannot apply edits')
            _check_identity(self._path, self._identity)
        self._check()

    @contextmanager
    def _decoder(self):
        self._guard()
        flags = os.O_RDONLY | getattr(os, 'O_BINARY', 0) | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_NONBLOCK', 0)
        descriptor = os.open(self._path, flags)
        try:
            with os.fdopen(descriptor, 'rb') as source:
                descriptor = None
                before = stat_snapshot(os.fstat(source.fileno()), domain='descriptor')
                if not path_matches_descriptor(self._identity.stat_snapshot, before):
                    raise CanonicalVideoReview('source descriptor changed before pixel decode')
                bounded = _BoundedInput(source, self._identity.metadata[3], before, self._check)
                manager = self._access.open_decoder(bounded, mode='r', options=dict(_OPTIONS))
                container = manager.__enter__()
                failure = None
                try:
                    yield container
                except BaseException as error:
                    failure = error
                    raise
                finally:
                    try:
                        # Decoder contexts cannot suppress a source/mapping or
                        # cancellation failure and publish a partial pixel result.
                        manager.__exit__(None if failure is None else type(failure), failure,
                                         None if failure is None else failure.__traceback__)
                    except BaseException as error:
                        if failure is not None:
                            failure.add_note(f'pixel decoder teardown also failed: {error!r}')
                            if error is failure:
                                raise failure
                            raise failure from error
                        raise
                if not same_domain(before, stat_snapshot(os.fstat(source.fileno()), domain='descriptor')):
                    raise CanonicalVideoReview('source descriptor changed during pixel decode')
                self._guard()
        finally:
            if descriptor is not None:
                os.close(descriptor)

    def _pixels(self, sample, *, seek):
        with self._decoder() as container:
            videos = list(container.streams.video)
            if len(videos) != 1 or videos[0].id != self._inventory.decoder.stream_id:
                raise CanonicalVideoReview('pixel decoder selected a different video track')
            stream = videos[0]
            base = _exact_fraction(stream.time_base, 'pixel stream time_base')
            if base != self._inventory.decoder.stream_time_base:
                raise CanonicalVideoReview('pixel decoder time base differs from inventory')
            if seek:
                self._check()
                try:
                    container.seek(sample.asset_pts // base, stream=stream, backward=True, any_frame=False)
                except Exception as error:
                    # Cancellation/source checks below prevent treating these
                    # failures as a harmless unsupported seek.
                    if isinstance(error, (LocalDecoderError, SecondaryIODenied)):
                        raise
                    boundary = getattr(container, 'check_boundary', None)
                    if callable(boundary):
                        boundary()
                    self._guard()
                    raise _SeekUnavailable() from error
            frames = iter(container.decode(stream))
            failure = None
            try:
                previous = None
                for frame in frames:
                    self._check()
                    observed = _observe(frame, self._limits)
                    if previous is not None and observed.pts <= previous:
                        raise CanonicalVideoReview('pixel decode PTS reordered or duplicate')
                    previous = observed.pts
                    if observed.pts < sample.asset_pts:
                        continue
                    if observed != sample.observation:
                        raise CanonicalVideoReview('decoded pixel row does not exactly match selected inventory sample')
                    # Reject known HDR/high-depth until validated SDR tone mapping
                    # exists. Do not silently collapse PQ/HLG to untagged RGB8.
                    if getattr(frame, 'color_trc', None) in (16, 18):
                        raise CanonicalVideoReview('HDR transfer needs validated tone mapping')
                    components = getattr(getattr(frame, 'format', None), 'components', None)
                    if not components or any(type(c.bits) is not int or not 0 < c.bits <= 8 for c in components):
                        raise CanonicalVideoReview('unknown/high-depth pixel policy needs review')
                    sar = observed.frame_sar
                    if sar is None or sar == 0:
                        sar = self._inventory.decoder.codec_sar
                    if sar is None or sar == 0:
                        # No guessed stream SAR or implicit 1:1 normalization.
                        raise CanonicalVideoReview('exact display SAR unavailable; no guessed geometry')
                    width = round(observed.width * sar)
                    if (width <= 0 or width > self._limits.max_dimension or
                            width * observed.height > self._limits.max_pixels):
                        raise CanonicalVideoReview('normalized pixels exceed explicit resource budget')
                    metadata = dict(getattr(stream, 'metadata', {}))
                    if observed.display_matrix is None and not observed.rotation:
                        rotate = next((v for k, v in metadata.items() if k.lower() == 'rotate'), 0)
                        if str(rotate) not in ('0', '0.0'):
                            raise CanonicalVideoReview('unobserved stream rotation requires geometry review')
                    image = _display_image(frame, sar, metadata)
                    if image.isNull():
                        raise CanonicalVideoReview('pixel decoder produced no normalized image')
                    self._check()
                    return image.copy()
                raise CanonicalVideoReview('selected observed sample missing from pixel decode; no future/last substitute')
            except BaseException as error:
                failure = error
                raise
            finally:
                close = getattr(frames, 'close', None)
                if close is not None:
                    try:
                        close()
                    except BaseException as error:
                        if failure is not None:
                            failure.add_note(f'pixel iterator teardown also failed: {error!r}')
                            if error is failure:
                                raise failure
                            raise failure from error
                        raise

    def frame_at(self, time):
        with self._lock:
            if type(time) is not Fraction:
                raise CanonicalVideoReview('exact Fraction asset query required')
            if not 0 <= time <= self._duration:
                raise CanonicalVideoReview('asset query outside exact duration')
            try:
                self._guard(hash_source=True)
                presence = self._index.presence(time)
                sample = presence.sample
                image = None
                if sample is not None:
                    if self._cached_index != sample.source_index:
                        try:
                            image = self._pixels(sample, seek=True)
                        except _SeekUnavailable:
                            image = self._pixels(sample, seek=False)
                        self._cached_index, self._cached_image = sample.source_index, image
                    image = self._cached_image.copy()
                self._guard(hash_source=True)
                return CanonicalPixels(presence.kind, time,
                    None if sample is None else sample.asset_pts,
                    None if sample is None else sample.interval_start,
                    None if sample is None else sample.interval_end,
                    None if sample is None else sample.source_index, image,
                    self._sha, self._descriptor_sha, self._generation)
            except BaseException as error:
                self._discard(error)
                raise

    def _discard(self, primary):
        try:
            self.close()
        except BaseException as error:
            primary.add_note(f'canonical candidate cleanup also failed: {error!r}')
            primary.retry_canonical_cleanup = self.close
            if error is primary:
                raise primary
            raise primary from error

    @property
    def asset_duration(self):
        with self._lock:
            try:
                self._guard()
                return self._duration
            except BaseException as error:
                self._discard(error)
                raise

    @property
    def descriptor_sha256(self):
        with self._lock:
            try:
                self._guard()
                return self._descriptor_sha
            except BaseException as error:
                self._discard(error)
                raise

    @property
    def timeline(self):
        """Fresh validated DTO copy; no clock shift or producer metadata is added."""
        with self._lock:
            try:
                self._guard()
                return json.loads(self._timeline_json)
            except BaseException as error:
                self._discard(error)
                raise

    def close(self):
        with self._lock:
            self._closed = True
            self._cached_index = self._cached_image = None
            if self._index is not None:
                self._index.close()
                self._index = None
            if self._inventory is not None:
                self._inventory.close()  # retained for retry if teardown raises
                self._inventory = None

    def __enter__(self):
        with self._lock:
            try:
                self._guard(); return self
            except BaseException as error:
                self._discard(error)
                raise

    def __exit__(self, kind, failure, traceback):
        if failure is None:
            self.close()
        else:
            self._discard(failure)
