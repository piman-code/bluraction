"""EOF/raw observation contract; fake seams do not prove PyAV/asset clock mapping.

Actual test reuses the authored MPEG4/PCM helper (no native H264 device). Missing
PyAV is an explicit skip, rejected by the required Windows family runner. This
file generates only test-owned media; no imports change an operating app.
"""
from fractions import Fraction
import hashlib
import importlib.util
from pathlib import Path
import struct
import tempfile
from threading import Event
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from platforms.windows.bluraction import frame_inventory as inventory
from platforms.windows.bluraction import media


def frame(pts=500, duration=40, **changes):
    fields = dict(pts=pts, duration=duration, time_base=Fraction(1, 1000), width=96, height=64,
                  rotation=0.0, sample_aspect_ratio=None, side_data={}, is_corrupt=False)
    fields.update(changes)
    return SimpleNamespace(**fields)


class Frames:
    def __init__(self, values, *, failure=None, on_eof=None, close_failure=None):
        self.values = iter(values); self.failure = failure; self.on_eof = on_eof
        self.close_failure = close_failure; self.closed = False; self.eof = False
    def __iter__(self): return self
    def __next__(self):
        try: return next(self.values)
        except StopIteration:
            if self.failure is not None: raise self.failure
            self.eof = True
            if self.on_eof is not None: self.on_eof()
            raise
    def close(self):
        self.closed = True
        if self.close_failure is not None: raise self.close_failure


class FakeContainer:
    def __init__(self, frames, *, on_close=None, close_failure=None, stream_count=1):
        self.frames = frames; self.on_close = on_close; self.close_failure = close_failure; self.closed = False
        video = SimpleNamespace(width=96, height=64, index=1, id=2, time_base=Fraction(1,1000),
                                codec_context=SimpleNamespace(sample_aspect_ratio=None), sample_aspect_ratio=None)
        self.streams = SimpleNamespace(video=[video]*stream_count)
    def __enter__(self): return self
    def __exit__(self, *args):
        self.closed = True
        if self.on_close is not None: self.on_close()
        if self.close_failure is not None: raise self.close_failure
    def decode(self, video): return self.frames


class FlakySpool:
    """Inject errors around a real private file, including after actual close."""
    def __init__(self, inner, *, write_failure=None, short_write=False, flush_failure=None,
                 close_failures=0, close_after_failure=False):
        self.inner = inner; self.write_failure = write_failure; self.short_write = short_write
        self.flush_failure = flush_failure; self.close_failures = close_failures
        self.close_after_failure = close_after_failure; self.close_calls = 0
    def __getattr__(self, name): return getattr(self.inner, name)
    def write(self, data):
        if self.write_failure is not None: raise self.write_failure
        return self.inner.write(data[:-1] if self.short_write else data)
    def flush(self):
        if self.flush_failure is not None: raise self.flush_failure
        return self.inner.flush()
    def close(self):
        self.close_calls += 1
        if self.close_failures:
            self.close_failures -= 1
            if self.close_after_failure: self.inner.close()
            raise OSError('synthetic private spool close failure')
        return self.inner.close()


class FlakyDirectory:
    def __init__(self, inner, failures=1):
        self.inner = inner; self.failures = failures; self.cleanup_calls = 0
    def __getattr__(self, name): return getattr(self.inner, name)
    def cleanup(self):
        self.cleanup_calls += 1
        if self.failures:
            self.failures -= 1
            raise PermissionError('synthetic owned directory cleanup failure')
        return self.inner.cleanup()


class FrameInventoryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(); self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name); self.source = self.root/'authored.mov'
        self.source.write_bytes(b'authored fake-decoder source bytes')
        self.original = self.source.read_bytes(); self.sha = hashlib.sha256(self.original).hexdigest()
        self.generation = 19; self.spools = []
        real_directory = tempfile.TemporaryDirectory
        def private_directory(*args, **kwargs):
            directory = real_directory(*args, **dict(kwargs, dir=self.root))
            self.spools.append(Path(directory.name)); return directory
        self.patch = patch.object(inventory.tempfile, 'TemporaryDirectory', side_effect=private_directory)
        self.patch.start(); self.addCleanup(self.patch.stop)

    def build(self, values=None, *, iterator=None, container=None, **kwargs):
        iterator = iterator or Frames([frame(500), frame(610, 90)] if values is None else values)
        container = container or FakeContainer(iterator)
        module = SimpleNamespace(__version__='19.0.0', open=lambda *a, **k: container)
        with patch.object(inventory, '_av', return_value=module):
            return inventory.FrameInventory.build(self.source, expected_sha256=self.sha,
                generation=self.generation, **kwargs)

    def assert_no_spools(self):
        self.assertTrue(all(not path.exists() for path in self.spools))

    def test_complete_eof_exact_records_bound_generation_and_idempotent_lifetime(self):
        rows = [frame(-100, 30), frame(100, 20), frame(300, 91)]
        frames = Frames(rows)
        result = self.build(iterator=frames)
        self.assertTrue(frames.eof); self.assertTrue(frames.closed)
        self.assertTrue(result.complete); self.assertEqual(len(result), 3)
        self.assertEqual([r.pts for r in result], [Fraction(-1,10), Fraction(1,10), Fraction(3,10)])
        self.assertEqual(result[-1].duration, Fraction(91,1000))
        self.assertEqual(result[-1].raw_pts, 300); self.assertEqual(result[-1].raw_duration, 91)
        self.assertEqual(result.source_sha256, self.sha); self.assertEqual(result.generation, 19)
        self.assertEqual(result.decoder.clock, 'pyav-decoded-observation')
        self.assertEqual(result.decoder.canonical_asset_mapping, 'unproven')
        result.require_binding(source_sha256=self.sha, generation=19)
        for arguments in (dict(source_sha256='0'*64, generation=19), dict(source_sha256=self.sha, generation=20),
                          dict(source_sha256=self.sha, generation=True)):
            with self.assertRaises(inventory.FrameInventoryError): result.require_binding(**arguments)
        with self.assertRaises(AttributeError): result.generation = 20
        with self.assertRaises(inventory.FrameInventoryError): result[:]
        with self.assertRaises(IndexError): result[3]
        result.close(); result.close(); self.assert_no_spools()
        self.assertFalse(result.complete)
        with self.assertRaises(inventory.FrameInventoryError): len(result)
        self.assertEqual(self.source.read_bytes(), self.original)

    def test_context_manager_cleans_private_spool(self):
        with self.build() as result:
            self.assertTrue(result.complete)
        self.assert_no_spools()
        with self.assertRaises(inventory.FrameInventoryError): result[0]

    def test_write_short_write_and_flush_failure_clean_attempt_preserve_primary_and_old_inventory(self):
        real_file = tempfile.TemporaryFile
        with self.build() as old:
            old_first = old[0]
            write_error, flush_error = OSError('primary private write failure'), OSError('primary private flush failure')
            for changes, expected_error in ((dict(write_failure=write_error), write_error),
                                             (dict(short_write=True), None),
                                             (dict(flush_failure=flush_error), flush_error)):
                with self.subTest(changes=changes):
                    with patch.object(inventory.tempfile, 'TemporaryFile',
                                      side_effect=lambda *a, **k: FlakySpool(real_file(*a, **k), **changes)):
                        with self.assertRaises((OSError, inventory.FrameInventoryError)) as caught:
                            self.build()
                    if expected_error is not None: self.assertIs(caught.exception, expected_error)
                    self.assertEqual(old[0], old_first); self.assertTrue(old.complete)
                    self.assertEqual(self.source.read_bytes(), self.original)
                    self.assertTrue(all(not path.exists() for path in self.spools[1:]))
        self.assert_no_spools()

    def test_close_failure_before_or_after_actual_fd_close_and_directory_cleanup_can_retry(self):
        for close_after in (False, True):
            with self.subTest(close_after=close_after):
                result = self.build()
                stream = FlakySpool(result._stream, close_failures=1, close_after_failure=close_after)
                directory = FlakyDirectory(result._directory)
                result._stream, result._directory = stream, directory
                with self.assertRaisesRegex(OSError, 'private spool close failure') as caught:
                    result.close()
                self.assertIsInstance(caught.exception.__cause__, PermissionError)
                self.assertTrue(any('directory cleanup also failed' in note for note in caught.exception.__notes__))
                self.assertFalse(result.complete)
                self.assertIs(result._directory, directory)
                self.assertTrue(Path(directory.name).exists())
                self.assertIs(result._stream, None if close_after else stream)
                with self.assertRaises(inventory.FrameInventoryError): result[0]
                result.close()
                self.assertEqual(stream.close_calls, 1 if close_after else 2)
                self.assertEqual(directory.cleanup_calls, 2)
                self.assertIsNone(result._stream); self.assertIsNone(result._directory)
                result.close()  # No successful stage is called a third time.
                self.assertEqual(directory.cleanup_calls, 2)
                self.assert_no_spools()
                self.assertEqual(self.source.read_bytes(), self.original)

    def test_directory_only_cleanup_failure_keeps_own_reference_and_closed_properties_reject(self):
        result = self.build(); directory = FlakyDirectory(result._directory)
        result._directory = directory
        with self.assertRaises(PermissionError): result.close()
        self.assertIsNone(result._stream); self.assertIs(result._directory, directory)
        self.assertFalse(result.complete)
        for lookup in (lambda: result.decoder, lambda: result.source_sha256, lambda: result.generation,
                       lambda: result.source_identity, lambda: result.__enter__,
                       lambda: result.require_binding(source_sha256=self.sha, generation=19)):
            # __enter__ must actually be invoked, not just retrieve its method.
            with self.assertRaises(inventory.FrameInventoryError):
                returned = lookup()
                if callable(returned): returned()
        result.close(); self.assertEqual(directory.cleanup_calls, 2); self.assert_no_spools()

    def test_build_decoder_or_cancel_primary_survives_teardown_failure_and_exposes_owned_retry(self):
        real_file = tempfile.TemporaryFile
        original_factory = inventory.tempfile.TemporaryDirectory
        created = []
        def failing_directory(*args, **kwargs):
            owned = FlakyDirectory(original_factory(*args, **kwargs)); created.append(owned); return owned
        for cancelled in (False, True):
            event = Event()
            primary = None if cancelled else RuntimeError('primary decoded failure')
            frames = Frames([frame()], on_eof=event.set) if cancelled else Frames([frame()], failure=primary)
            with patch.object(inventory.tempfile, 'TemporaryFile',
                              side_effect=lambda *a, **k: FlakySpool(real_file(*a, **k), close_failures=1)), \
                 patch.object(inventory.tempfile, 'TemporaryDirectory', side_effect=failing_directory):
                with self.assertRaises(inventory.InventoryCancelled if cancelled else RuntimeError) as caught:
                    self.build(iterator=frames, cancel=event)
            if cancelled:
                self.assertTrue(event.is_set()); self.assertTrue(frames.eof)
                self.assertIn('frame inventory cancelled', str(caught.exception))
            else:
                self.assertIs(caught.exception, primary)
            self.assertIsInstance(caught.exception.__cause__, OSError)
            self.assertTrue(any('inventory cleanup also failed' in note for note in caught.exception.__notes__))
            self.assertTrue(callable(caught.exception.retry_inventory_cleanup))
            self.assertTrue(frames.closed)
            self.assertTrue(Path(created[-1].name).exists())
            caught.exception.retry_inventory_cleanup()
            caught.exception.retry_inventory_cleanup()
            self.assertEqual(created[-1].cleanup_calls, 2)
            self.assert_no_spools(); self.assertEqual(self.source.read_bytes(), self.original)

    def test_build_primary_write_or_flush_failure_with_cleanup_failure_is_not_replaced(self):
        real_file = tempfile.TemporaryFile
        for operation in ('write', 'flush'):
            with self.subTest(operation=operation):
                primary = OSError('original ' + operation + ' exception')
                options = {operation + '_failure': primary, 'close_failures': 1}
                with patch.object(inventory.tempfile, 'TemporaryFile',
                                  side_effect=lambda *a, **k: FlakySpool(real_file(*a, **k), **options)):
                    with self.assertRaises(OSError) as caught: self.build()
                self.assertIs(caught.exception, primary)
                self.assertEqual(str(caught.exception), 'original ' + operation + ' exception')
                self.assertTrue(any('cleanup also failed' in note for note in caught.exception.__notes__))
                # On POSIX the private directory may already be removed while
                # its file remains open; Windows may need a removal retry too.
                caught.exception.retry_inventory_cleanup()
                self.assert_no_spools(); self.assertEqual(self.source.read_bytes(), self.original)

    def test_context_body_primary_survives_cleanup_error_and_own_cleanup_is_retryable(self):
        result = self.build(); result._directory = FlakyDirectory(result._directory)
        primary = RuntimeError('body primary error')
        with self.assertRaises(RuntimeError) as caught:
            with result: raise primary
        self.assertIs(caught.exception, primary)
        self.assertIsInstance(caught.exception.__cause__, PermissionError)
        caught.exception.retry_inventory_cleanup()
        self.assert_no_spools()

    def test_metadata_queries_hold_lock_against_concurrent_close_until_check_and_return(self):
        # Make the existing lock observable without sleeps or relying on thread
        # scheduling. Each getter must return under a lock that close also takes.
        result = self.build()
        class GuardedLock:
            held = False
            def __enter__(self): self.held = True
            def __exit__(self, *args): self.held = False
        guard = GuardedLock(); actual_require = result._require_open
        def checked():
            self.assertTrue(guard.held, 'check and metadata return must share the close lock')
            actual_require()
        result._lock = guard
        with patch.object(result, '_require_open', side_effect=checked):
            self.assertEqual(result.decoder.clock, 'pyav-decoded-observation')
            self.assertEqual(result.source_sha256, self.sha); self.assertEqual(result.generation, 19)
            self.assertEqual(result.source_identity.canonical, str(self.source.resolve()))
            result.require_binding(source_sha256=self.sha, generation=19)
            self.assertIs(result.__enter__(), result)
        # complete() has no _require_open, so observe its state read itself.
        class ObservedBoolean:
            def __bool__(self):
                self_test.assertTrue(guard.held); return True
        self_test = self; result._complete = ObservedBoolean()
        self.assertTrue(result.complete)
        result._complete = True; result.close(); self.assert_no_spools()

    def test_missing_duration_and_pts_are_not_guessed_duplicate_or_out_of_order_reject(self):
        cases = [[frame(500, 0)], [frame(500, None)], [frame(None)], [frame(500, True)],
                 [frame(time_base=None)], [frame(time_base=.001)], [frame(time_base=Fraction(0))],
                 [frame(500), frame(500)], [frame(500), frame(499)], [frame(is_corrupt=True)]]
        for values in cases:
            with self.subTest(values=values):
                with self.assertRaises(inventory.FrameInventoryError): self.build(values)
                self.assert_no_spools()
        self.assertEqual(self.source.read_bytes(), self.original)

    def test_fraction_boundary_rejects_primitives_and_forged_duck_class(self):
        class Duck:
            numerator, denominator = 1, 12288
        class FractionSubclass(Fraction):
            pass
        for value in (True, False, 1, .001, '1/12288', None, Duck(), FractionSubclass(1,12288)):
            with self.subTest(value=value):
                with self.assertRaises(inventory.FrameInventoryError):
                    inventory._fraction(value, 'test time_base')
                with self.assertRaises(inventory.FrameInventoryError):
                    inventory._exact_fraction(value, 'test exact boundary')
        self.assertEqual(inventory._fraction(Fraction(1,12288), 'test'), Fraction(1,12288))

    def test_raw_signed64_and_exact_fraction_representation_fail_without_rounding(self):
        for value in (True, 1.0, inventory.INT64_MAX+1, inventory.INT64_MIN-1):
            with self.subTest(pts=value):
                with self.assertRaises(inventory.FrameInventoryError): self.build([frame(value)])
        with self.assertRaises(inventory.FrameInventoryError): self.build([frame(duration=inventory.INT64_MAX+1)])
        with self.assertRaises(inventory.FrameInventoryError): self.build([frame(time_base=Fraction(1, 1<<129))])
        with self.build([frame(inventory.INT64_MIN, 1, time_base=Fraction(1, 1_000_000_007))]) as result:
            self.assertEqual(result[0].pts, Fraction(inventory.INT64_MIN, 1_000_000_007))
        self.assert_no_spools()

    def test_sar_matrix_rotation_observations_preserved_without_display_normalization(self):
        matrix = struct.pack('=9i', 0,-65536,0,65536,0,0,0,0,1<<30)
        values = [frame(500, sample_aspect_ratio=Fraction(4,3), rotation=90., side_data={'DISPLAYMATRIX': matrix}),
                  frame(600, sample_aspect_ratio=Fraction(0), rotation=12.5), frame(700)]
        with self.build(values) as result:
            self.assertEqual(result[0].frame_sar, Fraction(4,3)); self.assertEqual(result[0].display_matrix, matrix)
            self.assertEqual((result[0].width, result[0].height, result[0].rotation), (96,64,90.))
            self.assertEqual(result[1].frame_sar, Fraction(0)); self.assertEqual(result[1].rotation, 12.5)
            self.assertIsNone(result[2].frame_sar); self.assertIsNone(result.decoder.codec_sar)
            self.assertIsNone(result.decoder.guessed_stream_sar)
        for bad in (frame(side_data={'DISPLAYMATRIX': b'bad'}), frame(rotation=float('nan')),
                    frame(sample_aspect_ratio=Fraction(-1)), frame(width=0)):
            with self.assertRaises(inventory.FrameInventoryError): self.build([bad])
        self.assert_no_spools()

    def test_budget_error_preserves_old_inventory_and_source_and_cleans_new_attempt(self):
        old = self.build()
        try:
            old_first = old[0]
            for limits in (inventory.InventoryLimits(max_frames=1), inventory.InventoryLimits(max_spool_bytes=inventory.RECORD_BYTES),
                           inventory.InventoryLimits(max_pixels=1)):
                with self.assertRaises(inventory.FrameInventoryError): self.build(limits=limits)
                self.assertEqual(old[0], old_first); self.assertTrue(old.complete)
                self.assertEqual(self.source.read_bytes(), self.original)
                self.assertTrue(all(not path.exists() for path in self.spools[1:]))
        finally: old.close()
        self.assert_no_spools()

    def test_decode_exception_empty_eof_iterator_close_or_container_close_fail_without_commit(self):
        for frames, container_error in ((Frames([], failure=RuntimeError('decoder failed')), None),
                                        (Frames([]), None),
                                        (Frames([frame()], close_failure=RuntimeError('iterator close failed')), None),
                                        (Frames([frame()]), RuntimeError('codec close failed'))):
            container = FakeContainer(frames, close_failure=container_error)
            with self.assertRaises((inventory.FrameInventoryError, RuntimeError)):
                self.build(iterator=frames, container=container)
            self.assertTrue(frames.closed); self.assertTrue(container.closed); self.assert_no_spools()
        for count in (0,2):
            with self.assertRaises(inventory.FrameInventoryError):
                self.build(container=FakeContainer(Frames([frame()]), stream_count=count))
            self.assert_no_spools()

    def test_cancel_before_decode_and_at_eof_or_after_final_hash_leaves_old_inventory(self):
        with self.build() as old:
            event = Event(); event.set()
            with self.assertRaises(inventory.InventoryCancelled): self.build(cancel=event)
            event.clear(); iterator = Frames([frame()], on_eof=event.set)
            with self.assertRaises(inventory.InventoryCancelled): self.build(iterator=iterator, cancel=event)
            self.assertTrue(iterator.closed)
            event.clear(); actual_hash = media.fingerprint; calls = []
            def cancel_after_hash(*args, **kwargs):
                result = actual_hash(*args, **kwargs); calls.append(True)
                if len(calls) == 2: event.set()
                return result
            with patch.object(media, 'fingerprint', side_effect=cancel_after_hash):
                with self.assertRaises(inventory.InventoryCancelled): self.build(cancel=event)
            self.assertEqual(len(calls), 2); self.assertTrue(old.complete)
            self.assertTrue(all(not path.exists() for path in self.spools[1:]))
        self.assert_no_spools(); self.assertEqual(self.source.read_bytes(), self.original)

    def test_generation_change_and_callback_exception_at_eof_do_not_commit(self):
        current = [19]
        frames = Frames([frame()], on_eof=lambda: current.__setitem__(0,20))
        with self.assertRaises(inventory.FrameInventoryError): self.build(iterator=frames, current_generation=lambda: current[0])
        self.assert_no_spools()
        def failure(): raise RuntimeError('generation owner unavailable')
        with self.assertRaisesRegex(RuntimeError, 'generation owner unavailable'): self.build(current_generation=failure)
        self.assert_no_spools()
        eof_owner_failed = [False]
        def current_until_eof():
            if eof_owner_failed[0]: raise RuntimeError('generation callback failed after EOF')
            return 19
        frames = Frames([frame()], on_eof=lambda: eof_owner_failed.__setitem__(0, True))
        with self.assertRaisesRegex(RuntimeError, 'generation callback failed after EOF'):
            self.build(iterator=frames, current_generation=current_until_eof)
        self.assertTrue(frames.closed); self.assert_no_spools()
        for bad in (True, -1, 1.0, inventory.INT64_MAX+1):
            with self.assertRaises(inventory.FrameInventoryError):
                inventory.FrameInventory.build(self.source, expected_sha256=self.sha, generation=bad)

    def test_source_change_after_codec_close_and_wrong_saved_sha_never_commit_or_rewrite(self):
        replacement = b'authored replacement changed by test, not inventory'
        actual_hash = media.fingerprint
        calls = []
        def replace_after_fd_closed(*args, **kwargs):
            calls.append(True)
            if len(calls) == 2:
                # The decoder's descriptor has actually closed before final
                # hashing. Do not require Windows while-open replacement.
                self.source.write_bytes(replacement)
            return actual_hash(*args, **kwargs)
        with patch.object(media, 'fingerprint', side_effect=replace_after_fd_closed):
            with self.assertRaises(ValueError): self.build()
        self.assertEqual(len(calls), 2)
        self.assertEqual(self.source.read_bytes(), replacement); self.assert_no_spools()
        self.source.write_bytes(self.original)
        with self.assertRaises(inventory.FrameInventoryError):
            inventory.FrameInventory.build(self.source, expected_sha256='0'*64, generation=19)
        self.assertEqual(self.source.read_bytes(), self.original); self.assert_no_spools()

    def test_generation_callback_source_change_after_final_hash_is_guarded_before_commit(self):
        hash_calls = []
        actual_hash = media.fingerprint
        final_hash_done = [False]
        def hash_and_mark(*args, **kwargs):
            result = actual_hash(*args, **kwargs); hash_calls.append(True)
            if len(hash_calls) == 2: final_hash_done[0] = True
            return result
        replacement = b'test-triggered external source change after final hash'
        def generation_owner():
            if final_hash_done[0]:
                self.source.write_bytes(replacement)
                final_hash_done[0] = False
            return 19
        with patch.object(media, 'fingerprint', side_effect=hash_and_mark):
            with self.assertRaises(ValueError): self.build(current_generation=generation_owner)
        self.assertEqual(len(hash_calls), 2); self.assert_no_spools()
        self.assertEqual(self.source.read_bytes(), replacement, 'Inventory must not overwrite the changed source')

    def test_bounded_input_uses_owned_descriptor_not_reopened_path_and_limits_each_read(self):
        observed = []
        def opening(stream, **kwargs):
            self.assertIsInstance(stream, inventory._BoundedInput)
            observed.append(stream.read(-1))
            stream.seek(0); self.assertEqual(stream.read(4), self.original[:4])
            return FakeContainer(Frames([frame()]))
        with patch.object(inventory, '_av', return_value=SimpleNamespace(__version__='19.0.0', open=opening)):
            with inventory.FrameInventory.build(self.source, expected_sha256=self.sha, generation=19) as result:
                self.assertTrue(result.complete)
        self.assertEqual(observed, [self.original]); self.assert_no_spools()

    def test_demux_choices_recorded_explicitly_and_never_claim_asset_clock(self):
        with self.build(demux_options={'ignore_editlist':'1', 'advanced_editlist':'0'}) as result:
            self.assertEqual(dict(result.decoder.demux_options), {'ignore_editlist':'1', 'advanced_editlist':'0'})
            self.assertEqual(result.decoder.canonical_asset_mapping, 'unproven')
            self.assertEqual(result[0].pts, Fraction(1,2))
        for options in ({'ignore_editlist':'yes'}, {'some_unknown_option':'1'}):
            with self.assertRaises(inventory.FrameInventoryError): self.build(demux_options=options)
        for token in (lambda: None, lambda: 1, object()):
            with self.assertRaises(inventory.FrameInventoryError): self.build(cancel=token)
        self.assert_no_spools()


@unittest.skipUnless(importlib.util.find_spec('av') is not None,
                     'Actual PyAV19 decoded EOF proof unavailable: isolated runtime missing')
class ActualFrameInventoryTests(unittest.TestCase):
    def test_native_avrational_integer_boundary_exact_controls_and_zero_denominator_rejection(self):
        from av.rational import AVRational
        for num, den in ((1,12288), (4,3), (2,6), (0,1)):
            native = AVRational(num,den)
            self.assertIs(type(native.numerator), int); self.assertIs(type(native.denominator), int)
            self.assertEqual(inventory._exact_fraction(native, 'native observed'), Fraction(num,den))
            self.assertEqual(inventory._sar(native, 'native SAR'), Fraction(num,den))
        with self.assertRaises(inventory.FrameInventoryError):
            inventory._fraction(AVRational(0,1), 'native time_base')
        for num, den in ((1,0), (-1,0), (0,0)):
            native = AVRational(num,den)
            with self.subTest(native=native):
                with self.assertRaises(inventory.FrameInventoryError): inventory._exact_fraction(native, 'native')
                with self.assertRaises(inventory.FrameInventoryError): inventory._sar(native, 'native SAR')
        forged = type('AVRational', (), {'__module__':'av.rational', 'numerator':1, 'denominator':12288})()
        with self.assertRaises(inventory.FrameInventoryError): inventory._exact_fraction(forged, 'forged native')
        # Large signed64 ticks multiply only after conversion to Fraction; no
        # native-native int32 arithmetic or approximate float intermediates.
        native = AVRational(1,12288)
        observation = inventory._observe(frame(inventory.INT64_MAX, 91, time_base=native,
                                              sample_aspect_ratio=AVRational(4,3)), inventory.InventoryLimits())
        self.assertEqual(observation.pts, Fraction(inventory.INT64_MAX,12288))
        self.assertEqual(observation.duration, Fraction(91,12288))
        self.assertEqual(observation.frame_sar, Fraction(4,3))

    def test_actual_mpeg4_pcm_vfr_rotation_eof_matches_direct_decoder_without_origin_shift(self):
        # Reuse only the existing public synthetic generator. It uses LGPL
        # built-in MPEG4+PCM, no VT/MF/H264 encoder, no CLI or downloads.
        from Tests.WindowsAppTests.test_video import VideoTests, PTS
        av = inventory._av()
        helper = VideoTests(methodName='test_actual_container_rotation_is_applied_once_to_decoded_pixels')
        with tempfile.TemporaryDirectory() as directory:
            for rotation in (0,90):
                with self.subTest(rotation=rotation):
                    path = Path(directory)/f'authored-{rotation}.mov'
                    helper.make_source(path, audio=True, rotation=rotation)
                    original = path.read_bytes(); digest = hashlib.sha256(original).hexdigest()
                    with av.open(str(path)) as container:
                        video = container.streams.video[0]
                        expected = []
                        for decoded in container.decode(video):
                            # Independent oracle crosses the documented native
                            # integer boundary explicitly, without _observe.
                            def exact(raw):
                                if raw is None: return None
                                self.assertIs(type(raw.numerator), int)
                                self.assertIs(type(raw.denominator), int)
                                self.assertGreater(raw.denominator, 0)
                                return Fraction(raw.numerator, raw.denominator)
                            base = exact(decoded.time_base)
                            matrix = decoded.side_data.get('DISPLAYMATRIX')
                            expected.append(inventory.FrameObservation(
                                Fraction(decoded.pts)*base, Fraction(decoded.duration)*base,
                                base, decoded.pts, decoded.duration, decoded.width, decoded.height,
                                exact(getattr(decoded, 'sample_aspect_ratio', None)), float(decoded.rotation),
                                bytes(matrix) if matrix is not None else None))
                    self.assertEqual([row.pts for row in expected], [Fraction(pts,1000) for pts in PTS])
                    self.assertEqual([row.duration for row in expected],
                                     [Fraction(ticks,1000) for ticks in (40,90,70,230,80)])
                    self.assertTrue(all(row.duration > 0 for row in expected))
                    with inventory.FrameInventory.build(path, expected_sha256=digest, generation=7) as result:
                        self.assertEqual(list(result), expected)
                        self.assertEqual(result[-1].pts, expected[-1].pts)
                        self.assertEqual(result[-1].duration, expected[-1].duration)
                        self.assertEqual(result.decoder.canonical_asset_mapping, 'unproven')
                        self.assertEqual(result.source_sha256, digest)
                        self.assertEqual(result[0].rotation, float(rotation))
                    self.assertEqual(path.read_bytes(), original)


if __name__ == '__main__':
    unittest.main()
