"""Pure synthetic disk-index checks; no media decoder or native-axis proof."""
from collections.abc import Sequence
from concurrent.futures import ThreadPoolExecutor
from fractions import Fraction
import gc
import math
from pathlib import Path
import tempfile
from threading import Event
import unittest
from unittest.mock import patch
import weakref

from platforms.windows.bluraction import pts_index
from platforms.windows.bluraction.pts_index import (
    ExactPTSIndex, PTSIndexCancelled, PTSIndexError,
    NUMERATOR_MAX, NUMERATOR_MIN, DENOMINATOR_MAX, RECORD_BYTES,
)
from platforms.windows.bluraction.temporal_mapping import (
    INT64_MAX, INT64_MIN, TemporalMappingError,
)


class PTSIndexTests(unittest.TestCase):
    def make(self, values):
        index = ExactPTSIndex.build(values)
        self.addCleanup(index.close)
        return index

    def temp_scope(self):
        """Capture only test-owned spool dirs without exposing a product path API."""
        original = tempfile.TemporaryDirectory
        root = original(prefix='bluraction-pts-test-')
        self.addCleanup(root.cleanup)
        captured = []

        def directory(*args, **kwargs):
            result = original(*args, **kwargs, dir=root.name)
            captured.append(Path(result.name))
            return result

        return patch.object(pts_index.tempfile, 'TemporaryDirectory', side_effect=directory), captured

    def test_vfr_inventory_is_complete_exact_and_independent_of_input_mutation(self):
        raw = [Fraction(0), Fraction(1, 12), Fraction(5, 24), Fraction(7, 24),
               Fraction(1, 2), Fraction(7, 12), Fraction(5, 6)]
        index = self.make(iter(raw))
        raw.append(Fraction(1))
        self.assertEqual(index.count, 7)
        self.assertEqual(index.first, Fraction(0))
        self.assertEqual(index.last, Fraction(5, 6))
        for stamp, value in [(83333, Fraction(1, 12)), (208333, Fraction(5, 24)),
                             (583333, Fraction(7, 12))]:
            self.assertEqual(index.canonical_time(stamp, source_origin=Fraction(0),
                native_origin=Fraction(0)), value)
        self.assertEqual(index._stream.seek(0, 2), index.count * RECORD_BYTES)

    def test_open_quantum_endpoints_are_excluded_without_epsilon(self):
        raw = [Fraction(99, 1_000_000), Fraction(199, 2_000_000),
               Fraction(100, 1_000_000), Fraction(201, 2_000_000),
               Fraction(101, 1_000_000)]
        index = self.make(raw)
        window = index.candidates(100, native_origin=Fraction(0))
        self.assertIsInstance(window, Sequence)
        self.assertNotIsInstance(window, (list, tuple))
        self.assertEqual(list(window), raw[1:4])
        self.assertEqual(list(window[::-1]), raw[1:4][::-1])
        self.assertEqual(window[-1], raw[3])
        with self.assertRaises(IndexError):
            _ = window[3]
        with self.assertRaises(TypeError):
            window[0] = Fraction(0)
        with self.assertRaisesRegex(TemporalMappingError, 'ambiguous'):
            index.canonical_time(100, source_origin=Fraction(0), native_origin=Fraction(0))

    def test_dense_quantum_is_lazy_and_canonical_ambiguity_has_logarithmic_reads(self):
        count = 10_000
        index = self.make(Fraction(i, 10_000_000_000) for i in range(count))
        self.assertEqual(len(index.candidates(0, native_origin=Fraction(0))), count)
        with patch.object(index, '_read_at', wraps=index._read_at) as read:
            with self.assertRaisesRegex(TemporalMappingError, 'ambiguous'):
                index.canonical_time(0, source_origin=Fraction(0), native_origin=Fraction(0))
            self.assertLessEqual(read.call_count, 2 * math.ceil(math.log2(count)) + 4)

    def test_empty_and_missing_never_choose_nearest_or_interpolate(self):
        for raw in ([], [Fraction(0), Fraction(1, 3), Fraction(5, 6)]):
            with self.subTest(raw=raw):
                index = self.make(raw)
                self.assertEqual(len(index.candidates(100000, native_origin=Fraction(0))), 0)
                with self.assertRaisesRegex(TemporalMappingError, 'missing'):
                    index.canonical_time(100000, source_origin=Fraction(0), native_origin=Fraction(0))
        empty = self.make([])
        self.assertIsNone(empty.first)
        self.assertIsNone(empty.last)

    def test_negative_pts_and_independent_negative_origins_are_exact(self):
        index = self.make([Fraction(-2), Fraction(-3, 2), Fraction(-1)])
        self.assertEqual(index.canonical_time(500000, source_origin=Fraction(-2),
            native_origin=Fraction(-2)), Fraction(1, 2))
        self.assertEqual(index.canonical_time(500000, source_origin=Fraction(-3),
            native_origin=Fraction(-2)), Fraction(3, 2))
        with self.assertRaisesRegex(TemporalMappingError, 'negative'):
            index.canonical_time(500000, source_origin=Fraction(0), native_origin=Fraction(-2))

    def test_wide_records_preserve_products_beyond_signed64(self):
        raw = Fraction(((1 << 63) - 1) * ((1 << 31) - 1), (1 << 31) - 2)
        self.assertGreater(raw.numerator, (1 << 63) - 1)
        index = self.make([raw])
        self.assertEqual(index.canonical_time(0, source_origin=raw, native_origin=raw), Fraction(0))
        for raw in (Fraction(NUMERATOR_MIN), Fraction(NUMERATOR_MAX), Fraction(1, DENOMINATOR_MAX)):
            with self.subTest(raw=raw):
                index = self.make([raw])
                self.assertEqual(index.candidates(0, native_origin=raw)[0], raw)

    def test_native_whole_inventory_overflow_and_elapsed_overflow_fail_closed(self):
        for raw in ([Fraction(INT64_MIN - 1, 1_000_000), Fraction(0)],
                    [Fraction(0), Fraction(INT64_MAX + 1, 1_000_000)]):
            index = self.make(raw)
            with self.assertRaisesRegex(PTSIndexError, 'overflows'):
                index.canonical_time(0, source_origin=Fraction(0), native_origin=Fraction(0))
        maximum = Fraction(INT64_MAX, 1_000_000)
        index = self.make([maximum])
        self.assertEqual(index.canonical_time(INT64_MAX, source_origin=Fraction(0),
            native_origin=Fraction(0)), maximum)
        index = self.make([Fraction(0)])
        with self.assertRaisesRegex(TemporalMappingError, 'overflows'):
            index.canonical_time(0, source_origin=-Fraction(INT64_MAX + 1, 1_000_000),
                native_origin=Fraction(0))

    def test_invalid_native_inputs_and_origin_are_rejected(self):
        index = self.make([Fraction(0)])
        for stamp in (True, 0.0, -1, INT64_MAX + 1, float('inf')):
            with self.subTest(stamp=stamp), self.assertRaises(PTSIndexError):
                index.candidates(stamp, native_origin=Fraction(0))
        for origin in (0, True, .0, float('nan'), None):
            with self.subTest(origin=origin), self.assertRaises(PTSIndexError):
                index.candidates(0, native_origin=origin)
        with self.assertRaisesRegex(TemporalMappingError, 'exact Fraction'):
            index.canonical_time(0, source_origin=0, native_origin=Fraction(0))

    def test_late_invalid_order_type_and_record_overflow_never_publish_and_cleanup(self):
        invalid = [([Fraction(0), Fraction(1), Fraction(1)], 'strictly increasing'),
                   ([Fraction(0), Fraction(1), Fraction(1, 2)], 'strictly increasing'),
                   ([Fraction(0), Fraction(1), .5], 'exact Fraction'),
                   ([Fraction(0), Fraction(NUMERATOR_MAX + 1)], 'signed128'),
                   ([Fraction(0), Fraction(1, DENOMINATOR_MAX + 1)], 'unsigned128')]
        scope, dirs = self.temp_scope()
        with scope:
            for raw, message in invalid:
                with self.subTest(message=message), self.assertRaisesRegex(PTSIndexError, message):
                    ExactPTSIndex.build(iter(raw))
                self.assertFalse(dirs[-1].exists())

    def test_iterator_failure_after_last_yield_closes_and_removes_spool(self):
        closed = []

        def raw():
            try:
                yield Fraction(0)
                yield Fraction(1)
                raise RuntimeError('decoder failed before normal EOF')
            finally:
                closed.append(True)

        scope, dirs = self.temp_scope()
        with scope, self.assertRaisesRegex(RuntimeError, 'before normal EOF'):
            ExactPTSIndex.build(raw())
        self.assertEqual(closed, [True])
        self.assertFalse(dirs[0].exists())

    def test_cancel_before_during_and_at_eof_removes_partial_index(self):
        token = Event()
        token.set()
        with self.assertRaises(PTSIndexCancelled):
            ExactPTSIndex.build([Fraction(0)], cancel=token)
        for at_eof in (False, True):
            token.clear()
            closed = []

            def raw():
                try:
                    yield Fraction(0)
                    token.set()
                    if not at_eof:
                        yield Fraction(1)
                finally:
                    closed.append(True)

            scope, dirs = self.temp_scope()
            with scope, self.assertRaises(PTSIndexCancelled):
                ExactPTSIndex.build(raw(), cancel=token)
            self.assertEqual(closed, [True])
            self.assertFalse(dirs[0].exists())

    def test_iterator_teardown_cancel_is_checked_before_publishing(self):
        token = Event()

        class ClosingIterator:
            def __init__(self):
                self.iterator = iter([Fraction(0)])
            def __iter__(self):
                return self
            def __next__(self):
                return next(self.iterator)
            def close(self):
                token.set()

        scope, dirs = self.temp_scope()
        with scope, self.assertRaises(PTSIndexCancelled):
            ExactPTSIndex.build(ClosingIterator(), cancel=token)
        self.assertFalse(dirs[0].exists())

    def test_iterator_close_failure_never_returns_complete_index(self):
        class ClosingIterator:
            def __init__(self):
                self.iterator = iter([Fraction(0)])
            def __iter__(self):
                return self
            def __next__(self):
                return next(self.iterator)
            def close(self):
                raise OSError('synthetic decoder teardown failure')

        scope, dirs = self.temp_scope()
        with scope, self.assertRaisesRegex(OSError, 'decoder teardown failure'):
            ExactPTSIndex.build(ClosingIterator())
        self.assertFalse(dirs[0].exists())

    def test_decoder_failure_remains_primary_when_iterator_teardown_also_fails(self):
        class FailingDecoder:
            def __init__(self):
                self.yielded = False
                self.close_attempted = False
            def __iter__(self):
                return self
            def __next__(self):
                if not self.yielded:
                    self.yielded = True
                    return Fraction(0)
                raise RuntimeError('primary decoder failure before EOF')
            def close(self):
                self.close_attempted = True
                raise OSError('secondary decoder teardown failure')

        decoder = FailingDecoder()
        scope, dirs = self.temp_scope()
        with scope, self.assertRaisesRegex(RuntimeError, 'primary decoder failure before EOF') as caught:
            ExactPTSIndex.build(decoder)
        self.assertTrue(decoder.close_attempted)
        self.assertIsInstance(caught.exception.__cause__, OSError)
        self.assertIn('secondary decoder teardown failure', str(caught.exception.__cause__))
        self.assertTrue(any('teardown also failed' in note for note in caught.exception.__notes__))
        self.assertFalse(dirs[0].exists())

    def test_write_failure_closes_handle_before_private_directory_cleanup(self):
        original = tempfile.TemporaryFile
        handles = []

        class FailingWriter:
            def __init__(self, inner):
                self.inner, self.writes = inner, 0
            def __getattr__(self, name):
                return getattr(self.inner, name)
            def write(self, value):
                self.writes += 1
                if self.writes == 2:
                    raise OSError('synthetic disk write failure')
                return self.inner.write(value)

        def spool(*args, **kwargs):
            inner = original(*args, **kwargs)
            handles.append(inner)
            return FailingWriter(inner)

        scope, dirs = self.temp_scope()
        with scope, patch.object(pts_index.tempfile, 'TemporaryFile', side_effect=spool):
            with self.assertRaisesRegex(OSError, 'disk write failure'):
                ExactPTSIndex.build([Fraction(0), Fraction(1)])
        self.assertTrue(handles[0].closed)
        self.assertFalse(dirs[0].exists())

    def test_short_write_and_flush_failure_are_not_complete_eof_indexes(self):
        original = tempfile.TemporaryFile
        for failure in ('short', 'flush'):
            handles = []

            class FailingSpool:
                def __init__(self, inner):
                    self.inner = inner
                def __getattr__(self, name):
                    return getattr(self.inner, name)
                def write(self, value):
                    if failure == 'short':
                        return self.inner.write(value[:-1])
                    return self.inner.write(value)
                def flush(self):
                    raise OSError('synthetic flush failure')

            def spool(*args, **kwargs):
                inner = original(*args, **kwargs)
                handles.append(inner)
                return FailingSpool(inner)

            scope, dirs = self.temp_scope()
            with scope, patch.object(pts_index.tempfile, 'TemporaryFile', side_effect=spool):
                error = PTSIndexError if failure == 'short' else OSError
                message = 'incomplete actual PTS record write' if failure == 'short' else 'synthetic flush failure'
                with self.subTest(failure=failure), self.assertRaisesRegex(error, message):
                    ExactPTSIndex.build([Fraction(0)])
            self.assertTrue(handles[0].closed)
            self.assertFalse(dirs[0].exists())

    def test_close_context_destructor_and_existing_window_invalidation(self):
        scope, dirs = self.temp_scope()
        with scope:
            with ExactPTSIndex.build([Fraction(0)]) as index:
                window = index.candidates(0, native_origin=Fraction(0))
                self.assertTrue(dirs[0].exists())
            index.close()
            self.assertFalse(dirs[0].exists())
            for read in (lambda: index.count, lambda: len(window), lambda: window[0],
                         lambda: index.candidates(0, native_origin=Fraction(0))):
                with self.assertRaisesRegex(PTSIndexError, 'closed'):
                    read()
            unused = ExactPTSIndex.build([Fraction(0)])
            reference = weakref.ref(unused)
            del unused
            gc.collect()
            self.assertIsNone(reference())
            self.assertFalse(dirs[1].exists())

    def test_build_failure_preserves_primary_error_when_close_also_raises(self):
        original = tempfile.TemporaryFile
        handles = []

        class FailingSpool:
            def __init__(self, inner):
                self.inner = inner
            def __getattr__(self, name):
                return getattr(self.inner, name)
            def write(self, value):
                raise OSError('primary disk write failure')
            def close(self):
                self.inner.close()
                raise OSError('secondary close flush failure')

        def spool(*args, **kwargs):
            inner = original(*args, **kwargs)
            handles.append(inner)
            return FailingSpool(inner)

        scope, dirs = self.temp_scope()
        with scope, patch.object(pts_index.tempfile, 'TemporaryFile', side_effect=spool):
            with self.assertRaisesRegex(OSError, 'primary disk write failure') as caught:
                ExactPTSIndex.build([Fraction(0)])
        self.assertIn('secondary close flush failure', str(caught.exception.__cause__))
        self.assertTrue(handles[0].closed)
        self.assertFalse(dirs[0].exists())

    def test_close_attempts_directory_cleanup_even_if_handle_remains_open_then_retries(self):
        scope, dirs = self.temp_scope()
        with scope:
            index = ExactPTSIndex.build([Fraction(0)])
            self.addCleanup(index.close)
            inner = index._stream

            class FailOnce:
                calls = 0
                def __getattr__(self, name):
                    return getattr(inner, name)
                def close(self):
                    self.calls += 1
                    if self.calls == 1:
                        raise OSError('handle remained open')
                    inner.close()

            wrapper = FailOnce()
            index._stream = wrapper
            directory = index._directory
            with patch.object(directory, 'cleanup', wraps=directory.cleanup) as cleanup:
                with self.assertRaisesRegex(OSError, 'handle remained open'):
                    index.close()
                self.assertEqual(cleanup.call_count, 1)
                self.assertFalse(inner.closed)
                self.assertIs(index._stream, wrapper)
                with self.assertRaisesRegex(PTSIndexError, 'closed'):
                    _ = index.count
                index.close()
            self.assertTrue(inner.closed)
            self.assertFalse(dirs[0].exists())

    def test_parallel_reads_do_not_mix_shared_seek_offsets(self):
        index = self.make(Fraction(i, 10) for i in range(100))
        def query(i):
            return index.canonical_time(i * 100000, source_origin=Fraction(0),
                native_origin=Fraction(0))
        requested = list(range(99, -1, -1)) * 3
        with ThreadPoolExecutor(max_workers=4) as executor:
            actual = list(executor.map(query, requested))
        self.assertEqual(actual, [Fraction(i, 10) for i in requested])


if __name__ == '__main__':
    unittest.main()
