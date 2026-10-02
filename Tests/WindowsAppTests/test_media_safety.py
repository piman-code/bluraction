"""Controlled local filesystem regressions; no personal media or installs.

These tests are authored for serial execution by the parent. A host that cannot
create symlinks reports those specific integration proofs as skips.
"""
import os
os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')
import hashlib
from fractions import Fraction
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from PIL import Image
from PySide6.QtWidgets import QApplication
from platforms.windows.bluraction import media, video

APP = QApplication.instance() or QApplication([])


class MediaSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.folder = Path(self.temp.name)
        with media._cache_guard:
            media._image_cache.clear()

    def tearDown(self):
        with media._cache_guard:
            media._image_cache.clear()
        self.temp.cleanup()

    def png(self, path=None):
        path = path or self.folder / 'source.png'
        Image.new('RGB', (32, 20), (235, 180, 80)).save(path)
        return path

    def test_invalid_image_failure_releases_device_while_traceback_is_retained(self):
        path = self.folder / 'invalid-new.png'
        path.write_bytes(b'controlled invalid image')
        failure = None
        try:
            media.load_pages([path])
        except ValueError as error:
            failure = error  # Keep traceback alive, as the asynchronous UI does.
        self.assertIsNotNone(failure)
        self.assertIsNotNone(failure.__traceback__)
        self.assertEqual(path.read_bytes(), b'controlled invalid image')
        renamed = path.with_name('released-invalid.png')
        path.rename(renamed)  # Actual Windows handle exclusion is tested by CI.
        renamed.unlink()
        self.assertFalse(renamed.exists())

    def test_valid_image_metadata_and_pixels_release_input_before_return(self):
        path = self.png()
        before = path.read_bytes()
        size = media._read_qt_image(path, metadata_only=True)
        image = media._read_qt_image(path)
        self.assertEqual((size.width(), size.height()), (32, 20))
        self.assertEqual((image.width(), image.height()), (32, 20))
        self.assertEqual(image.pixelColor(16, 10).getRgb(), (235, 180, 80, 255))
        self.assertEqual(path.read_bytes(), before)
        path.unlink()  # The returned decoded image must not keep the file open.
        self.assertFalse(path.exists())

    def test_invalid_pdf_failure_releases_document_while_traceback_is_retained(self):
        path = self.folder / 'invalid-new.pdf'
        path.write_bytes(b'%PDF-1.7\ncontrolled incomplete PDF')
        failure = None
        try:
            media.load_pages([path])
        except ValueError as error:
            failure = error
        self.assertIsNotNone(failure)
        self.assertIsNotNone(failure.__traceback__)
        self.assertEqual(path.read_bytes(), b'%PDF-1.7\ncontrolled incomplete PDF')
        renamed = path.with_name('released-invalid.pdf')
        path.rename(renamed)
        renamed.unlink()
        self.assertFalse(renamed.exists())

    def symlink(self, target, path, directory=False):
        try:
            path.symlink_to(target, target_is_directory=directory)
        except (OSError, NotImplementedError) as error:
            self.skipTest('This host cannot create synthetic symlinks: ' + str(error))

    def sparse(self, path, size):
        with path.open('wb') as out:
            out.truncate(size)
        return path

    def test_fingerprint_size_limit_is_checked_before_opening_content(self):
        path = self.sparse(self.folder / 'oversized.bin', 4097)
        with patch.object(media.os, 'open', side_effect=AssertionError('Content opened before size rejection')) as opened:
            with self.assertRaisesRegex(ValueError, '용량 한도'):
                media.fingerprint(path, max_bytes=4096)
        opened.assert_not_called()
        path.write_bytes(b'controlled original bytes')
        self.assertEqual(media.fingerprint(path, max_bytes=4096), hashlib.sha256(path.read_bytes()).hexdigest())

    def test_load_preflights_per_file_and_entire_set_before_any_hash(self):
        for suffix, limit in (('.png', 128 * 1024 ** 2), ('.pdf', 512 * 1024 ** 2)):
            path = self.folder / ('oversized' + suffix); path.write_bytes(b'controlled preflight fixture')
            identity = media._capture_identity(path)
            metadata = list(identity.metadata); metadata[3] = limit + 1
            oversized = media.SourceIdentity(identity.canonical, tuple(metadata))
            with patch.object(media, '_capture_identity', return_value=oversized), \
                 patch.object(media, 'fingerprint', side_effect=AssertionError('Hashing oversized source')) as digest:
                with self.assertRaisesRegex(ValueError, '한 파일'):
                    media.load_pages([path])
            digest.assert_not_called()
        paths = [self.sparse(self.folder / f'aggregate-{index}.png', 128) for index in range(9)]
        with patch.object(media, 'MAX_SOURCE_BYTES', 1024), \
             patch.object(media, 'fingerprint', side_effect=AssertionError('Content read before aggregate preflight')) as digest:
            with self.assertRaisesRegex(ValueError, '전체 입력'):
                media.load_pages(paths)
        digest.assert_not_called()

    def test_cancel_before_open_and_after_first_read_stops_hashing(self):
        path = self.folder / 'chunks.bin'; path.write_bytes(b'A' * (3 * 1024 ** 2))
        with patch.object(media.os, 'open', side_effect=AssertionError('Cancelled source opened')):
            with self.assertRaises(media.Cancelled):
                media.fingerprint(path, cancel=lambda: True)
        cancelled = False
        original_read = os.read
        def read(fd, count):
            nonlocal cancelled
            result = original_read(fd, count)
            cancelled = True
            return result
        with patch.object(media.os, 'read', side_effect=read) as reads:
            with self.assertRaises(media.Cancelled):
                media.fingerprint(path, cancel=lambda: cancelled)
        self.assertEqual(reads.call_count, 1, 'Cancel must be observed before reading the rest of the source')
        with patch.object(media, 'fingerprint', side_effect=AssertionError('Cancelled load started hashing')):
            with self.assertRaises(media.Cancelled):
                media.load_pages([path], cancel=lambda: True)

    def test_descriptor_path_replacement_between_stat_and_open_is_rejected(self):
        path = self.folder / 'source.bin'; path.write_bytes(b'same synthetic bytes')
        rival = self.folder / 'replacement.bin'; rival.write_bytes(path.read_bytes())
        original_open = os.open
        def open_replacement(value, flags, *args, **kwargs):
            os.replace(rival, path)
            return original_open(value, flags, *args, **kwargs)
        with patch.object(media.os, 'open', side_effect=open_replacement), patch.object(media.os, 'read') as reads:
            with self.assertRaisesRegex(ValueError, '변경'):
                media.fingerprint(path)
        reads.assert_not_called()
        self.assertEqual(path.read_bytes(), b'same synthetic bytes')

    def test_fingerprint_rejects_growth_during_stream_read(self):
        path = self.folder / 'growing.bin'; original = b'G' * (2 * 1024 ** 2)
        path.write_bytes(original)
        original_read = os.read
        grew = False
        def grow(fd, count):
            nonlocal grew
            chunk = original_read(fd, count)
            if not grew:
                with path.open('ab') as out:
                    out.write(b'controlled growth')
                grew = True
            return chunk
        with patch.object(media.os, 'read', side_effect=grow) as reads:
            with self.assertRaisesRegex(ValueError, '변경'):
                media.fingerprint(path, max_bytes=len(original))
        self.assertEqual(reads.call_count, 1)
        self.assertEqual(path.read_bytes(), original + b'controlled growth')

    def test_symlink_leaf_is_rejected_and_no_follow_flag_is_used_when_available(self):
        path = self.folder / 'source.bin'; path.write_bytes(b'controlled bytes')
        original_open = os.open
        with patch.object(media.os, 'open', wraps=original_open) as opened:
            media.fingerprint(path)
        if hasattr(os, 'O_NOFOLLOW'):
            self.assertTrue(opened.call_args.args[1] & os.O_NOFOLLOW)
        link = self.folder / 'source-link.bin'; self.symlink(path, link)
        with patch.object(media.os, 'open', side_effect=AssertionError('Symlink content opened')):
            with self.assertRaises(ValueError):
                media.fingerprint(link)

    def test_parent_symlink_retarget_during_read_is_rejected(self):
        a, b = self.folder / 'a', self.folder / 'b'; a.mkdir(); b.mkdir()
        data = b'S' * (2 * 1024 ** 2)
        (a / 'source.bin').write_bytes(data); (b / 'source.bin').write_bytes(data)
        link = self.folder / 'current'; self.symlink(a, link, directory=True)
        original_read = os.read
        changed = False
        def retarget(fd, count):
            nonlocal changed
            result = original_read(fd, count)
            if not changed:
                link.unlink(); link.symlink_to(b, target_is_directory=True)
                changed = True
            return result
        with patch.object(media.os, 'read', side_effect=retarget):
            with self.assertRaisesRegex(ValueError, '변경'):
                media.fingerprint(link / 'source.bin')
        self.assertEqual((a / 'source.bin').read_bytes(), data)
        self.assertEqual((b / 'source.bin').read_bytes(), data)

    def test_cache_checks_identity_without_rehashing_each_paint(self):
        path = self.png()
        page = media.load_pages([path])[0]
        with patch.object(media, 'fingerprint', side_effect=AssertionError('Cached paint rehashed the entire source')):
            self.assertEqual((page.image.width(), page.image.height()), (32, 20))
            self.assertEqual((page.image.width(), page.image.height()), (32, 20))
        before = path.stat(); path.write_bytes(path.read_bytes() + b'synthetic mutation')
        os.utime(path, ns=(before.st_atime_ns, before.st_mtime_ns + 1_000_000_000))
        with self.assertRaisesRegex(ValueError, '변경'):
            _ = page.image

    def test_cache_retarget_and_snapshot_captured_identity_are_preserved(self):
        a, b = self.folder / 'a', self.folder / 'b'; a.mkdir(); b.mkdir()
        self.png(a / 'source.png'); self.png(b / 'source.png')
        link = self.folder / 'current'; self.symlink(a, link, directory=True)
        page = media.load_pages([link / 'source.png'])[0]
        cached = page.image
        link.unlink(); link.symlink_to(b, target_is_directory=True)
        snapshot = media.Page(page.source, page.source_sha256, cached, page.pdf_index,
                              page.point_size, dict(page.state), source_identity=page.source_identity)
        for candidate in (page, snapshot):
            with self.assertRaisesRegex(ValueError, '변경'):
                _ = candidate.image

    def test_publish_fallback_failure_reports_incomplete_output_without_deleting_public_path(self):
        temporary = self.folder / 'encoded.tmp'; temporary.write_bytes(b'finished synthetic payload')
        target = self.folder / 'output.bin'
        with patch.object(media.os, 'link', side_effect=OSError('Controlled no-hardlink filesystem')), \
             patch.object(media.os, 'fsync', side_effect=OSError('Controlled copy failure')):
            with self.assertRaisesRegex(media.IncompleteOutputError, '미완료 출력') as failure:
                media.publish_new(temporary, target)
        self.assertEqual(failure.exception.partial_output, target)
        self.assertIn('copy failure', str(failure.exception.__cause__))
        self.assertEqual(target.read_bytes(), b'finished synthetic payload')
        self.assertEqual(temporary.read_bytes(), b'finished synthetic payload')

    def test_publish_failure_preserves_rival_that_replaced_owned_file(self):
        temporary = self.folder / 'encoded.tmp'; temporary.write_bytes(b'finished synthetic payload')
        target = self.folder / 'output.bin'; owned = self.folder / 'original-owned-file.bin'
        original_open = Path.open
        class RivalOnClose:
            def __init__(self, stream):
                self.stream = stream
            def __enter__(self):
                return self
            def __getattr__(self, name):
                return getattr(self.stream, name)
            def __exit__(self, *args):
                self.stream.close()
                os.replace(target, owned)  # Keep inode alive to avoid reuse in this fixture.
                target.write_bytes(b'rival must survive')
                raise OSError('Controlled failure after rival replacement')
        def opened(path, mode='r', *args, **kwargs):
            stream = original_open(path, mode, *args, **kwargs)
            return RivalOnClose(stream) if Path(path) == target and mode == 'xb' else stream
        with patch.object(media.os, 'link', side_effect=OSError('Controlled no-hardlink filesystem')), \
             patch.object(Path, 'open', opened):
            with self.assertRaises(media.IncompleteOutputError) as failure:
                media.publish_new(temporary, target)
        self.assertEqual(failure.exception.partial_output, target)
        self.assertIn('rival replacement', str(failure.exception.__cause__))
        self.assertEqual(target.read_bytes(), b'rival must survive')
        self.assertEqual(owned.read_bytes(), b'finished synthetic payload')
        self.assertEqual(temporary.read_bytes(), b'finished synthetic payload')

    def test_publish_missing_temporary_reports_and_preserves_incomplete_public_path(self):
        missing = self.folder / 'missing.tmp'; target = self.folder / 'output.bin'
        with patch.object(media.os, 'link', side_effect=OSError('Controlled fallback')):
            with self.assertRaises(media.IncompleteOutputError) as failure:
                media.publish_new(missing, target)
        self.assertIsInstance(failure.exception.__cause__, FileNotFoundError)
        self.assertEqual(failure.exception.partial_output, target)
        self.assertEqual(target.read_bytes(), b'')

    def test_publish_collision_after_preflight_never_changes_rival(self):
        temporary = self.folder / 'encoded.tmp'; temporary.write_bytes(b'finished synthetic payload')
        target = self.folder / 'output.bin'
        def racing_link(*args):
            target.write_bytes(b'rival created after save panel')
            raise OSError('Controlled fallback after rival creation')
        with patch.object(media.os, 'link', side_effect=racing_link):
            with self.assertRaises(FileExistsError):
                media.publish_new(temporary, target)
        self.assertEqual(target.read_bytes(), b'rival created after save panel')
        self.assertEqual(temporary.read_bytes(), b'finished synthetic payload')

    def test_pdf_aggregate_budget_uses_metadata_before_any_page_decode(self):
        source = self.png()
        original = source.read_bytes()
        digest = media.fingerprint(source)
        # 23 metadata-only 24MP pages cross the 500MP export budget. None of
        # these synthetic descriptors may be decoded just to count pixels.
        pages = [media.Page(source, digest, pdf_index=index, point_size=(3000, 2000)) for index in range(23)]
        with patch.object(media, 'page_image', side_effect=AssertionError('Decoded before metadata budget')) as decode, \
             patch.object(media.tempfile, 'mkstemp', side_effect=AssertionError('Created output before metadata budget')) as temporary:
            with self.assertRaisesRegex(ValueError, '5억 화소'):
                media.export_pdf(pages, self.folder / 'too-many-pixels.pdf')
        decode.assert_not_called(); temporary.assert_not_called()
        self.assertEqual(source.read_bytes(), original)

    def test_page_image_cancellation_is_observed_even_for_cached_and_inline_pages(self):
        page = media.load_pages([self.png()])[0]
        inline = media.Page(page.source, page.source_sha256, page.image, point_size=page.point_size,
                            source_identity=page.source_identity)
        with patch.object(media, 'fingerprint', side_effect=AssertionError('Cancelled paint read source')):
            for candidate in (page, inline):
                with self.assertRaises(media.Cancelled):
                    media.page_image(candidate, cancel=lambda: True)

    def test_image_and_pdf_cancel_during_final_validation_never_publish_and_clean_private_temporary(self):
        page = media.load_pages([self.png()])[0]
        original = page.source.read_bytes()
        for format in ('png', 'pdf'):
            target = self.folder / ('cancel-final.' + format)
            calls, cancelled = 0, False
            def validate(pages, cancel=None):
                nonlocal calls, cancelled
                media_validate(pages, cancel)
                calls += 1
                if calls == 2:
                    cancelled = True  # Cancellation arrives as the final SHA finishes.
            media_validate = media.validate_sources
            with patch.object(media, 'validate_sources', side_effect=validate), \
                 patch.object(media, 'publish_new', side_effect=AssertionError('Cancelled result published')) as publish:
                with self.assertRaises(media.Cancelled):
                    if format == 'png':
                        media.export_image(page, target, cancel=lambda: cancelled)
                    else:
                        media.export_pdf([page], target, cancel=lambda: cancelled)
            self.assertEqual(calls, 2)
            publish.assert_not_called()
            self.assertFalse(target.exists())
            self.assertFalse(list(self.folder.glob('.bluraction-*')))
            self.assertEqual(page.source.read_bytes(), original)

    def test_inline_video_page_validation_uses_captured_size_without_image_set_limit(self):
        page = media.load_pages([self.png()])[0]
        metadata = list(page.source_identity.metadata); metadata[3] = 1024 ** 3 + 17
        captured = media.SourceIdentity(page.source_identity.canonical, tuple(metadata))
        inline = media.Page(page.source, page.source_sha256, page.image, source_identity=captured)
        # Synthetic metadata avoids allocating >1GB; this contract test checks
        # the streaming bound, not codec support for a large real video.
        with patch.object(media, '_check_identity'), patch.object(media, 'fingerprint', return_value=page.source_sha256) as digest:
            media.validate_sources([inline])
        self.assertEqual(digest.call_args.kwargs['max_bytes'], 1024 ** 3 + 17)

    def video_validation_source(self, path):
        source = object.__new__(video.VideoSource)
        source.path = path
        source._source_identity = media._capture_identity(path)
        source._identity = video._signature(path)
        source.source_sha256 = media.fingerprint(path)
        return source

    def test_video_validation_propagates_cancellation_and_original_size_bound(self):
        path = self.folder / 'controlled-video-bytes.bin'; path.write_bytes(b'V' * (2 * 1024 ** 2))
        source = self.video_validation_source(path)
        with patch.object(video, 'fingerprint', side_effect=AssertionError('Cancelled video hash opened')):
            with self.assertRaises(media.Cancelled):
                source.validate(cancel=lambda: True)
        cancelled = False
        original_read = os.read
        def read(fd, count):
            nonlocal cancelled
            data = original_read(fd, count); cancelled = True
            return data
        with patch.object(media.os, 'read', side_effect=read) as reads, \
             patch.object(video, 'fingerprint', wraps=media.fingerprint) as digest:
            with self.assertRaises(media.Cancelled):
                source.validate(cancel=lambda: cancelled)
        self.assertEqual(reads.call_count, 1)
        self.assertEqual(digest.call_args.kwargs['max_bytes'], len(path.read_bytes()))
        self.assertIsNotNone(digest.call_args.kwargs['cancel'])

    def test_video_open_cancel_during_initial_hash_never_enters_codec(self):
        path = self.folder / 'cancel-before-codec.bin'; path.write_bytes(b'V' * (2 * 1024 ** 2))
        cancelled = False
        original_read = os.read
        def read(fd, count):
            nonlocal cancelled
            data = original_read(fd, count); cancelled = True
            return data
        with patch.object(media.os, 'read', side_effect=read) as reads, \
             patch.object(video, '_av', side_effect=AssertionError('Cancelled hash entered codec')) as codec:
            with self.assertRaises(media.Cancelled):
                video.VideoSource(path, cancel=lambda: cancelled)
        self.assertEqual(reads.call_count, 1)
        codec.assert_not_called()

    def test_video_page_retains_identity_captured_before_decode(self):
        page = media.load_pages([self.png()])[0]
        source = self.video_validation_source(page.source)
        source._first_image = page.image
        with patch.object(media, '_capture_identity', wraps=media._capture_identity) as captured:
            preview = source.page()
        self.assertEqual(captured.call_count, 1, 'Only the existing cheap guard captures current metadata; Page retains the initial identity')
        self.assertEqual(preview.source_identity, source._source_identity)
        self.assertEqual((preview._image.width(), preview._image.height()), (32, 20))

    def test_video_cancel_at_final_validation_prevents_publication_without_codec_runtime(self):
        # Fake AV objects exercise only export lifecycle/order. Real codec,
        # PTS/audio/rotation proofs remain in the separate video integration tests.
        page = media.load_pages([self.png()])[0]
        source = self.video_validation_source(page.source)
        source._first_image = page.image
        source.stream_index, source.average_rate = 0, Fraction(1)
        source.sample_aspect_ratio, source.metadata = Fraction(1), {}
        source.origin, source.video_end, source.duration = Fraction(0), Fraction(1), 1.0
        cancelled, validations = False, 0
        def validate(cancel=None):
            nonlocal validations, cancelled
            video.VideoSource.validate(source, cancel)
            validations += 1
            if validations == 2:
                cancelled = True
        source.validate = validate
        stream = SimpleNamespace(index=0, type='video', time_base=Fraction(1, 1000), bit_rate=0)
        frame = SimpleNamespace(pts=0, time_base=Fraction(1, 1000), duration=1000)
        packet = SimpleNamespace(stream=stream, decode=lambda: [frame])
        class Streams(list):
            audio = []
        class Input:
            streams = Streams([stream])
            def __enter__(self): return self
            def __exit__(self, *args): return False
            def demux(self, selected): return iter([packet])
        result = SimpleNamespace(codec_context=SimpleNamespace(), set_display_rotation=lambda value: None)
        result.encode = lambda value: [] if value is not None else [SimpleNamespace(pts=0, time_base=Fraction(1, 1000))]
        class Output:
            def __init__(self, path): self.path = path
            def __enter__(self): return self
            def __exit__(self, *args):
                Path(self.path).write_bytes(b'fake encoded lifecycle payload')
                return False
            def add_stream(self, *args, **kwargs): return result
            def start_encoding(self): pass
            def mux(self, packet): pass
        av = SimpleNamespace(open=lambda path, *args, **kwargs: Input() if path == str(source.path) else Output(path),
                             VideoFrame=SimpleNamespace(from_image=lambda image: SimpleNamespace()))
        target = self.folder / 'cancel-final-video.mov'
        with patch.object(video, '_av', return_value=av), \
             patch.object(video, 'encoder_capability', return_value={'registered': True, 'encoder': 'h264_mf'}), \
             patch.object(video, '_display_image', return_value=page.image), \
             patch.object(video, 'publish_new', side_effect=AssertionError('Cancelled video published')) as publish:
            with self.assertRaises(media.Cancelled):
                video.export_video(source, {'regions': [], 'drawings': []}, target, cancel=lambda: cancelled)
        self.assertEqual(validations, 2)
        publish.assert_not_called()
        self.assertFalse(target.exists())
        self.assertFalse(list(self.folder.glob('.bluraction-video-*')))


if __name__ == '__main__':
    unittest.main()
