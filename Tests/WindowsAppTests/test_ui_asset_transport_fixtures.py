"""Actual Qt worker/UI adoption with eight default spawned public MOV sources.

No fake VideoSource/session/native target, player playback, audio-device start or
OS input. This is an internal Qt UI bridge, not installed-app/Finder acceptance.
The family runner owns the outer 120-second process-tree deadline.
"""
import os
os.environ.setdefault('QT_QPA_PLATFORM','offscreen')
from fractions import Fraction
import hashlib
import json
import multiprocessing
from pathlib import Path
import time
import unittest
from unittest.mock import patch

from PySide6.QtWidgets import QApplication, QMessageBox
from platforms.windows.bluraction.ui import BlurActionWindow
from Tests.WindowsAppTests.test_canonical_transport_fixtures import ROOT, KINDS, MANIFESTS, marker
from Tests.WindowsAppTests.test_asset_transport_transactions import pixels
from shared.video_timeline import rational

APP=QApplication.instance() or QApplication([])


class ActualAssetUIFixtureTests(unittest.TestCase):
    def wait(self,predicate,seconds=10):
        deadline=time.monotonic()+seconds
        while not predicate() and time.monotonic()<deadline:
            APP.processEvents()
            time.sleep(.005)
        self.assertTrue(predicate(),'Actual Qt media/preview transaction did not complete')

    def check_case(self,kind):
        manifest=ROOT/'video-timelines/manifest.json'
        manifest_bytes=manifest.read_bytes()
        self.assertEqual(hashlib.sha256(manifest_bytes).hexdigest(),MANIFESTS['video-timelines'])
        case=next(c for c in json.loads(manifest_bytes)['cases'] if c['kind']==kind)
        self.assertEqual(case['file'],kind+'.mov')
        source=manifest.parent/case['file']
        self.assertFalse(source.is_symlink())
        before=source.read_bytes()
        self.assertEqual(hashlib.sha256(before).hexdigest(),case['sourceSHA256'])
        window=BlurActionWindow()
        session=None
        try:
            with patch('platforms.windows.bluraction.ui.QMessageBox.warning',
                       return_value=QMessageBox.StandardButton.Ok) as warning:
                window.open_paths([source])
                self.wait(lambda:not window.workspace.busy and window._thread is None)
                self.assertEqual(warning.call_count,0,str(warning.call_args_list))
                self.assertIsNotNone(window.workspace.video)
                session=window.workspace.video.asset_session
                self.assertIsNotNone(session)
                self.assertTrue(session._process.is_alive())
                pid=session._process.pid; directory=Path(session._directory.name)
                self.assertEqual(window.workspace.video.asset_duration,rational(case['timeline']['assetDuration']))
                self.assertEqual(window._asset_clock.duration,rational(case['timeline']['assetDuration']))
                self.assertEqual(session.metadata['timeline'],case['timeline'])
                self.wait(lambda:not window.canvas.preview_pending and not window.canvas.preview_queue.busy)
                first=case['frames'][0]
                self.assertEqual((window.workspace.time,window.canvas.time),
                                 (float(rational(first['pts'])),)*2)
                self.assertEqual(marker(pixels(window.canvas.image)),first['markerCode'])
                # The actual worker decodes a paused between-frame seek; the
                # creation period must use the displayed PTS, not its target.
                row=case['frames'][1]
                target=rational(row['pts'])+rational(row['duration'])/2
                window.seek_video(float(target))
                self.wait(lambda:not window.canvas.preview_pending and not window.canvas.preview_queue.busy)
                self.assertEqual((window.workspace.time,window.canvas.time),(float(rational(row['pts'])),)*2)
                self.assertNotEqual(window.workspace.time,float(target))
                self.assertEqual(marker(pixels(window.canvas.image)),row['markerCode'])
                window.create_item('cover_rectangle',[[.1,.1],[.6,.6]])
                self.wait(lambda:not window.canvas.preview_pending and not window.canvas.preview_queue.busy)
                self.assertEqual(len(window.workspace.page.state['regions']),1)
                self.assertEqual(window.workspace.page.state['regions'][0]['effect']['timeRange'],
                                 [float(rational(row['pts'])),float(session.duration)])
                self.assertEqual(window.canvas.state,window.workspace.page.state)
                window.workspace.video.validate()
                self.assertEqual(warning.call_count,0,str(warning.call_args_list))
                # Native Qt player never supplies this owned MOV's clock/image.
                self.assertFalse(window._asset_clock.playing)
                self.assertIsNone(window._asset_audio.sink)
            window.workspace.dirty=False
            window.close()
            self.wait(lambda:not window.canvas.preview_queue.busy and not window._asset_audio.queue.busy)
            session.close()  # Join the source retirement before checking resources.
            self.assertIsNone(session._process)
            self.assertFalse(directory.exists())
            self.assertNotIn(pid,[child.pid for child in multiprocessing.active_children()])
        finally:
            if window.workspace.busy:
                window.cancel_operation()
                self.wait(lambda:not window.workspace.busy and window._thread is None)
            window.workspace.dirty=False
            window.close()
            self.wait(lambda:not window.canvas.preview_queue.busy and not window._asset_audio.queue.busy)
            if session is not None: session.close()
            self.assertEqual(source.read_bytes(),before)
            self.assertEqual(manifest.read_bytes(),manifest_bytes)


for _kind in KINDS:
    def _test(self,kind=_kind): self.check_case(kind)
    setattr(ActualAssetUIFixtureTests,'test_'+_kind.replace('-','_'),_test)
