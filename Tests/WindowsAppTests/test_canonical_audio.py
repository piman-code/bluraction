"""Exact PCM schedule controls plus one actual self-contained PCM MOV test.

Controlled decoder callbacks are not actual clock/codec/secondary-reference proof.
The final case uses PyAV/software MPEG4 + PCM directly, not CLI/native encoders;
its known raw bytes are compared without numpy/float/resampling. All fixtures are
authored here. Native Windows/audio-device/mixing/export/P1 remain unverified.
"""
from array import array
from copy import deepcopy
from fractions import Fraction as F
import hashlib
import importlib.util
from pathlib import Path
import tempfile
from threading import Event
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from platforms.windows.bluraction import canonical_audio as audio
from platforms.windows.bluraction import local_decoder
from platforms.windows.bluraction.frame_inventory import InventoryCancelled
from Tests.WindowsAppTests.test_asset_timeline import movie, track


def pcm(pts, samples, *, rate=8000, planar=False, channels=('FC',), payload=None,
        duration=None, **changes):
    width = 2
    if payload is None:
        payload = tuple(bytes((i+1,0))*samples for i in range(len(channels))) if planar else (
            b''.join(bytes((i+1,0)) for i in range(len(channels)))*samples,)
    fields = dict(pts=pts,time_base=F(1,rate),duration=samples if duration is None else duration,
        samples=samples,sample_rate=rate,is_corrupt=False,
        format=SimpleNamespace(name='s16p' if planar else 's16',bytes=width,is_planar=planar),
        layout=SimpleNamespace(name='mono' if len(channels)==1 else 'stereo',
            channels=tuple(SimpleNamespace(name=c) for c in channels)),
        planes=tuple(bytearray(p+b'padding') for p in payload))
    fields.update(changes)
    return SimpleNamespace(**fields)


class Streams:
    def __init__(self, identities):
        self.rows = [SimpleNamespace(id=identity,index=index,type=kind,time_base=F(1,8000))
                     for index,(identity,kind) in enumerate(identities)]
    def __iter__(self): return iter(self.rows)


class Container:
    def __init__(self, primary, callback, identities, rows, *, after_frame=None,
                 after_close=None, eof_failure=None, denied_at=None):
        self.primary,self.callback = primary,callback
        self.streams=Streams(identities); self.format=SimpleNamespace(name='mov,mp4')
        self.rows=rows; self.after_frame=after_frame; self.after_close=after_close
        self.eof_failure=eof_failure; self.denied_at=denied_at
        self.closed=False; self.iterator_closed=False
    def denied(self):
        try: self.callback('https://controlled.invalid/never-opened',1,{})
        except local_decoder.SecondaryIODenied: pass
    def decode(self, stream):
        try:
            for row in self.rows[stream.id]:
                if self.denied_at == 'decode': self.denied()
                yield row
                if self.after_frame is not None: self.after_frame()
            if self.eof_failure is not None: raise self.eof_failure
        finally: self.iterator_closed=True
    def close(self):
        self.closed=True; self.primary.close()
        if self.denied_at == 'close': self.denied()
        if self.after_close is not None: self.after_close()


class CanonicalAudioTests(unittest.TestCase):
    def setUp(self):
        self.directory=tempfile.TemporaryDirectory(); self.addCleanup(self.directory.cleanup)
        self.path=Path(self.directory.name)/'controlled.mov'
        self.current=[3]; self.event=Event(); self.containers=[]; self.opens=[]; self.spools=[]

    def source(self, audio_tracks=((2,((1000,0,1),)),), asset_ticks=1500):
        tracks=track(identity=1,ticks=asset_ticks,media_ticks=asset_ticks,
                     entries=((asset_ticks,0,1),))
        for identity,entries in audio_tracks:
            ticks=sum(e[0] for e in entries)
            tracks+=track(identity=identity,ticks=ticks,media_scale=8000,media_ticks=40000,
                entries=entries,handler=b'soun',timing_entries=((40000,1),))
        self.path.write_bytes(movie(tracks,ticks=asset_ticks))
        self.original=self.path.read_bytes(); self.sha=hashlib.sha256(self.original).hexdigest()

    def module(self, rows, *, identities=None, **changes):
        identities = [(1,'video')]+[(identity,'audio') for identity in rows] if identities is None else identities
        def open_native(primary,**options):
            self.opens.append(options)
            container=Container(primary,options['io_open'],identities,rows,**changes)
            self.containers.append(container); return container
        return SimpleNamespace(__version__='19.0.0',open=open_native)

    def build(self, rows, *, module=None, **changes):
        arguments=dict(expected_sha256=self.sha,generation=3,
            decoder_clock_mode='ffmpeg-editlist-applied',current_generation=lambda:self.current[0],
            cancel=self.event)
        arguments.update(changes)
        real_temp=tempfile.TemporaryDirectory
        def private_temp(**kwargs):
            result=real_temp(**kwargs); self.spools.append(Path(result.name)); return result
        with patch.object(local_decoder,'_av',return_value=self.module(rows) if module is None else module), \
             patch.object(audio.tempfile,'TemporaryDirectory',side_effect=private_temp):
            result=audio.OwnedCanonicalAudioProvider.build(self.path,**arguments)
        self.addCleanup(result.close)
        return result

    def assert_preserved_clean(self):
        self.assertEqual(self.path.read_bytes(),self.original)
        self.assertTrue(all(c.closed for c in self.containers))
        self.assertTrue(all(c.primary._file.stream.closed for c in self.containers))
        self.assertTrue(all(not p.exists() for p in self.spools))

    def test_exact_negative_trim_and_already_decoded_7600_are_not_double_trimmed(self):
        self.assertEqual(audio.clip_samples(F(-1,4),9600,8000,F(0),F(19,20)),(2000,9600))
        self.assertEqual(audio.clip_samples(F(0),7600,8000,F(0),F(19,20)),(0,7600))
        self.assertIsNone(audio.clip_samples(F(-1),100,8000,F(0),F(19,20)))
        self.source(((2,((950,2000,1),)),),asset_ticks=1000)
        payload=array('h',range(7600)).tobytes()
        provider=self.build({2:[pcm(0,7600,payload=(payload,))]})
        self.assertEqual(provider.tracks[0].decoded_samples,7600)
        self.assertEqual(provider.tracks[0].scheduled_samples,7600)
        result=provider.read_samples(2,F(0),8000)
        self.assertEqual(result.planes,(payload,)); self.assertEqual(result.samples,7600)
        self.assertEqual(result.source_sample_offset,0); self.assertEqual(result.asset_pts,F(0))
        self.assertEqual(provider.observation(2,0).samples,7600)
        self.assertEqual(provider.observation(2,0).raw_pts,0)
        self.assertEqual(provider.read_samples(2,F(19,20)).presence,'suffix')
        provider.close(); self.assert_preserved_clean()

    def test_leading_two_seconds_and_late_three_quarters_keep_raw_asset_clock(self):
        for start,ticks in ((F(2),2000),(F(3,4),750)):
            with self.subTest(start=start):
                self.source(((2,((ticks,-1,1),(1200,0,1))),),asset_ticks=ticks+1500)
                provider=self.build({2:[pcm(int(start*8000),9600)]})
                empty=provider.read_samples(2,start/2)
                self.assertEqual((empty.presence,empty.samples,empty.planes),('empty',0,()))
                self.assertEqual((empty.interval_start,empty.interval_end),(F(0),start))
                result=provider.read_samples(2,start,9600)
                self.assertEqual((result.asset_pts,result.samples),(start,9600))
                self.assertEqual(result.interval_end,start+F(6,5))
                self.assertEqual(provider.read_samples(2,start+F(6,5)).presence,'suffix')
                self.assertEqual(provider.read_samples(2,start+F(3,2)).presence,'EOF')
                self.assertEqual(self.opens[-1]['options'],{'advanced_editlist':'1','ignore_editlist':'0'})
                provider.close()
        self.assert_preserved_clean()

    def test_middle_explicit_empty_and_half_open_sample_boundaries(self):
        self.source(((2,((250,0,1),(250,-1,1),(250,2000,1))),),asset_ticks=1000)
        provider=self.build({2:[pcm(0,2000),pcm(4000,2000)]})
        self.assertEqual(provider.read_samples(2,F(1999,8000),10).samples,1)
        self.assertEqual(provider.read_samples(2,F(1,4)).presence,'empty')
        self.assertEqual(provider.read_samples(2,F(1,2)).asset_pts,F(1,2))
        self.assertEqual(provider.read_samples(2,F(3,4)).presence,'suffix')
        self.assertEqual(provider.tracks[0].scheduled_samples,4000)
        self.assertEqual(provider.read_samples(2,F(1)).presence,'EOF')
        provider.close(); self.assert_preserved_clean()

    def test_integer_sample_clipping_preserves_raw_observation_and_plane_byte_offset(self):
        self.source(((2,((250,-1,1),(500,0,1))),),asset_ticks=1000)
        left=array('h',range(8000)).tobytes(); right=array('h',range(8000,16000)).tobytes()
        row=pcm(0,8000,planar=True,channels=('FL','FR'),payload=(left,right))
        provider=self.build({2:[row]})
        self.assertEqual(provider.tracks[0].decoded_samples,8000)
        self.assertEqual(provider.tracks[0].scheduled_samples,4000)
        observed=provider.observation(2,0)
        self.assertEqual((observed.pts,observed.samples,observed.clip_first,observed.clip_stop),(F(0),8000,2000,6000))
        row.planes[0][:]=b'X'*len(row.planes[0])
        result=provider.read_samples(2,F(1,4),4000)
        self.assertEqual(result.planes,(left[4000:12000],right[4000:12000]))
        self.assertEqual((result.format.name,result.format.channels,result.source_sample_offset),('s16p',('FL','FR'),2000))
        provider.close(); self.assert_preserved_clean()

    def test_fractional_clip_and_query_are_reviewed_without_flooring(self):
        with self.assertRaisesRegex(audio.CanonicalAudioReview,'fractional'):
            audio.clip_samples(F(0),100,8000,F(1,16000),F(100,8000))
        with self.assertRaises(audio.CanonicalAudioReview):
            audio.clip_samples(0.0,100,8000,F(0),F(1))
        self.source(); provider=self.build({2:[pcm(0,8000)]})
        with self.assertRaisesRegex(audio.CanonicalAudioReview,'sample boundary'):
            provider.read_samples(2,F(1,16000))
        with self.assertRaises(audio.CanonicalAudioReview): provider.read_samples(2,F(0))
        self.assert_preserved_clean()

    def test_missing_content_and_duration_sample_disagreement_never_become_silence(self):
        self.source()
        for rows in ([pcm(1,7999)],[pcm(0,7999)],[pcm(0,8000,duration=7999)],
                     [pcm(0,4000),pcm(4001,3999)]):
            with self.subTest(rows=rows),self.assertRaises(audio.CanonicalAudioReview): self.build({2:rows})
        self.assert_preserved_clean()

    def test_all_audio_tracks_separate_layout_and_no_missing_or_extra_decoder_track(self):
        self.source(((2,((1000,0,1),)),(3,((750,-1,1),(250,0,1)))),asset_ticks=1500)
        rows={2:[pcm(0,8000)],3:[pcm(6000,2000,channels=('FL','FR'))]}
        provider=self.build(rows)
        self.assertEqual([t.track_id for t in provider.tracks],[2,3])
        self.assertEqual(provider.read_samples(2,F(0),1).planes,(b'\x01\0',))
        self.assertEqual(provider.read_samples(3,F(3,4),1).planes,(b'\x01\0\x02\0',))
        self.assertEqual(len(self.containers),2)
        provider.close()
        for identities in ([(1,'video'),(2,'audio')],[(1,'video'),(2,'audio'),(3,'audio'),(4,'audio')]):
            with self.assertRaisesRegex(audio.CanonicalAudioReview,'identities'):
                self.build(rows,module=self.module(rows,identities=identities))
        self.assert_preserved_clean()

    def test_repeated_nonunit_ambiguous_cross_gap_and_changing_format_hold(self):
        self.source(((2,((500,0,1),(500,0,1))),),asset_ticks=1000)
        with self.assertRaisesRegex(audio.CanonicalAudioReview,'repeated'): self.build({2:[pcm(0,8000)]})
        self.assertEqual(self.opens,[])
        self.source(((2,((1000,0,2),)),),asset_ticks=1000)
        with self.assertRaises(ValueError): self.build({2:[pcm(0,8000)]})
        self.source(((2,((250,0,1),(250,-1,1),(250,2000,1))),),asset_ticks=1000)
        with self.assertRaisesRegex(audio.CanonicalAudioReview,'multiple content'): self.build({2:[pcm(0,6000)]})
        self.source()
        with self.assertRaisesRegex(audio.CanonicalAudioReview,'changing PCM'):
            self.build({2:[pcm(0,4000),pcm(4000,4000,channels=('FL','FR'))]})
        self.assert_preserved_clean()

    def test_late_eof_failure_and_overlap_discard_complete_candidate(self):
        self.source(); primary=RuntimeError('controlled late decoder failure')
        with self.assertRaises(RuntimeError) as caught:
            self.build({2:[pcm(0,8000)]},module=self.module({2:[pcm(0,8000)]},eof_failure=primary))
        self.assertIs(caught.exception,primary)
        with self.assertRaisesRegex(audio.CanonicalAudioReview,'overlapping'):
            self.build({2:[pcm(0,4001),pcm(4000,4000)]})
        self.assertTrue(all(c.iterator_closed for c in self.containers))
        self.assert_preserved_clean()

    def test_cancel_during_decode_after_native_close_and_generation_permanent_invalidation(self):
        self.source(); rows={2:[pcm(0,4000),pcm(4000,4000)]}
        with self.assertRaises(InventoryCancelled):
            self.build(rows,module=self.module(rows,after_frame=self.event.set))
        self.event.clear()
        with self.assertRaises(InventoryCancelled):
            self.build(rows,module=self.module(rows,after_close=self.event.set))
        self.event.clear(); unrelated=self.build(rows); changed=self.build(rows)
        self.current[0]=4
        with self.assertRaises(ValueError): changed.read_samples(2,F(0))
        self.current[0]=3
        with self.assertRaises(audio.CanonicalAudioReview): changed.read_samples(2,F(0))
        self.assertEqual(unrelated.read_samples(2,F(0),1).samples,1)
        unrelated.close(); self.assert_preserved_clean()

    def test_source_change_after_decode_and_same_byte_replacement_refuse_publication_or_reads(self):
        self.source(); rows={2:[pcm(0,8000)]}
        def mutate():
            data=bytearray(self.original); data[-1]^=1; self.path.write_bytes(data)
        with self.assertRaises(ValueError): self.build(rows,module=self.module(rows,after_close=mutate))
        self.assertTrue(all(not p.exists() for p in self.spools))
        self.source(); provider=self.build(rows)
        replacement=self.path.with_suffix('.replacement'); replacement.write_bytes(self.original); replacement.replace(self.path)
        with self.assertRaises(ValueError): provider.read_samples(2,F(0))
        self.assert_preserved_clean()

    def test_descriptor_binding_alias_isolation_and_no_audio_control(self):
        self.source(); provider=self.build({2:[pcm(0,8000)]})
        original=provider.timeline; supplied=deepcopy(original)
        supplied['tracks'][1]['segments'][0]['mediaStart']['numerator']='999'
        self.assertEqual(provider.timeline,original)
        with self.assertRaisesRegex(audio.CanonicalAudioReview,'caller binding'):
            self.build({2:[pcm(0,8000)]},expected_timeline=supplied)
        self.assertEqual(provider.read_samples(2,F(0),1).source_sha256,self.sha)
        with self.assertRaisesRegex(audio.CanonicalAudioReview,'clock required'):
            self.build({2:[pcm(0,8000)]},decoder_clock_mode=None)
        provider.close(); self.source((),asset_ticks=1000)
        silent=self.build({}); self.assertEqual(silent.tracks,()); self.assertEqual(silent.asset_duration,F(1))
        self.assertTrue(self.containers[-1].closed); silent.close(); self.assert_preserved_clean()

    def test_ignored_secondary_decode_and_close_requests_cannot_publish_pcm(self):
        self.source(); rows={2:[pcm(0,8000)]}
        for stage in ('decode','close'):
            with self.subTest(stage=stage),self.assertRaises(local_decoder.SecondaryIODenied):
                self.build(rows,module=self.module(rows,denied_at=stage))
        self.assert_preserved_clean()

    def test_budgets_query_bound_and_closed_handles_cleanup(self):
        self.source(); rows={2:[pcm(0,8000)]}
        for limits in (audio.AudioLimits(max_spool_bytes=15999),audio.AudioLimits(max_frame_bytes=15999)):
            with self.assertRaises(audio.CanonicalAudioReview): self.build(rows,limits=limits)
        provider=self.build(rows,limits=audio.AudioLimits(max_query_bytes=64))
        chunk=provider.read_samples(2,F(0),8000)
        self.assertEqual(chunk.samples,32); self.assertEqual(len(chunk.planes[0]),64)
        streams=[(t.pcm,t.records) for t in provider._tracks.values()]
        provider.close(); provider.close()
        self.assertTrue(all(p.closed and r.closed for p,r in streams)); self.assert_preserved_clean()
        # A real private spool is opened, then a controlled disk failure and
        # failed-close-after-release occur. Keep the first failure and still
        # remove the newly owned directory; never claim a partial candidate.
        primary=OSError('controlled PCM disk full'); teardown=OSError('controlled close flush error')
        original_open=audio._Track.open_spools; wrappers=[]
        class FailingPCM:
            def __init__(self, stream): self.stream=stream
            def __getattr__(self, name): return getattr(self.stream,name)
            def write(self, data): raise primary
            def close(self): self.stream.close(); raise teardown
        def failing_open(owner, directory):
            original_open(owner,directory)
            owner.pcm=FailingPCM(owner.pcm); wrappers.append(owner.pcm)
        with patch.object(audio._Track,'open_spools',new=failing_open):
            with self.assertRaises(OSError) as caught: self.build(rows)
        self.assertIs(caught.exception,primary); self.assertIs(primary.__cause__,teardown)
        self.assertIsNot(primary.__cause__,primary)
        self.assertTrue(all(w.stream.closed for w in wrappers)); self.assert_preserved_clean()

    def test_second_spool_open_and_first_handle_close_failure_preserve_primary_and_retry_owner(self):
        self.source()
        primary=OSError('controlled second spool open failure')
        cleanup=OSError('controlled first PCM close still owns open handle')
        wrappers=[]; native_open=open
        class RetainedPCM:
            def __init__(self, stream): self.stream=stream; self.attempts=0
            def __getattr__(self, name): return getattr(self.stream,name)
            def close(self):
                self.attempts+=1
                if self.attempts == 1: raise cleanup
                self.stream.close()
        def spool_open(path,*args,**kwargs):
            if Path(path).suffix == '.index': raise primary
            self.assertEqual(Path(path).suffix,'.pcm')
            wrapper=RetainedPCM(native_open(path,*args,**kwargs)); wrappers.append(wrapper); return wrapper
        with patch.object(audio,'open',new=spool_open,create=True):
            with self.assertRaises(OSError) as caught: self.build({2:[pcm(0,8000)]})
        self.assertIs(caught.exception,primary); self.assertIs(primary.__cause__,cleanup)
        self.assertIsNot(primary.__cause__,primary)
        retry=primary.retry_canonical_audio_close; self.addCleanup(retry)
        owner=retry.__self__
        self.assertTrue(owner._closed); self.assertFalse(owner._complete)
        self.assertIs(owner._tracks[2].pcm,wrappers[0]); self.assertIsNone(owner._tracks[2].records)
        self.assertEqual(self.containers,[]); self.assertFalse(wrappers[0].stream.closed)
        self.assertGreaterEqual(wrappers[0].stream.fileno(),0)
        self.assertTrue(self.spools[-1].is_dir())  # unlink waits for the live handle
        self.assertEqual(self.path.read_bytes(),self.original)
        retry(); retry()
        self.assertEqual(wrappers[0].attempts,2); self.assertTrue(wrappers[0].stream.closed)
        self.assertIsNone(owner._tracks[2].pcm); self.assertIsNone(owner._directory)
        self.assert_preserved_clean()

    @unittest.skipUnless(importlib.util.find_spec('av') is not None,'actual PyAV PCM codec unavailable; UNVERIFIED')
    def test_actual_contained_pcm_eof_exact_original_bytes_no_float_conversion(self):
        import av
        rate=8000
        original_pcm=array('h',((i*31)%1000-500 for i in range(rate))).tobytes()
        with av.open(str(self.path),'w',format='mov') as output:
            video=output.add_stream('mpeg4',rate=8); video.width=96; video.height=64; video.pix_fmt='yuv420p'
            sound=output.add_stream('pcm_s16le',rate=rate); sound.layout='mono'
            for i in range(8):
                image=av.VideoFrame(96,64,'yuv420p')
                for plane in image.planes: plane.update(bytes([64])*plane.buffer_size)
                image.pts=i; image.time_base=F(1,8)
                output.mux(video.encode(image))
            output.mux(video.encode(None))
            for offset in (0,4000):
                frame=av.AudioFrame(format='s16',layout='mono',samples=4000)
                frame.sample_rate=rate; frame.pts=offset; frame.time_base=F(1,rate)
                data=original_pcm[offset*2:(offset+4000)*2]
                frame.planes[0].update(data+b'\0'*(frame.planes[0].buffer_size-len(data)))
                output.mux(sound.encode(frame))
            output.mux(sound.encode(None))
        before=self.path.read_bytes(); digest=hashlib.sha256(before).hexdigest()
        provider=audio.OwnedCanonicalAudioProvider.build(self.path,expected_sha256=digest,generation=1,
            decoder_clock_mode='ffmpeg-editlist-applied')
        self.addCleanup(provider.close)
        self.assertEqual(len(provider.tracks),1); info=provider.tracks[0]
        self.assertEqual((info.decoded_samples,info.scheduled_samples,info.format.sample_rate),(rate,rate,rate))
        self.assertEqual((info.format.name,info.format.layout),('s16','mono'))
        result=bytearray(); time=F(0)
        while time < F(1):
            chunk=provider.read_samples(info.track_id,time,8000)
            self.assertEqual(chunk.presence,'content'); self.assertGreater(chunk.samples,0)
            self.assertEqual(chunk.interval_start,time)
            result.extend(chunk.planes[0]); time=chunk.interval_end
        self.assertEqual(time,F(1)); self.assertEqual(bytes(result),original_pcm)
        self.assertEqual(provider.read_samples(info.track_id,F(1)).presence,'EOF')
        private=Path(provider._directory.name); provider.close()
        self.assertFalse(private.exists()); self.assertEqual(self.path.read_bytes(),before)
        self.assertEqual(hashlib.sha256(self.path.read_bytes()).hexdigest(),digest)


if __name__ == '__main__': unittest.main()
