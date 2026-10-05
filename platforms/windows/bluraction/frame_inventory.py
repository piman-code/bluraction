"""Complete PyAV decoded-frame observations, not canonical asset clock proof.

No VideoSource origin, FPS, microseconds, epsilon, duration/SAR guesses, rendering
or media rewriting. The observed clock depends on the recorded demux options;
EOF membership alone does not prove edit-list, asset, native Qt or audio mapping.
Missing actual duration is an explicit incomplete observation, not a format ban.
Decoder input now uses the PyAV19 latched secondary-open denial boundary. This
does not certify an OS sandbox or canonical timeline; native policy is separate.

Official PyAV19 APIs: Frame.pts/duration/time_base/is_corrupt are decoder values;
VideoFrame.rotation is counterclockwise. VideoStream.sample_aspect_ratio is a
*guessed* value, kept distinct from codec/frame SAR, never a 1:1 default here.
https://pyav.basswood.io/docs/stable/api/frame.html
https://pyav.basswood.io/docs/stable/api/video.html
https://pyav.basswood.io/docs/stable/api/container.html
https://github.com/PyAV-Org/PyAV/blob/v19.0.0/av/video/frame.py
https://github.com/PyAV-Org/PyAV/blob/v19.0.0/av/buffer.py
https://github.com/PyAV-Org/PyAV/blob/v19.0.0/av/rational.py

Memory: one decoded frame (plus native codec buffers), constant metadata and a
64KiB spool buffer. File reads stream within the original captured size; there
is no new arbitrary video file-size ban. Disk: RECORD_BYTES per observed frame,
bounded by caller-adjustable frame/spool budgets. Native decode cannot be
preempted by a Python cancellation callback; callers retain a process deadline.
Source identity/SHA is guarded before/after, including after codec close. Only
normal EOF + cleanup + final guards yield an inventory. The old inventory is
never touched. Caller owns path authorization and eventual atomic publication.
"""
from __future__ import annotations
from collections.abc import Sequence
from dataclasses import dataclass
from fractions import Fraction
import math
import os
from pathlib import Path
import re
import struct
import tempfile
from threading import RLock

from shared.source_identity import stat_snapshot, same_domain, path_matches_descriptor

INT64_MIN, INT64_MAX = -(1 << 63), (1 << 63)-1
NUMERATOR_MIN, NUMERATOR_MAX = -(1 << 127), (1 << 127)-1
DENOMINATOR_MAX = (1 << 128)-1
_RECORD = struct.Struct('<32s32s32s32sqqdIIB36s')
RECORD_BYTES = _RECORD.size
BUFFER_BYTES = 64 * 1024
READ_BYTES = 1024 * 1024


class FrameInventoryError(ValueError):
    """No complete usable inventory; never a partially committed result."""


class InventoryCancelled(FrameInventoryError):
    pass


@dataclass(frozen=True)
class InventoryLimits:
    max_frames: int = 10_000_000
    max_spool_bytes: int = 2 * 1024 ** 3
    max_dimension: int = 16384
    max_pixels: int = 33_177_600

    def __post_init__(self):
        if any(type(v) is not int or v <= 0 for v in
               (self.max_frames, self.max_spool_bytes, self.max_dimension, self.max_pixels)):
            raise FrameInventoryError('inventory budgets must be positive integers')


@dataclass(frozen=True)
class FrameObservation:
    pts: Fraction
    duration: Fraction
    time_base: Fraction
    raw_pts: int
    raw_duration: int
    width: int
    height: int
    frame_sar: Fraction | None
    rotation: float
    display_matrix: bytes | None


@dataclass(frozen=True)
class DecoderObservation:
    pyav_version: str
    stream_index: int
    stream_id: int | None
    stream_time_base: Fraction | None
    codec_sar: Fraction | None
    guessed_stream_sar: Fraction | None
    demux_options: tuple[tuple[str, str], ...]
    clock: str = 'pyav-decoded-observation'
    canonical_asset_mapping: str = 'unproven'


def _cancel(cancel):
    if cancel is None:
        return
    check = getattr(cancel, 'is_set', None)
    check = check if callable(check) else cancel if callable(cancel) else None
    if check is None:
        raise FrameInventoryError('cancel must be callable or Event-like')
    result = check()
    if type(result) is not bool:
        raise FrameInventoryError('cancel callback must return bool')
    if result:
        raise InventoryCancelled('frame inventory cancelled; no partial result')


def _generation(value, current):
    if type(value) is not int or not 0 <= value <= INT64_MAX:
        raise FrameInventoryError('generation must be a nonnegative signed64 integer')
    if current is not None:
        if not callable(current):
            raise FrameInventoryError('current_generation must be callable')
        # Callback exceptions propagate; never reinterpret them as unchanged.
        observed = current()
        if type(observed) is not int or observed != value:
            raise FrameInventoryError('frame inventory generation changed')


def _exact_fraction(value, label):
    """Cross the PyAV19 AVRational boundary before any timestamp arithmetic.

    Native AVRational exposes exact int32 numerator/denominator but permits
    zero-denominator infinity/undefined, and native-native arithmetic may
    approximate to int32. Accept only Fraction or the actual final native class;
    do not accept a float, bool, generic Rational, or numerator/denominator duck.
    Fraction(integer, integer) yields the exact canonical reduced value.
    """
    if type(value) is Fraction:
        return value
    observed_type = type(value)
    if observed_type.__module__ != 'av.rational' or observed_type.__name__ != 'AVRational':
        raise FrameInventoryError(label + ' must be Fraction or native PyAV AVRational')
    try:
        from av.rational import AVRational
    except ImportError as error:
        raise FrameInventoryError('native PyAV rational type unavailable') from error
    if observed_type is not AVRational:
        raise FrameInventoryError(label + ' is not the native PyAV AVRational class')
    numerator, denominator = value.numerator, value.denominator
    if type(numerator) is not int or type(denominator) is not int or denominator <= 0:
        raise FrameInventoryError(label + ' requires exact integers and a positive denominator')
    return Fraction(numerator, denominator)


def _fraction(value, label, *, optional=False):
    if value is None and optional:
        return None
    exact = _exact_fraction(value, label)
    if exact <= 0:
        raise FrameInventoryError(label + ' must be an observed positive rational')
    _pack_fraction(exact)
    return exact


def _sar(value, label):
    # FFmpeg 0/1 is an observed unspecified SAR, not permission to invent 1/1.
    if value is None:
        return None
    exact = _exact_fraction(value, label)
    if exact < 0:
        raise FrameInventoryError(label + ' must be a nonnegative observed rational or None')
    _pack_fraction(exact)
    return exact


def _pack_fraction(value):
    if (type(value) is not Fraction or not NUMERATOR_MIN <= value.numerator <= NUMERATOR_MAX
            or not 1 <= value.denominator <= DENOMINATOR_MAX):
        raise FrameInventoryError('exact rational exceeds signed128/unsigned128 record representation')
    return value.numerator.to_bytes(16, 'little', signed=True) + value.denominator.to_bytes(16, 'little')


def _unpack_fraction(raw):
    return Fraction(int.from_bytes(raw[:16], 'little', signed=True), int.from_bytes(raw[16:], 'little'))


def _dimensions(width, height, limits):
    if (type(width) is not int or type(height) is not int or width <= 0 or height <= 0 or
            width > min(limits.max_dimension, 0xffffffff) or height > min(limits.max_dimension, 0xffffffff) or
            width * height > limits.max_pixels):
        raise FrameInventoryError('decoded resolution exceeds explicit inventory resource budget')


def _observe(frame, limits):
    if getattr(frame, 'is_corrupt', False):
        raise FrameInventoryError('decoder marked a corrupt frame; inventory incomplete')
    pts, duration = frame.pts, frame.duration
    if type(pts) is not int or not INT64_MIN <= pts <= INT64_MAX:
        raise FrameInventoryError('missing or unrepresentable signed64 decoded PTS')
    if type(duration) is not int or not 0 < duration <= INT64_MAX:
        raise FrameInventoryError('missing or unrepresentable positive signed64 decoded duration; no guessing')
    time_base = _fraction(frame.time_base, 'decoded time_base')
    _dimensions(frame.width, frame.height, limits)
    sar = _sar(getattr(frame, 'sample_aspect_ratio', None), 'frame SAR')
    rotation = frame.rotation
    if type(rotation) not in (int, float) or not math.isfinite(rotation):
        raise FrameInventoryError('decoded rotation observation must be finite')
    matrix = frame.side_data.get('DISPLAYMATRIX')
    if matrix is not None:
        # PyAV Buffer exposes the buffer protocol/buffer_size, not __len__.
        # A view checks actual byte size without allocating an unknown payload.
        with memoryview(matrix) as view:
            if view.nbytes != 36:
                raise FrameInventoryError('decoded display matrix must retain its actual 36 bytes')
            matrix = bytes(view)
    return FrameObservation(Fraction(pts)*time_base, Fraction(duration)*time_base,
                            time_base, pts, duration, frame.width, frame.height, sar, float(rotation), matrix)


def _encode(row):
    flags = (1 if row.frame_sar is not None else 0) | (2 if row.display_matrix is not None else 0)
    return _RECORD.pack(_pack_fraction(row.pts), _pack_fraction(row.duration), _pack_fraction(row.time_base),
                        _pack_fraction(row.frame_sar if row.frame_sar is not None else Fraction(1)), row.raw_pts, row.raw_duration,
                        row.rotation, row.width, row.height, flags, row.display_matrix or bytes(36))


def _decode(raw):
    if len(raw) != RECORD_BYTES:
        raise FrameInventoryError('incomplete private inventory record')
    pts, duration, base, sar, raw_pts, raw_duration, rotation, width, height, flags, matrix = _RECORD.unpack(raw)
    return FrameObservation(_unpack_fraction(pts), _unpack_fraction(duration), _unpack_fraction(base),
                            raw_pts, raw_duration, width, height,
                            _unpack_fraction(sar) if flags & 1 else None, rotation, matrix if flags & 2 else None)


def _av():
    try:
        import av
    except ImportError as error:
        raise FrameInventoryError('PyAV 19 runtime unavailable; frame inventory unverified') from error
    if int(av.__version__.split('.')[0]) < 19:
        raise FrameInventoryError('PyAV 19 or newer is required for observed frame duration/rotation')
    return av


class _BoundedInput:
    """Read only the captured descriptor, never reopen a pathname in the decoder."""
    def __init__(self, stream, size, descriptor, check):
        self.stream, self.size, self.descriptor, self.check = stream, size, descriptor, check
    def read(self, count=-1):
        self.check()
        if not same_domain(self.descriptor, stat_snapshot(os.fstat(self.stream.fileno()), domain='descriptor')):
            raise FrameInventoryError('original descriptor metadata changed during decoding')
        if type(count) is not int:
            raise FrameInventoryError('decoder requested a noninteger read')
        remaining = max(0, self.size-self.stream.tell())
        data = self.stream.read(min(remaining, READ_BYTES if count < 0 else min(count, READ_BYTES)))
        self.check()
        return data
    def seek(self, offset, whence=0):
        self.check()
        return self.stream.seek(offset, whence)
    def tell(self): return self.stream.tell()
    def readable(self): return True
    def seekable(self): return True


class FrameInventory(Sequence):
    """Immutable metadata spool; close invalidates queries and deletes own temp.

    Build is transactional: errors clean only this attempt's private spool. The
    supplied source and any existing inventory remain untouched. If teardown itself fails,
    the primary exception exposes retry_inventory_cleanup() for this attempt
    only; normal close() is also retryable after partial failure. generation/SHA
    are explicit bindings, not authority to apply edits or evidence of a native
    clock map. Arbitrary/non-right-angle rotation is retained, not transformed.
    """
    def __init__(self):
        raise TypeError('use FrameInventory.build(...)')

    @classmethod
    def build(cls, path, *, expected_sha256, generation, limits=None, cancel=None,
              current_generation=None, demux_options=None):
        from .media import _capture_identity, _check_identity, fingerprint
        # The helper imports _BoundedInput; importing here avoids a module-level
        # cycle and keeps actual decoder loading behind the explicit build call.
        from .local_decoder import open_local_decoder
        limits = InventoryLimits() if limits is None else limits
        if type(limits) is not InventoryLimits:
            raise FrameInventoryError('limits must be InventoryLimits')
        if not isinstance(expected_sha256, str) or not re.fullmatch('[0-9a-fA-F]{64}', expected_sha256):
            raise FrameInventoryError('expected source SHA256 baseline is required')
        expected_sha256 = expected_sha256.lower()
        options = {} if demux_options is None else dict(demux_options)
        if any(k not in ('ignore_editlist', 'advanced_editlist') or v not in ('0', '1') for k, v in options.items()):
            raise FrameInventoryError('only explicit raw edit-list demux option observations are accepted')
        def check():
            _cancel(cancel); _generation(generation, current_generation)
        check()
        path = Path(path).absolute()
        identity = _capture_identity(path)
        size = identity.metadata[3]
        if size <= 0:
            raise FrameInventoryError('original source must be nonempty')
        if fingerprint(path, max_bytes=size, cancel=lambda: (check() or False)) != expected_sha256:
            raise FrameInventoryError('original source SHA256 does not match baseline')
        _check_identity(path, identity); check()
        result = object.__new__(cls)
        result._lock, result._complete, result._closed, result._count = RLock(), False, False, 0
        result._directory = result._stream = None
        iterator, fd = None, None
        try:
            result._directory = tempfile.TemporaryDirectory(prefix='bluraction-frame-inventory-')
            result._stream = tempfile.TemporaryFile(mode='w+b', dir=result._directory.name, buffering=BUFFER_BYTES)
            av = _av()
            flags = os.O_RDONLY | getattr(os, 'O_BINARY', 0) | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_NONBLOCK', 0)
            fd = os.open(path, flags)
            descriptor = stat_snapshot(os.fstat(fd), domain='descriptor')
            if not path_matches_descriptor(identity.stat_snapshot, descriptor):
                raise FrameInventoryError('original descriptor changed before decode')
            with os.fdopen(fd, 'rb') as source:
                fd = None
                _check_identity(path, identity); check()
                bounded = _BoundedInput(source, size, descriptor, check)
                with open_local_decoder(bounded, mode='r', options=options) as container:
                    videos = list(container.streams.video)
                    if len(videos) != 1:
                        raise FrameInventoryError('exactly one video stream is required for this inventory')
                    video = videos[0]
                    _dimensions(video.width, video.height, limits)
                    result._decoder = DecoderObservation(str(av.__version__), video.index, video.id,
                        _fraction(video.time_base, 'stream time_base', optional=True),
                        _sar(video.codec_context.sample_aspect_ratio, 'codec SAR'),
                        _sar(video.sample_aspect_ratio, 'guessed stream SAR'), tuple(sorted(options.items())))
                    iterator = iter(container.decode(video))
                    previous = None
                    while True:
                        check()
                        try:
                            frame = next(iterator)
                        except StopIteration:
                            break
                        check()
                        if (result._count >= limits.max_frames or
                                (result._count+1)*RECORD_BYTES > limits.max_spool_bytes):
                            raise FrameInventoryError('inventory frame/spool budget reached before complete EOF')
                        row = _observe(frame, limits)
                        if previous is not None and row.pts <= previous:
                            raise FrameInventoryError('decoded PTS must be strictly ordered and unique')
                        if result._stream.write(_encode(row)) != RECORD_BYTES:
                            raise FrameInventoryError('incomplete private inventory write')
                        result._count += 1; previous = row.pts
                        del frame  # Do not retain decoded pixels in the inventory.
                    check()
                    if not result._count:
                        raise FrameInventoryError('no decoded frames before EOF')
                    close = getattr(iterator, 'close', None)
                    if close is not None: close()
                    iterator = None
                # Codec close is part of success; guard the still-owned fd too.
                check()
                if not same_domain(descriptor, stat_snapshot(os.fstat(source.fileno()), domain='descriptor')):
                    raise FrameInventoryError('original descriptor changed before inventory completion')
                _check_identity(path, identity)
            if fingerprint(path, max_bytes=size, cancel=lambda: (check() or False)) != expected_sha256:
                raise FrameInventoryError('original source SHA256 changed during decode')
            result._stream.flush()
            # Flush may block; check cancellation/generation after it. Put the
            # final identity recheck after callbacks, which may themselves
            # trigger a source change, and directly before marking complete.
            check(); _check_identity(path, identity)
            result._source_sha256, result._generation, result._source_identity = expected_sha256, generation, identity
            result._complete = True
            return result
        except BaseException as failure:
            teardown_error = None
            if iterator is not None:
                close = getattr(iterator, 'close', None)
                if close is not None:
                    try:
                        close()
                    except BaseException as error:
                        teardown_error = error
                        failure.add_note(f'frame iterator teardown also failed: {error!r}')
            try:
                result.close()
            except BaseException as cleanup_error:
                failure.add_note(f'private frame inventory cleanup also failed: {cleanup_error!r}')
                # Retain only this attempt's private cleanup owner. A caller can
                # retry after a transient close/removal failure; the source and
                # any previous inventory are never part of this cleanup target.
                failure.retry_inventory_cleanup = result.close
                raise failure from cleanup_error
            if teardown_error is not None:
                if teardown_error is not failure:
                    raise failure from teardown_error
                raise  # Repeated iterator close may raise the same primary object.
            raise
        finally:
            if fd is not None: os.close(fd)

    def _require_open(self):
        if self._closed or not self._complete or self._stream is None:
            raise FrameInventoryError('frame inventory is incomplete or closed')

    def __len__(self):
        with self._lock:
            self._require_open(); return self._count

    def __getitem__(self, index):
        with self._lock:
            self._require_open()
            if isinstance(index, slice):
                raise FrameInventoryError('iterate records without materializing unbounded slices')
            if type(index) is not int:
                raise TypeError('frame record index must be integer')
            if index < 0: index += self._count
            if not 0 <= index < self._count: raise IndexError(index)
            self._stream.seek(index*RECORD_BYTES)
            return _decode(self._stream.read(RECORD_BYTES))

    @property
    def decoder(self):
        with self._lock:
            self._require_open(); return self._decoder

    @property
    def source_sha256(self):
        with self._lock:
            self._require_open(); return self._source_sha256

    @property
    def generation(self):
        with self._lock:
            self._require_open(); return self._generation

    @property
    def source_identity(self):
        with self._lock:
            self._require_open(); return self._source_identity

    def require_binding(self, *, source_sha256, generation):
        with self._lock:
            self._require_open()
            if (type(generation) is not int or generation != self._generation or
                    source_sha256 != self._source_sha256):
                raise FrameInventoryError('inventory source SHA/generation binding does not match')

    @property
    def complete(self):
        with self._lock:
            return self._complete and not self._closed

    def close(self):
        # Logical invalidation is immediate, but owned resource references stay
        # until each teardown succeeds. Repeated close can retry partial failure.
        with self._lock:
            if self._closed and self._stream is None and self._directory is None:
                return
            self._closed = True; self._complete = False
            stream, directory = self._stream, self._directory
            close_error = None
            try:
                if stream is not None:
                    stream.close()
            except BaseException as error:
                close_error = error
            finally:
                # close may raise after closing the actual handle. Retain only
                # still-open handles, always attempt removal of the owned dir.
                if stream is None or stream.closed:
                    self._stream = None
                try:
                    if directory is not None:
                        directory.cleanup()
                        self._directory = None
                except BaseException as cleanup_error:
                    if close_error is not None:
                        close_error.add_note(f'private frame directory cleanup also failed: {cleanup_error!r}')
                        raise close_error from cleanup_error
                    raise
            if close_error is not None:
                raise close_error

    def __enter__(self):
        with self._lock:
            self._require_open(); return self

    def __exit__(self, kind, failure, traceback):
        try:
            self.close()
        except BaseException as cleanup_error:
            if failure is not None:
                failure.add_note(f'private frame context cleanup also failed: {cleanup_error!r}')
                failure.retry_inventory_cleanup = self.close
                raise failure from cleanup_error
            raise
