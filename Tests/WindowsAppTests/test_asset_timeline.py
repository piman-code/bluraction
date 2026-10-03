"""Pure authored ISO BMFF structural/timeline tests; no Qt/PyAV/native claims."""
from dataclasses import replace
from fractions import Fraction
import hashlib
import json
import os
from pathlib import Path
import struct
import tempfile
from threading import Event
import unittest
from unittest.mock import patch

from platforms.windows.bluraction import asset_timeline as timeline


def box(kind, body=b'', extended=False, to_eof=False):
    if extended:
        return struct.pack('>I4sQ', 1, kind, 16 + len(body)) + body
    return struct.pack('>I4s', 0 if to_eof else 8 + len(body), kind) + body


def full(body=b'', version=0, flags=0):
    return bytes([version]) + flags.to_bytes(3, 'big') + body


def time_header(kind, scale, ticks, version=0):
    dates = struct.pack('>QQ' if version else '>II', 0, 0)
    timing = struct.pack('>IQ' if version else '>II', scale, ticks)
    tail = bytes(80 if kind == b'mvhd' else 4)
    return box(kind, full(dates + timing + tail, version))


def track_header(identity, ticks, version=0, flags=7):
    dates = struct.pack('>QQ' if version else '>II', 0, 0)
    body = dates + struct.pack('>II', identity, 0) + struct.pack('>Q' if version else '>I', ticks) + bytes(60)
    return box(b'tkhd', full(body, version, flags))


def edits(entries, version=0):
    data = b''.join(struct.pack('>Qqi' if version else '>Iii', duration, media, int(Fraction(rate) * 65536))
                    for duration, media, rate in entries)
    return box(b'edts', box(b'elst', full(struct.pack('>I', len(entries)) + data, version)))


def stts(entries):
    return box(b'stts', full(struct.pack('>I', len(entries))
                             + b''.join(struct.pack('>II', count, delta) for count, delta in entries)))


def track(identity=1, ticks=1000, media_scale=1000, media_ticks=2000,
          entries=None, version=0, handler=b'vide', timing_entries=((2, 1000),), extra_sample=b'', extra=b''):
    timing = b'' if timing_entries is None else stts(timing_entries)
    sample = box(b'minf', box(b'stbl', timing + extra_sample))
    media = box(b'mdia', time_header(b'mdhd', media_scale, media_ticks, version)
                + box(b'hdlr', full(bytes(4) + handler + bytes(12))) + sample)
    edit = b'' if entries is None else edits(entries, version)
    return box(b'trak', track_header(identity, ticks, version) + media + edit + extra)


def movie(tracks=None, scale=1000, ticks=1000, version=0, extra=b'', top=b'', extended=False):
    body = time_header(b'mvhd', scale, ticks, version) + (track() if tracks is None else tracks) + extra
    return box(b'ftyp', b'isom' + bytes(4) + b'isom') + top + box(b'moov', body, extended)


class AssetTimelineTests(unittest.TestCase):
    def test_v0_empty_leading_gap_media_and_asset_clocks_are_distinct(self):
        data = movie(track(ticks=1500, entries=((500, -1, 1), (1000, 0, 1))), ticks=1500)
        parsed = timeline.parse_asset_timeline(data)
        video = parsed.track(1)
        self.assertEqual(parsed.asset_duration, Fraction(3, 2))
        self.assertEqual(video.media_duration, Fraction(2))
        self.assertEqual(video.asset_to_media(Fraction(1, 4)), None)
        self.assertEqual(video.asset_to_media(Fraction(1, 2)), Fraction(0))
        self.assertEqual(video.media_to_asset(Fraction(1, 4)), (Fraction(3, 4),))
        self.assertEqual(video.mapping_basis, 'explicit-edit-list')
        self.assertIn('unproven', parsed.decoder_raw_relation)
        self.assertFalse(hasattr(video, 'raw_pts_origin'))

    def test_trim_empty_middle_and_repeated_media_preserve_all_matches(self):
        segments = ((500, 250, 1), (500, -1, 1), (500, 250, 1))
        video = timeline.parse_asset_timeline(movie(track(ticks=1500, entries=segments), ticks=1500)).track(1)
        self.assertEqual(video.asset_to_media(Fraction(1, 4)), Fraction(1, 2))
        self.assertIsNone(video.asset_to_media(Fraction(3, 4)))
        self.assertEqual(video.asset_to_media(Fraction(5, 4)), Fraction(1, 2))
        self.assertEqual(video.media_to_asset(Fraction(1, 2)), (Fraction(1, 4), Fraction(5, 4)))
        self.assertEqual(video.media_to_asset(Fraction(2)), ())
        with self.assertRaisesRegex(timeline.TimelineCannotMap, 'outside'):
            video.asset_to_media(Fraction(3, 2))

    def test_v1_uint64_header_and_signed64_edits_are_exact_not_float(self):
        big = (1 << 32) + 123
        parsed = timeline.parse_asset_timeline(movie(
            track(ticks=big, media_scale=48000, media_ticks=big * 48,
                  entries=((big, (1 << 32) + 7, 1),), version=1), ticks=big, version=1))
        self.assertEqual(parsed.asset_duration, Fraction(big, 1000))
        video = parsed.track(1)
        self.assertEqual(video.segments[0].media_start, Fraction((1 << 32) + 7, 48000))
        self.assertEqual(video.asset_to_media(Fraction(1, 1000)), video.segments[0].media_start + Fraction(1, 1000))

    def test_media_timescale_differs_from_movie_and_stts_is_decode_clock(self):
        video = timeline.parse_asset_timeline(movie(track(media_scale=48000, media_ticks=96000,
            entries=((1000, 12000, 1),), timing_entries=((2, 24000), (1, 12000)),
            extra_sample=box(b'ctts', full(struct.pack('>III', 1, 3, 24000)))))).track(1)
        self.assertEqual(video.asset_to_media(Fraction(1, 2)), Fraction(3, 4))
        self.assertEqual(video.sample_count, 3)
        self.assertEqual(video.decode_duration, Fraction(5, 4))
        self.assertEqual(video.unparsed_sample_timing_boxes, ('ctts',))
        self.assertEqual(video.media_duration, 2)
        # No method pretends stts proves composition PTS/frame identity.
        self.assertFalse(hasattr(video, 'frame_pts'))

    def test_audio_suffix_shorter_than_asset_and_track_id_selection(self):
        parsed = timeline.parse_asset_timeline(movie(track(identity=10, ticks=3200, entries=((3200, 0, 1),))
            + track(identity=20, ticks=1200, handler=b'soun', entries=((1200, 0, 1),)), ticks=3200))
        parsed.require_mappable()
        self.assertEqual(parsed.track(20).kind, 'audio')
        self.assertEqual(parsed.track(20).track_duration, Fraction(6, 5))
        self.assertEqual(parsed.asset_duration, Fraction(16, 5))
        for identity in (True, 0, 999):
            with self.assertRaises(timeline.TimelineCannotMap):
                parsed.track(identity)

    def test_no_edit_list_identity_is_explicit_and_eof_never_guessed(self):
        video = timeline.parse_asset_timeline(movie()).track(1)
        self.assertEqual(video.mapping_basis, 'implicit-identity-without-edit-list')
        self.assertFalse(video.edit_list_present)
        self.assertEqual(video.asset_to_media(Fraction(1, 3)), Fraction(1, 3))
        for value in (Fraction(1), Fraction(-1), .5, True, 0):
            with self.assertRaises(timeline.TimelineCannotMap):
                video.asset_to_media(value)
        with self.assertRaises(timeline.TimelineCannotMap):
            video.media_to_asset(.5)

    def test_affine_mapping_does_not_claim_frames_exist_or_clamp_composition_to_decode_duration(self):
        # No-elst identity and explicit edits can mathematically map beyond mdhd
        # media duration; ctts/frame witnesses, not header-length guesses, decide
        # whether a composition frame exists at that point.
        for data in (movie(track(ticks=2000, media_ticks=1000), ticks=2000),
                     movie(track(media_ticks=1000, entries=((1000, 1500, 1),)))):
            video = timeline.parse_asset_timeline(data).track(1)
            video.require_mappable()
            mapped = video.asset_to_media(Fraction(3, 4))
            self.assertGreater(mapped, 0)
            if video.edit_list_present:
                self.assertEqual(mapped, Fraction(9, 4))
                self.assertGreater(mapped, video.media_duration)
            else:
                self.assertEqual(video.asset_to_media(Fraction(3, 2)), Fraction(3, 2))
            self.assertFalse(hasattr(video, 'composition_frames_verified'))

    def test_non_unit_dwell_reverse_and_fractional_rates_retain_metadata_but_block(self):
        for rate in (0, 2, -1, Fraction(1, 2)):
            with self.subTest(rate=rate):
                video = timeline.parse_asset_timeline(movie(track(entries=((1000, 0, rate),)))).track(1)
                self.assertEqual(video.segments[0].rate, rate)
                self.assertIn('unsupported_edit_rate', video.mapping_issues)
                with self.assertRaises(timeline.TimelineCannotMap):
                    video.asset_to_media(Fraction(1, 4))
        for entries in ((), ((0, 0, 1),)):
            video = timeline.parse_asset_timeline(movie(track(entries=entries))).track(1)
            with self.assertRaises(timeline.TimelineCannotMap):
                video.require_mappable()

    def test_unknown_duration_fragmented_and_inconsistent_metadata_never_fallback(self):
        parsed = timeline.parse_asset_timeline(movie(ticks=(1 << 32) - 1))
        self.assertIsNone(parsed.asset_duration)
        with self.assertRaises(timeline.TimelineCannotMap):
            parsed.require_mappable()
        parsed = timeline.parse_asset_timeline(movie(extra=box(b'mvex'), top=box(b'moof')))
        self.assertIn('fragmented_movie_not_mapped', parsed.mapping_issues)
        with self.assertRaises(timeline.TimelineCannotMap):
            parsed.track(1).require_mappable()
        for data in (movie(track(entries=((500, 0, 1),))), movie(track(ticks=2000))):
            parsed = timeline.parse_asset_timeline(data)
            with self.assertRaises(timeline.TimelineCannotMap):
                parsed.require_mappable()
        parsed = timeline.parse_asset_timeline(movie(track(handler=b'meta')))
        self.assertEqual(parsed.track(1).kind, 'other')
        with self.assertRaises(timeline.TimelineCannotMap):
            parsed.require_mappable()

    def test_missing_and_duplicate_boxes_and_ids_are_malformed(self):
        for data in (box(b'moov'), movie(track() + track()),
                     movie(extra=time_header(b'mvhd', 1000, 1000)),
                     movie(track(extra=track_header(1, 1000))), movie() + movie()):
            with self.subTest(dataLength=len(data)):
                with self.assertRaises(timeline.TimelineParseError):
                    timeline.parse_asset_timeline(data)

    def test_zero_timescale_invalid_negative_edit_and_unsupported_versions(self):
        for data in (movie(scale=0), movie(track(media_scale=0)),
                     movie(track(entries=((1000, -2, 1),)))):
            with self.assertRaises(timeline.TimelineParseError):
                timeline.parse_asset_timeline(data)
        valid = movie()
        changed = bytearray(valid)
        changed[valid.index(b'mvhd') + 4] = 2
        with self.assertRaises(timeline.TimelineCannotMap):
            timeline.parse_asset_timeline(bytes(changed))
        changed = bytearray(valid)
        changed[valid.index(b'mdhd') + 7] = 1
        with self.assertRaises(timeline.TimelineCannotMap):
            timeline.parse_asset_timeline(bytes(changed))

    def test_extended_and_eof_box_sizes_and_enclosing_overflow(self):
        timeline.parse_asset_timeline(movie(extended=True) + box(b'mdat', b'opaque', to_eof=True))
        for data in (b'\0' * 7, struct.pack('>I4s', 7, b'free'),
                     struct.pack('>I4sQ', 1, b'moov', 15),
                     struct.pack('>I4sQ', 1, b'moov', (1 << 64) - 1),
                     box(b'uuid', b'bad'), movie(extra=box(b'free', to_eof=True)) + box(b'mdat')):
            with self.assertRaises(timeline.TimelineParseError):
                timeline.parse_asset_timeline(data)

    def test_table_lengths_huge_counts_and_cumulative_overflow_fail_before_allocation(self):
        bad_stts = box(b'stts', full(struct.pack('>I', 0xFFFFFFFF)))
        with self.assertRaises(timeline.TimelineLimitError):
            timeline.parse_asset_timeline(movie(track(timing_entries=None, extra_sample=bad_stts)))
        truncated = box(b'stts', full(struct.pack('>I', 2) + struct.pack('>II', 1, 100)))
        with self.assertRaises(timeline.TimelineParseError):
            timeline.parse_asset_timeline(movie(track(timing_entries=None, extra_sample=truncated)))
        with self.assertRaises(timeline.TimelineParseError):
            timeline.parse_asset_timeline(movie(track(version=1, ticks=10,
                entries=(((1 << 64) - 2, 0, 1), (100, 0, 1))), version=1))
        with self.assertRaises(timeline.TimelineParseError):
            timeline.parse_asset_timeline(movie(track(timing_entries=((0xFFFFFFFF, 0xFFFFFFFF),) * 2)))
        with self.assertRaises(timeline.TimelineCannotMap):
            timeline.parse_asset_timeline(movie(track(timing_entries=((1, 0),))))

    def test_metadata_box_track_depth_and_total_table_limits(self):
        limits = timeline.TimelineLimits()
        cases = [(movie(), replace(limits, max_metadata_bytes=100)),
                 (movie(), replace(limits, max_boxes=2)),
                 (movie(track() + track(identity=2)), replace(limits, max_tracks=1)),
                 (movie(), replace(limits, max_depth=3)),
                 (movie(track(entries=((500, 0, 1), (500, 0, 1)), timing_entries=((2, 1000),))),
                  replace(limits, max_total_table_entries=2)),
                 (movie(track(entries=((500, 0, 1), (500, 0, 1)))), replace(limits, max_edits_per_track=1))]
        for data, bound in cases:
            with self.assertRaises(timeline.TimelineLimitError):
                timeline.parse_asset_timeline(data, limits=bound)
        for value in (0, True, 1.5):
            with self.assertRaises(timeline.TimelineLimitError):
                replace(limits, max_boxes=value)

    def test_immutable_input_strict_cancellation_and_no_partial_return(self):
        for data in (bytearray(movie()), memoryview(movie()), None):
            with self.assertRaises(timeline.AssetTimelineError):
                timeline.parse_asset_timeline(data)
        event = Event(); event.set()
        with self.assertRaises(timeline.TimelineCancelled):
            timeline.parse_asset_timeline(movie(), cancel=event)
        for token in (False, lambda: 1):
            with self.assertRaises(timeline.AssetTimelineError):
                timeline.parse_asset_timeline(movie(), cancel=token)
        calls = 0
        def middle():
            nonlocal calls
            calls += 1
            return calls == 8
        with self.assertRaises(timeline.TimelineCancelled):
            timeline.parse_asset_timeline(movie(), cancel=middle)

    def test_file_reader_skips_mdat_preserves_bytes_and_does_not_return_private_names(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'private-name.mov'
            metadata = movie()
            media = box(b'mdat', b'private opaque media' * 10000)
            path.write_bytes(media + metadata)
            before = hashlib.sha256(path.read_bytes()).hexdigest()
            reads = []
            original_fdopen = os.fdopen
            class RecordingFile:
                def __init__(self, inner): self.inner = inner
                def __enter__(self): return self
                def __exit__(self, *args): return self.inner.__exit__(*args)
                def fileno(self): return self.inner.fileno()
                def seek(self, offset): return self.inner.seek(offset)
                def read(self, count):
                    reads.append((self.inner.tell(), count))
                    return self.inner.read(count)
            with patch.object(timeline.os, 'fdopen', side_effect=lambda *a, **k: RecordingFile(original_fdopen(*a, **k))):
                parsed = timeline.inspect_asset_timeline(path)
            self.assertEqual(parsed.asset_duration, Fraction(1))
            self.assertTrue(all(offset == 0 or offset >= len(media) for offset, count in reads))
            self.assertLess(sum(count for offset, count in reads), 4096)
            self.assertNotIn('private-name', repr(parsed))
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), before)
            self.assertEqual(list(Path(temporary).iterdir()), [path])

    def test_file_replacement_and_leaf_symlink_fail_without_deleting_rival(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            original, rival = folder / 'source.mov', folder / 'rival.mov'
            original_bytes, rival_bytes = movie(), movie(ticks=2000)
            original.write_bytes(original_bytes); rival.write_bytes(rival_bytes)
            calls, outcomes, callback_errors, permission_errors = 0, [], [], []
            def replace_while_reading():
                nonlocal calls
                calls += 1
                if calls == 6:
                    try:
                        os.replace(rival, original)
                    except PermissionError as error:
                        # An open Windows CRT handle may deny native replacement.
                        # This does not prove a rival was published. Inject a
                        # bounded callback failure and check both original files.
                        outcomes.append('blocked-while-open')
                        permission_errors.append(error)
                        failure = OSError('synthetic callback failure after blocked native replacement')
                        callback_errors.append(failure)
                        raise failure from error
                    else:
                        outcomes.append('published-rival')
                return False
            with patch.object(timeline.os, 'unlink', side_effect=AssertionError('source protection must not unlink')):
                with self.assertRaises(timeline.AssetTimelineError) as result:
                    timeline.inspect_asset_timeline(original, cancel=replace_while_reading)
            self.assertGreaterEqual(calls, 6)
            self.assertEqual(len(outcomes), 1, 'Actual native replacement must be attempted once')
            if outcomes == ['published-rival']:
                # Actual replacement, then production fd/path identity rejection.
                self.assertEqual(str(result.exception), 'timeline input identity changed during inspection')
                self.assertEqual(callback_errors, [])
                self.assertEqual(original.read_bytes(), rival_bytes)
                self.assertFalse(rival.exists())
            else:
                self.assertEqual(outcomes, ['blocked-while-open'])
                self.assertEqual(len(permission_errors), 1)
                self.assertIsInstance(permission_errors[0], PermissionError)
                self.assertEqual(len(callback_errors), 1)
                self.assertIs(callback_errors[0].__cause__, permission_errors[0])
                # Inspector intentionally normalizes OSError with suppressed
                # cause/path detail. __context__ verifies the actual callback
                # failure, without requiring production privacy to be relaxed.
                self.assertEqual(str(result.exception), 'cannot read stable local asset metadata')
                self.assertIsNone(result.exception.__cause__)
                self.assertTrue(result.exception.__suppress_context__)
                self.assertIs(result.exception.__context__, callback_errors[0])
                self.assertEqual(original.read_bytes(), original_bytes)
                self.assertEqual(rival.read_bytes(), rival_bytes)
            print('NATIVE_REPLACEMENT_JSON=' + json.dumps({
                'phase': 'asset-inspection-while-open', 'outcome': outcomes[0],
                'bothInputsPreserved': outcomes[0] == 'blocked-while-open',
                'callbackCause': type(permission_errors[0]).__name__ if permission_errors else None,
                'errno': permission_errors[0].errno if permission_errors else None,
                'winerror': getattr(permission_errors[0], 'winerror', None) if permission_errors else None}))
            link = folder / 'private-link.mov'
            try:
                link.symlink_to(original)
            except OSError:
                self.skipTest('Host cannot create a test-only symlink')
            with self.assertRaises(timeline.AssetTimelineError) as error:
                timeline.inspect_asset_timeline(link)
            self.assertNotIn(str(link), str(error.exception))

    def test_actual_replacement_after_fd_close_and_injected_failure_preserve_rival(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            original, rival = folder / 'source.mov', folder / 'rival.mov'
            original.write_bytes(movie()); rival_bytes = movie(ticks=2000)
            rival.write_bytes(rival_bytes)
            real_fdopen, outcomes, close_errors = os.fdopen, [], []
            class CloseThenReplace:
                def __init__(self, stream): self.stream = stream
                def __enter__(self): return self.stream.__enter__()
                def __exit__(self, kind, value, traceback):
                    self.stream.__exit__(kind, value, traceback)
                    if not self.stream.closed:
                        raise AssertionError('Actual replacement must follow real descriptor close')
                    if kind is not None:
                        raise AssertionError('Fixture inspection must succeed before injected close failure')
                    os.replace(rival, original)
                    outcomes.append('published-rival')
                    failure = OSError('synthetic failure after actual asset fd close and replacement')
                    close_errors.append(failure)
                    raise failure
            def wrapped_fdopen(*args, **kwargs):
                return CloseThenReplace(real_fdopen(*args, **kwargs))
            with patch.object(timeline.os, 'fdopen', side_effect=wrapped_fdopen), \
                 patch.object(timeline.os, 'unlink', side_effect=AssertionError('source protection must not unlink')):
                with self.assertRaises(timeline.AssetTimelineError) as result:
                    timeline.inspect_asset_timeline(original)
            self.assertEqual(outcomes, ['published-rival'])
            self.assertEqual(len(close_errors), 1)
            self.assertIs(type(close_errors[0]), OSError)
            self.assertEqual(str(close_errors[0]), 'synthetic failure after actual asset fd close and replacement')
            self.assertEqual(str(result.exception), 'cannot read stable local asset metadata')
            self.assertIsNone(result.exception.__cause__)
            self.assertTrue(result.exception.__suppress_context__)
            self.assertIs(result.exception.__context__, close_errors[0])
            self.assertEqual(original.read_bytes(), rival_bytes)
            self.assertFalse(rival.exists())
            self.assertEqual(list(folder.iterdir()), [original])
            print('NATIVE_REPLACEMENT_JSON=' + json.dumps({
                'phase': 'asset-inspection-after-close', 'outcome': outcomes[0],
                'rivalPreserved': True, 'callbackCause': type(close_errors[0]).__name__}))

    def test_parent_symlink_retarget_and_missing_path_are_generic_read_failures(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            left, right, parent = folder / 'left', folder / 'right', folder / 'alias'
            left.mkdir(); right.mkdir()
            (left / 'source.mov').write_bytes(movie()); (right / 'source.mov').write_bytes(movie())
            try:
                parent.symlink_to(left, target_is_directory=True)
            except OSError:
                self.skipTest('Host cannot create a test-only directory symlink')
            calls = 0
            def retarget():
                nonlocal calls
                calls += 1
                if calls == 6:
                    parent.unlink(); parent.symlink_to(right, target_is_directory=True)
                return False
            with self.assertRaises(timeline.AssetTimelineError):
                timeline.inspect_asset_timeline(parent / 'source.mov', cancel=retarget)
            missing = folder / 'secret-does-not-exist.mov'
            with self.assertRaises(timeline.AssetTimelineError) as error:
                timeline.inspect_asset_timeline(missing)
            self.assertNotIn(str(missing), str(error.exception))


if __name__ == '__main__':
    unittest.main()
