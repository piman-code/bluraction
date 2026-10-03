"""Exact source-frame identity from an explicitly related native time axis.

This module selects no origin policy and decodes no media. Callers must provide
actual source PTS candidates and an independently established native origin.
Source/origin Fractions may be negative. Native observed microseconds and the
returned canonical elapsed time must be nonnegative. Project ranges are untouched.
No FPS, floating-point conversion, epsilon or guessed timestamp is used.
"""
from __future__ import annotations

from collections.abc import Sequence
from fractions import Fraction

MICROSECONDS_PER_SECOND = 1_000_000
INT64_MIN = -(1 << 63)
INT64_MAX = (1 << 63) - 1


class TemporalMappingError(ValueError):
    """Missing, ambiguous, inexact or unrepresentable frame mapping."""


def _exact(value: Fraction, name: str) -> Fraction:
    # Reject bool/int/float (including NaN/Inf) rather than silently converting a
    # rounded timestamp into purportedly exact source evidence.
    if type(value) is not Fraction:
        raise TemporalMappingError(f'{name} must be an exact Fraction')
    return value


def canonical_frame_time(
    native_timestamp_us: int,
    source_pts: Sequence[Fraction],
    *,
    source_origin: Fraction,
    native_origin: Fraction,
) -> Fraction:
    """Return the unique actual source PTS minus the canonical source origin.

    Native presentation time is explicitly related by ``raw_pts-native_origin``.
    Its exact floor/ceil microsecond interval must contain the observed native
    integer. This models loss of sub-microsecond representation, not a tolerance
    on effect ranges. Two candidates in the same quantum (even duplicate PTS)
    are ambiguous and are never deduplicated or selected by order.

    All candidate native intervals must fit signed64 microseconds; the selected
    canonical elapsed time must fit nonnegative signed64 microseconds too.
    The input Sequence is finite and is never sorted, rewritten or consumed as
    an unbounded iterator. Missing/ambiguous/invalid mappings raise before a
    caller can apply edits to a guessed frame. No duration/segment policy is
    inferred here, and this function alone cannot approve a decoder time axis.
    """
    if type(native_timestamp_us) is not int or not 0 <= native_timestamp_us <= INT64_MAX:
        raise TemporalMappingError('native_timestamp_us must be a nonnegative signed64 integer')
    source_origin = _exact(source_origin, 'source_origin')
    native_origin = _exact(native_origin, 'native_origin')
    if not isinstance(source_pts, Sequence) or isinstance(source_pts, (str, bytes, bytearray)):
        raise TemporalMappingError('source_pts must be a finite Sequence of actual Fraction PTS')
    matches = []
    for value in source_pts:
        value = _exact(value, 'source_pts candidate')
        ticks = (value - native_origin) * MICROSECONDS_PER_SECOND
        lower = ticks.numerator // ticks.denominator
        upper = -(-ticks.numerator // ticks.denominator)
        if lower < INT64_MIN or upper > INT64_MAX:
            raise TemporalMappingError('candidate native microsecond interval overflows signed64')
        if lower <= native_timestamp_us <= upper:
            matches.append(value)
    if not matches:
        raise TemporalMappingError('missing source frame for observed native timestamp')
    if len(matches) != 1:
        raise TemporalMappingError('ambiguous source frames in observed native microsecond quantum')
    elapsed = matches[0] - source_origin
    if elapsed < 0:
        raise TemporalMappingError('canonical elapsed source time is negative')
    if elapsed * MICROSECONDS_PER_SECOND > INT64_MAX:
        raise TemporalMappingError('canonical elapsed microsecond time overflows signed64')
    return elapsed
