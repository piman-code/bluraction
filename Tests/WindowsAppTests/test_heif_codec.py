"""Fake-policy checks are not HEIC proof. Actual optional codec tests stay visible.

Run only in an approved codec environment. Tests generate synthetic containers;
no personal sources, downloads, installation or native UI automation is used.
"""
import os
os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')
from io import BytesIO
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

from PIL import Image, ImageOps
from PySide6.QtGui import QColor, QColorSpace, QImage
from PySide6.QtWidgets import QApplication

from platforms.windows.bluraction import heif_codec as codec
from platforms.windows.bluraction.renderer import to_qimage

APP = QApplication.instance() or QApplication([])


class FakeContainer:
    """Already displayed pixels; models lazy primary-only access, not a codec."""
    mimetype = 'image/heic'

    def __init__(self, primary, info=None, count=1):
        self.primary = primary
        self.size = primary.size
        self.info = {'bit_depth': 8, 'chroma': 444, **(info or {})}
        self.has_alpha = primary.mode == 'RGBA'
        self.count = count
        self.to_pillow = Mock(return_value=primary)

    def __len__(self):
        return self.count


class HeifPolicyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.source = Path(self.temp.name) / 'fake-not-real-heic.heic'
        self.source.write_bytes(b'fake container metadata only; not real HEIC')

    def tearDown(self):
        self.temp.cleanup()

    def test_absent_and_old_backend_report_explicit_error_without_install(self):
        with patch.object(codec.importlib, 'import_module', side_effect=ModuleNotFoundError('missing')):
            with self.assertRaisesRegex(codec.HeifUnavailable, '자동 설치하지'):
                codec.inspect_heif(self.source)
        with patch.object(codec.importlib, 'import_module', return_value=SimpleNamespace(__version__='1.7.0')):
            with self.assertRaisesRegex(codec.HeifUnavailable, '1.8'):
                codec.inspect_heif(self.source)

    def test_primary_metadata_preflight_rejects_oversize_before_pixel_access(self):
        fake = FakeContainer(Image.new('RGB', (4, 4)))
        fake.size = (6000, 4001)
        backend = SimpleNamespace(open_heif=Mock(return_value=fake))
        with patch.object(codec, '_backend', return_value=backend):
            with self.assertRaisesRegex(codec.HeifCodecError, '24MP'):
                codec.read_heif(self.source)
        fake.to_pillow.assert_not_called()

    def test_inspect_is_lazy_and_read_uses_only_primary_without_second_exif_rotation(self):
        primary = Image.new('RGBA', (20, 40), 'white')
        primary.putpixel((0, 0), (255, 0, 0, 255))
        fake = FakeContainer(primary, count=2)
        # libheif/to_pillow have already consumed the encoded transforms.
        exif = Image.Exif()
        exif[274] = 1
        primary.info = {'exif': exif.tobytes(), 'original_orientation': 6, 'xmp': b'private source metadata'}
        backend = SimpleNamespace(open_heif=Mock(return_value=fake))
        with patch.object(codec, '_backend', return_value=backend), \
             patch.object(ImageOps, 'exif_transpose', side_effect=AssertionError('double rotation')):
            metadata = codec.inspect_heif(self.source)
            fake.to_pillow.assert_not_called()
            self.assertEqual(metadata.item_count, 2)
            result = codec.read_heif(self.source)
        fake.to_pillow.assert_called_once()
        self.assertEqual((result.width(), result.height()), (20, 40))
        self.assertEqual(result.pixelColor(0, 0), QColor('red'))
        self.assertEqual(result.colorSpace(), QColorSpace(QColorSpace.NamedColorSpace.SRgb))
        self.assertEqual(result.textKeys(), [])

    def test_hdr_and_unknown_or_invalid_profile_are_explicit_not_srgb_relabeling(self):
        for info in ({'nclx_profile': {'transfer_characteristics': 16}},
                     {'nclx_profile': {'transfer_characteristics': 18}},
                     {'icc_profile': b'invalid ICC'},
                     {'nclx_profile': {'color_primaries': 999, 'transfer_characteristics': 13}}):
            fake = FakeContainer(Image.new('RGB', (16, 16)), info)
            with patch.object(codec, '_backend', return_value=SimpleNamespace(open_heif=Mock(return_value=fake))):
                with self.assertRaises(codec.HeifCodecError):
                    codec.read_heif(self.source)
            fake.to_pillow.assert_not_called()

    def test_icc_color_conversion_matches_one_qt_transform(self):
        profile = QColorSpace(QColorSpace.NamedColorSpace.DisplayP3)
        pil = Image.new('RGB', (16, 16), (220, 95, 40))
        fake = FakeContainer(pil, {'icc_profile': bytes(profile.iccProfile())})
        expected = to_qimage(pil)
        expected.setColorSpace(profile)
        expected = expected.convertedToColorSpace(QColorSpace(QColorSpace.NamedColorSpace.SRgb))
        with patch.object(codec, '_backend', return_value=SimpleNamespace(open_heif=Mock(return_value=fake))):
            result = codec.read_heif(self.source)
        self.assertEqual(result.pixelColor(0, 0), expected.pixelColor(0, 0))
        self.assertEqual(result.colorSpace(), expected.colorSpace())

    def fake_encoder(self):
        backend = SimpleNamespace(open_heif=Mock(), from_bytes=Mock())
        save = Mock(side_effect=lambda output, **kwargs: output.write(b'fake encoder output; not real HEIC'))

        def from_bytes(mode, size, data):
            backend.open_heif.return_value = FakeContainer(Image.frombytes(mode, size, data))
            return SimpleNamespace(save=save)

        backend.from_bytes.side_effect = from_bytes
        return backend, save

    def test_preserve_alpha_sanitizes_transparent_rgb_and_saves_only_fresh_pixels(self):
        pil = Image.new('RGBA', (16, 16), (255, 0, 0, 128))
        pil.putpixel((0, 0), (250, 200, 150, 0))
        pil.info = {'exif': b'private', 'xmp': b'private', 'thumbnails': [b'unmasked']}
        backend, save = self.fake_encoder()
        with patch.object(codec, '_backend', return_value=backend):
            output = codec.encode_heic(to_qimage(pil), 73)
        self.assertIn(b'fake encoder', output)
        mode, size, data = backend.from_bytes.call_args.args
        pixels = Image.frombytes(mode, size, data)
        self.assertEqual(mode, 'RGBA')
        self.assertEqual(pixels.getpixel((0, 0)), (0, 0, 0, 0))
        self.assertEqual(pixels.getpixel((8, 8)), (255, 0, 0, 128))
        self.assertEqual(save.call_args.kwargs['quality'], 73)
        self.assertEqual(save.call_args.kwargs['chroma'], 444)
        self.assertEqual(save.call_args.kwargs['bit_depth'], 8)
        self.assertFalse(save.call_args.kwargs['save_all'])
        self.assertIsNone(save.call_args.kwargs['exif'])
        self.assertIsNone(save.call_args.kwargs['xmp'])
        backend.open_heif.assert_called_once()
        backend.open_heif.return_value.to_pillow.assert_called_once()

    def test_explicit_white_policy_composites_alpha_without_preserving_source_aux(self):
        backend, _ = self.fake_encoder()
        with patch.object(codec, '_backend', return_value=backend):
            codec.encode_heic(to_qimage(Image.new('RGBA', (16, 16), (255, 0, 0, 128))), alpha_policy='white')
        mode, size, data = backend.from_bytes.call_args.args
        self.assertEqual(mode, 'RGB')
        self.assertEqual(Image.frombytes(mode, size, data).getpixel((8, 8)), (255, 127, 127))

    def test_reopen_rejects_unmasked_siblings_and_non_alpha_auxiliary(self):
        for info, count in [({}, 2), ({'aux': {'urn:private:gainmap': [2]}}, 1),
                            ({'thumbnails': [16]}, 1), ({'exif': b'private'}, 1),
                            ({'chroma': 420}, 1)]:
            fake = FakeContainer(Image.new('RGBA', (16, 16)), info, count)
            with self.assertRaises(codec.HeifCodecError):
                codec._verify_output(fake, (16, 16), True)
            fake.to_pillow.assert_not_called()
        alpha = FakeContainer(Image.new('RGBA', (16, 16)), {'aux': {'urn:mpeg:hevc:2015:auxid:1': [2]}})
        codec._verify_output(alpha, (16, 16), True)
        alpha.to_pillow.assert_called_once()

    def test_quality_policy_and_encoder_failure_never_silently_fall_back(self):
        image = to_qimage(Image.new('RGB', (16, 16)))
        for quality in (-1, 101, True, 95.0):
            with self.assertRaises(codec.HeifCodecError):
                codec.encode_heic(image, quality)
        backend, save = self.fake_encoder()
        save.side_effect = RuntimeError('4:4:4 encoder unavailable')
        with patch.object(codec, '_backend', return_value=backend):
            with self.assertRaisesRegex(codec.HeifCodecError, '대체하지'):
                codec.encode_heic(image)
        save.assert_called_once()


class ActualHeifCodecTests(unittest.TestCase):
    """Generated real codec bytes. Missing runtime is a visible unverified skip."""
    def setUp(self):
        try:
            self.backend = codec._backend()
        except codec.HeifUnavailable as error:
            self.skipTest('Actual HEIC decoder/encoder and alpha/metadata interoperability UNVERIFIED: ' + str(error))
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)

    def test_actual_heic_round_trip_preserves_8bit_alpha_and_has_no_source_items(self):
        pil = Image.new('RGBA', (96, 64), (255, 255, 255, 255))
        pil.paste((0, 0, 0, 255), (24, 16, 72, 48))
        pil.paste((0, 0, 0, 0), (0, 0, 16, 16))
        payload = codec.encode_heic(to_qimage(pil), 100)
        reopened = self.backend.open_heif(payload, convert_hdr_to_8bit=True)
        self.assertEqual(len(reopened), 1)
        self.assertEqual(reopened.info['bit_depth'], 8)
        self.assertTrue(reopened.has_alpha)
        path = Path(self.temp.name) / 'synthetic-alpha.heic'
        path.write_bytes(payload)
        result = codec.read_heif(path)
        self.assertEqual((result.width(), result.height()), (96, 64))
        self.assertLessEqual(result.pixelColor(8, 8).alpha(), 3)
        self.assertGreaterEqual(result.pixelColor(80, 55).alpha(), 252)
        self.assertLessEqual(max(result.pixelColor(48, 32).getRgb()[:3]), 6)
        self.assertEqual(reopened.info.get('thumbnails', []), [])
        self.assertFalse(reopened.info.get('exif'))
        self.assertFalse(reopened.info.get('xmp'))

    def test_actual_primary_rotation_icc_and_flatten_excludes_other_unmasked_frame(self):
        source = Image.new('RGB', (96, 64), 'white')
        source.paste('black', (16, 16, 80, 48))
        source.paste('red', (0, 0, 16, 16))
        source.paste('green', (80, 0, 96, 16))
        source.paste('blue', (0, 48, 16, 64))
        source.paste('yellow', (80, 48, 96, 64))
        exif = Image.Exif()
        exif[274] = 6
        # Supply raw pixels plus one orientation at encode, avoiding a fixture
        # helper which may itself pre-rotate before adding encoded transforms.
        sibling = Image.new('RGB', (96, 64), 'red')
        container = self.backend.from_bytes('RGB', sibling.size, sibling.tobytes())
        primary = container.add_frombytes('RGB', source.size, source.tobytes())
        primary.info['exif'] = exif.tobytes()
        primary.info['icc_profile'] = bytes(QColorSpace(QColorSpace.NamedColorSpace.SRgb).iccProfile())
        original = Path(self.temp.name) / 'synthetic-two-images.heif'
        container.save(original, primary_index=1, save_all=True, quality=100, chroma=444, tile_size=0)
        original_bytes = original.read_bytes()
        metadata = codec.inspect_heif(original)
        self.assertEqual(metadata.item_count, 2)
        result = codec.read_heif(original)
        self.assertEqual((result.width(), result.height()), (64, 96))
        self.assertLessEqual(max(result.pixelColor(32, 48).getRgb()[:3]), 6)
        for point, expected in [((8, 8), QColor('blue')), ((56, 8), QColor('red')),
                                ((8, 88), QColor('yellow')), ((56, 88), QColor('green'))]:
            actual = result.pixelColor(*point).getRgb()[:3]
            self.assertLessEqual(max(abs(a - b) for a, b in zip(actual, expected.getRgb()[:3])), 8)
        output = codec.encode_heic(result, 100)
        flattened = self.backend.open_heif(output)
        self.assertEqual(len(flattened), 1)
        self.assertEqual(flattened.size, (64, 96))
        self.assertFalse(flattened.info.get('exif'))
        self.assertFalse(flattened.info.get('metadata'))
        self.assertEqual(flattened.info.get('thumbnails', []), [])
        self.assertEqual(original.read_bytes(), original_bytes)


if __name__ == '__main__':
    unittest.main()
