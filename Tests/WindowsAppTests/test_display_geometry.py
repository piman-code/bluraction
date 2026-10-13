from fractions import Fraction as F
from types import SimpleNamespace
import unittest
from platforms.windows.bluraction.display_geometry import resolve_display_sar, DisplayGeometryError
from platforms.windows.bluraction.canonical_video import OwnedCanonicalVideoProvider
from platforms.windows.bluraction.frame_inventory import InventoryLimits
from Tests.WindowsAppTests.test_canonical_video import frame


class DisplayGeometryTests(unittest.TestCase):
    def test_absent_and_zero_ratios_use_square_pixels(self):
        for values in ((None,None,None),(F(0),F(0),F(0)),(None,F(0),None)):
            with self.subTest(values=values):
                self.assertEqual(resolve_display_sar(*values),F(1))

    def test_observed_non_square_pixels_take_priority(self):
        self.assertEqual(resolve_display_sar(F(4,3),F(1),F(2)),F(4,3))
        self.assertEqual(resolve_display_sar(None,F(8,9),F(1)),F(8,9))
        self.assertEqual(resolve_display_sar(F(0),F(0),F(3,2)),F(3,2))

    def test_malformed_metadata_does_not_use_square_fallback(self):
        for value in (F(-1),1.0,True,'1:1',SimpleNamespace(numerator=1,denominator=1)):
            with self.subTest(value=value), self.assertRaises(DisplayGeometryError):
                resolve_display_sar(value)

    def test_native_pyav_rational_keeps_exact_anamorphic_ratio(self):
        from av.rational import AVRational
        self.assertEqual(resolve_display_sar(None,AVRational(8,9)),F(8,9))
        self.assertEqual(resolve_display_sar(None,AVRational(0,1)),F(1))
        with self.assertRaises(DisplayGeometryError):
            resolve_display_sar(AVRational(1,0))

    def test_display_uses_container_ratio_when_codec_and_frame_omit_it(self):
        provider=SimpleNamespace(_inventory=SimpleNamespace(decoder=SimpleNamespace(
            codec_sar=None,guessed_stream_sar=F(3,2))),_limits=InventoryLimits())
        pixels=frame(0,sample_aspect_ratio=None)
        observation=SimpleNamespace(frame_sar=None,width=96,height=64,display_matrix=None,rotation=0.)
        image=OwnedCanonicalVideoProvider._normalized_image(provider,pixels,observation,SimpleNamespace(metadata={}))
        self.assertEqual((image.width(),image.height()),(144,64))

    def test_display_without_metadata_keeps_original_pixel_geometry(self):
        provider=SimpleNamespace(_inventory=SimpleNamespace(decoder=SimpleNamespace(
            codec_sar=None,guessed_stream_sar=None)),_limits=InventoryLimits())
        pixels=frame(0,sample_aspect_ratio=None)
        observation=SimpleNamespace(frame_sar=None,width=96,height=64,display_matrix=None,rotation=0.)
        image=OwnedCanonicalVideoProvider._normalized_image(provider,pixels,observation,SimpleNamespace(metadata={}))
        self.assertEqual((image.width(),image.height()),(96,64))

    def test_anamorphic_normalization_still_enforces_resource_limit(self):
        provider=SimpleNamespace(_inventory=SimpleNamespace(decoder=SimpleNamespace(
            codec_sar=F(200),guessed_stream_sar=None)),_limits=InventoryLimits())
        pixels=frame(0,sample_aspect_ratio=None)
        observation=SimpleNamespace(frame_sar=None,width=96,height=64,display_matrix=None,rotation=0.)
        with self.assertRaisesRegex(ValueError,'resource budget'):
            OwnedCanonicalVideoProvider._normalized_image(provider,pixels,observation,SimpleNamespace(metadata={}))
