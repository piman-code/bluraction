"""Converter contract boundaries; native eight-MOV bytes live in the fixture family.

Controlled reformatter observations prove flags, tight rows and no fallback.
They are not a substitute for actual two-host decoding, color or alpha parity.
"""
from fractions import Fraction
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from PIL import Image
from platforms.windows.bluraction import video


class Plane:
    def __init__(self, data, stride): self.data=data; self.line_size=stride
    def __bytes__(self): return self.data


class VideoPixelContractTests(unittest.TestCase):
    def frame(self, width=2, height=2, name='yuv420p', transfer=2):
        def forbidden(): raise AssertionError('v2 must not fall back to native default converter')
        return SimpleNamespace(width=width,height=height,format=SimpleNamespace(name=name),
            color_trc=transfer,rotation=0.0,side_data={},to_image=forbidden)

    def converted(self, data=None, stride=8, width=2, height=2, name='rgb24'):
        if data is None:
            # Visible red/green then blue/white. Nonzero padding is NEVER pixels.
            data=b'\xff\0\0\0\xff\0AB'+b'\0\0\xff\xff\xff\xffCD'
        return SimpleNamespace(width=width,height=height,format=SimpleNamespace(name=name),
                               planes=[Plane(data,stride)])

    def test_precise_flags_tight_rows_and_source_metadata_unchanged(self):
        frame=self.frame(); before=vars(frame).copy()
        result=self.converted()
        with patch('av.video.reformatter.VideoReformatter') as constructor:
            constructor.return_value.reformat.return_value=result
            pixels=video._decoded_pixel_image(frame)
            constructor.assert_called_once_with()
            call=constructor.return_value.reformat.call_args
            self.assertEqual(call.args,(frame,))
            self.assertEqual(set(call.kwargs),{'format','interpolation'})
            self.assertEqual(call.kwargs['format'],'rgb24')
            self.assertEqual(int(call.kwargs['interpolation']),786434)
        self.assertEqual(pixels.tobytes(),b'\xff\0\0\0\xff\0\0\0\xff\xff\xff\xff')
        self.assertEqual(pixels.mode,'RGB')
        self.assertEqual(vars(frame),before)
        self.assertEqual(bytes(result.planes[0]),b'\xff\0\0\0\xff\0AB\0\0\xff\xff\xff\xffCD')

    def test_legacy_formats_and_known_hdr_keep_existing_path_and_no_v2_claim(self):
        for name,transfer in (('rgba',1),('rgb24',1),('yuv444p',1),('yuv420p10le',16),
                              ('yuv420p',16),('yuv420p',18)):
            with self.subTest(name=name,transfer=transfer):
                frame=self.frame(name=name,transfer=transfer)
                original=Image.new('RGBA',(2,2),(71,89,133,127))
                calls=[]
                frame.to_image=lambda:(calls.append(True) or original)
                with patch('av.video.reformatter.VideoReformatter') as constructor:
                    output=video._decoded_pixel_image(frame)
                    constructor.assert_not_called()
                self.assertEqual(video.pixel_contract(frame),video.LEGACY_PIXEL_CONTRACT)
                self.assertEqual(output.tobytes(),original.convert('RGB').tobytes())
                self.assertEqual(original.getpixel((0,0)),(71,89,133,127))
                self.assertEqual(calls,[True])

    def test_conversion_failure_never_chooses_legacy_or_close_color(self):
        frame=self.frame(); primary=RuntimeError('controlled native conversion failed')
        with patch('av.video.reformatter.VideoReformatter') as constructor:
            constructor.return_value.reformat.side_effect=primary
            with self.assertRaises(RuntimeError) as caught: video._decoded_pixel_image(frame)
        self.assertIs(caught.exception,primary)

    def test_truncated_rows_changed_dimensions_and_format_fail_closed(self):
        bad=(self.converted(data=b'x'*15),self.converted(stride=5),
             self.converted(width=1),self.converted(name='rgba'))
        for result in bad:
            with self.subTest(result=result):
                with patch('av.video.reformatter.VideoReformatter') as constructor:
                    constructor.return_value.reformat.return_value=result
                    with self.assertRaises(video.VideoError): video._decoded_pixel_image(self.frame())

    def test_invalid_geometry_rejected_before_native_converter_allocates(self):
        for width,height in ((0,2),(True,2),(16385,2),(16384,16384)):
            with self.subTest(width=width,height=height),patch('av.video.reformatter.VideoReformatter') as constructor:
                with self.assertRaises(video.VideoError): video._decoded_pixel_image(self.frame(width,height))
                constructor.assert_not_called()

    def test_rotation_and_sar_still_happen_once_after_precise_conversion(self):
        frame=self.frame();frame.rotation=90.0
        with patch('av.video.reformatter.VideoReformatter') as constructor:
            constructor.return_value.reformat.return_value=self.converted()
            output=video._display_image(frame,Fraction(2))
        self.assertEqual((output.width(),output.height()),(2,4))
        # SAR resized horizontal axis is rotated into height exactly once.
        self.assertEqual(output.pixelColor(0,0).green(),255)
        self.assertEqual(output.pixelColor(1,0).red(),255)
        self.assertEqual(output.pixelColor(1,0).green(),255)
        self.assertEqual(output.pixelColor(0,3).red(),255)
        self.assertEqual(output.pixelColor(1,3).blue(),255)


if __name__=='__main__':unittest.main()
