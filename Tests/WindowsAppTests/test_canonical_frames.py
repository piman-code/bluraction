"""Exact presence foundation with controlled EOF inventory seams.

These synthetic decoder observations prove neither an actual MOV demux clock,
native Windows playback nor production P1 closure. Root separately compares the
eight authored MOVs' actual inventories to native content identities/timestamps.
"""
from copy import deepcopy
from fractions import Fraction as F
import hashlib
from pathlib import Path
import tempfile
from threading import Event
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from platforms.windows.bluraction import frame_inventory as raw
from platforms.windows.bluraction import canonical_frames as canonical
from platforms.windows.bluraction import local_decoder
from shared.video_timeline import encode_rational as R


def segment(start, duration, media=None, rate=F(1)):
    return dict(assetStart=R(F(start)), assetDuration=R(F(duration)),
                mediaStart=None if media is None else R(F(media)), rate=R(rate))


def timeline(segments, duration):
    return dict(version=1, basis='asset-presentation', assetDuration=R(F(duration)),
                tracks=[dict(id=2, kind='video', mediaTimescale=1000, segments=segments)])


class CanonicalFramesTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(); self.addCleanup(self.directory.cleanup)
        self.source = Path(self.directory.name) / 'synthetic-observation.mov'
        self.original = b'controlled observation input; not encoded MOV'
        self.source.write_bytes(self.original)
        self.sha = hashlib.sha256(self.original).hexdigest()
        self.generation = 7

    def inventory(self, rows, **kwargs):
        frames = [SimpleNamespace(pts=p, duration=d, time_base=F(1,1000), width=96,
            height=64, rotation=0.0, sample_aspect_ratio=None, side_data={}, is_corrupt=False)
            for p, d in rows]
        stream = SimpleNamespace(width=96, height=64, index=0, id=2, time_base=F(1,1000),
            codec_context=SimpleNamespace(sample_aspect_ratio=None), sample_aspect_ratio=None)
        class Container:
            streams = SimpleNamespace(video=[stream])
            format = SimpleNamespace(name='mov')
            def __enter__(self): return self
            def __exit__(self, *args): self.close()
            def close(self): pass
            def decode(self, *args, **kwargs): return iter(frames)
        module = SimpleNamespace(__version__='19.0.0', open=lambda *a, **k: Container())
        with patch.object(raw, '_av', return_value=module), \
             patch.object(local_decoder, '_av', return_value=module):
            result = raw.FrameInventory.build(self.source, expected_sha256=self.sha,
                generation=self.generation, **kwargs)
        self.addCleanup(result.close)
        return result

    def build(self, inventory, descriptor=None, **kwargs):
        defaults = dict(source_sha256=self.sha, generation=self.generation,
            timeline=descriptor or timeline([segment(0, 2, 0)], 2),
            decoder_clock_mode='ffmpeg-editlist-applied', container_format='mov')
        defaults.update(kwargs)
        result = canonical.CanonicalFrameIndex.build(inventory, **defaults)
        self.addCleanup(result.close)
        return result

    def test_leading_content_suffix_eof_are_half_open_without_future_or_hold(self):
        inv = self.inventory([(500,250), (750,250)])
        descriptor = timeline([segment(0,F(1,2)), segment(F(1,2),F(1,2),0)], F(3,2))
        view = self.build(inv, descriptor)
        for t, expected in [(F(0),'empty'), (F(499,1000),'empty'), (F(1,2),'content'),
                (F(3,4),'content'), (F(1),'suffix'), (F(1499,1000),'suffix'), (F(3,2),'EOF')]:
            with self.subTest(t=t): self.assertEqual(view.presence(t).kind, expected)
        self.assertEqual(view.sample_at(F(3,4)).source_index, 1)
        for t in (F(0),F(1),F(3,2)): self.assertIsNone(view.sample_at(t))
        self.assertEqual(view.asset_duration,F(3,2))

    def test_middle_empty_and_unobserved_content_do_not_return_previous_or_future(self):
        inv = self.inventory([(100,200), (1100,200)])
        view = self.build(inv, timeline([segment(0,F(1,2),0), segment(F(1,2),F(1,2)),
            segment(1,F(1,2),F(1,2))],2))
        for t, kind in [(F(0),'content-no-sample'),(F(3,10),'content-no-sample'),
                (F(1,2),'empty'), (F(1),'content-no-sample'),(F(11,10),'content'),(F(3,2),'suffix')]:
            self.assertEqual(view.presence(t).kind,kind)

    def test_negative_preroll_is_retained_raw_but_not_remapped_or_presented(self):
        inv = self.inventory([(-200,100), (0,200), (200,200)])
        view = self.build(inv,timeline([segment(0,F(2,5),F(1,12))],F(2,5)))
        self.assertIsNone(view.sample_for_source_index(0))
        samples = list(view.iter_samples())
        self.assertEqual([s.source_index for s in samples],[1,2])
        self.assertEqual([s.asset_pts for s in samples],[F(0),F(1,5)])
        self.assertEqual(samples[0].observation, inv[1])
        self.assertEqual(inv[0].pts,F(-1,5)); self.assertEqual(view.raw_count,3)
        self.assertEqual(view.sample_count,2)

    def test_right_clip_retains_observed_duration_and_stops_at_explicit_boundary(self):
        inv = self.inventory([(0,600)])
        view = self.build(inv,timeline([segment(0,F(1,2),0),segment(F(1,2),F(1,2))],1))
        sample = view.sample_at(F(499,1000))
        self.assertEqual(sample.interval_end,F(1,2)); self.assertEqual(sample.observation.duration,F(3,5))
        self.assertIsNone(view.sample_at(F(1,2))); self.assertEqual(inv[0].duration,F(3,5))

    def test_clipped_start_and_sample_across_distinct_content_occurrences_require_review(self):
        descriptor=timeline([segment(0,F(1,2)),segment(F(1,2),F(1,2),0)],1)
        # [-.1,.1) is wholly outside content [.5,1): keep that real
        # nonintersection as a PASS control, rather than expecting a trim hold.
        preroll=self.inventory([(-100,200),(500,100)])
        view=self.build(preroll,descriptor)
        self.assertIsNone(view.sample_for_source_index(0))
        self.assertEqual(view.sample_at(F(1,2)).source_index,1)
        self.assertEqual(preroll[0].pts,F(-1,10))
        # [-.1,.6) and [.4,.6) genuinely cross the .5 content start.
        for rows in ([(-100,700),(500,100)],[(400,200),(700,100)]):
            inv=self.inventory(rows)
            with self.assertRaisesRegex(canonical.CanonicalFramesReview,'clipped-start'):
                self.build(inv,descriptor)
            self.assertTrue(inv.complete)
        inv=self.inventory([(0,1500)])
        with self.assertRaisesRegex(canonical.CanonicalFramesReview,'multiple content'):
            self.build(inv,timeline([segment(0,1,0),segment(1,1,0)],2))
        self.assertTrue(inv.complete)

    def test_repeated_content_requires_distinct_applied_asset_observations(self):
        descriptor=timeline([segment(0,1,0),segment(1,1,0)],2)
        inv=self.inventory([(0,1000),(1000,1000)])
        view=self.build(inv,descriptor)
        self.assertEqual(view.sample_at(F(3,2)).asset_pts,F(1))
        self.assertEqual(view.sample_at(F(1,2)).source_index,0)
        missing=self.inventory([(0,1000)])
        with self.assertRaisesRegex(canonical.CanonicalFramesReview,'no observed'):
            self.build(missing,descriptor)
        self.assertTrue(missing.complete)

    def test_overlapping_samples_rejected_without_closing_borrowed_inventory(self):
        inv=self.inventory([(0,700),(500,500)])
        with self.assertRaisesRegex(canonical.CanonicalFramesReview,'overlapping'):
            self.build(inv)
        self.assertTrue(inv.complete); self.assertEqual(inv[0].duration,F(7,10))

    def test_explicit_mode_container_options_track_and_rate_gate(self):
        inv=self.inventory([(0,1000)])
        for kwargs in (dict(decoder_clock_mode='media-composition'),dict(container_format='matroska')):
            with self.assertRaises(canonical.CanonicalFramesReview): self.build(inv,**kwargs)
        for option in ({'ignore_editlist':'1'}, {'advanced_editlist':'0'}):
            other=self.inventory([(0,1000)],demux_options=option)
            with self.assertRaisesRegex(canonical.CanonicalFramesReview,'options'): self.build(other)
            self.assertTrue(other.complete)
        for descriptor, reason in ((timeline([segment(0,1,0,F(2))],1),'rate'),
                (dict(timeline([segment(0,1,0)],1),tracks=[dict(id=3,kind='video',
                    mediaTimescale=1000,segments=[segment(0,1,0)])]),'track ID')):
            with self.assertRaisesRegex(canonical.CanonicalFramesReview,reason): self.build(inv,descriptor)
        self.assertTrue(inv.complete)

    def test_bindings_frozen_descriptor_no_state_or_source_rewrite(self):
        inv=self.inventory([(0,1000)]); descriptor=timeline([segment(0,1,0)],1)
        original=deepcopy(descriptor); view=self.build(inv,descriptor)
        digest=view.descriptor_sha256
        self.assertEqual(digest,canonical.descriptor_sha256(original))
        view.require_binding(source_sha256=self.sha,generation=7,descriptor_sha256=digest)
        for changes in (dict(source_sha256='0'*64),dict(generation=True),dict(generation=8),
                dict(descriptor_sha256='0'*64)):
            arguments=dict(source_sha256=self.sha,generation=7,descriptor_sha256=digest); arguments.update(changes)
            with self.assertRaises(canonical.CanonicalFramesReview): view.require_binding(**arguments)
        descriptor['tracks'][0]['segments'][0]['mediaStart']=R(F(9))
        self.assertEqual(view.descriptor_sha256,digest); self.assertEqual(view.sample_at(F(0)).asset_pts,F(0))
        self.assertEqual(self.source.read_bytes(),self.original)
        with self.assertRaises(AttributeError): view.sample_at(F(0)).asset_pts=F(9)

    def test_generation_cancel_and_borrowed_close_invalidate_lazy_reads(self):
        inv=self.inventory([(0,500),(500,500)]); current=[7]; event=Event()
        view=self.build(inv,current_generation=lambda:current[0],cancel=event)
        iterator=view.iter_samples(); self.assertEqual(next(iterator).source_index,0)
        current[0]=8
        with self.assertRaises(raw.FrameInventoryError): next(iterator)
        self.assertTrue(inv.complete)
        current[0]=7
        with self.assertRaises(canonical.CanonicalFramesReview): view.presence(F(0))
        cancelled=self.build(inv,cancel=event); event.set()
        with self.assertRaises(raw.InventoryCancelled): cancelled.presence(F(0))
        event.clear()
        with self.assertRaises(canonical.CanonicalFramesReview): cancelled.presence(F(0))
        borrowed=self.build(inv); inv.close()
        with self.assertRaises(raw.FrameInventoryError): borrowed.sample_at(F(0))

    def test_late_build_cancellation_or_generation_failure_never_consumes_inventory(self):
        inv=self.inventory([(0,500),(500,500)])
        for cancelled in (True,False):
            calls=[0]
            def condition():
                calls[0]+=1
                return calls[0]>5 if cancelled else 8 if calls[0]>5 else 7
            arguments=dict(cancel=condition) if cancelled else dict(current_generation=condition)
            with self.assertRaises(raw.FrameInventoryError): self.build(inv,**arguments)
            self.assertTrue(inv.complete); self.assertEqual(inv[1].pts,F(1,2))

    def test_close_context_and_failure_cleanup_only_new_view(self):
        inv=self.inventory([(0,1000)])
        view=self.build(inv)
        with view: self.assertEqual(view.sample_at(F(0)).source_index,0)
        view.close()
        with self.assertRaises(canonical.CanonicalFramesReview): view.raw_count
        self.assertTrue(inv.complete)
        with self.assertRaises(raw.FrameInventoryError): self.build(inv,source_sha256='0'*64)
        self.assertTrue(inv.complete); self.assertEqual(self.source.read_bytes(),self.original)

    def test_exact_query_domain_and_unknown_metadata_fail_without_guess(self):
        inv=self.inventory([(0,1000)]); view=self.build(inv)
        for time in (0,0.0,True,F(-1,10),F(21,10)):
            with self.assertRaises(canonical.CanonicalFramesReview): view.sample_at(time)
        descriptor=timeline([segment(0,1,0)],1); descriptor['unverifiedOrigin']=0
        with self.assertRaises(ValueError): self.build(inv,descriptor)
        inv.close()
        with self.assertRaises(canonical.CanonicalFramesReview): self.build(inv)


if __name__ == '__main__':
    unittest.main()
