"""Actual desktop constructor and failed Workspace transactions on public MOVs.

Only synthetic project output is authored. No fake native target/provider,
player/audio device or OS input. Native deadline/process tree is runner-owned.
"""
from copy import deepcopy
from fractions import Fraction
import hashlib
import json
import multiprocessing
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from platforms.windows.bluraction import video
from platforms.windows.bluraction.editor import Workspace
from platforms.windows.bluraction.media import Cancelled
from platforms.windows.bluraction.video_project_compatibility import VideoTimelineReview
from Tests.WindowsAppTests.test_canonical_transport_fixtures import ROOT, KINDS, MANIFESTS, marker
from shared.video_timeline import rational


def pixels(image):
    from PySide6.QtGui import QImage
    owned=image.convertToFormat(QImage.Format.Format_RGBA8888)
    return b''.join(bytes(owned.constBits()[y*owned.bytesPerLine():y*owned.bytesPerLine()+owned.width()*4])
                    for y in range(owned.height()))


class AssetTransportTransactionTests(unittest.TestCase):
    def setUp(self):
        self.folder=ROOT/'video-timelines'
        self.manifest=self.folder/'manifest.json'
        self.manifest_bytes=self.manifest.read_bytes()
        self.assertEqual(hashlib.sha256(self.manifest_bytes).hexdigest(),MANIFESTS['video-timelines'])
        self.cases=json.loads(self.manifest_bytes)['cases']
        self.assertEqual(tuple(c['kind'] for c in self.cases),KINDS)

    def source(self,kind):
        case=next(c for c in self.cases if c['kind']==kind)
        self.assertEqual(case['file'],kind+'.mov')
        path=self.folder/case['file']
        self.assertFalse(path.is_symlink())
        data=path.read_bytes()
        self.assertEqual(hashlib.sha256(data).hexdigest(),case['sourceSHA256'])
        return path,case,data

    def check_case(self,kind):
        path,case,before=self.source(kind)
        source=session=None
        try:
            # Parent raw decoder is forbidden; default spawned child is actual.
            with patch.object(video,'_av',side_effect=AssertionError('parent native decode forbidden')):
                with video.asset_transport_load(): source=video.VideoSource(path)
            session=source.asset_session
            self.assertIsNotNone(session)
            pid=session._process.pid; directory=Path(session._directory.name)
            self.assertTrue(session._process.is_alive())
            self.assertEqual(session.metadata['timeline'],case['timeline'])
            self.assertEqual(source.asset_duration,rational(case['timeline']['assetDuration']))
            self.assertEqual(source.duration,float(source.asset_duration))
            meta=session.metadata['decoder']
            for key in ('timeBase','sar','legacyOrigin','videoEnd'):
                self.assertIs(type(meta[key]),Fraction)
            if meta['averageRate'] is not None: self.assertIs(type(meta['averageRate']),Fraction)
            self.assertEqual(source.time_base,meta['timeBase'])
            self.assertEqual(source.sample_aspect_ratio,meta['sar'])
            self.assertEqual(source.origin,meta['legacyOrigin'])  # Guard only, not presentation clock.
            first=case['frames'][0]
            self.assertEqual(source.first_frame_time,rational(first['pts']))
            page=source.page()
            self.assertEqual(page.source_sha256,case['sourceSHA256'])
            self.assertEqual(marker(pixels(page.image)),first['markerCode'])
            for row in case['frames']:
                result=source.frame_at_timed(rational(row['pts']))
                self.assertEqual((result.time,result.presence),(rational(row['pts']),'content'))
                self.assertEqual(marker(pixels(result.image)),row['markerCode'])
            source.validate()
            session.close()
            self.assertFalse(directory.exists())
            self.assertNotIn(pid,[child.pid for child in multiprocessing.active_children()])
        finally:
            if session is not None: session.close()
            self.assertEqual(path.read_bytes(),before)
            self.assertEqual(self.manifest.read_bytes(),self.manifest_bytes)

    def transaction(self,mode):
        old_path,_,old_bytes=self.source('gap0-vfr')
        new_path,new_case,new_bytes=self.source('nonzero-origin')
        workspace=Workspace()
        candidates=[]
        old=None
        with tempfile.TemporaryDirectory(prefix='bluraction-owned-transaction-') as folder:
            project=Path(folder)/'authored.bluraction'
            project.write_text(json.dumps(dict(version=1,mediaPath=str(new_path),
                sourceSHA256=new_case['sourceSHA256'],regions=[{
                    'shape':{'rectangle':{'id':'00000000-0000-0000-0000-000000000001',
                        'origin':[.1,.1],'size':[.6,.6]}},
                    'effect':{'blurRadius':25,'featherRadius':0,'timeRange':[.5,1],
                        'enabled':True,'style':'blur','keyframes':[],'erasures':[]}}],drawings=[])),encoding='utf-8')
            project_before=project.read_bytes()
            try:
                with video.asset_transport_load(): workspace.load([old_path])
                old=workspace.video.asset_session
                workspace.add_cover('rectangle',[[.1,.1],[.6,.6]],'solid',25,0)
                workspace.add_drawing('line',[[.1,.1],[.7,.7]])
                workspace.undo()
                workspace.selectionID=workspace.page.state['regions'][0]['shape']['rectangle']['id']
                workspace.time=.2
                previous=(workspace.page,workspace.video,deepcopy(workspace.page.state),
                          deepcopy(workspace._undo),deepcopy(workspace._redo),set(workspace.selection_ids),
                          workspace.time,workspace.title,workspace.index,workspace.dirty,pixels(workspace.page.image))
                constructor=video.VideoSource
                def capture(*args,**kwargs):
                    result=constructor(*args,**kwargs)
                    session=result.asset_session
                    candidates.append((session,session._process.pid,Path(session._directory.name)))
                    return result
                with patch.object(video,'VideoSource',side_effect=capture):
                    with self.assertRaises(Cancelled if mode=='cancel' else VideoTimelineReview):
                        with video.asset_transport_load():
                            if mode=='cancel': workspace.load([new_path],cancel=lambda:bool(candidates))
                            elif mode=='project': workspace.load_project(project)
                            else: workspace.apply_project_template(project,[new_path])
                self.assertEqual(len(candidates),1)
                for session,pid,directory in candidates:
                    self.assertIsNone(session._process)
                    self.assertFalse(directory.exists())
                    self.assertNotIn(pid,[child.pid for child in multiprocessing.active_children()])
                self.assertIs(workspace.page,previous[0]); self.assertIs(workspace.video,previous[1])
                self.assertEqual((workspace.page.state,workspace._undo,workspace._redo,workspace.selection_ids,
                                  workspace.time,workspace.title,workspace.index,workspace.dirty,
                                  pixels(workspace.page.image)),previous[2:])
                self.assertIs(workspace.video.asset_session,old)
                self.assertTrue(old._process.is_alive())
                workspace.video.validate()
                self.assertEqual(project.read_bytes(),project_before)
            finally:
                for session,_,_ in candidates: session.close()
                if old is not None: old.close()
                self.assertEqual(old_path.read_bytes(),old_bytes)
                self.assertEqual(new_path.read_bytes(),new_bytes)
                self.assertEqual(self.manifest.read_bytes(),self.manifest_bytes)

    def test_cancel_after_actual_constructor_reaps_unadopted_session(self): self.transaction('cancel')
    def test_legacy_project_rejection_reaps_new_session_preserves_dirty_borrowed_session(self): self.transaction('project')
    def test_template_rejection_reaps_new_session_preserves_dirty_borrowed_session(self): self.transaction('template')


for _kind in KINDS:
    def _test(self,kind=_kind): self.check_case(kind)
    setattr(AssetTransportTransactionTests,'test_desktop_'+_kind.replace('-','_'),_test)
