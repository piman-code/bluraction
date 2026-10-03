"""Actual spawned MOV/v3 host transactions; no fake decoder or device playback.

The native family runner owns an outer 120-second process-tree deadline. Source
fixtures are public authored files; all output lives in owned temporary folders.
Mac/Windows installed-app, audio-device, export and generic-format QA are separate.
"""
from copy import deepcopy
import hashlib
import json
import multiprocessing
import os
from pathlib import Path
import tempfile
import time
import unittest
import uuid
from unittest.mock import patch
from shared.portable_project import PortableProject, ProjectError, dump_project, load_project
from shared.source_relink import check_source, resolve_reference, relink_media
from Tests.PortableProjectTests.test_video_project_v3 import fixture
from platforms.windows.bluraction.project_compatibility import validate_host_reviews
from platforms.windows.bluraction.editor import Workspace
from platforms.windows.bluraction.media import Cancelled
from platforms.windows.bluraction import __version__, video
from platforms.windows.bluraction.video_project_compatibility import VideoTimelineReview
from Tests.WindowsAppTests.test_canonical_transport_fixtures import ROOT, KINDS, UNIQUE, MANIFESTS, marker
from Tests.WindowsAppTests.test_asset_transport_transactions import pixels
from shared.video_timeline import rational


def rich_edits():
    """All known enums, fractional styles, untouched nulls and motion ordering."""
    original=fixture()
    region,drawing=original['regions'][0],original['drawings'][0]
    state={'regions':[], 'drawings':[]}
    for index,kind in enumerate(('rectangle','ellipse','polygon')):
        item=deepcopy(region)
        body={'id':str(uuid.UUID(int=index+1)).upper()}
        if kind=='polygon': body['points']=[[.1,.2],[.5,.7],[.8,.3]]
        else: body.update(origin=[.1,.2],size=[.3,.4])
        item['shape']={kind:body}
        item['effect'].update(timeRange=[4,6], enabled=index!=1,
            blurRadius=123.456789,featherRadius=400.125,
            keyframes=[{'time':2,'rect':[[.1,.2],[.3,.4]]},
                       {'time':1,'rect':[[.2,.1],[.4,.3]]},
                       {'time':1,'rect':[[.3,.2],[.2,.4]]}])
        item['effect']['erasures'][0]['from']=None
        if index==2:
            for key in ('style','color','name','locked'): item['effect'].pop(key,None)
        state['regions'].append(item)
    for index,kind in enumerate(('rectangle','ellipse','line','freehand','arrow','text')):
        item=deepcopy(drawing)
        item.update(id=str(uuid.UUID(int=index+100)).upper(),kind=kind,
            lineWidth=.00123456789,fillOpacity=.3456789,timeRange=[4,6],
            hidden=index%2==1,locked=index%2==0,
            keyframes=[{'time':2,'rect':[[.1,.2],[.3,.4]]},
                       {'time':1,'rect':[[.2,.1],[.4,.3]]}])
        item['erasures'][0]['from']=.5000162760416667
        if index==0:
            item.pop('bold'); item['fontName']=None; item['name']=None
        state['drawings'].append(item)
    return state


def authored_project(path,case,state=None):
    return dict(version=3,mediaKind='video',mediaPath=str(path),sourceSHA256=case['sourceSHA256'],
        producer={'name':'BlurAction','platform':'macos','version':'test.native'},
        timeline=deepcopy(case['timeline']),**deepcopy(state if state is not None else rich_edits()))


class VideoProjectV3HostTests(unittest.TestCase):
    def test_v3_grapheme_review_uses_top_level_video_without_mutation(self):
        tree = fixture()
        tree['drawings'][0]['text'] = '\u1100\u1161\u11a8' * 1000
        project = PortableProject(tree)
        self.assertTrue(project.required_reviews)
        self.assertEqual(validate_host_reviews(project), ())
        self.assertEqual(project.to_dict(), tree)
        tree['drawings'][0]['text'] += 'x'
        with self.assertRaises(ProjectError): validate_host_reviews(PortableProject(tree))

    def test_v3_relink_verifies_selected_bytes_and_changes_only_media_path(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); source = root / 'replacement.mov'
            source.write_bytes(b'authored byte identity only; never decoded as media')
            tree = fixture(); tree['sourceSHA256'] = hashlib.sha256(source.read_bytes()).hexdigest()
            project = PortableProject(tree)
            platform = 'windows' if os.name == 'nt' else 'macos'
            location = str(root/'project.bluraction')
            resolution = resolve_reference(source.name, location, platform)
            checked = check_source(resolution, tree['sourceSHA256'], approved_roots=[root])
            self.assertEqual(checked.state, 'verified')
            relinked = relink_media(project, tree['mediaPath'], source.name,
                project_location=location, platform=platform, checked=checked)
            expected = deepcopy(tree); expected['mediaPath'] = source.name
            self.assertEqual(relinked.to_dict(), expected)
            self.assertEqual(project.to_dict(), tree)
            self.assertEqual(relinked.sources[0].expected_sha256, tree['sourceSHA256'])

    def test_unknown_v3_semantics_hold_before_source_reads_or_session_change(self):
        workspace = Workspace()
        workspace.title = 'keep dirty session'; workspace.dirty = True
        workspace.selection_ids = {'preserved-selection'}
        workspace._undo = {'preserved': [1, 2]}
        before = deepcopy(workspace.__dict__)
        with tempfile.TemporaryDirectory() as folder:
            tree=fixture(); tree['futureEffect']={'unknown':True}
            path = Path(folder)/'video-v3.bluraction'; path.write_bytes(dump_project(PortableProject(tree)))
            with patch('platforms.windows.bluraction.editor.fingerprint', side_effect=AssertionError('v3 must be held before source access')):
                with self.assertRaisesRegex(ValueError, '호환 검토'):
                    workspace.load_project(path)
        self.assertEqual(workspace.__dict__, before)


class ActualVideoProjectV3HostTests(unittest.TestCase):
    def source(self,kind):
        group='video-timelines' if kind in KINDS else 'video-timelines-unique-pcm'
        manifest=ROOT/group/'manifest.json'; raw=manifest.read_bytes()
        self.assertEqual(hashlib.sha256(raw).hexdigest(),MANIFESTS[group])
        case=next(c for c in json.loads(raw)['cases'] if c['kind']==kind)
        self.assertEqual(case['file'],kind+'.mov')
        path=manifest.parent/case['file']; self.assertFalse(path.is_symlink())
        data=path.read_bytes(); self.assertEqual(hashlib.sha256(data).hexdigest(),case['sourceSHA256'])
        return path,case,data,manifest,raw

    def close_source(self,workspace):
        session=getattr(workspace.video,'asset_session',None)
        if session is not None:
            pid=session._process.pid if session._process is not None else None
            directory=Path(session._directory.name) if session._directory is not None else None
            session.close()
            self.assertIsNone(session._process)
            if directory is not None: self.assertFalse(directory.exists())
            if pid is not None: self.assertNotIn(pid,[c.pid for c in multiprocessing.active_children()])

    def owned(self,path):
        workspace=Workspace()
        with video.asset_transport_load(): workspace.load([path])
        self.assertIsNotNone(workspace.video.asset_session)
        return workspace

    def snapshot(self,workspace):
        return (workspace.page,workspace.video,deepcopy(workspace.page.state),deepcopy(workspace._undo),
            deepcopy(workspace._redo),set(workspace.selection_ids),workspace.time,workspace.title,
            workspace.index,workspace.dirty,deepcopy(workspace._project_tree),pixels(workspace.page.image))

    def assert_snapshot(self,workspace,before):
        now=self.snapshot(workspace)
        self.assertIs(now[0],before[0]); self.assertIs(now[1],before[1]); self.assertEqual(now[2:],before[2:])
        self.assertTrue(workspace.video.asset_session._process.is_alive())

    def roundtrip(self,kind):
        path,case,before,manifest,manifest_raw=self.source(kind)
        workspace=reopened=None
        try:
            with tempfile.TemporaryDirectory(prefix='bluraction-v3-host-') as folder:
                output=Path(folder)/'first.bluraction'; output2=Path(folder)/'second.bluraction'
                workspace=self.owned(path); workspace.page.state=rich_edits(); workspace.dirty=True
                expected=deepcopy(workspace.page.state)
                binding=workspace.video.verified_asset_binding()
                self.assertEqual(binding.timeline,case['timeline'])
                self.assertEqual(binding.source_sha256,case['sourceSHA256'])
                exposed=binding.timeline; exposed['tracks'].clear()
                self.assertEqual(binding.timeline,case['timeline'])
                # Public ready metadata may be mutated by a caller; it cannot
                # approve or rewrite the immutable project source descriptor.
                workspace.video.asset_session.metadata['timeline']['tracks'].clear()
                workspace.video.asset_session.metadata['descriptorSHA256']='0'*64
                workspace.save_project(output)
                original_project=output.read_bytes(); tree=load_project(original_project).to_dict()
                self.assertEqual(tree['version'],3)
                self.assertEqual(tree['producer'],{'name':'BlurAction','platform':'windows','version':__version__})
                self.assertEqual(tree['timeline'],case['timeline'])
                self.assertEqual(tree['sourceSHA256'],case['sourceSHA256'])
                self.assertEqual({k:tree[k] for k in expected},expected)
                self.assertFalse(workspace.dirty)
                reopened=Workspace(); reopened.load_project(output)
                self.assertEqual(reopened.page.state,expected,'ordinary reopen must not clip periods to asset duration')
                self.assertEqual(reopened.video.asset_duration,rational(case['timeline']['assetDuration']))
                self.assertEqual(reopened.video.verified_asset_binding().timeline,case['timeline'])
                for row in case.get('frames',()):
                    result=reopened.video.frame_at_timed(rational(row['pts']))
                    self.assertEqual((result.time,result.presence),(rational(row['pts']),'content'))
                    self.assertEqual(marker(pixels(result.image)),row['markerCode'])
                if not case.get('frames'):
                    # Unique PCM fixtures have no independent RGB hash oracle.
                    self.assertEqual(reopened.video.first_frame_time,workspace.video.first_frame_time)
                    self.assertFalse(reopened.video.frame_at_timed(reopened.video.first_frame_time).image.isNull())
                reopened.selectionID=reopened.items()[0][0]['shape']['rectangle']['id']
                reopened.update_selected(blurRadius=99.125)
                self.assertTrue(reopened.can_undo)
                reopened.undo(); self.assertEqual(reopened.page.state,expected)
                reopened.redo(); self.assertEqual(reopened.page.state['regions'][0]['effect']['blurRadius'],99.125)
                edited=deepcopy(reopened.page.state); reopened.save_project(output2)
                saved=load_project(output2.read_bytes()).to_dict()
                self.assertEqual({k:saved[k] for k in edited},edited)
                self.assertEqual(saved['timeline'],case['timeline'])
                self.assertEqual(output.read_bytes(),original_project)
        finally:
            for current in (reopened,workspace):
                if current is not None: self.close_source(current)
            self.assertEqual(path.read_bytes(),before); self.assertEqual(manifest.read_bytes(),manifest_raw)

    def test_real_relink_uses_content_role_even_when_movie_is_renamed_png(self):
        path,case,before,manifest,manifest_raw=self.source('nonzero-origin')
        workspace=Workspace()
        try:
            with tempfile.TemporaryDirectory(prefix='bluraction-v3-relink-') as folder:
                root=Path(folder); source=root/'renamed.png'; source.write_bytes(before)
                tree=authored_project(path,case); tree['mediaPath']=r'Z:\other-host\missing.mov'
                project=root/'original.bluraction'; original=dump_project(PortableProject(tree)); project.write_bytes(original)
                from platforms.windows.bluraction.editor import MissingSources
                with self.assertRaises(MissingSources): workspace.load_project(project)
                workspace.load_project(project,relinks={tree['mediaPath']:source})
                self.assertEqual(workspace.video.path,source)
                self.assertEqual(workspace.page.state,rich_edits())
                self.assertEqual(workspace.video.verified_asset_binding().timeline,case['timeline'])
                first=case['frames'][0]
                self.assertEqual(marker(pixels(workspace.video.frame_at_timed(rational(first['pts'])).image)),first['markerCode'])
                saved=root/'relinked.bluraction'; workspace.save_project(saved)
                result=load_project(saved.read_bytes()).to_dict()
                self.assertEqual(result['mediaPath'],source.name)
                self.assertEqual(result['sourceSHA256'],case['sourceSHA256'])
                self.assertEqual(result['timeline'],tree['timeline'])
                self.assertEqual(project.read_bytes(),original); self.assertEqual(source.read_bytes(),before)
        finally:
            self.close_source(workspace)
            self.assertEqual(path.read_bytes(),before); self.assertEqual(manifest.read_bytes(),manifest_raw)

    def test_actual_failed_descriptor_sha_unknown_cancel_and_legacy_loads_keep_dirty_session(self):
        old_path,_,old_bytes,_,_=self.source('gap0-vfr')
        new_path,case,new_bytes,manifest,manifest_raw=self.source('nonzero-origin')
        workspace=self.owned(old_path); workspace.page.state=rich_edits()
        workspace._checkpoint(); workspace.page.state['drawings'][0]['name']='dirty change'
        workspace.undo(); workspace.redo(); workspace.selectionID=workspace.page.state['drawings'][0]['id']
        workspace.time=workspace.video.first_frame_time; before=self.snapshot(workspace)
        try:
            with tempfile.TemporaryDirectory(prefix='bluraction-v3-reject-') as folder:
                for mode in ('descriptor','sha','unknown','producer','cancel','legacy'):
                    with self.subTest(mode=mode):
                        tree=authored_project(new_path,case)
                        if mode=='descriptor': tree['timeline']['tracks'][0]['mediaTimescale']+=1
                        elif mode=='sha': tree['sourceSHA256']='0'*64
                        elif mode=='unknown': tree['drawings'][0]['futureMeaning']={'enabled':True}
                        elif mode=='producer': tree['producer']['platform']='unverified-platform'
                        elif mode=='legacy':
                            tree={key:tree[key] for key in ('mediaPath','sourceSHA256','regions','drawings')}
                            tree['version']=1
                        project=Path(folder)/(mode+'.bluraction')
                        # Malformed producer is tested as incoming raw JSON;
                        # it cannot be produced by the shared validated writer.
                        original=json.dumps(tree,ensure_ascii=False).encode('utf-8'); project.write_bytes(original)
                        candidates=[]; constructor=video.VideoSource
                        def capture(*args,**kwargs):
                            result=constructor(*args,**kwargs)
                            session=result.asset_session
                            candidates.append((session,session._process.pid,Path(session._directory.name)))
                            return result
                        error=Cancelled if mode=='cancel' else VideoTimelineReview if mode=='legacy' else ValueError
                        with patch.object(video,'VideoSource',side_effect=capture):
                            with self.assertRaises(error):
                                workspace.load_project(project,cancel=(lambda:bool(candidates)) if mode=='cancel' else None)
                        if mode in ('descriptor','cancel','legacy'): self.assertEqual(len(candidates),1)
                        for session,pid,directory in candidates:
                            self.assertIsNone(session._process); self.assertFalse(directory.exists())
                            self.assertNotIn(pid,[c.pid for c in multiprocessing.active_children()])
                        self.assert_snapshot(workspace,before)
                        self.assertEqual(project.read_bytes(),original)
        finally:
            self.close_source(workspace)
            self.assertEqual(old_path.read_bytes(),old_bytes); self.assertEqual(new_path.read_bytes(),new_bytes)
            self.assertEqual(manifest.read_bytes(),manifest_raw)

    def test_save_collision_source_overwrite_cancel_and_replacement_do_not_commit(self):
        path,case,source_bytes,manifest,manifest_raw=self.source('nonzero-origin')
        workspace=None
        try:
            with tempfile.TemporaryDirectory(prefix='bluraction-v3-save-') as folder:
                root=Path(folder); source=root/'owned.mov'; source.write_bytes(source_bytes)
                workspace=self.owned(source); workspace.page.state=rich_edits(); workspace.dirty=True
                before=self.snapshot(workspace)
                occupied=root/'occupied.bluraction'; occupied.write_bytes(b'preserve occupied output')
                for target in (occupied,source):
                    with self.assertRaises(FileExistsError): workspace.save_project(target)
                    self.assert_snapshot(workspace,before)
                self.assertEqual(occupied.read_bytes(),b'preserve occupied output')
                stop=[False]; original=workspace.video.verified_asset_binding
                def validated(cancel=None):
                    result=original(cancel); stop[0]=True; return result
                cancelled=root/'cancelled.bluraction'
                with patch.object(workspace.video,'verified_asset_binding',side_effect=validated):
                    with self.assertRaises(Cancelled): workspace.save_project(cancelled,cancel=lambda:stop[0])
                self.assertFalse(cancelled.exists()); self.assert_snapshot(workspace,before)
                # Change only an owned fixture copy after its baseline; no user
                # or pinned source is modified. Existing state remains dirty.
                source.write_bytes(source_bytes[:-1]+bytes([source_bytes[-1]^1]))
                changed=root/'changed.bluraction'
                with self.assertRaises(ValueError): workspace.save_project(changed)
                self.assertFalse(changed.exists())
                self.assertIs(workspace.video,before[1]); self.assertEqual(workspace.page.state,before[2])
                self.assertEqual(workspace._undo,before[3]); self.assertEqual(workspace._redo,before[4])
                self.assertEqual(workspace.selection_ids,before[5]); self.assertEqual(workspace.dirty,before[9])
                self.assertEqual(workspace._project_tree,before[10])
        finally:
            if workspace is not None: self.close_source(workspace)
            self.assertEqual(path.read_bytes(),source_bytes); self.assertEqual(manifest.read_bytes(),manifest_raw)

    def test_explicit_template_and_import_use_target_binding_clip_only_periods_and_keep_one_undo(self):
        old_path,old_case,old_bytes,_,_=self.source('nonzero-origin')
        target,target_case,target_bytes,manifest,manifest_raw=self.source('gap0-vfr')
        workspace=Workspace()
        try:
            with tempfile.TemporaryDirectory(prefix='bluraction-v3-template-') as folder:
                root=Path(folder); project=root/'template.bluraction'
                tree=authored_project(old_path,old_case); raw=dump_project(PortableProject(tree)); project.write_bytes(raw)
                workspace.apply_project_template(project,[target])
                duration=float(rational(target_case['timeline']['assetDuration']))
                for item,region in workspace.items():
                    properties=item['effect'] if region else item
                    self.assertEqual(properties['timeRange'],[duration,duration])
                self.assertEqual(workspace.page.state['regions'][0]['effect']['keyframes'],tree['regions'][0]['effect']['keyframes'])
                self.assertEqual(workspace.page.state['drawings'][0]['erasures'],tree['drawings'][0]['erasures'])
                output=root/'target.bluraction'; workspace.save_project(output)
                saved=load_project(output.read_bytes()).to_dict()
                self.assertEqual(saved['sourceSHA256'],target_case['sourceSHA256'])
                self.assertNotEqual(saved['sourceSHA256'],tree['sourceSHA256'])
                self.assertEqual(saved['timeline'],target_case['timeline'])
                previous=deepcopy(workspace.page.state); owner=workspace.video
                old_ids={workspace.item_id(item,region) for item,region in workspace.items()}
                workspace.import_project_items(project)
                self.assertIs(workspace.video,owner)
                self.assertEqual(len(workspace._undo[workspace.index]),1)
                self.assertEqual(len(workspace.page.state['regions']),6)
                self.assertTrue(workspace.selection_ids.isdisjoint(old_ids))
                new_groups={(item['effect'] if region else item).get('groupID') for item,region in workspace.items()
                            if workspace.item_id(item,region) in workspace.selection_ids}
                self.assertEqual(len(new_groups),1)
                workspace.undo(); self.assertEqual(workspace.page.state,previous)
                workspace.redo(); self.assertEqual(len(workspace.page.state['drawings']),12)
                self.assertEqual(project.read_bytes(),raw)
        finally:
            self.close_source(workspace)
            self.assertEqual(old_path.read_bytes(),old_bytes); self.assertEqual(target.read_bytes(),target_bytes)
            self.assertEqual(manifest.read_bytes(),manifest_raw)

    def test_temp_flush_source_replacement_or_late_cancel_prevents_publication(self):
        path,_,source_bytes,manifest,manifest_raw=self.source('nonzero-origin')
        real_fsync=os.fsync
        for mode in ('bytes','inode','cancel'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory(prefix='bluraction-v3-flush-') as folder:
                root=Path(folder); source=root/'owned.mov'; source.write_bytes(source_bytes)
                workspace=self.owned(source)
                try:
                    workspace.page.state=rich_edits(); workspace._checkpoint()
                    workspace.page.state['drawings'][0]['name']='unsaved'; workspace.undo(); workspace.redo()
                    workspace.selectionID=workspace.page.state['drawings'][0]['id']
                    old=self.snapshot(workspace); session=workspace.video.asset_session
                    output=root/'not-published.bluraction'; stopped=[False]; calls=[]
                    def flushed(fd):
                        real_fsync(fd); calls.append(fd)
                        # Runs only after the actual project temporary file has
                        # been flushed. Both old JSON and pinned MOV stay local.
                        if mode=='bytes':
                            source.write_bytes(source_bytes[:-1]+bytes([source_bytes[-1]^1]))
                        elif mode=='inode':
                            replacement=root/'replacement.mov'; replacement.write_bytes(source_bytes)
                            os.replace(replacement,source)
                        else:
                            stopped[0]=True
                    with patch('platforms.windows.bluraction.media.os.fsync',side_effect=flushed):
                        with self.assertRaises(Cancelled if mode=='cancel' else ValueError):
                            workspace.save_project(output,cancel=lambda:stopped[0])
                    self.assertEqual(len(calls),1)
                    self.assertFalse(output.exists())
                    self.assertEqual(list(root.glob('.bluraction-*.tmp')),[])
                    self.assertIs(workspace.page,old[0]); self.assertIs(workspace.video,old[1])
                    self.assertEqual(workspace.page.state,old[2]); self.assertEqual(workspace._undo,old[3])
                    self.assertEqual(workspace._redo,old[4]); self.assertEqual(workspace.selection_ids,old[5])
                    self.assertEqual(workspace.dirty,old[9]); self.assertEqual(workspace._project_tree,old[10])
                    self.assertEqual(pixels(workspace.page._image),old[11])
                    self.assertIs(workspace.video.asset_session,session); self.assertTrue(session._process.is_alive())
                finally:
                    self.close_source(workspace)
        self.assertEqual(path.read_bytes(),source_bytes); self.assertEqual(manifest.read_bytes(),manifest_raw)

    def test_actual_qt_worker_open_import_and_save_keep_presented_pts_and_borrowed_session(self):
        from PySide6.QtWidgets import QApplication, QFileDialog, QMessageBox
        from platforms.windows.bluraction.ui import BlurActionWindow
        app=QApplication.instance() or QApplication([])
        def wait(predicate):
            deadline=time.monotonic()+15
            while not predicate() and time.monotonic()<deadline:
                app.processEvents(); time.sleep(.005)
            self.assertTrue(predicate(),'actual Qt v3 worker/preview did not complete')
        path,case,before,manifest,manifest_raw=self.source('nonzero-origin')
        window=BlurActionWindow(); session=None
        try:
            with tempfile.TemporaryDirectory(prefix='bluraction-v3-qt-') as folder, \
                 patch('platforms.windows.bluraction.ui.QMessageBox.warning',
                       return_value=QMessageBox.StandardButton.Ok) as warnings:
                project=Path(folder)/'mac-authored.bluraction'
                tree=authored_project(path,case); project_bytes=dump_project(PortableProject(tree))
                project.write_bytes(project_bytes)
                window.open_project(project)
                wait(lambda:not window.workspace.busy and not window.canvas.preview_pending)
                self.assertEqual(warnings.call_count,0)
                self.assertEqual(window.workspace.page.state,rich_edits())
                session=window.workspace.video.asset_session
                self.assertIsNotNone(session)
                first=rational(case['frames'][0]['pts'])
                self.assertEqual(window.workspace.time,first)
                self.assertEqual(window.canvas.time,first)
                owner=window.workspace.video; old_state=deepcopy(window.workspace.page.state)
                window.import_item_project(project)
                self.assertTrue(window.workspace.busy)
                wait(lambda:not window.workspace.busy and not window.canvas.preview_pending)
                self.assertEqual(warnings.call_count,0)
                self.assertIs(window.workspace.video,owner)
                self.assertIs(window.workspace.video.asset_session,session)
                self.assertTrue(session._process.is_alive())
                self.assertEqual(window.workspace.time,first); self.assertEqual(window.canvas.time,first)
                self.assertEqual(len(window.workspace.page.state['drawings']),12)
                window.workspace.undo(); self.assertEqual(window.workspace.page.state,old_state)
                window.refresh(); wait(lambda:not window.canvas.preview_pending)
                # Real controller callbacks create at the actually presented
                # asset PTS, rather than a shorter Qt-native transport origin.
                from platforms.windows.bluraction.renderer import render
                unedited=pixels(render(window.canvas.image,old_state,window.workspace.time))
                window.create_item('cover_rectangle',[[.15,.15],[.7,.7]])
                wait(lambda:not window.canvas.preview_pending)
                effect=window.workspace.page.state['regions'][-1]['effect']
                self.assertEqual(effect['timeRange'],[first,window.workspace.video.duration])
                self.assertNotEqual(pixels(render(window.canvas.image,window.workspace.page.state,
                                                 window.workspace.time)),unedited)
                window.create_item('rectangle',[[.1,.1],[.8,.8]])
                wait(lambda:not window.canvas.preview_pending)
                self.assertEqual(window.workspace.page.state['drawings'][-1]['timeRange'],
                                 [first,window.workspace.video.duration])
                generated_state=deepcopy(window.workspace.page.state)
                output=Path(folder)/'windows-authored.bluraction'
                with patch.object(QFileDialog,'getSaveFileName',return_value=(str(output),'BlurAction')):
                    window.save_dialog()
                wait(lambda:not window.workspace.busy and not window.canvas.preview_pending)
                self.assertEqual(warnings.call_count,0)
                result=load_project(output.read_bytes()).to_dict()
                self.assertEqual(result['version'],3)
                self.assertEqual(result['timeline'],case['timeline'])
                self.assertEqual({k:result[k] for k in generated_state},generated_state)
                self.assertEqual(window.workspace.time,first)
                self.assertEqual(project.read_bytes(),project_bytes)
        finally:
            window.close()
            if session is not None:
                session.close()
                self.assertIsNone(session._process)
            self.assertEqual(path.read_bytes(),before); self.assertEqual(manifest.read_bytes(),manifest_raw)


for _kind in KINDS+UNIQUE:
    def _roundtrip(self,kind=_kind): self.roundtrip(kind)
    setattr(ActualVideoProjectV3HostTests,'test_actual_v3_'+_kind.replace('-','_'),_roundtrip)
