"""Controlled owned-provider contracts, not audited IO/native codec/P1 proof.

BMFF metadata is actually inspected, and actual FrameInventory spools are built
through explicit fake decoder seams. All source bytes belong to this test.
No current application, network, encoder, Qt audio or native player is used.
"""
from copy import deepcopy
from contextlib import contextmanager
from dataclasses import replace
from fractions import Fraction as F
import hashlib
from pathlib import Path
import tempfile
from threading import Event
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from PIL import Image
from platforms.windows.bluraction import canonical_video as video
from platforms.windows.bluraction import frame_inventory as raw
from platforms.windows.bluraction import local_decoder
from Tests.WindowsAppTests.test_asset_timeline import movie, track


def frame(pts, duration=250, **changes):
    fields=dict(pts=pts,duration=duration,time_base=F(1,1000),width=96,height=64,
        rotation=0.0,sample_aspect_ratio=F(1),side_data={},is_corrupt=False,
        format=SimpleNamespace(components=[SimpleNamespace(bits=8)]),color_trc=1,
        to_image=lambda:Image.new('RGB',(96,64),(20,180,40)))
    fields.update(changes)
    return SimpleNamespace(**fields)


class Container:
    def __init__(self, rows, *, seek_failure=False, exit_action=None, exit_failure=None):
        self.rows=rows; self.seek_failure=seek_failure; self.closed=False
        self.exit_action=exit_action; self.exit_failure=exit_failure
        self.seek_calls=[]; self.iterator_closed=False
        self.format=SimpleNamespace(name='mov')
        self.streams=SimpleNamespace(video=[SimpleNamespace(id=2,index=0,time_base=F(1,1000),
            width=96,height=64,codec_context=SimpleNamespace(sample_aspect_ratio=F(1)),
            sample_aspect_ratio=F(1),metadata={})])
    def __enter__(self): return self
    def __exit__(self,*args): self.close()
    def close(self):
        self.closed=True
        if self.exit_action is not None: self.exit_action()
        if self.exit_failure is not None: raise self.exit_failure
    def seek(self,offset,**kwargs):
        self.seek_calls.append(offset)
        if self.seek_failure: raise OSError('controlled unavailable seek')
    def decode(self,*args,**kwargs):
        try:
            yield from self.rows
        finally:
            self.iterator_closed=True


class CanonicalVideoTests(unittest.TestCase):
    def setUp(self):
        self.directory=tempfile.TemporaryDirectory(); self.addCleanup(self.directory.cleanup)
        self.source=Path(self.directory.name)/'controlled.mov'
        self.source.write_bytes(movie(track(identity=2,ticks=1000,media_ticks=500,
            entries=((500,-1,1),(500,0,1)),timing_entries=((2,250),)),ticks=1500))
        self.original=self.source.read_bytes(); self.sha=hashlib.sha256(self.original).hexdigest()
        self.rows=[frame(500),frame(750)]; self.inventories=[]; self.containers=[]
        self.inventory_options=[]; self.pixel_options=[]; self.received_files=[]
        self.current=[9]; self.event=Event()

    def access(self, *, pixel_rows=None, seek_failure=False, pixel_exit=None,
               pixel_exit_failure=None, inventory_change=None):
        def build_inventory(path,**kwargs):
            self.inventory_options.append(kwargs['demux_options'].copy())
            container=Container(self.rows)
            module=SimpleNamespace(__version__='19.0.0',open=lambda *a,**k:container)
            with patch.object(raw,'_av',return_value=module), \
                 patch.object(local_decoder,'_av',return_value=module):
                result=raw.FrameInventory.build(path,**kwargs)
            self.inventories.append(result); self.addCleanup(result.close)
            if inventory_change is not None: inventory_change(result)
            return result
        def open_decoder(file,**kwargs):
            self.received_files.append(file)
            self.pixel_options.append(kwargs['options'].copy())
            self.assertIsInstance(file,raw._BoundedInput)
            self.assertEqual(file.read(16),self.original[:16])
            container=Container(self.rows if pixel_rows is None else pixel_rows,
                seek_failure=seek_failure,exit_action=pixel_exit,exit_failure=pixel_exit_failure)
            self.containers.append(container); return container
        return video.DecoderAccess(build_inventory,open_decoder)

    def build(self,**kwargs):
        arguments=dict(expected_sha256=self.sha,generation=9,decoder_access=self.access(),
            current_generation=lambda:self.current[0],cancel=self.event)
        arguments.update(kwargs)
        result=video.OwnedCanonicalVideoProvider.build(self.source,**arguments)
        self.addCleanup(result.close)
        return result

    def test_explicit_access_gate_precedes_any_decoder_or_source_mutation(self):
        for access in (None,SimpleNamespace()):
            with self.assertRaisesRegex(video.CanonicalVideoReview,'inventory AND pixels'):
                video.OwnedCanonicalVideoProvider.build(self.source,expected_sha256=self.sha,
                    generation=9,decoder_access=access)
        self.assertEqual(self.inventories,[]); self.assertEqual(self.containers,[])
        self.assertEqual(self.source.read_bytes(),self.original)

    def test_exact_pixels_asset_duration_presence_boundaries_and_explicit_options(self):
        provider=self.build(); self.assertEqual(provider.asset_duration,F(3,2))
        for time,kind in ((F(0),'empty'),(F(1,4),'empty'),(F(1),'suffix'),(F(3,2),'EOF')):
            result=provider.frame_at(time)
            self.assertEqual(result.presence,kind); self.assertIsNone(result.image)
            self.assertIsNone(result.asset_pts); self.assertIsNone(result.source_index)
        self.assertEqual(self.containers,[])
        result=provider.frame_at(F(7,8))
        self.assertEqual(result.asset_pts,F(3,4)); self.assertEqual(result.source_index,1)
        self.assertEqual(result.interval_end,F(1)); self.assertEqual(result.requested_time,F(7,8))
        self.assertEqual(result.image.pixelColor(0,0).getRgb(),(20,180,40,255))
        self.assertEqual(result.source_sha256,self.sha); self.assertEqual(result.generation,9)
        self.assertEqual(result.descriptor_sha256,provider.descriptor_sha256)
        self.assertEqual(self.inventory_options,[{'advanced_editlist':'1','ignore_editlist':'0'}])
        self.assertEqual(self.pixel_options,[{'advanced_editlist':'1','ignore_editlist':'0'}])
        self.assertEqual(self.containers[0].seek_calls,[750]); self.assertTrue(self.containers[0].closed)
        self.assertTrue(self.containers[0].iterator_closed)
        self.assertTrue(self.received_files[0].stream.closed)
        self.assertEqual(self.source.read_bytes(),self.original)

    def test_single_cached_image_is_not_mutated_by_returned_qimage_and_no_new_decoder(self):
        provider=self.build(); first=provider.frame_at(F(1,2)); first.image.fill(0)
        second=provider.frame_at(F(3,5))
        self.assertEqual(len(self.containers),1)
        self.assertEqual(second.image.pixelColor(0,0).getRgb(),(20,180,40,255))
        self.assertEqual(first.asset_pts,second.asset_pts)

    def test_seek_failure_uses_fresh_owned_descriptor_and_exact_beginning_match(self):
        provider=self.build(decoder_access=self.access(seek_failure=True))
        result=provider.frame_at(F(3,4))
        self.assertEqual(result.asset_pts,F(3,4)); self.assertEqual(len(self.containers),2)
        self.assertEqual([c.seek_calls for c in self.containers],[[750],[]])
        self.assertTrue(all(c.closed for c in self.containers))
        self.assertTrue(all(f.stream.closed for f in self.received_files))

    def test_secondary_seek_request_never_becomes_successful_fresh_decode(self):
        for native_failure in (False, True):
            with self.subTest(native_failure=native_failure):
                opened = []
                base = self.access()

                def native_open(file, **kwargs):
                    container = Container(self.rows)
                    opened.append(container)

                    def seek(*args, **options):
                        try:
                            kwargs['io_open']('controlled-secondary', 1, {})
                        except local_decoder.SecondaryIODenied:
                            pass  # Native optional IO can ignore callback denial.
                        if native_failure:
                            raise OSError('controlled native seek failed after denied IO')
                    container.seek = seek
                    return container

                module = SimpleNamespace(__version__='19.0.0', open=native_open)

                @contextmanager
                def guarded_open(file, **kwargs):
                    with patch.object(local_decoder, '_av', return_value=module):
                        with local_decoder.open_local_decoder(file, **kwargs) as decoder:
                            yield decoder

                provider = self.build(decoder_access=video.DecoderAccess(
                    base.build_inventory, guarded_open))
                inventory = self.inventories[-1]
                with self.assertRaises((local_decoder.SecondaryIODenied, OSError)):
                    provider.frame_at(F(3, 4))
                self.assertEqual(len(opened), 1, 'Denied IO must never open a fallback decoder')
                self.assertTrue(opened[0].closed)
                self.assertFalse(inventory.complete)
                with self.assertRaises(video.CanonicalVideoReview):
                    provider.frame_at(F(3, 4))
                self.assertEqual(self.source.read_bytes(), self.original)

    def test_missing_future_and_changed_row_metadata_fail_without_pixel_substitution(self):
        variants=([frame(750)], [frame(500,duration=251)], [frame(500,width=95)],
                  [frame(500,rotation=90.0)])
        for rows in variants:
            with self.subTest(rows=rows):
                provider=self.build(decoder_access=self.access(pixel_rows=rows))
                with self.assertRaisesRegex(video.CanonicalVideoReview,'exactly match'):
                    provider.frame_at(F(1,2))
                self.assertFalse(self.inventories[-1].complete)
                with self.assertRaises(video.CanonicalVideoReview): provider.frame_at(F(3,4))
        provider=self.build(decoder_access=self.access(pixel_rows=[]))
        with self.assertRaisesRegex(video.CanonicalVideoReview,'missing'):
            provider.frame_at(F(1,2))
        self.assertEqual(self.source.read_bytes(),self.original)

    def test_generation_cancel_permanently_discard_owned_candidate_and_keep_unrelated_inventory(self):
        unrelated=self.access().build_inventory(self.source,expected_sha256=self.sha,generation=9,
            demux_options={'advanced_editlist':'1','ignore_editlist':'0'})
        provider=self.build(); owned=self.inventories[-1]
        provider.frame_at(F(1,2)); self.current[0]=10
        with self.assertRaises(raw.FrameInventoryError): provider.frame_at(F(1,2))
        self.assertFalse(owned.complete); self.assertTrue(unrelated.complete)
        self.current[0]=9
        with self.assertRaises(video.CanonicalVideoReview): provider.frame_at(F(1,2))
        cancelled=self.build(); owned=self.inventories[-1]; self.event.set()
        with self.assertRaises(raw.InventoryCancelled): cancelled.frame_at(F(0))
        self.event.clear(); self.assertFalse(owned.complete)
        with self.assertRaises(video.CanonicalVideoReview): cancelled.frame_at(F(0))
        late=self.build(decoder_access=self.access(pixel_exit=self.event.set))
        with self.assertRaises(raw.InventoryCancelled): late.frame_at(F(1,2))
        self.event.clear(); self.assertFalse(self.inventories[-1].complete)
        self.assertTrue(unrelated.complete)

    def test_source_replacement_before_decode_rejects_and_never_changes_saved_edit_state(self):
        state={'regions':[{'timeRange':[.5,1.0],'keyframes':[{'time':.75}]}]}; before=deepcopy(state)
        provider=self.build(); replacement=self.source.with_suffix('.replacement')
        replacement.write_bytes(self.original); replacement.replace(self.source)
        with self.assertRaises(ValueError): provider.frame_at(F(1,2))
        self.assertFalse(self.inventories[-1].complete); self.assertEqual(self.containers,[])
        self.assertEqual(state,before); self.assertEqual(self.source.read_bytes(),self.original)

    def test_same_length_pixel_decode_mutation_cannot_publish_or_reuse_cached_frame(self):
        def mutate():
            value=bytearray(self.original); value[-1]^=1; self.source.write_bytes(value)
        provider=self.build(decoder_access=self.access(pixel_exit=mutate))
        with self.assertRaises(ValueError): provider.frame_at(F(1,2))
        self.assertFalse(self.inventories[-1].complete)
        self.assertTrue(self.containers[-1].closed)
        with self.assertRaises(video.CanonicalVideoReview): provider.frame_at(F(1,2))

    def test_wrong_inventory_binding_or_clock_options_cleanup_only_new_inventory(self):
        for change in (lambda inv:setattr(inv,'_generation',10),
                lambda inv:setattr(inv,'_decoder',replace(inv.decoder,demux_options=()))):
            with self.subTest(change=change):
                with self.assertRaises(ValueError): self.build(decoder_access=self.access(inventory_change=change))
                self.assertFalse(self.inventories[-1].complete)
        self.assertEqual(self.source.read_bytes(),self.original)

    def test_close_context_cleanup_and_invalid_exact_query_no_resource_leak(self):
        provider=self.build(); owned=self.inventories[-1]; private=Path(owned._directory.name)
        for time in (0,0.5,True,F(-1,10),F(2)):
            with self.assertRaises(video.CanonicalVideoReview): provider.frame_at(time)
        self.assertTrue(owned.complete)
        with provider: self.assertEqual(provider.frame_at(F(1,2)).source_index,0)
        provider.close(); self.assertFalse(owned.complete); self.assertFalse(private.exists())
        with self.assertRaises(video.CanonicalVideoReview): provider.descriptor_sha256
        self.assertEqual(self.source.read_bytes(),self.original)

    def test_known_hdr_high_depth_unknown_sar_hold_instead_of_silent_conversion(self):
        for changes in (dict(color_trc=16),dict(color_trc=18),
                dict(format=SimpleNamespace(components=[SimpleNamespace(bits=10)]))):
            # Inventory does not claim color proof. The pixel policy must refuse
            # unsupported conversion even though its raw timing row matches.
            provider=self.build(decoder_access=self.access(pixel_rows=[frame(500,**changes)]))
            with self.assertRaises(video.CanonicalVideoReview): provider.frame_at(F(1,2))
            self.assertFalse(self.inventories[-1].complete)
        self.rows=[frame(500,sample_aspect_ratio=None),frame(750,sample_aspect_ratio=None)]
        provider=self.build(decoder_access=self.access(inventory_change=lambda inv:
            setattr(inv,'_decoder',replace(inv.decoder,codec_sar=None))))
        with self.assertRaisesRegex(video.CanonicalVideoReview,'SAR unavailable'):
            provider.frame_at(F(1,2))
        self.assertFalse(self.inventories[-1].complete)
        self.assertEqual(self.source.read_bytes(),self.original)

    def test_primary_pixel_failure_survives_decoder_teardown_error_and_candidate_is_cleaned(self):
        cleanup_error=OSError('controlled decoder teardown failure')
        provider=self.build(decoder_access=self.access(pixel_rows=[frame(750)],pixel_exit_failure=cleanup_error))
        with self.assertRaisesRegex(video.CanonicalVideoReview,'exactly match') as caught:
            provider.frame_at(F(1,2))
        self.assertIs(caught.exception.__cause__,cleanup_error)
        self.assertTrue(any('decoder teardown' in text for text in caught.exception.__notes__))
        self.assertFalse(self.inventories[-1].complete)
        self.assertTrue(self.received_files[-1].stream.closed)

    def test_same_cancel_error_during_active_pixels_and_decoder_close_preserves_first_error(self):
        old=self.build(); old_image=old.frame_at(F(1,2)).image
        old_inventory=self.inventories[-1]
        cancelled=[False]; primary=raw.InventoryCancelled('controlled repeated pixel cancellation')
        def cancel_check():
            if cancelled[0]: raise primary
            return False
        def pixels_then_cancel():
            cancelled[0]=True
            return Image.new('RGB',(96,64),(20,180,40))
        provider=self.build(cancel=cancel_check,decoder_access=self.access(
            pixel_rows=[frame(500,to_image=pixels_then_cancel)],pixel_exit_failure=primary))
        owned=self.inventories[-1]; private=Path(owned._directory.name)
        with self.assertRaises(raw.InventoryCancelled) as caught:
            provider.frame_at(F(1,2))
        self.assertIs(caught.exception,primary); self.assertIsNot(primary.__cause__,primary)
        self.assertTrue(any('pixel decoder teardown' in n for n in primary.__notes__))
        self.assertTrue(self.containers[-1].iterator_closed); self.assertTrue(self.containers[-1].closed)
        self.assertFalse(owned.complete); self.assertFalse(private.exists())
        self.assertTrue(self.received_files[-1].stream.closed)
        cancelled[0]=False
        with self.assertRaises(video.CanonicalVideoReview): provider.frame_at(F(1,2))
        self.assertTrue(old_inventory.complete)
        self.assertEqual(old.frame_at(F(1,2)).image,old_image)
        self.assertEqual(self.source.read_bytes(),self.original)

    def test_descriptor_dto_reads_are_independent_of_caller_mutation_and_stale_review(self):
        provider=self.build(); snapshot=provider.timeline; original=deepcopy(snapshot)
        digest=provider.descriptor_sha256
        snapshot['tracks'][0]['segments'][1]['mediaStart']['numerator']='99'
        snapshot['tracks'].clear(); snapshot['version']=999
        self.assertEqual(provider.timeline,original)
        self.assertIsNot(provider.timeline,provider.timeline)
        from platforms.windows.bluraction.canonical_frames import descriptor_sha256
        self.assertEqual(descriptor_sha256(provider.timeline),digest)
        self.assertEqual(provider.frame_at(F(1,2)).asset_pts,F(1,2))
        self.current[0]=10
        with self.assertRaises(raw.FrameInventoryError): provider.timeline
        self.assertFalse(self.inventories[-1].complete)
        self.current[0]=9
        with self.assertRaises(video.CanonicalVideoReview): provider.timeline
        self.assertEqual(self.source.read_bytes(),self.original)


if __name__ == '__main__':
    unittest.main()
