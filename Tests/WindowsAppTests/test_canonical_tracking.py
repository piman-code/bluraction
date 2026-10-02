"""Actual asset tracking frame membership and atomic candidate paths.

Controlled tracker tests expose clock/geometry differences without claiming
CSRT success. One authored moving-texture MOV uses the real CSRT implementation.
Native calls run only under the parent's family watchdog; no desktop/device IO.
"""
from copy import deepcopy
from fractions import Fraction as F
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from PySide6.QtGui import QImage
from platforms.windows.bluraction import video
from platforms.windows.bluraction.media import Cancelled
from Tests.WindowsAppTests import test_video as legacy


def image(color):
    result = QImage(96,64,QImage.Format.Format_RGBA8888)
    result.fill(color)
    return result


def item():
    return {'shape': {'rectangle': {'id': 'track-control', 'origin': [.2,.2], 'size': [.3,.3]}},
        'effect': {'enabled':True,'locked':False,'timeRange':[0,0],
            'keyframes':[{'time':0,'rect':[[.2,.2],[.3,.3]]},
                         {'time':1,'rect':[[.4,.2],[.3,.3]]},
                         {'time':2,'rect':[[.6,.2],[.3,.3]]}]}}


class Source:
    duration=2
    def __init__(self, *, blank=False, gap=False):
        self.blank,self.gap=blank,gap; self.initial_times=[]; self.ranges=[]; self.validations=0; self.cursor_closed=False
        self.frames=[video.TimedImage(F(1,4),image(0xff204080),'content',F(1,2),2,F(1,4)),
                     video.TimedImage(F(1,2),image(0xff408020),'content',F(3,4),3,F(1,2)),
                     video.TimedImage(F(3,4),image(0xff802040),'content',F(1),4,F(3,4))]
    def validate(self,cancel=None):
        self.validations+=1; video.check_cancel(cancel)
    def frame_at_timed(self,start,cancel=None):
        self.initial_times.append(start); video.check_cancel(cancel)
        if self.blank: return video.TimedImage(F(str(start)),image(0),'empty')
        return self.frames[0]
    def iter_frames(self,start,end,cancel=None):
        self.ranges.append((start,end))
        try:
            for index,row in enumerate(self.frames):
                if self.gap and index==1:
                    row=video.TimedImage(F(3,5),row.image,'content',F(3,4),row.source_index,F(3,5))
                yield row
        finally:
            self.cursor_closed=True


class Tracker:
    def __init__(self): self.initial=None; self.updates=0
    def init(self,pixels,roi): self.initial=roi; return None
    def update(self,pixels):
        self.updates+=1
        x,y,w,h=self.initial
        return True,(x+self.updates,y,w,h)


class CanonicalTrackingTests(unittest.TestCase):
    def test_between_frame_initial_geometry_uses_observed_pts_not_transport_target(self):
        source=Source(); tracker=Tracker(); selected=item(); original=deepcopy(selected)
        with patch.object(video,'_csrt',return_value=(None,tracker)):
            result=video.track(source,selected,True,.3,.8)
        self.assertEqual(source.ranges,[(.3,.8)])
        in_range=[r for r in result if .3 <= r['time'] <= .8]
        outside=[r for r in result if r['time'] < .3 or r['time'] > .8]
        self.assertEqual(in_range[0]['time'],.3,'Explicit requested range is not shifted')
        # Geometry is interpolated at the actual displayed .25 frame, not .30.
        self.assertAlmostEqual(in_range[0]['rect'][0][0],.25)
        self.assertEqual([r['time'] for r in in_range],[.3,.5,.75])
        self.assertEqual(outside,original['effect']['keyframes'])
        self.assertEqual([r['time'] for r in result],[0,.3,.5,.75,1,2])
        self.assertEqual(tracker.updates,2)
        self.assertEqual(selected,original)
        self.assertEqual(source.validations,2)
        self.assertTrue(source.cursor_closed)

    def test_initial_empty_or_later_content_gap_returns_no_partial_candidate(self):
        selected=item(); original=deepcopy(selected)
        for source in (Source(blank=True),Source(gap=True)):
            with self.subTest(blank=source.blank), patch.object(video,'_csrt',return_value=(None,Tracker())):
                with self.assertRaises(video.TrackingLost): video.track(source,selected,True,.25,.8)
        self.assertEqual(selected,original)

    def test_cancel_after_update_and_old_keyframes_outside_range_are_preserved(self):
        source=Source(); tracker=Tracker(); selected=item(); original=deepcopy(selected)
        cancelled=[False]
        def progress(value): cancelled[0]=True
        with patch.object(video,'_csrt',return_value=(None,tracker)):
            with self.assertRaises(Cancelled):
                video.track(source,selected,True,.25,.8,cancel=lambda:cancelled[0],progress=progress)
        self.assertEqual(selected,original)
        self.assertTrue(source.cursor_closed, 'Cancel closes the actual sequential cursor')
        with patch.object(video,'_csrt',return_value=(None,Tracker())):
            result=video.track(Source(),selected,True,.25,.8)
        self.assertEqual([f for f in result if f['time'] in (0,1,2)],original['effect']['keyframes'])

    def test_tracking_loss_keeps_primary_when_cursor_cleanup_also_fails(self):
        source=Source(); base=source.iter_frames
        def cursor(*args):
            stream=base(*args)
            try: yield from stream
            finally:
                stream.close()
                raise OSError('controlled cursor cleanup failure')
        source.iter_frames=cursor
        tracker=Tracker(); tracker.update=lambda pixels:(False,None)
        selected=item(); before=deepcopy(selected)
        with patch.object(video,'_csrt',return_value=(None,tracker)):
            with self.assertRaises(video.TrackingLost) as observed:
                video.track(source,selected,True,.25,.8)
        self.assertTrue(source.cursor_closed)
        self.assertTrue(any('cursor cleanup' in note for note in observed.exception.__notes__))
        self.assertEqual(selected,before)

    def test_content_tail_gap_cannot_apply_partial_candidate(self):
        source=Source(); selected=item(); before=deepcopy(selected)
        with patch.object(video,'_csrt',return_value=(None,Tracker())):
            with self.assertRaises(video.TrackingLost):
                video.track(source,selected,True,.25,1.2)
        self.assertTrue(source.cursor_closed)
        self.assertEqual(selected,before)

    def test_drawing_follows_center_without_resizing_at_asset_pts(self):
        drawing={'id':'drawing-control','kind':'line','points':[[.2,.2],[.4,.4]],
                 'timeRange':[0,0],'hidden':False,'locked':False,'keyframes':[]}
        original=deepcopy(drawing)
        with patch.object(video,'_csrt',return_value=(None,Tracker())):
            result=video.track(Source(),drawing,False,.25,.8)
        self.assertTrue(all(row['rect'][1]==[.2,.2] for row in result))
        self.assertEqual(drawing,original)

    def test_actual_owned_mov_cursor_and_real_csrt_use_source_asset_pts(self):
        temp=tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup)
        path=Path(temp.name)/'owned-texture.mov'
        builder=legacy.VideoTests('test_actual_uneven_pts_seek_duration_and_shared_preview_timing')
        builder.make_source(path,audio=True)
        original=path.read_bytes()
        source=video.VideoSource(path,require_asset_presentation=True)
        self.addCleanup(source.close_asset_transport)
        rows=list(source.iter_frames())
        self.assertEqual([row.time for row in rows],[F(t,1000) for t in legacy.PTS])
        self.assertTrue(all(row.source_index is not None for row in rows))
        self.assertEqual(len({row.source_index for row in rows}),5)
        selected=builder.track_item()
        start=float(rows[0].time); end=float(rows[-1].time)
        selected['effect']['timeRange']=[start,end]
        before=deepcopy(selected)
        result=video.track(source,selected,True,start,end)
        self.assertEqual([row['time'] for row in result],[float(row.time) for row in rows])
        self.assertGreater(result[-1]['rect'][0][0],result[0]['rect'][0][0]+.06)
        self.assertEqual(selected,before); self.assertEqual(path.read_bytes(),original)
        self.assertFalse(source.asset_session._closed)


if __name__ == '__main__':
    unittest.main()
