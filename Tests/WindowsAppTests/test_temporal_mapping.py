"""Pure frame mapping regressions; no decoder, Qt, export or Windows proof.

The VFR cases retain actual observed Fraction/microsecond pairs. A mapping PASS
does not establish a native origin or complete the production P1 repair.
"""
from fractions import Fraction
import unittest

from platforms.windows.bluraction.temporal_mapping import (
    INT64_MAX, INT64_MIN, TemporalMappingError, canonical_frame_time,
)


class TemporalMappingTests(unittest.TestCase):
    def map(self, stamp, pts, source_origin=Fraction(0), native_origin=Fraction(0)):
        return canonical_frame_time(stamp, pts, source_origin=source_origin, native_origin=native_origin)

    def test_observed_vfr_floor_restores_raw_period_without_changing_conditions(self):
        candidates = [Fraction(0), Fraction(1, 12), Fraction(5, 24), Fraction(7, 24),
                      Fraction(1, 2), Fraction(7, 12), Fraction(5, 6)]
        original = list(candidates)
        for raw, stamp in [(Fraction(1, 12), 83333), (Fraction(7, 12), 583333),
                           (Fraction(5, 24), 208333)]:
            with self.subTest(raw=raw):
                self.assertEqual(Fraction(stamp, 1_000_000) - raw, Fraction(-1, 3_000_000))
                actual = self.map(stamp, candidates)
                self.assertEqual(actual, raw)
                # Inclusive raw conditions stay exactly as authored. This fails
                # with native-us alone and remains false for a genuine prior end.
                interval = [float(raw), float(raw)]
                self.assertFalse(interval[0] <= stamp / 1_000_000 <= interval[1])
                self.assertTrue(interval[0] <= float(actual) <= interval[1])
                prior_end = raw - Fraction(1, 10_000_000)
                self.assertFalse(float(actual) <= float(prior_end))
                self.assertEqual(interval, [float(raw), float(raw)])
        self.assertEqual(candidates, original)

    def test_floor_and_ceil_are_representation_endpoints_only(self):
        raw = Fraction(1, 12)
        self.assertEqual(self.map(83333, [raw]), raw)
        self.assertEqual(self.map(83334, [raw]), raw)
        for stamp in (83332, 83335):
            with self.subTest(stamp=stamp), self.assertRaisesRegex(TemporalMappingError, 'missing'):
                self.map(stamp, [raw])
        exact = Fraction(1, 4)
        self.assertEqual(self.map(250000, [exact]), exact)
        with self.assertRaisesRegex(TemporalMappingError, 'missing'):
            self.map(250001, [exact])

    def test_gap100_source_and_native_origins_are_independent_explicit_axes(self):
        origin = Fraction(1229, 12288)
        pts = [origin + Fraction(i, 12) for i in range(9)]
        # Observed gap100 Qt sink583334us: source raw index7, native offset
        # known explicitly. No conversion of a Mac-style raw editing axis.
        self.assertEqual(self.map(583334, pts, native_origin=origin), origin + Fraction(7, 12))
        # A separately normalized source editing axis is allowed only when the
        # caller explicitly chooses its origin; it is never inferred here.
        self.assertEqual(self.map(583334, pts, source_origin=origin, native_origin=origin), Fraction(7, 12))
        with self.assertRaisesRegex(TemporalMappingError, 'missing'):
            self.map(583334, pts)

    def test_negative_source_pts_and_origins_preserve_valid_elapsed(self):
        pts = [Fraction(-2), Fraction(-3, 2), Fraction(-1)]
        self.assertEqual(self.map(500000, pts, source_origin=Fraction(-2), native_origin=Fraction(-2)), Fraction(1, 2))
        self.assertEqual(self.map(0, [Fraction(-1)], source_origin=Fraction(-2), native_origin=Fraction(-1)), Fraction(1))
        # A negative native candidate may exist; it is not mistaken for invalid
        # raw source evidence or filtered into a guessed matching frame.
        self.assertEqual(self.map(0, [Fraction(-1), Fraction(0)]), Fraction(0))

    def test_same_native_quantum_and_duplicate_pts_are_ambiguous(self):
        for pts in ([Fraction(1, 12), Fraction(1, 12) + Fraction(1, 2_000_000)],
                    [Fraction(1, 12), Fraction(1, 12)],
                    [Fraction(1, 12) + Fraction(1, 2_000_000), Fraction(1, 12)]):
            with self.subTest(pts=pts), self.assertRaisesRegex(TemporalMappingError, 'ambiguous'):
                self.map(83333, pts)

    def test_missing_frame_is_not_interpolated_or_replaced_with_fps(self):
        for candidates in ([], [Fraction(0), Fraction(1, 3), Fraction(5, 6)]):
            with self.subTest(candidates=candidates), self.assertRaisesRegex(TemporalMappingError, 'missing'):
                self.map(100000, candidates)

    def test_inexact_and_nonfinite_inputs_fail_before_mapping(self):
        for stamp in (True, .0, float('nan'), float('inf'), -1, INT64_MAX + 1):
            with self.subTest(stamp=stamp), self.assertRaises(TemporalMappingError):
                self.map(stamp, [Fraction(0)])
        for bad in (0, True, .1, float('nan'), float('inf'), '1/12', None):
            for field in ('source_pts', 'source_origin', 'native_origin'):
                with self.subTest(field=field, value=bad), self.assertRaisesRegex(TemporalMappingError, 'exact Fraction'):
                    self.map(0, [bad] if field == 'source_pts' else [Fraction(0)],
                             source_origin=bad if field == 'source_origin' else Fraction(0),
                             native_origin=bad if field == 'native_origin' else Fraction(0))
        with self.assertRaisesRegex(TemporalMappingError, 'finite Sequence'):
            self.map(0, iter([Fraction(0)]))
        # A valid matching frame must not hide an invalid later candidate.
        with self.assertRaisesRegex(TemporalMappingError, 'exact Fraction'):
            self.map(0, [Fraction(0), float('nan')])

    def test_canonical_negative_and_signed64_overflow_fail_closed(self):
        with self.assertRaisesRegex(TemporalMappingError, 'negative'):
            self.map(0, [Fraction(-1)], native_origin=Fraction(-1))
        for value in (Fraction(INT64_MAX + 1, 1_000_000), Fraction(INT64_MIN - 1, 1_000_000)):
            with self.subTest(value=value), self.assertRaisesRegex(TemporalMappingError, 'overflows'):
                self.map(0, [value])
        with self.assertRaisesRegex(TemporalMappingError, 'overflows'):
            self.map(0, [Fraction(0)], source_origin=-Fraction(INT64_MAX + 1, 1_000_000))
        maximum = Fraction(INT64_MAX, 1_000_000)
        self.assertEqual(self.map(INT64_MAX, [maximum]), maximum)
        # Large signed raw clock/origins are exact when their explicitly mapped
        # native and canonical elapsed times are representable.
        self.assertEqual(self.map(0, [Fraction(-10**30)], source_origin=Fraction(-10**30),
                                  native_origin=Fraction(-10**30)), Fraction(0))


if __name__ == '__main__':
    unittest.main()
