"""Opt-in frozen candidate diagnostic; never installation or release approval.

Generated fixtures only. An external caller must enforce a process-tree deadline
because an in-process Python deadline cannot interrupt every native codec call.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import multiprocessing
import os
from pathlib import Path
import sys


def _require(condition, code):
    if not condition:
        raise ValueError(code)


def _sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def _fresh_directory(value):
    from shared.windows_package_receipt import canonical, plain
    path = Path(value).absolute()
    parent = plain(path.parent, directory=True)
    canonical(path.name)
    destination = parent / path.name
    destination.mkdir()  # Exclusive: never reuse a caller's media directory.
    return destination


def _dependencies(frozen):
    import PySide6
    from PySide6 import QtPdf
    import PIL
    import numpy
    import av
    import cv2
    import pypdf
    import pillow_heif
    modules = (PySide6, QtPdf, PIL, numpy, av, cv2, pypdf, pillow_heif)
    base = Path(sys._MEIPASS).resolve() if frozen else None
    result = {}
    for module in modules:
        if base is not None:
            _require(Path(module.__file__).resolve().is_relative_to(base), 'dependency_outside_bundle')
        result[module.__name__] = str(getattr(module, '__version__', 'loaded'))[:128]
    _require(cv2.TrackerCSRT_create() is not None, 'tracker_unavailable')
    _require(isinstance(pillow_heif.libheif_info(), dict), 'heif_backend_unavailable')
    if frozen:
        from PySide6.QtCore import QLibraryInfo
        plugins = Path(QLibraryInfo.path(QLibraryInfo.LibraryPath.PluginsPath)).resolve()
        _require(plugins.is_relative_to(base), 'qt_plugins_outside_bundle')
        _require((plugins / 'platforms/qwindows.dll').is_file(), 'windows_plugin_missing')
    return result


def _documents(directory):
    from PySide6.QtCore import QSize
    from PySide6.QtGui import QImage
    from PySide6.QtPdf import QPdfDocument
    from PIL import Image
    from pypdf import PdfWriter
    from pypdf.generic import DecodedStreamObject, NameObject
    from .editor import Workspace
    from .media import export_image, export_pdf
    from .renderer import render
    png, pdf = directory / '원본.png', directory / '원본.pdf'
    Image.new('RGB', (80, 60), 'white').save(png)
    writer = PdfWriter()
    for _ in range(2):
        page = writer.add_blank_page(width=80, height=60)
        content = DecodedStreamObject()
        content.set_data(b'1 1 1 rg 0 0 80 60 re f\n')
        page[NameObject('/Contents')] = writer._add_object(content)
    with pdf.open('xb') as stream:
        writer.write(stream)
    originals = {p.name: _sha(p) for p in (png, pdf)}
    workspace = Workspace()
    workspace.load([png, pdf])
    _require(len(workspace.pages) == 3, 'mixed_page_count')
    def pixels(image):
        _require(not image.isNull(), 'empty_image')
        w, h = image.width(), image.height()
        black, white = image.pixelColor(w // 8, 5 * h // 6), image.pixelColor(7 * w // 8, h // 6)
        _require(max(black.red(), black.green(), black.blue()) < 5 and black.alpha() == 255, 'cover_pixel')
        _require(min(white.red(), white.green(), white.blue()) > 250 and white.alpha() == 255, 'outside_pixel')
    for index in range(3):
        workspace.set_page(index)
        workspace.add_cover('rectangle', [[0, 0], [.5, .5]], 'solid', 0, 0)
        pixels(render(workspace.page.image, workspace.page.state))
    project = directory / '작업.bluraction'
    workspace.save_project(project)
    reopened = Workspace()
    reopened.load_project(project)
    _require(len(reopened.pages) == 3, 'reopened_page_count')
    for original, restored in zip(workspace.pages, reopened.pages):
        _require(original.state == restored.state and original.source_sha256 == restored.source_sha256, 'project_state_drift')
    for index, page in enumerate(reopened.pages):
        target = directory / ('결과-' + str(index + 1) + '.png')
        export_image(page, target)
        image = QImage(str(target))
        _require(image.size() == page.image.size(), 'image_size_drift')
        pixels(image)
    flattened = directory / '결과.pdf'
    export_pdf(reopened.pages, flattened)
    document = QPdfDocument()
    try:
        _require(document.load(str(flattened)) == QPdfDocument.Error.None_, 'pdf_reopen')
        _require(document.pageCount() == 3, 'pdf_output_page_count')
        for index in range(3):
            pixels(document.render(index, QSize(80, 60)))
    finally:
        document.close()
    for name, digest in originals.items():
        _require(_sha(directory / name) == digest, 'source_changed')
    return {'pages': 3, 'projectStateRoundtrip': True, 'outputPixelsChecked': True, 'originalsUnchanged': True}


def _pdf_user_units(directory):
    from PySide6.QtGui import QImage
    from pypdf import PdfReader, PdfWriter
    from pypdf.generic import DecodedStreamObject, FloatObject, NameObject, RectangleObject
    from .editor import Workspace
    from .media import export_image, export_pdf
    checked = 0
    for cropped in (False, True):
        for rotation in (0, 90, 180, 270):
            for unit in (.5, 1, 2):
                stem = f'unit-{unit}-crop-{int(cropped)}-rotate-{rotation}'
                source = directory / (stem + '.pdf')
                writer = PdfWriter()
                page = writer.add_blank_page(300, 200)
                if cropped:
                    page.cropbox = RectangleObject([50, 30, 250, 150])
                page.rotate(rotation)
                page[NameObject('/UserUnit')] = FloatObject(unit)
                content = DecodedStreamObject()
                content.set_data(b'1 1 1 rg 0 0 300 200 re f')
                page[NameObject('/Contents')] = writer._add_object(content)
                with source.open('xb') as stream:
                    writer.write(stream)
                digest = _sha(source)
                expected = [200 if cropped else 300, 120 if cropped else 200]
                if rotation in (90, 270):
                    expected.reverse()
                expected = tuple(value * unit for value in expected)
                workspace = Workspace()
                workspace.load([source])
                _require(workspace.page.point_size == expected, 'pdf_unit_physical_size')
                workspace.add_cover('rectangle', [[.1, .1], [.3, .3]], 'solid', 0, 0)
                project = directory / (stem + '.bluraction')
                workspace.save_project(project)
                reopened = Workspace()
                reopened.load_project(project)
                _require(reopened.page.point_size == expected and reopened.page.state == workspace.page.state,
                         'pdf_unit_project_roundtrip')
                target = directory / (stem + '-output.pdf')
                export_pdf(reopened.pages, target)
                result = PdfReader(target).pages[0]
                actual = (float(result.mediabox.width), float(result.mediabox.height))
                _require(all(abs(a - b) < .01 for a, b in zip(actual, expected)), 'pdf_unit_output_size')
                png = directory / (stem + '.png')
                export_image(reopened.page, png)
                image = QImage(str(png))
                _require((image.width(), image.height()) == tuple(round(value * 2) for value in expected),
                         'pdf_unit_png_size')
                black = image.pixelColor(round(image.width() * .2), round(image.height() * .8))
                _require(max(black.red(), black.green(), black.blue()) < 5 and black.alpha() == 255,
                         'pdf_unit_cover_pixel')
                _require(_sha(source) == digest, 'pdf_unit_source_changed')
                checked += 1
    return {'cases': checked, 'physicalSizesPreserved': True, 'coverPixelsChecked': True,
            'projectStateRoundtrip': True, 'originalsUnchanged': True}


def _pdf_paper(directory):
    from PySide6.QtCore import QSize
    from PySide6.QtGui import QImage
    from PySide6.QtPdf import QPdfDocument
    from pypdf import PdfWriter
    from pypdf.generic import DecodedStreamObject, NameObject
    from .editor import Workspace
    from .media import export_image, export_pdf
    from .renderer import render
    source = directory / 'unpainted-paper.pdf'
    writer = PdfWriter()
    page = writer.add_blank_page(100, 100)
    content = DecodedStreamObject()
    content.set_data(b'0 0 0 rg 10 10 20 20 re f 0 0 1 rg 60 60 20 20 re f')
    page[NameObject('/Contents')] = writer._add_object(content)
    with source.open('xb') as stream:
        writer.write(stream)
    digest = _sha(source)
    def pixels(image, color_tolerance=0):
        _require(image.pixelColor(5, 5).getRgb() == (255, 255, 255, 255), 'pdf_paper_white')
        _require(image.pixelColor(40, 160).getRgb() == (0, 0, 0, 255), 'pdf_paper_black_ink')
        blue = image.pixelColor(140, 60).getRgb()
        _require(blue[3] == 255 and all(abs(a - b) <= color_tolerance
                                      for a, b in zip(blue[:3], (0, 0, 255))), 'pdf_paper_color')
    workspace = Workspace()
    workspace.load([source])
    pixels(workspace.page.image)
    pixels(render(workspace.page.image, workspace.page.state))
    project = directory / 'paper.bluraction'
    workspace.save_project(project)
    reopened = Workspace()
    reopened.load_project(project)
    pixels(reopened.page.image)
    png = directory / 'paper.png'
    export_image(reopened.page, png)
    pixels(QImage(str(png)))
    pdf = directory / 'paper-output.pdf'
    export_pdf(reopened.pages, pdf)
    document = QPdfDocument()
    try:
        _require(document.load(str(pdf)) == QPdfDocument.Error.None_, 'pdf_paper_export_reopen')
        pixels(document.render(0, QSize(200, 200)), color_tolerance=2)
    finally:
        document.close()
    _require(_sha(source) == digest, 'pdf_paper_source_changed')
    return {'whitePaper': True, 'blackInk': True, 'colorPreserved': True,
            'previewExportAndProjectChecked': True, 'originalUnchanged': True}


def _video(directory):
    from fractions import Fraction
    import av
    from PIL import Image
    from .canonical_transport import CanonicalSession
    path = directory / '합성.mov'
    with av.open(str(path), 'w') as output:
        stream = output.add_stream('mpeg4', rate=25)
        stream.width, stream.height, stream.pix_fmt = 96, 64, 'yuv420p'
        stream.time_base = stream.codec_context.time_base = Fraction(1, 25)
        stream.codec_context.sample_aspect_ratio = Fraction(1)
        stream.codec_context.max_b_frames = 0
        for index in range(3):
            frame = av.VideoFrame.from_image(Image.new('RGB', (96, 64), 'white'))
            frame.pts, frame.time_base, frame.duration = index, Fraction(1, 25), 1
            for packet in stream.encode(frame):
                packet.duration = 1
                output.mux(packet)
        for packet in stream.encode(None):
            packet.duration = 1
            output.mux(packet)
    digest = _sha(path)
    session = None
    pid = work = None
    try:
        session = CanonicalSession(path, digest, build_timeout=20, query_timeout=10)
        pid, work = session._process.pid, Path(session._directory.name)
        _require(pid != os.getpid() and session._process.is_alive(), 'spawned_worker_missing')
        _require(session.metadata['sha256'] == digest and session.metadata.get('timeline'), 'decoder_handshake')
        meta, buffers = session.frame(session.first_time)
        _require(meta.get('presence') == 'content' and len(buffers) == 1 and len(buffers[0]) > 0, 'decoded_frame_missing')
        session.validate()
    finally:
        if session is not None:
            session.close()
    _require(pid not in [child.pid for child in multiprocessing.active_children()], 'worker_not_closed')
    _require(work is not None and not work.exists(), 'worker_spool_not_closed')
    _require(_sha(path) == digest, 'video_source_changed')
    return {'productionWorkerHandshake': True, 'decodedFrame': True, 'ownedChildClosed': True,
            'audioVerified': False, 'videoExportVerified': False}


def run(output, *, _allow_source=False):
    """Internal source-test seam does not change observed host/frozen claims."""
    directory = _fresh_directory(output)
    frozen = bool(getattr(sys, 'frozen', False))
    report = {'schemaVersion': 1, 'status': 'fail', 'host': sys.platform, 'actualWindows': sys.platform == 'win32', 'frozen': frozen,
              'syntheticOnly': True, 'frozenExecutionVerified': False,
              'installerVerified': False, 'userAcceptanceVerified': False,
              'redistributionApproved': False, 'checks': {},
              'limits': ['Offscreen only; no Explorer, dialogs or ordinary Windows GUI verification.',
                         'Synthetic PDF/image and decoder smoke only; not complete format, audio or export coverage.']}
    stage = 'runtime'
    previous = os.environ.get('QT_QPA_PLATFORM')
    app = None
    try:
        _require(_allow_source or (sys.platform == 'win32' and frozen), 'actual_frozen_windows_required')
        stage = 'dependencies'
        report['checks'][stage] = _dependencies(frozen)
        os.environ['QT_QPA_PLATFORM'] = 'offscreen'
        from PySide6.QtWidgets import QApplication
        _require(QApplication.instance() is None, 'diagnostic_requires_fresh_process')
        app = QApplication(['BlurAction-candidate-smoke'])
        stage = 'documents'
        report['checks'][stage] = _documents(directory)
        stage = 'pdf-user-units'
        report['checks'][stage] = _pdf_user_units(directory)
        stage = 'pdf-paper'
        report['checks'][stage] = _pdf_paper(directory)
        stage = 'production-decoder'
        report['checks'][stage] = _video(directory)
        report['files'] = [{'path': p.name, 'bytes': p.stat().st_size, 'sha256': _sha(p)}
                           for p in sorted(directory.iterdir()) if p.is_file()]
        report['status'] = 'pass'
        report['frozenExecutionVerified'] = sys.platform == 'win32' and frozen
    except Exception as error:
        # Codec exceptions can contain local filenames. Record bounded class and
        # stage only; never echo arbitrary exception text or a native traceback.
        report['failure'] = {'stage': stage, 'type': type(error).__name__[:80]}
    finally:
        if app is not None:
            app.quit()
        if previous is None:
            os.environ.pop('QT_QPA_PLATFORM', None)
        else:
            os.environ['QT_QPA_PLATFORM'] = previous
    payload = (json.dumps(report, ensure_ascii=True, indent=2) + '\n').encode('ascii')
    _require(len(payload) <= 65536, 'bounded_report_required')
    with (directory / 'report.json').open('xb') as stream:
        stream.write(payload)
    return 0 if report['status'] == 'pass' else 1


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--auto-find-only', action='store_true')
    parser.add_argument('--face-fixture', type=Path)
    parser.add_argument('--video-fixtures', type=Path)
    parser.add_argument('--performance-fixture', type=Path)
    args = parser.parse_args(argv)
    try:
        if args.performance_fixture:
            os.environ['QT_QPA_PLATFORM'] = 'offscreen'
            from .performance_smoke import run as run_performance
            return run_performance(args.output,args.performance_fixture)
        if args.video_fixtures:
            os.environ['QT_QPA_PLATFORM'] = 'offscreen'
            from .video_compat_smoke import run as run_video_compat
            return run_video_compat(args.output,args.video_fixtures)
        if args.auto_find_only:
            os.environ['QT_QPA_PLATFORM'] = 'offscreen'
            from .auto_find_smoke import run as run_auto_find
            return run_auto_find(args.output, face_fixture=args.face_fixture)
        return run(args.output)
    except Exception:
        # Invalid output arguments must not overwrite an existing report and a
        # windowed executable need not have a functioning stderr stream.
        return 2
