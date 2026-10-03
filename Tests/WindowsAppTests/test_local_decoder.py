"""Secondary-open latch controls plus one actual contained PyAV MOV decode.

Mock callbacks deliberately simulate native ignored optional IO; they do not
establish an existing exploit. Actual self-contained software MPEG4 EOF proof is
distinct from actual secondary-reference/native Windows/backend coverage.
"""
from fractions import Fraction
import hashlib
import importlib.util
import io
import os
from pathlib import Path
import tempfile
from threading import Thread
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from platforms.windows.bluraction import local_decoder as local
from platforms.windows.bluraction.frame_inventory import _BoundedInput
from shared.source_identity import stat_snapshot


class NativeIterator:
    def __init__(self, container):
        self.container=container; self.index=0; self.closed=False
        self.close_failures=container.iterator_close_failures
    def __iter__(self): return self
    def __next__(self):
        if self.index == 0:
            self.index+=1
            if self.container.stage == 'decode': self.container.ignored_request()
            if self.container.stage == 'threaded':
                self.container.callback_thread=Thread(target=self.container.ignored_request)
                self.container.callback_thread.start()
                self.container.callback_thread.join(timeout=1)
                if self.container.callback_thread.is_alive():
                    raise RuntimeError('secondary callback blocked behind native operation lock')
            return 'controlled-frame'
        if self.container.stage == 'EOF': self.container.ignored_request()
        raise StopIteration
    def close(self):
        if self.close_failures:
            self.close_failures-=1
            raise OSError('controlled iterator close failure')
        self.closed=True


class NativeContainer:
    def __init__(self,file,callback,stage,*,close_failures=0,iterator_close_failures=0,
                 format_name='mov,mp4',close_action=None):
        self.file,self.callback,self.stage=file,callback,stage
        self.format=SimpleNamespace(name=format_name)
        self.close_failures=close_failures; self.iterator_close_failures=iterator_close_failures
        self.close_action=close_action; self.closed=False; self.close_calls=0; self.iterators=[]
    def ignored_request(self):
        try: self.callback('https://controlled.invalid/never-opened',1,{'controlled':'ignored'})
        except local.SecondaryIODenied: pass
    def decode(self,*args,**kwargs):
        result=NativeIterator(self); self.iterators.append(result); return result
    def demux(self,*args,**kwargs): return self.decode(*args,**kwargs)
    def seek(self,*args,**kwargs):
        if self.stage == 'seek': self.ignored_request()
    def close(self):
        self.close_calls+=1
        # Native close attempts to close its primary. The wrapper must shield it.
        self.file.close()
        if self.stage == 'close':
            for unused in range(3): self.ignored_request()
        if self.close_action is not None: self.close_action()
        if self.close_failures:
            self.close_failures-=1
            raise OSError('controlled native close failure')
        self.closed=True


class LocalDecoderTests(unittest.TestCase):
    def setUp(self):
        self.directory=tempfile.TemporaryDirectory(); self.addCleanup(self.directory.cleanup)
        self.path=Path(self.directory.name)/'owned-primary.bin'
        self.original=b'controlled caller-owned source'
        self.path.write_bytes(self.original)
        self.stream=self.path.open('rb'); self.addCleanup(self.stream.close)
        self.bounded=_BoundedInput(self.stream,len(self.original),
            stat_snapshot(os.fstat(self.stream.fileno()),domain='descriptor'),lambda:False)
        self.containers=[]; self.opens=[]

    def module(self,stage=None,*,open_error=None,**kwargs):
        def open_native(file,**options):
            self.opens.append(options)
            container=NativeContainer(file,options['io_open'],stage,**kwargs)
            self.containers.append(container)
            if stage == 'open': container.ignored_request()
            if open_error is not None: raise open_error
            return container
        return SimpleNamespace(__version__='19.0.0',open=open_native)

    def assert_original_borrowed(self):
        self.assertFalse(self.stream.closed)
        self.stream.seek(0); self.assertEqual(self.stream.read(),self.original)
        self.assertEqual(self.path.read_bytes(),self.original)

    def test_rejects_path_url_unbounded_primary_and_output_before_native_open(self):
        with patch.object(local,'_av',return_value=self.module()):
            for file in (str(self.path),self.path,'https://controlled.invalid',io.BytesIO(self.original)):
                with self.assertRaises(local.LocalDecoderError):
                    with local.open_local_decoder(file): self.fail('must not yield')
            with self.assertRaises(local.LocalDecoderError):
                with local.open_local_decoder(self.bounded,mode='w'): self.fail('must not yield')
        self.assertEqual(self.opens,[]); self.assert_original_borrowed()

    def test_contained_decode_eof_demux_and_context_never_closes_borrowed_file(self):
        options={'advanced_editlist':'1','ignore_editlist':'0'}
        with patch.object(local,'_av',return_value=self.module()):
            with local.open_local_decoder(self.bounded,options=options) as container:
                self.assertEqual(list(container.decode()),['controlled-frame'])
                self.assertEqual(list(container.demux()),['controlled-frame'])
                self.assertEqual(container.secondary_request_count,0)
                with self.assertRaises(AttributeError): container.io_open
            self.assertTrue(self.containers[0].closed)
            with self.assertRaises(local.LocalDecoderError): container.seek(0)
        self.assertEqual(options,{'advanced_editlist':'1','ignore_editlist':'0'})
        self.assertEqual(self.opens[0]['options'],options)
        self.assertTrue(all(it.closed for it in self.containers[0].iterators))
        self.assert_original_borrowed()

    def test_optional_secondary_request_ignored_by_native_open_still_prevents_yield(self):
        with patch.object(local,'_av',return_value=self.module('open')):
            with self.assertRaises(local.SecondaryIODenied) as caught:
                with local.open_local_decoder(self.bounded): self.fail('denied open must not yield')
        self.assertEqual(caught.exception.request_count,1)
        self.assertNotIn('controlled.invalid',str(caught.exception))
        self.assertTrue(self.containers[0].closed); self.assert_original_borrowed()

    def test_optional_decode_and_demux_request_cannot_publish_even_one_returned_frame(self):
        for method in ('decode','demux'):
            for stage in ('decode','threaded'):
                with self.subTest(method=method,stage=stage),patch.object(local,'_av',return_value=self.module(stage)):
                    with self.assertRaises(local.SecondaryIODenied):
                        with local.open_local_decoder(self.bounded) as container:
                            frames=getattr(container,method)()
                            with self.assertRaises(local.SecondaryIODenied): next(frames)
                            self.assertEqual(container.secondary_request_count,1)
                            with self.assertRaises(local.LocalDecoderError): container.seek(0)
                    self.assertTrue(self.containers[-1].closed)
                    self.assertTrue(self.containers[-1].iterators[0].closed)
                    if stage == 'threaded':
                        self.assertFalse(self.containers[-1].callback_thread.is_alive())
        self.assert_original_borrowed()

    def test_optional_eof_seek_and_close_requests_are_latched_without_success_publication(self):
        for stage in ('EOF','seek','close'):
            with self.subTest(stage=stage),patch.object(local,'_av',return_value=self.module(stage)):
                with self.assertRaises(local.SecondaryIODenied):
                    with local.open_local_decoder(self.bounded) as container:
                        if stage == 'seek': container.seek(0)
                        elif stage == 'EOF':
                            iterator=container.decode()
                            self.assertEqual(next(iterator),'controlled-frame')
                            with self.assertRaises(local.SecondaryIODenied): next(iterator)
                        else: self.assertEqual(list(container.decode()),['controlled-frame'])
                self.assertEqual(container.secondary_request_count,3 if stage=='close' else 1)
                self.assertTrue(self.containers[-1].closed)
        self.assert_original_borrowed()

    def test_native_open_failure_preserves_primary_and_records_denial_without_target_details(self):
        primary=RuntimeError('controlled native open failure')
        with patch.object(local,'_av',return_value=self.module('open',open_error=primary)):
            with self.assertRaises(RuntimeError) as caught:
                with local.open_local_decoder(self.bounded): self.fail('must not yield')
        self.assertIs(caught.exception,primary)
        self.assertTrue(any('denied (1 requests)' in n for n in primary.__notes__))
        self.assertNotIn('controlled.invalid',' '.join(primary.__notes__))
        self.assert_original_borrowed()

    def test_body_error_survives_native_close_error_and_owned_close_is_retryable(self):
        primary=RuntimeError('controlled caller decode failure')
        with patch.object(local,'_av',return_value=self.module(close_failures=1)):
            with self.assertRaises(RuntimeError) as caught:
                with local.open_local_decoder(self.bounded): raise primary
            self.assertIs(caught.exception,primary)
            self.assertIsInstance(primary.__cause__,OSError)
            self.assertFalse(self.containers[0].closed)
            primary.retry_local_decoder_close()
            primary.retry_local_decoder_close()
            self.assertTrue(self.containers[0].closed); self.assertEqual(self.containers[0].close_calls,2)
        self.assert_original_borrowed()

    def test_iterator_close_failure_retains_owned_retry_even_after_native_close_succeeded(self):
        primary=RuntimeError('controlled interruption after one frame')
        with patch.object(local,'_av',return_value=self.module(iterator_close_failures=1)):
            with self.assertRaises(RuntimeError) as caught:
                with local.open_local_decoder(self.bounded) as container:
                    self.assertEqual(next(container.decode()),'controlled-frame')
                    raise primary
            self.assertIs(caught.exception,primary)
            self.assertTrue(self.containers[0].closed)
            self.assertFalse(self.containers[0].iterators[0].closed)
            primary.retry_local_decoder_close()
            self.assertTrue(self.containers[0].iterators[0].closed)
            self.assertEqual(self.containers[0].close_calls,1)
        self.assert_original_borrowed()

    def test_cancel_before_open_and_source_guard_before_close_still_cleans_native_only(self):
        with patch.object(local,'_av',return_value=self.module()):
            with self.assertRaises(local.LocalDecoderCancelled):
                with local.open_local_decoder(self.bounded,check=lambda:True): self.fail('must not yield')
        self.assertEqual(self.opens,[])
        changed=[False]; primary=ValueError('controlled source change')
        def source_check():
            if changed[0]: raise primary
        with patch.object(local,'_av',return_value=self.module()):
            with self.assertRaises(ValueError) as caught:
                with local.open_local_decoder(self.bounded,check=source_check): changed[0]=True
        self.assertIs(caught.exception,primary); self.assertTrue(self.containers[0].closed)
        self.assertIsNot(primary.__cause__,primary)
        self.assert_original_borrowed()

    def test_cancel_after_native_close_and_hls_review_cannot_return_success(self):
        cancelled=[False]
        with patch.object(local,'_av',return_value=self.module(close_action=lambda:cancelled.__setitem__(0,True))):
            with self.assertRaises(local.LocalDecoderCancelled):
                with local.open_local_decoder(self.bounded,check=lambda:cancelled[0]) as container:
                    self.assertEqual(list(container.decode()),['controlled-frame'])
        self.assertTrue(self.containers[0].closed)
        with patch.object(local,'_av',return_value=self.module(format_name='hls')):
            with self.assertRaisesRegex(local.LocalDecoderError,'HLS'):
                with local.open_local_decoder(self.bounded): self.fail('must not yield')
        self.assertTrue(self.containers[-1].closed); self.assert_original_borrowed()

    def test_active_iterator_same_source_guard_error_keeps_first_error_without_self_cause(self):
        changed=[False]; primary=ValueError('controlled repeated source identity failure')
        def source_check():
            if changed[0]: raise primary
        with patch.object(local,'_av',return_value=self.module()):
            with self.assertRaises(ValueError) as caught:
                with local.open_local_decoder(self.bounded,check=source_check) as container:
                    iterator=container.decode()
                    self.assertEqual(next(iterator),'controlled-frame')
                    changed[0]=True
            self.assertIs(caught.exception,primary)
            self.assertIsNot(primary.__cause__,primary)
            self.assertTrue(any('active decoder iterator cleanup' in n for n in primary.__notes__))
            self.assertTrue(self.containers[0].iterators[0].closed)
            self.assertTrue(self.containers[0].closed)
            self.assertEqual(self.containers[0].close_calls,1)
            primary.retry_local_decoder_close()
            self.assertEqual(self.containers[0].close_calls,1)
            with self.assertRaises(local.LocalDecoderError): next(iterator)
        self.assert_original_borrowed()

    def test_one_active_iterator_bound_and_sticky_error_are_explicit(self):
        with patch.object(local,'_av',return_value=self.module()):
            with local.open_local_decoder(self.bounded) as container:
                first=container.decode()
                with self.assertRaisesRegex(local.LocalDecoderError,'active'): container.demux()
                first.close()
                self.assertEqual(list(container.demux()),['controlled-frame'])
        self.assert_original_borrowed()


@unittest.skipUnless(importlib.util.find_spec('av') is not None,
                     'PyAV19 actual contained decoder unavailable; required runner rejects this skip')
class ActualLocalDecoderTests(unittest.TestCase):
    def test_actual_software_mpeg4_mov_eof_exact_pts_and_primary_hash_preserved(self):
        import av
        from PIL import Image
        with tempfile.TemporaryDirectory() as directory:
            source=Path(directory)/'authored-contained.mov'
            with av.open(str(source),'w',format='mov') as output:
                stream=output.add_stream('mpeg4',rate=24)
                stream.width=96; stream.height=64; stream.pix_fmt='yuv420p'
                for index in range(3):
                    frame=av.VideoFrame.from_image(Image.new('RGB',(96,64),(20+index*30,100,40)))
                    frame.pts=index; frame.time_base=Fraction(1,24)
                    for packet in stream.encode(frame): output.mux(packet)
                for packet in stream.encode(None): output.mux(packet)
            before=hashlib.sha256(source.read_bytes()).hexdigest()
            with source.open('rb') as file:
                bounded=_BoundedInput(file,source.stat().st_size,
                    stat_snapshot(os.fstat(file.fileno()),domain='descriptor'),lambda:False)
                with local.open_local_decoder(bounded) as container:
                    observed=[]
                    for frame in container.decode(video=0):
                        self.assertLess(len(observed),4,'finite authored EOF cap')
                        base=Fraction(frame.time_base.numerator,frame.time_base.denominator)
                        observed.append(frame.pts*base)
                    self.assertEqual(observed,[Fraction(0),Fraction(1,24),Fraction(1,12)])
                    self.assertEqual(container.secondary_request_count,0)
                self.assertFalse(file.closed)
            self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(),before)


if __name__ == '__main__':
    unittest.main()
