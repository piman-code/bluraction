"""Complete disk-backed actual PTS inventory; no decoder or origin policy.

The caller must guard the same source identity/SHA before and after decoding,
prove the source/native axis relationship, and discard this index on any source,
generation or seek-policy change. This helper cannot establish those facts.
Only a normally exhausted, strictly chronological actual Fraction iterator is
usable. No FPS, duration cap, floating point or guessed timestamps are used.
"""
from __future__ import annotations

from collections.abc import Sequence
from fractions import Fraction
import sys
import tempfile
from threading import RLock

from .temporal_mapping import (INT64_MAX, INT64_MIN, MICROSECONDS_PER_SECOND,
                               TemporalMappingError, canonical_frame_time)

RECORD_BYTES = 32
WRITE_BUFFER_BYTES = 64 * 1024
NUMERATOR_MIN = -(1 << 127)
NUMERATOR_MAX = (1 << 127) - 1
DENOMINATOR_MAX = (1 << 128) - 1


class PTSIndexError(TemporalMappingError):
    """Invalid, incomplete, closed or unrepresentable actual PTS inventory."""


class PTSIndexCancelled(PTSIndexError):
    """No partial index is returned after cancellation."""


def _check_cancel(cancel):
    if cancel is None:
        return
    check = getattr(cancel, 'is_set', None)
    if not callable(check):
        check = cancel if callable(cancel) else None
    if check is None:
        raise PTSIndexError('cancel must be an Event-like token or a callable')
    requested = check()
    if type(requested) is not bool:
        raise PTSIndexError('cancel callback must return bool')
    if requested:
        raise PTSIndexCancelled('actual PTS index creation cancelled')


def _pack_record(value):
    if type(value) is not Fraction:
        raise PTSIndexError('actual raw PTS must be an exact Fraction')
    if not NUMERATOR_MIN <= value.numerator <= NUMERATOR_MAX:
        raise PTSIndexError('raw PTS numerator does not fit signed128 record')
    if not 1 <= value.denominator <= DENOMINATOR_MAX:
        raise PTSIndexError('raw PTS denominator does not fit unsigned128 record')
    # A signed64 PTS multiplied by a signed32 time-base numerator fits this
    # wider field. Other exact Fractions outside it fail, never round/truncate.
    return (value.numerator.to_bytes(16, 'little', signed=True)
            + value.denominator.to_bytes(16, 'little', signed=False))


class _CandidateWindow(Sequence):
    """Immutable lazy window; retains its owner and is invalid after close."""

    __slots__ = ('_owner', '_indices')

    def __init__(self, owner, indices):
        self._owner, self._indices = owner, indices

    def __len__(self):
        with self._owner._lock:
            self._owner._require_open()
            return len(self._indices)

    def __getitem__(self, position):
        with self._owner._lock:
            self._owner._require_open()
            index = self._indices[position]
            if isinstance(index, range):
                return _CandidateWindow(self._owner, index)
            return self._owner._read_at(index)


class ExactPTSIndex:
    """Read-only API over a private fixed-record spool, complete at creation.

    Use ``build`` and close explicitly (prefer a context manager). The input
    iterator is consumed to EOF and, if it has close(), closed on every outcome.
    Creation memory is a constant number of Fractions/32-byte records plus a
    fixed 64KiB buffer;
    query memory is logarithmic search state, not a list of nearby frames.
    Disk usage is 32 bytes per actual frame. No path or temp directory parameter
    is accepted. OS temporary-file permissions still follow the user's runtime.
    """

    def __init__(self):
        raise TypeError('use ExactPTSIndex.build(actual_raw_pts, cancel=...)')

    @classmethod
    def build(cls, actual_raw_pts, cancel=None):
        _check_cancel(cancel)
        index = object.__new__(cls)
        index._lock = RLock()
        index._stream = None
        index._directory = None
        index._complete = False
        index._closed = False
        index._count = 0
        index._first = index._last = None
        iterator = None
        try:
            index._directory = tempfile.TemporaryDirectory(prefix='bluraction-pts-')
            index._stream = tempfile.TemporaryFile(mode='w+b', dir=index._directory.name,
                buffering=WRITE_BUFFER_BYTES)
            iterator = iter(actual_raw_pts)
            iterator_failure = None
            try:
                while True:
                    _check_cancel(cancel)
                    try:
                        value = next(iterator)
                    except StopIteration:
                        break
                    _check_cancel(cancel)
                    encoded = _pack_record(value)
                    if index._last is not None and value <= index._last:
                        raise PTSIndexError('actual raw PTS must be strictly increasing; duplicate/nonincreasing PTS')
                    if index._count == sys.maxsize:
                        raise PTSIndexError('actual frame count exceeds Sequence representability')
                    written = index._stream.write(encoded)
                    if written != RECORD_BYTES:
                        raise PTSIndexError('incomplete actual PTS record write')
                    if index._first is None:
                        index._first = value
                    index._last = value
                    index._count += 1
                _check_cancel(cancel)  # EOF itself may issue a cancellation.
            except BaseException as failure:
                iterator_failure = failure
                raise
            finally:
                close_iterator = getattr(iterator, 'close', None)
                if callable(close_iterator):
                    try:
                        close_iterator()
                    except BaseException as teardown_error:
                        if iterator_failure is not None:
                            iterator_failure.add_note(f'actual PTS iterator teardown also failed: {teardown_error!r}')
                            raise iterator_failure from teardown_error
                        raise
            index._stream.flush()
            if index._stream.tell() != index._count * RECORD_BYTES:
                raise PTSIndexError('actual PTS spool size is inconsistent')
            index._stream.seek(0)
            _check_cancel(cancel)  # Also cover iterator teardown/flush cancellation.
            index._complete = True
            return index
        except BaseException as failure:
            try:
                index.close()
            except BaseException as cleanup_error:
                failure.add_note(f'actual PTS index cleanup also failed: {cleanup_error!r}')
                raise failure from cleanup_error
            raise

    def _require_open(self):
        if self._closed or not self._complete or self._stream is None:
            raise PTSIndexError('actual PTS index is closed or incomplete')

    @property
    def count(self):
        with self._lock:
            self._require_open()
            return self._count

    @property
    def first(self):
        with self._lock:
            self._require_open()
            return self._first

    @property
    def last(self):
        with self._lock:
            self._require_open()
            return self._last

    def _read_at(self, position):
        # Every seek/read pair and close uses this lock; no shared-offset race.
        with self._lock:
            self._require_open()
            if not 0 <= position < self._count:
                raise IndexError(position)
            self._stream.seek(position * RECORD_BYTES)
            encoded = self._stream.read(RECORD_BYTES)
            if len(encoded) != RECORD_BYTES:
                raise PTSIndexError('actual PTS spool has a missing/truncated record')
            numerator = int.from_bytes(encoded[:16], 'little', signed=True)
            denominator = int.from_bytes(encoded[16:], 'little', signed=False)
            if denominator == 0:
                raise PTSIndexError('actual PTS spool has an invalid denominator')
            return Fraction(numerator, denominator)

    def _bisect(self, value, after_equal):
        left, right = 0, self._count
        while left < right:
            mid = (left + right) // 2
            raw = self._read_at(mid)
            if raw < value or (after_equal and raw == value):
                left = mid + 1
            else:
                right = mid
        return left

    def candidates(self, native_timestamp_us, *, native_origin):
        """All candidates in the exact open (u-1,u+1) microsecond bounds.

        This window is complete only because build reached EOF and proved the
        actual PTS strictly increasing. It does not prove the native origin.
        The native intervals of the entire inventory must fit signed64, as in
        canonical_frame_time; sorted first/last prove this without a full scan.
        """
        with self._lock:
            self._require_open()
            if type(native_timestamp_us) is not int or not 0 <= native_timestamp_us <= INT64_MAX:
                raise PTSIndexError('native_timestamp_us must be a nonnegative signed64 integer')
            if type(native_origin) is not Fraction:
                raise PTSIndexError('native_origin must be an exact Fraction')
            if self._count:
                first_ticks = (self._first - native_origin) * MICROSECONDS_PER_SECOND
                last_ticks = (self._last - native_origin) * MICROSECONDS_PER_SECOND
                lower = first_ticks.numerator // first_ticks.denominator
                upper = -(-last_ticks.numerator // last_ticks.denominator)
                if lower < INT64_MIN or upper > INT64_MAX:
                    raise PTSIndexError('candidate native microsecond interval overflows signed64')
            low = native_origin + Fraction(native_timestamp_us - 1, MICROSECONDS_PER_SECOND)
            high = native_origin + Fraction(native_timestamp_us + 1, MICROSECONDS_PER_SECOND)
            left = self._bisect(low, after_equal=True)
            right = self._bisect(high, after_equal=False)
            return _CandidateWindow(self, range(left, right))

    def canonical_time(self, native_timestamp_us, *, source_origin, native_origin):
        """Use the existing mapper with bounded candidate memory, never guess."""
        with self._lock:
            window = self.candidates(native_timestamp_us, native_origin=native_origin)
            # Two proven matches already establish ambiguity. Do not allocate
            # every candidate or let mapper accumulate an unbounded match list.
            evidence = window[:2] if len(window) > 1 else window
            return canonical_frame_time(native_timestamp_us, evidence,
                source_origin=source_origin, native_origin=native_origin)

    def close(self):
        # Windows must close its file handle before removing the private dir.
        with self._lock:
            if self._closed and self._stream is None and self._directory is None:
                return
            self._closed = True
            self._complete = False
            stream, directory = self._stream, self._directory
            close_error = None
            try:
                if stream is not None:
                    stream.close()
            except BaseException as error:
                close_error = error
            finally:
                # close() can raise after it has actually closed the fd. Keep
                # an open handle for retry, but always attempt private-dir
                # cleanup. Windows may reject removal while a handle is open;
                # preserve that directory for retry too, without hiding errors.
                if stream is None or stream.closed:
                    self._stream = None
                try:
                    if directory is not None:
                        directory.cleanup()
                        self._directory = None
                except BaseException as cleanup_error:
                    if close_error is not None:
                        close_error.add_note(f'private PTS directory cleanup also failed: {cleanup_error!r}')
                        raise close_error from cleanup_error
                    raise
            if close_error is not None:
                raise close_error

    def __enter__(self):
        with self._lock:
            self._require_open()
        return self

    def __exit__(self, *exc):
        self.close()

    def __del__(self):
        # Fallback only; callers should close deterministically, not rely on GC.
        if hasattr(self, '_lock'):
            try:
                self.close()
            except Exception:
                pass
