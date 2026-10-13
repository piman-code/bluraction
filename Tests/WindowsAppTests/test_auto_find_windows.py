"""New feature regressions; fixtures are retained, never cleaned or deleted."""
from copy import deepcopy
from fractions import Fraction
import math
import os
import threading
import time
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import uuid

from PySide6.QtGui import QImage
from PySide6.QtWidgets import QApplication
from platforms.windows.bluraction.auto_find import Detection, detect, deduplicate, normalized_box, text_lines
from platforms.windows.bluraction.auto_tracking import track_many, smooth_frames
from platforms.windows.bluraction.auto_find_smoke import SyntheticVideo
from platforms.windows.bluraction.find_actions import prepared_regions, commit_find, commit_tracking
from platforms.windows.bluraction.editor import Workspace
from platforms.windows.bluraction.media import Cancelled, Page, fingerprint

APP = QApplication.instance() or QApplication([])
BLACK = {'red':0,'green':0,'blue':0,'alpha':1}


class AreaTests(unittest.TestCase):
    def test_top_left_pixels_map_to_bottom_left_portable_box(self):
        box = normalized_box(20,10,40,30,100,100,'text',.8)
        self.assertAlmostEqual(box.rect[0],.16)
        self.assertAlmostEqual(box.rect[1],.66)

    def test_faces_pad_hair_and_chin(self):
        box = normalized_box(20,20,40,40,100,100,'faces',.9)
        self.assertEqual(tuple(round(v,2) for v in box.rect),(.16,.57,.28,.30))

    def test_edge_padding_stays_inside_frame(self):
        box = normalized_box(0,0,100,100,100,100,'faces',.9)
        self.assertEqual(box.rect,(0,0,1,1))

    def test_tiny_finds_are_enlarged_not_dropped(self):
        box = normalized_box(999,999,1000,1000,1000,1000,'text',.9)
        self.assertGreater(box.rect[2],.01)
        self.assertGreater(box.rect[3],.01)
        self.assertLessEqual(box.rect[0]+box.rect[2],1.)

    def test_nonfinite_or_empty_boxes_are_rejected(self):
        for value in (float('nan'),float('inf')):
            self.assertIsNone(normalized_box(value,1,2,3,10,10,'text',.9))
        self.assertIsNone(normalized_box(2,1,1,2,10,10,'text',.9))

    def test_overlapping_tile_detections_are_deduplicated(self):
        a=Detection((.1,.2,.3,.1),'text',.95)
        b=Detection((.105,.202,.3,.1),'text',.9)
        self.assertEqual(deduplicate([a,b]),[a])

    def test_separate_text_boxes_are_retained(self):
        boxes=[Detection((.1,.1,.1,.1),'text',.9),Detection((.8,.8,.1,.1),'text',.9)]
        self.assertEqual(len(deduplicate(boxes)),2)

    def test_full_text_line_precedes_confident_word_fragments(self):
        line=Detection((.1,.5,.6,.1),'text',1.)
        word=Detection((.11,.51,.15,.08),'text',.999)
        self.assertEqual(deduplicate([word,line]),[line])

    def test_a_confident_word_does_not_hide_the_rest_of_its_line(self):
        line=Detection((.1,.5,.6,.1),'text',.6)
        word=Detection((.11,.51,.15,.08),'text',.9)
        for order in ([word,line],[line,word]):
            self.assertEqual([d.rect for d in deduplicate(order)],[line.rect])
            self.assertEqual(deduplicate(order)[0].confidence,.9)

    def test_a_confident_caption_does_not_hide_the_title_over_it(self):
        title=Detection((.2,.3,.3,.12),'text',.55)
        caption=Detection((.22,.33,.1,.03),'text',.95)
        self.assertEqual([d.rect for d in deduplicate([caption,title])],[title.rect])

    def test_near_identical_tile_boxes_still_collapse_to_the_first(self):
        a=Detection((.1,.2,.3,.1),'text',.95)
        b=Detection((.12,.21,.28,.1),'text',.9)
        self.assertEqual(deduplicate([a,b]),[a])

    def test_dense_page_joins_words_before_the_512_limit(self):
        # 35 lines of 20 words: 700 word boxes, but only 35 lines.
        words=[Detection((.02+j*.045,.05+i*.025,.04,.02),'text',.9) for i in range(35) for j in range(20)]
        with self.assertRaises(ValueError):
            deduplicate(words)
        lines=text_lines(words,900,400)
        self.assertEqual(len(lines),35)

    def test_fragment_flood_is_refused_before_joining(self):
        flood=[Detection((.001*(j%900),.001*(j//900),.0005,.0005),'text',.9) for j in range(6001)]
        with self.assertRaises(ValueError):
            text_lines(flood,900,400)

    def test_same_baseline_word_anchors_cover_missing_middle_words(self):
        anchors=[Detection((.05,.7,.14,.19),'text',.9),Detection((.44,.68,.15,.23),'text',.9)]
        lines=text_lines(anchors,900,400)
        self.assertEqual(len(lines),1)
        self.assertLess(lines[0].rect[0],.32)
        self.assertGreater(lines[0].rect[0]+lines[0].rect[2],.32)

    def test_separate_rows_and_wide_columns_remain_separate(self):
        anchors=[Detection((.05,.7,.14,.06),'text',.9),Detection((.6,.7,.15,.06),'text',.9),
                 Detection((.05,.2,.14,.06),'text',.9)]
        self.assertEqual(len(text_lines(anchors,900,400)),3)

    def test_detection_cancel_before_native_work(self):
        image=QImage(32,32,QImage.Format.Format_RGB32)
        image.fill(0xffffffff)
        with self.assertRaises(Cancelled):
            detect(image,'faces',lambda:True)

    def test_model_failure_is_explicit(self):
        image=QImage(32,32,QImage.Format.Format_RGB32)
        with patch('platforms.windows.bluraction.auto_find.model_directory',return_value=Path('nonexistent-model-directory')):
            with self.assertRaisesRegex(ValueError,'모델'):
                detect(image,'text')


class TransactionTests(unittest.TestCase):
    def setUp(self):
        fixture_root=Path(os.environ.get('BLURACTION_FEATURE_TEST_OUTPUT',
                         str(Path(__file__).resolve().parents[2]/'outputs/Windows-auto-find-fixtures')))
        self.root=fixture_root/uuid.uuid4().hex
        self.root.mkdir(parents=True)
        self.source=self.root/'source.png'
        image=QImage(100,100,QImage.Format.Format_RGB32)
        image.fill(0xffffffff)
        image.save(str(self.source))
        self.workspace=Workspace()
        self.workspace._replace([Page(self.source,fingerprint(self.source),image)],'fixture')
        self.finds=[Detection((.1,.1,.2,.2),'faces',.9),Detection((.6,.6,.2,.1),'text',.9)]

    def prepare(self,finds=None):
        return prepared_regions(finds or self.finds,self.workspace.page.state,0.,None,
                                style='solid',radius=0.,feather=0.,color=BLACK)

    def test_face_is_ellipse_text_is_rectangle_and_names_are_portable(self):
        regions=self.prepare()
        self.assertIn('ellipse',regions[0]['shape'])
        self.assertIn('rectangle',regions[1]['shape'])
        self.assertEqual(regions[0]['effect']['name'],'찾은 얼굴')

    def test_find_commit_is_one_undo_and_redo(self):
        ids=commit_find(self.workspace,self.prepare())
        self.assertEqual(len(ids),2)
        self.assertEqual(self.workspace.selection_ids,ids)
        self.workspace.undo()
        self.assertEqual(self.workspace.page.state['regions'],[])
        self.workspace.redo()
        self.assertEqual(len(self.workspace.page.state['regions']),2)

    def test_preparation_never_mutates_current_state(self):
        before=deepcopy(self.workspace.page.state)
        self.prepare()
        self.assertEqual(self.workspace.page.state,before)
        self.assertFalse(self.workspace.can_undo)

    def test_fully_covered_rectangle_is_skipped(self):
        self.workspace.add_cover('rectangle',[[0,0],[1,1]])
        self.assertEqual(self.prepare(),[])

    def test_partial_or_erased_cover_does_not_hide_a_find(self):
        self.workspace.add_cover('rectangle',[[0,0],[1,1]])
        self.workspace.page.state['regions'][0]['effect']['erasures']=[{'points':[[.2,.2]],'width':.02,'timeRange':[0,0]}]
        self.assertEqual(len(self.prepare()),2)

    def test_hidden_cover_does_not_hide_a_find(self):
        self.workspace.add_cover('rectangle',[[0,0],[1,1]])
        self.workspace.page.state['regions'][0]['effect']['enabled']=False
        self.assertEqual(len(self.prepare()),2)

    def test_zero_strength_cover_does_not_hide_a_find(self):
        self.workspace.add_cover('rectangle',[[0,0],[1,1]])
        self.workspace.page.state['regions'][0]['effect']['blurRadius']=0
        self.assertEqual(len(self.prepare()),2)

    def test_remove_keeps_locked_found_region_and_one_undo(self):
        ids=commit_find(self.workspace,self.prepare())
        self.workspace.page.state['regions'][0]['effect']['locked']=True
        self.workspace.selection_ids=ids
        self.workspace.delete_selected()
        self.assertEqual(len(self.workspace.page.state['regions']),1)
        self.workspace.undo()
        self.assertEqual(len(self.workspace.page.state['regions']),2)

    def test_tracking_commit_is_one_undo_and_keeps_unselected_items(self):
        commit_find(self.workspace,self.prepare())
        before=deepcopy(self.workspace.page.state)
        identifier=next(iter(before['regions'][0]['shape'].values()))['id']
        frames=[{'time':0.,'rect':[[.2,.2],[.2,.2]]}]
        commit_tracking(self.workspace,[SimpleNamespace(item_id=identifier,skipped=False,keyframes=frames,time_range=[0.,1.])])
        self.assertEqual(self.workspace.page.state['regions'][1],before['regions'][1])
        self.workspace.undo()
        self.assertEqual(self.workspace.page.state,before)


class ConstantTracker:
    def init(self,image,roi):
        self.roi=roi
        return True
    def update(self,image):
        return True,self.roi


class TrackingTests(unittest.TestCase):
    def setUp(self):
        self.source=SyntheticVideo()

    def run_paths(self,targets=None,**kwargs):
        with patch('platforms.windows.bluraction.auto_tracking._csrt',side_effect=lambda:(None,ConstantTracker())):
            return track_many(self.source,targets or self.source.targets(),1.,**kwargs)

    def test_forward_timestamps(self):
        result=self.run_paths(direction='forward',smoothing=False)
        self.assertEqual([f['time'] for f in result[0].keyframes],[i/12 for i in range(12,24)])

    def test_backward_timestamps(self):
        result=self.run_paths(direction='backward',smoothing=False)
        self.assertEqual([f['time'] for f in result[0].keyframes],[i/12 for i in range(13)])

    def test_both_has_unique_actual_times_and_keeps_input(self):
        targets=self.source.targets()
        before=deepcopy(targets)
        result=self.run_paths(targets,direction='both')
        self.assertEqual(targets,before)
        self.assertEqual([f['time'] for f in result[0].keyframes],[i/12 for i in range(24)])

    def test_more_than_32_targets_are_processed_in_batches(self):
        targets=[]
        for index in range(33):
            item,region=deepcopy(self.source.targets()[0])
            item['shape']['rectangle']['id']=str(index)
            targets.append((item,region))
        result=self.run_paths(targets,direction='forward')
        self.assertEqual(len(result),33)
        self.assertTrue(all(len(r.keyframes)==12 for r in result))

    def test_locked_and_tiny_targets_are_skipped(self):
        targets=self.source.targets()
        targets[0][0]['effect']['locked']=True
        targets[1][0]['shape']['rectangle']['size']=[.001,.001]
        self.assertTrue(all(r.skipped for r in self.run_paths(targets)))

    def test_future_target_is_skipped(self):
        targets=self.source.targets()
        targets[0][0]['effect']['timeRange']=[1.5,2.]
        self.assertTrue(self.run_paths(targets)[0].skipped)

    def test_immediate_tracking_loss_never_means_entire_video(self):
        class LostTracker(ConstantTracker):
            def update(self,image): return False,(0,0,0,0)
        with patch('platforms.windows.bluraction.auto_tracking._csrt',side_effect=lambda:(None,LostTracker())):
            result=track_many(self.source,self.source.targets(0),0.,direction='forward',reacquire_faces=False)
        self.assertTrue(all(r.lost for r in result))
        self.assertTrue(all(r.time_range[1]>r.time_range[0] for r in result))
        self.assertTrue(all(r.time_range[1] <= 1/12 for r in result))

    def test_gap_stops_path_at_verified_interval(self):
        self.source.frames[14]=SimpleNamespace(**{**self.source.frames[14].__dict__,'presence':'blank'})
        result=self.run_paths(direction='forward')
        self.assertTrue(all(r.lost for r in result))
        self.assertTrue(all(r.time_range[1]<=13/12 for r in result))

    def test_cancel_discards_all_paths(self):
        with self.assertRaises(Cancelled):
            self.run_paths(cancel=lambda:True)

    def test_nonfinite_times_are_refused(self):
        with self.assertRaises(ValueError):
            track_many(self.source,self.source.targets(),float('nan'))

    def test_smoothing_keeps_raw_cover_inside(self):
        frames=[{'time':float(i),'rect':[[x,.2],[.1,.2]]} for i,x in enumerate((.1,.15,.11))]
        for raw,smoothed in zip(frames,smooth_frames(frames,True)):
            (x,y),(w,h)=smoothed['rect']
            self.assertLessEqual(x,raw['rect'][0][0]+1e-9)
            self.assertGreaterEqual(x+w,raw['rect'][0][0]+.1-1e-9)

    def test_reverse_no_progress_is_explicit(self):
        self.source.frame_at_timed=lambda stamp,cancel=None:self.source.frames[12]
        with self.assertRaisesRegex(ValueError,'이전'):
            self.run_paths(direction='backward')

    def test_unique_nearby_face_is_reacquired(self):
        class LostTracker(ConstantTracker):
            def update(self,image): return False,(0,0,0,0)
        targets=self.source.targets()[:1]
        targets[0][0]['effect']['name']='찾은 얼굴'
        (x,y),(w,h)=targets[0][0]['shape']['rectangle']['origin'],targets[0][0]['shape']['rectangle']['size']
        trackers=iter([LostTracker(),ConstantTracker()])
        with patch('platforms.windows.bluraction.auto_tracking._csrt',side_effect=lambda:(None,next(trackers))), \
             patch('platforms.windows.bluraction.auto_find.detect',return_value=[Detection((x,y,w,h),'faces',1.)]) as detector:
            result=track_many(self.source,targets,1.,direction='forward',smoothing=False)
        self.assertFalse(result[0].lost)
        self.assertEqual(len(result[0].keyframes),12)
        self.assertEqual(detector.call_count,1)

    def test_ambiguous_nearby_faces_are_not_silently_assigned(self):
        class LostTracker(ConstantTracker):
            def update(self,image): return False,(0,0,0,0)
        targets=self.source.targets()[:1]
        targets[0][0]['effect']['name']='찾은 얼굴'
        (x,y),(w,h)=targets[0][0]['shape']['rectangle']['origin'],targets[0][0]['shape']['rectangle']['size']
        faces=[Detection((x,y,w,h),'faces',1.),Detection((x+.01,y,w,h),'faces',1.)]
        with patch('platforms.windows.bluraction.auto_tracking._csrt',side_effect=lambda:(None,LostTracker())), \
             patch('platforms.windows.bluraction.auto_find.detect',return_value=faces):
            result=track_many(self.source,targets,1.,direction='forward',smoothing=False)
        self.assertTrue(result[0].lost)
        self.assertEqual(len(result[0].keyframes),1)


class WindowTests(unittest.TestCase):
    """Exercise real Qt worker delivery without automating the desktop UI."""
    prepare=TransactionTests.prepare

    def setUp(self):
        TransactionTests.setUp(self)
        from platforms.windows.bluraction.ui import BlurActionWindow
        self.window=BlurActionWindow()
        self.window.workspace=self.workspace
        self.errors=[]
        self.window.show_error=lambda error:self.errors.append(str(error))
        self.information=patch('platforms.windows.bluraction.ui.QMessageBox.information',return_value=None)
        self.information.start()
        self.window.refresh()
        self.wait_for(lambda:not self.window.canvas.preview_pending)

    def wait_for(self,predicate,timeout=8):
        deadline=time.monotonic()+timeout
        while not predicate() and time.monotonic()<deadline:
            APP.processEvents()
            time.sleep(.005)
        APP.processEvents()
        self.assertTrue(predicate(),'Qt operation did not settle')

    def tearDown(self):
        self.workspace.dirty=False
        self.window.cancel_operation()
        if self.workspace.busy:
            self.wait_for(lambda:not self.workspace.busy)
        self.wait_for(lambda:not self.window.canvas.preview_pending)
        self.window.close()
        APP.processEvents()
        self.information.stop()

    def test_find_buttons_enabled_after_preview_and_disabled_while_busy(self):
        self.assertTrue(self.window.find_faces_button.isEnabled())
        self.assertTrue(self.window.find_text_button.isEnabled())
        self.workspace.busy=True
        self.window._update_find_buttons()
        self.assertFalse(self.window.find_text_button.isEnabled())
        self.workspace.busy=False

    def test_actual_worker_commits_find_once_and_recent_remove_undo(self):
        with patch('platforms.windows.bluraction.auto_find.detect',return_value=self.finds):
            self.window.auto_find('faces')
            self.wait_for(lambda:not self.workspace.busy)
        self.assertFalse(self.errors)
        self.assertEqual(len(self.workspace.page.state['regions']),2)
        self.assertEqual(self.window._current_find_ids(),self.workspace.selection_ids)
        self.workspace.undo()
        self.assertEqual(self.workspace.page.state['regions'],[])
        self.workspace.redo()
        self.window.refresh()
        self.wait_for(lambda:not self.window.canvas.preview_pending)
        self.window.remove_latest_finds()
        self.assertEqual(self.workspace.page.state['regions'],[])
        self.workspace.undo()
        self.assertEqual(len(self.workspace.page.state['regions']),2)

    def test_worker_result_after_cancellation_never_commits(self):
        release=threading.Event()
        entered=threading.Event()
        def delayed(*args,**kwargs):
            entered.set()
            release.wait(4)
            return self.finds
        with patch('platforms.windows.bluraction.auto_find.detect',side_effect=delayed):
            self.window.auto_find('text')
            self.wait_for(entered.is_set)
            self.window.cancel_operation()
            release.set()
            self.wait_for(lambda:not self.workspace.busy)
        self.assertEqual(self.workspace.page.state['regions'],[])
        self.assertFalse(self.workspace.can_undo)
        self.assertFalse(self.errors)

    def test_changed_editor_state_discards_worker_result(self):
        release=threading.Event()
        entered=threading.Event()
        def delayed(*args,**kwargs):
            entered.set()
            release.wait(4)
            return self.finds
        with patch('platforms.windows.bluraction.auto_find.detect',side_effect=delayed):
            self.window.auto_find('text')
            self.wait_for(entered.is_set)
            self.workspace.page.state['regions'].append(self.prepare()[0])
            release.set()
            self.wait_for(lambda:not self.workspace.busy)
        self.assertEqual(len(self.workspace.page.state['regions']),1)
        self.assertEqual(len(self.errors),1)

    def test_recent_find_ids_do_not_cross_pages(self):
        self.window._last_find_page=object()
        self.window._last_find_ids={'other-page-id'}
        self.assertEqual(self.window._current_find_ids(),set())


if __name__=='__main__':
    unittest.main()
