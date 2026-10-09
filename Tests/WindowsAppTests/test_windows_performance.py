"""Pixel/clock regression checks for bounded playback and cropped effects."""
from copy import deepcopy
from fractions import Fraction as F
import unittest
from unittest.mock import patch
import numpy as np
from PIL import Image
from PySide6.QtGui import QImage
from platforms.windows.bluraction import renderer,canonical_transport as transport
from platforms.windows.bluraction.auto_find import Detection
from platforms.windows.bluraction.find_actions import prepared_regions
import test_canonical_video as fixtures


class WindowsPerformanceTests(unittest.TestCase):
    def test_windows_tcp_channel_disables_delayed_small_messages(self):
        import socket
        sock=socket.socket(socket.AF_INET,socket.SOCK_STREAM)
        self.addCleanup(sock.close)
        channel=transport._TransportChannel(sock)
        self.assertEqual(channel.socket.getsockopt(socket.IPPROTO_TCP,socket.TCP_NODELAY),1)

    def fixture(self):
        helper=fixtures.CanonicalVideoTests()
        helper.setUp()
        self.addCleanup(helper.doCleanups)
        return helper

    def test_forward_decoder_reuse_backward_seek_and_empty_intervals(self):
        helper=self.fixture(); provider=helper.build()
        first=transport.snapshot_frame(provider,F(1,2))
        second=transport.snapshot_frame(provider,F(3,4))
        self.assertEqual((first.source_index,second.source_index),(0,1))
        self.assertEqual(len(helper.containers),1)
        self.assertFalse(helper.containers[0].closed)
        repeat=transport.snapshot_frame(provider,F(7,8))
        self.assertEqual(repeat.asset_pts,F(3,4))
        self.assertEqual(len(helper.containers),1)
        empty=transport.snapshot_frame(provider,F(0))
        self.assertEqual(empty.presence,'empty'); self.assertIsNone(empty.image)
        back=transport.snapshot_frame(provider,F(1,2))
        self.assertEqual(back.source_index,0)
        self.assertEqual(len(helper.containers),2)
        self.assertTrue(helper.containers[0].closed)
        provider.close()
        self.assertTrue(all(c.closed for c in helper.containers))

    def test_changed_next_observation_never_publishes_pixels(self):
        helper=self.fixture()
        provider=helper.build(decoder_access=helper.access(pixel_rows=[fixtures.frame(500),fixtures.frame(750,width=95)]))
        transport.snapshot_frame(provider,F(1,2))
        with self.assertRaisesRegex(ValueError,'inventory'):
            transport.snapshot_frame(provider,F(3,4))
        self.assertTrue(provider._closed)

    def test_generation_change_invalidates_live_preview_even_on_close_error(self):
        helper=self.fixture(); provider=helper.build()
        transport.snapshot_frame(provider,F(1,2))
        helper.current[0]=10
        with self.assertRaisesRegex(ValueError,'generation'):
            transport.snapshot_frame(provider,F(3,4))
        self.assertTrue(provider._closed)
        helper.current[0]=9
        with self.assertRaises(ValueError):
            transport.snapshot_frame(provider,F(1,2))

    def test_scaled_cache_cannot_replace_full_resolution_query(self):
        helper=self.fixture(); provider=helper.build()
        original=provider._normalized_image
        def normalized(frame,observed,stream,maximum_edge=None):
            image=original(frame,observed,stream)
            return image.scaled(48,32) if maximum_edge else image
        with patch.object(provider,'_normalized_image',side_effect=normalized):
            small=transport.snapshot_frame(provider,F(1,2),maximum_edge=960)
            self.assertEqual(small.image.width(),48)
            full=provider.frame_at(F(1,2))
            self.assertEqual(full.image.width(),96)
            self.assertEqual(full.source_index,small.source_index)
            again=transport.snapshot_frame(provider,F(1,2))
            self.assertEqual(again.image.width(),96)

    def test_cropped_blur_preserves_full_filter_with_transparency_and_edges(self):
        rng=np.random.default_rng(719)
        source=rng.integers(0,256,(87,123,4),dtype=np.uint8)
        for box in [(0,0,20,25),(90,60,123,87),(31,21,61,51),(0,0,123,87)]:
            for radius in [0.,1.3,12.5,80.]:
                left,top,right,bottom=box
                for channel in [0,3]:
                    full=renderer._source_channel(source,channel)
                    renderer._gaussian_inplace(full,radius/2)
                    crop=renderer._cropped_blur(source,channel,radius,box)
                    np.testing.assert_allclose(crop,full[top:bottom,left:right],rtol=0,atol=3e-7)
                    fast=renderer._cropped_blur(source,channel,radius,box,fast=True)
                    np.testing.assert_allclose(fast,crop,rtol=0,atol=3e-6)

    def test_effect_render_stays_equivalent_to_full_frame_blur(self):
        rng=np.random.default_rng(77)
        source=rng.integers(0,256,(100,160,4),dtype=np.uint8)
        image=renderer.to_qimage(Image.fromarray(source))
        state={'regions':[],'drawings':[]}
        state['regions']=prepared_regions([Detection((0.,.05,.22,.35),'faces',1.),
            Detection((.70,.70,.30,.30),'text',1.)],state,0.,None,style='blur',radius=8.5,
            feather=4.,color={'red':0.,'green':0.,'blue':0.,'alpha':1.})
        actual=np.asarray(renderer.to_pillow(renderer.render(image,state)))
        def full_blur(source,channel,radius,box,**kwargs):
            left,top,right,bottom=box
            values=renderer._source_channel(source,channel)
            renderer._gaussian_inplace(values,radius/2)
            return values[top:bottom,left:right]
        with patch.object(renderer,'_cropped_blur',side_effect=full_blur):
            expected=np.asarray(renderer.to_pillow(renderer.render(image,state)))
        self.assertLessEqual(int(np.max(np.abs(actual.astype(int)-expected.astype(int)))),1)

    def test_playback_effect_scale_does_not_mutate_portable_state(self):
        state={'regions':[],'drawings':[]}
        state['regions']=prepared_regions([Detection((.1,.2,.3,.4),'text',1.)],state,0.,None,
            style='blur',radius=25.,feather=12.,color={'red':0.,'green':0.,'blue':0.,'alpha':1.})
        before=deepcopy(state); image=QImage(960,540,QImage.Format.Format_RGBA8888)
        with patch.object(renderer,'render',return_value=image) as render:
            renderer.render_preview(image,state,0.,(1920,1080))
        self.assertEqual(state,before)
        scaled=render.call_args.args[1]['regions'][0]
        self.assertEqual(scaled['shape'],state['regions'][0]['shape'])
        self.assertEqual(scaled['effect']['blurRadius'],12.5)
        self.assertEqual(scaled['effect']['featherRadius'],6.)

    def test_sparse_quantization_matches_dense_filter_and_keeps_untouched_bytes(self):
        rng=np.random.default_rng(910)
        original=rng.integers(0,256,(37,83,4),dtype=np.uint8)
        linear=renderer._source_linear(original)
        linear[:,:,:3]*=.72
        touched=rng.random((37,83))>.8
        dense=renderer._linear_bytes(linear)
        sparse=renderer._linear_bytes(linear,original,touched)
        np.testing.assert_array_equal(sparse[touched],dense[touched])
        np.testing.assert_array_equal(sparse[~touched],original[~touched])
