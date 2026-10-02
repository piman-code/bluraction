"""Exact scheduling/real owned process deadlines; not Windows audio-device QA."""
from dataclasses import asdict
from fractions import Fraction as F
import io
import multiprocessing
from pathlib import Path
import tempfile
import struct
import threading
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from platforms.windows.bluraction.canonical_transport import (
    AssetClock, CanonicalSession, PCMBuffer, PCMPlaybackPlan, TransportReview, exact_time, packed_pcm)
from platforms.windows.bluraction.canonical_audio import (
    OwnedCanonicalAudioProvider, CanonicalAudioReview, CanonicalPCM, PCMFormat, PCMObservation)
from platforms.windows.bluraction.media import Cancelled, fingerprint


def _blocked_decoder(connection,path,sha,work):
    # Top-level spawnable fixture. No native/media/network IO.
    connection.send((dict(kind='ready',sha256=sha,duration=F(2),firstTime=F(0),audioTracks=()),()))
    connection.recv()
    threading.Event().wait(60)


def _reply_decoder(connection,path,sha,work):
    connection.send((dict(kind='ready',sha256=sha,duration=F(2),firstTime=F(0),audioTracks=()),()))
    while True:
        sequence,operation,args=connection.recv()
        connection.send((dict(sequence=sequence,kind=operation,sha256=sha,time=args[0] if args else F(0)),()))


def _partial_body_decoder(connection,path,sha,work):
    connection.send((dict(kind='ready',sha256=sha,duration=F(2),firstTime=F(0),audioTracks=()),()))
    connection.recv()
    # Send a valid length and one body byte, then retain the open stream.
    connection.socket.sendall(struct.pack('!I',65536)+b'x')
    threading.Event().wait(60)


def _partial_header_decoder(connection,path,sha,work):
    connection.send((dict(kind='ready',sha256=sha,duration=F(2),firstTime=F(0),audioTracks=()),()))
    connection.recv()
    connection.socket.sendall(b'\0')
    threading.Event().wait(60)


def _partial_chunk_decoder(connection,path,sha,work):
    connection.send((dict(kind='ready',sha256=sha,duration=F(2),firstTime=F(0),audioTracks=()),()))
    sequence,operation,args=connection.recv()
    connection.send((dict(sequence=sequence,kind='frame',sha256=sha),(65536,)))
    connection.socket.sendall(struct.pack('!I',65536)+b'x')
    (Path(work)/'partial-written').write_bytes(b'header plus one byte sent')
    threading.Event().wait(60)


FMT=PCMFormat('s16',2,False,8,'mono',('FC',),'little')


class ScheduleSession:
    def __init__(self,fmt=FMT,kind='empty'):
        self.metadata={'audioTracks':({'track_id':2,'format':asdict(fmt)},)}
        self.format=fmt; self.kind=kind
        self.requests=[]

    def audio_anchor(self,identity,target,cancel=None):
        return target

    def audio(self,identity,stamp,count,cancel=None):
        self.requests.append((identity,stamp,count))
        if self.kind=='empty' and stamp<F(1,2):
            chunk=CanonicalPCM('empty',2,stamp,F(0),F(1,2),None,None,None,0,
                               self.format,(),'a'*64,'b'*64,1)
            return {'chunk':chunk},()
        if self.kind=='missing': raise TransportReview('content lacks observed PCM')
        if stamp>=F(1):
            return {'chunk':CanonicalPCM('suffix',2,stamp,F(1),F(3,2),None,None,None,0,
                                         self.format,(),'a'*64,'b'*64,1)},()
        samples=min(count,int((F(1)-stamp)*self.format.sample_rate))
        data=bytes(range(samples*self.format.bytes_per_time_sample))
        chunk=CanonicalPCM('content',2,stamp,stamp,stamp+F(samples,self.format.sample_rate),stamp,
                            0,0,samples,self.format,(),'a'*64,'b'*64,1)
        return {'chunk':chunk},(data,)


class CanonicalTransportTests(unittest.TestCase):
    def test_child_handshake_sar_matches_observed_pixel_contract_without_stream_guess(self):
        """Controlled metadata witness, not an authored native-media SAR proof.

        Exercise the actual child metadata/send path: pixels can use a frame
        SAR even when stream/codec metadata cannot provide a positive SAR.
        """
        from platforms.windows.bluraction.canonical_transport import _decoder_process
        class Inventory(list):
            pass
        class Streams(list):
            audio=()
        class Container:
            def __init__(self,stream): self.streams=Streams([stream])
            def __enter__(self): return self
            def __exit__(self,*args): return False
        class Connection:
            def __init__(self): self.messages=[]; self.closed=False
            def send(self,message): self.messages.append(message)
            def recv(self): return (1,'close',())
            def close(self): self.closed=True
        cases=((F(4,3),None,None,F(4,3)), (F(4,3),F(0),F(0),F(4,3)),
               (F(4,3),F(1),F(2),F(4,3)), (None,F(1),F(3,2),F(3,2)),
               (F(0),F(1),F(3,2),F(3,2)), (None,F(1),None,None),
               (F(0),F(1),F(0),None), (F(-1),F(1),F(1),None))
        for frame_sar,stream_sar,codec_sar,expected in cases:
            with self.subTest(frame=frame_sar,stream=stream_sar,codec=codec_sar):
                stream=SimpleNamespace(index=0,type='video',start_time=0,duration=2,
                    time_base=F(1),sample_aspect_ratio=stream_sar,average_rate=F(1),
                    codec_context=SimpleNamespace(sample_aspect_ratio=codec_sar),metadata={})
                first=SimpleNamespace(asset_pts=F(0),observation=SimpleNamespace(frame_sar=frame_sar))
                inventory=Inventory([SimpleNamespace(pts=F(0),duration=F(1)),
                                     SimpleNamespace(pts=F(1),duration=F(1))])
                inventory.decoder=SimpleNamespace(stream_index=0,codec_sar=codec_sar)
                retired=[]
                video=SimpleNamespace(_inventory=inventory,_index=SimpleNamespace(iter_samples=lambda:iter([first])),
                    _decoder=lambda:Container(stream),timeline={},asset_duration=F(2),
                    descriptor_sha256='b'*64,close=lambda:retired.append('video'))
                audio=SimpleNamespace(tracks=(),close=lambda:retired.append('audio'))
                connection=Connection()
                with patch('platforms.windows.bluraction.canonical_video.OwnedCanonicalVideoProvider.build',return_value=video), \
                     patch('platforms.windows.bluraction.canonical_audio.OwnedCanonicalAudioProvider.build',return_value=audio), \
                     patch('platforms.windows.bluraction.canonical_transport.tempfile.tempdir',tempfile.gettempdir()):
                    _decoder_process(connection,'unused-controlled-input','a'*64,tempfile.gettempdir())
                self.assertTrue(connection.closed)
                self.assertEqual(retired,['audio','video'])
                self.assertEqual(len(connection.messages),1)
                metadata,buffer_sizes=connection.messages[0]
                self.assertEqual(buffer_sizes,())
                if expected is None:
                    self.assertEqual(metadata['kind'],'error')
                    self.assertEqual(metadata['type'],'TransportReview')
                else:
                    self.assertEqual(metadata['kind'],'ready')
                    self.assertIs(type(metadata['decoder']['sar']),F)
                    self.assertEqual(metadata['decoder']['sar'],expected)

    def test_transport_target_is_continuous_without_relabeling_presented_pts(self):
        now=[10.0]; clock=AssetClock(F(19,12),lambda:now[0])
        clock.seek(F(1,12)); clock.play(); now[0]+=0.5
        self.assertEqual(clock.position(),F(7,12))
        displayed=F(5,12)
        self.assertNotEqual(displayed,clock.position())
        self.assertEqual(clock.pause(),F(7,12)); now[0]+=5
        self.assertEqual(clock.position(),F(7,12))
        clock.seek(F(1,10)); self.assertFalse(clock.playing)
        clock.play(); now[0]+=10
        self.assertEqual(clock.position(),F(19,12))

    def test_invalid_clock_inputs_and_backwards_monotonic_fail(self):
        for value in (True,float('nan'),float('inf'),-1,'0'):
            with self.subTest(value=value), self.assertRaises(TransportReview): exact_time(value)
        with self.assertRaises(TransportReview): AssetClock(F(0))
        now=[1.]; clock=AssetClock(2,lambda:now[0]); clock.play(); now[0]=0.
        with self.assertRaises(TransportReview): clock.position()
        with self.assertRaises(TransportReview): clock.seek(3)

    def test_epoch_ring_rejects_old_seek_and_does_not_fabricate_underrun(self):
        ring=PCMBuffer(8); old=ring.reset()
        self.assertTrue(ring.append(old,b'abcd')); self.assertEqual(ring.read(2),b'ab')
        new=ring.reset(); self.assertFalse(ring.append(old,b'old'))
        self.assertEqual(ring.read(4),b'')
        ring.append(new,b'12345678')
        with self.assertRaises(TransportReview): ring.append(new,b'9')
        self.assertEqual(ring.read(10),b'12345678')

    def test_plan_interleaves_meaningful_planar_bytes_without_numeric_conversion(self):
        fmt=PCMFormat('s16p',2,True,8000,'stereo',('FL','FR'),'little')
        chunk=CanonicalPCM('content',2,F(0),F(0),F(1,4000),F(0),0,0,2,fmt,
            (b'\x01\x02\x03\x04',b'\x05\x06\x07\x08'),'a'*64,'b'*64,1)
        self.assertEqual(packed_pcm(chunk),b'\x01\x02\x05\x06\x03\x04\x07\x08')

    def test_declared_empty_then_observed_content_then_suffix_no_extra_silence(self):
        session=ScheduleSession(); plan=PCMPlaybackPlan(session,F(0))
        data,end,done=plan.next_block(count=2)
        self.assertEqual((data,end,done),(b'\0'*4,F(1,4),False))
        self.assertEqual(plan.next_block(count=2)[1],F(1,2))
        data,end,done=plan.next_block(count=2)
        self.assertEqual((data,end,done),(bytes(range(4)),F(3,4),False))
        plan.next_block(count=2)
        self.assertEqual(plan.next_block(),(b'',F(1),True))
        self.assertEqual(plan.samples,8)

    def test_unsigned_empty_midpoint_and_missing_content_error(self):
        fmt=PCMFormat('u8',1,False,8,'mono',('FC',),'little')
        plan=PCMPlaybackPlan(ScheduleSession(fmt),F(0))
        self.assertEqual(plan.next_block(count=2)[0],b'\x80\x80')
        with self.assertRaises(TransportReview): PCMPlaybackPlan(ScheduleSession(kind='missing'),F(0)).next_block()

    def test_multitrack_and_unproved_device_layout_are_visible_holds(self):
        session=ScheduleSession(); session.metadata['audioTracks']*=2
        with self.assertRaises(TransportReview): PCMPlaybackPlan(session,F(0))
        fmt=PCMFormat('dbl',8,False,8000,'mono',('FC',),'little')
        with self.assertRaises(TransportReview): PCMPlaybackPlan(ScheduleSession(fmt),F(0))

    def provider(self):
        result=object.__new__(OwnedCanonicalAudioProvider)
        result._lock=threading.RLock(); result._closed=False; result._complete=True
        result._sha='a'*64; result._descriptor_sha='b'*64; result._generation=1
        result._cancel=None; result._current_generation=lambda:1
        result._duration=F(3,2); result._limits=SimpleNamespace(max_query_bytes=1024)
        track=SimpleNamespace(segments=((F(0),F(1,2),None),(F(1,2),F(1),F(0))),
            format=FMT,count=2,pcm=io.BytesIO(b'\x01\x02\x03\x04\x05\x06\x07\x08'))
        result._tracks={2:track}
        rows=(PCMObservation(F(1,2),F(1,8),4,2,2,0,0,2,1),
              PCMObservation(F(3,4),F(1,8),6,2,2,4,0,2,1))
        result._record=lambda chosen,index: rows[index]
        result._discard=lambda error: setattr(result,'discarded',error)
        return result

    def test_snapshot_query_uses_guards_but_full_revalidation_remains_explicit(self):
        provider=self.provider(); guards=[]
        provider._guard=lambda *,hash_source=False: guards.append(hash_source)
        chunk=provider.read_snapshot_samples(2,F(1,2),1)
        self.assertEqual(chunk.planes,(b'\x01\x02',)); self.assertGreaterEqual(len(guards),4)
        self.assertFalse(any(guards))
        guards.clear(); provider.read_samples(2,F(1,2),1)
        self.assertEqual(guards.count(True),2)
        guards.clear(); provider.validate_source(); self.assertIn(True,guards)

    def test_snapshot_changed_identity_does_not_return_cached_pcm(self):
        provider=self.provider()
        error=CanonicalAudioReview('changed original identity')
        provider._guard=lambda **kwargs: (_ for _ in ()).throw(error)
        with self.assertRaises(CanonicalAudioReview) as caught: provider.read_snapshot_samples(2,F(1,2))
        self.assertIs(caught.exception,error); self.assertIs(provider.discarded,error)

    def test_snapshot_pcm_plane_read_keeps_actual_generation_and_cancel_checks(self):
        from platforms.windows.bluraction.frame_inventory import InventoryCancelled, FrameInventoryError
        for stale in (False,True):
            with self.subTest(stale=stale):
                provider=self.provider(); provider._guard=lambda **kwargs:None
                if stale: provider._current_generation=lambda:2
                else: provider._cancel=lambda:True
                with self.assertRaises(FrameInventoryError) as caught:
                    provider.read_snapshot_samples(2,F(1,2),1)
                self.assertIs(provider.discarded,caught.exception)
                if not stale: self.assertIsInstance(caught.exception,InventoryCancelled)

    def test_arbitrary_seek_reports_next_observed_sample_not_an_epsilon(self):
        provider=self.provider(); provider._guard=lambda **kwargs: None
        self.assertEqual(provider.snapshot_anchor(2,F(51,100)),F(5,8))
        self.assertEqual(provider.snapshot_anchor(2,F(74,100)),F(3,4))
        self.assertEqual(provider.snapshot_anchor(2,F(1)),F(1))
        self.assertEqual(provider.snapshot_anchor(2,F(3,2)),F(3,2))
        self.assertEqual(provider.read_snapshot_samples(2,F(5,8),1).planes,(b'\x03\x04',))

    def test_native_query_deadline_reaps_actual_owned_process_and_preserves_input(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'synthetic.bin'; path.write_bytes(b'owned synthetic decoder input')
            before=path.read_bytes()
            session=CanonicalSession(path,fingerprint(path),build_timeout=10,query_timeout=.15,
                                     _decoder_target=_blocked_decoder)
            pid=session._process.pid; directory=Path(session._directory.name)
            with self.assertRaisesRegex(TransportReview,'deadline'): session.frame(F(0))
            self.assertIsNone(session._process)
            self.assertNotIn(pid,[child.pid for child in multiprocessing.active_children()])
            self.assertFalse(directory.exists()); self.assertEqual(path.read_bytes(),before)

    def test_source_replacement_before_rpc_never_consumes_old_candidate_reply(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'synthetic.bin'; path.write_bytes(b'old-owned-input')
            session=CanonicalSession(path,fingerprint(path),build_timeout=10,_decoder_target=_reply_decoder)
            try:
                replacement=Path(folder)/'replacement'; replacement.write_bytes(b'new-owned-input')
                replacement.replace(path)
                with self.assertRaises(ValueError): session.frame(F(0))
                self.assertTrue(session._closed); self.assertIsNone(session._process)
                self.assertEqual(path.read_bytes(),b'new-owned-input')
            finally: session.close()

    def test_partial_metadata_header_body_and_pixel_chunk_share_query_deadline(self):
        for target in (_partial_header_decoder,_partial_body_decoder,_partial_chunk_decoder):
            with self.subTest(target=target.__name__), tempfile.TemporaryDirectory() as folder:
                path=Path(folder)/'synthetic.bin'; path.write_bytes(b'owned partial stream input')
                before=path.read_bytes()
                session=CanonicalSession(path,fingerprint(path),build_timeout=10,query_timeout=.15,
                                         _decoder_target=target)
                pid=session._process.pid; directory=Path(session._directory.name)
                try:
                    with self.assertRaisesRegex(TransportReview,'deadline'): session.frame(F(0))
                    self.assertIsNone(session._process)
                    self.assertNotIn(pid,[child.pid for child in multiprocessing.active_children()])
                    self.assertFalse(directory.exists())
                finally:
                    session.close()
                    self.assertEqual(path.read_bytes(),before)

    def test_async_close_interrupts_partial_body_before_rpc_lock_is_released(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'synthetic.bin'; path.write_bytes(b'owned async-close input')
            before=path.read_bytes()
            session=CanonicalSession(path,fingerprint(path),build_timeout=10,query_timeout=30,
                                     _decoder_target=_partial_chunk_decoder)
            pid=session._process.pid; directory=Path(session._directory.name)
            errors=[]; entered=threading.Event()
            original=session._receive
            def observed(*args,**kwargs):
                entered.set()
                return original(*args,**kwargs)
            session._receive=observed
            def query():
                try: session.frame(F(0))
                except BaseException as error: errors.append(error)
            worker=threading.Thread(target=query,daemon=True)
            try:
                worker.start(); self.assertTrue(entered.wait(2))
                deadline=time.monotonic()+2
                while not (directory/'partial-written').exists() and time.monotonic()<deadline:
                    threading.Event().wait(.01)
                self.assertTrue((directory/'partial-written').is_file())
                self.assertTrue(worker.is_alive())
                session.close_async()
                worker.join(3)
                self.assertFalse(worker.is_alive(),'shutdown must wake the in-flight body read')
                session.close()  # Wait for the bounded owned retirement, never discard it.
                self.assertTrue(errors)
                self.assertIsNone(session._process)
                self.assertFalse(directory.exists())
                self.assertNotIn(pid,[child.pid for child in multiprocessing.active_children()])
            finally:
                session.close()
                self.assertEqual(path.read_bytes(),before)

    def test_partial_read_close_latch_survives_noop_or_failed_native_shutdown(self):
        class ShutdownSocket:
            def __init__(self, owned, fails): self.owned=owned; self.fails=fails; self.calls=0
            def __getattr__(self, name): return getattr(self.owned, name)
            def shutdown(self, how):
                self.calls+=1
                if self.fails: raise OSError('controlled native shutdown failure')
                # Deliberately leave the actual socket and peer open.
        for fails in (False, True):
            with self.subTest(fails=fails), tempfile.TemporaryDirectory() as folder:
                path=Path(folder)/'synthetic.bin'; path.write_bytes(b'owned latched-close input')
                before=path.read_bytes()
                session=CanonicalSession(path,fingerprint(path),build_timeout=10,query_timeout=30,
                                         _decoder_target=_partial_chunk_decoder)
                pid=session._process.pid; directory=Path(session._directory.name)
                wrapper=ShutdownSocket(session._connection.socket,fails)
                session._connection.socket=wrapper
                errors=[]
                def query():
                    try: session.frame(F(0))
                    except BaseException as error: errors.append(error)
                worker=threading.Thread(target=query,daemon=True)
                try:
                    worker.start(); deadline=time.monotonic()+2
                    while not (directory/'partial-written').is_file() and time.monotonic()<deadline:
                        threading.Event().wait(.01)
                    self.assertTrue((directory/'partial-written').is_file())
                    self.assertTrue(worker.is_alive())
                    session.close_async(); worker.join(3)
                    self.assertFalse(worker.is_alive(),'explicit latch must not depend on shutdown wake')
                    session.close()
                    self.assertGreater(wrapper.calls,0)
                    self.assertTrue(errors)
                    self.assertIsInstance(errors[0],TransportReview)
                    self.assertIn('interrupted',str(errors[0]))
                    self.assertIsNone(session._process)
                    self.assertFalse(directory.exists())
                    self.assertNotIn(pid,[child.pid for child in multiprocessing.active_children()])
                finally:
                    session.close()
                    self.assertEqual(path.read_bytes(),before)


if __name__=='__main__': unittest.main()
