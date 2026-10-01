"""Local decoding, source identity and non-overwriting flattened exports."""
from __future__ import annotations

from dataclasses import dataclass
from collections import OrderedDict
import hashlib
import math
import os
from pathlib import Path
import stat
import tempfile
import threading

from PySide6.QtCore import QMarginsF, QSize
from PySide6.QtGui import QImage, QImageIOHandler, QImageReader, QImageWriter, QPainter, QPageLayout, QPageSize, QPdfWriter
from PySide6.QtPdf import QPdfDocument, QPdfDocumentRenderOptions

from shared.portable_project import validate_output_path, windows_reserved_name

from .renderer import render


class Cancelled(Exception):
    pass


class IncompleteOutputError(OSError):
    """A fallback copy started; its public path must be reviewed, never unlinked."""
    def __init__(self, path):
        self.partial_output = Path(path)
        super().__init__(f'출력 복사가 완료되지 않았습니다. 미완료 출력 파일을 확인하세요: {self.partial_output}')


def check_cancel(cancel):
    if cancel and cancel():
        raise Cancelled('작업을 취소했습니다.')


MAX_SOURCE_BYTES = 1024 ** 3


@dataclass(frozen=True)
class SourceIdentity:
    canonical: str
    metadata: tuple


def _metadata(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def _capture_identity(path):
    """Cheap metadata/canonical guard, never media decoding or content hashing."""
    path = Path(path).absolute()
    try:
        before = path.lstat()
        if not stat.S_ISREG(before.st_mode):
            raise ValueError('읽을 수 있는 일반 원본 파일을 선택하세요.')
        canonical = path.resolve(strict=True)
        resolved = canonical.stat()
        after = path.lstat()
        if (_metadata(before) != _metadata(resolved) or _metadata(before) != _metadata(after)
                or path.resolve(strict=True) != canonical):
            raise ValueError('원본 경로가 확인 중 변경되었습니다.')
        return SourceIdentity(str(canonical), _metadata(before))
    except OSError as error:
        raise ValueError('읽을 수 있는 일반 원본 파일을 선택하세요.') from error


def _check_identity(path, expected):
    if _capture_identity(path) != expected:
        raise ValueError('원본 파일 또는 경로가 변경되었습니다. 가림 위치를 다시 확인하세요.')


def fingerprint(path, max_bytes=MAX_SOURCE_BYTES, cancel=None):
    """Bounded, cancellable SHA with descriptor/current-path identity checks."""
    if type(max_bytes) is not int or max_bytes <= 0:
        raise ValueError('원본 읽기 한도는 양의 정수여야 합니다.')
    path = Path(path).absolute()
    check_cancel(cancel)
    expected = _capture_identity(path)
    if not expected.metadata[3]:
        raise ValueError('원본 파일이 비어 있습니다.')
    if expected.metadata[3] > max_bytes:
        raise ValueError('원본 파일이 읽기 용량 한도를 넘습니다.')
    check_cancel(cancel)
    flags = os.O_RDONLY | getattr(os, 'O_BINARY', 0) | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_NONBLOCK', 0)
    fd = os.open(path, flags)
    try:
        opened = os.fstat(fd)
        if not stat.S_ISREG(opened.st_mode) or _metadata(opened) != expected.metadata:
            raise ValueError('원본 파일이 열리는 동안 변경되었습니다.')
        _check_identity(path, expected)
        digest, count = hashlib.sha256(), 0
        while True:
            check_cancel(cancel)
            chunk = os.read(fd, min(1024 * 1024, max_bytes - count + 1))
            check_cancel(cancel)
            count += len(chunk)
            if count > max_bytes:
                raise ValueError('원본 파일이 읽기 용량 한도를 넘습니다.')
            if _metadata(os.fstat(fd)) != expected.metadata:
                raise ValueError('원본이 읽는 동안 변경되었습니다.')
            _check_identity(path, expected)
            if not chunk:
                break
            digest.update(chunk)
        if count != opened.st_size:
            raise ValueError('원본 파일의 전체 크기를 읽지 못했습니다.')
        check_cancel(cancel)
        return digest.hexdigest()
    finally:
        os.close(fd)


@dataclass(init=False)
class Page:
    source: Path
    source_sha256: str
    _image: QImage | None
    pdf_index: int | None = None
    point_size: tuple[float, float] | None = None
    state: dict
    source_identity: SourceIdentity

    def __init__(self, source, source_sha256, image=None, pdf_index=None, point_size=None, state=None, *, source_identity=None):
        self.source, self.source_sha256 = Path(source), source_sha256
        self.source_identity = source_identity if source_identity is not None else _capture_identity(self.source)
        self._image, self.pdf_index, self.point_size = image, pdf_index, point_size
        self.state = state if state is not None else {'regions': [], 'drawings': []}

    @property
    def image(self):
        return page_image(self)

    @image.setter
    def image(self, value):
        self._image = value


# Pages keep metadata, not hundreds of full decoded buffers. Limit the shared
# read-only image cache to 48MP (one 24MP page plus a neighboring page).
_image_cache = OrderedDict()
_cache_guard = threading.RLock()


def page_image(page, cancel=None):
    check_cancel(cancel)
    _check_identity(page.source, page.source_identity)
    if page._image is not None:
        check_cancel(cancel)
        return page._image
    key = (str(page.source), page.source_sha256, page.pdf_index, page.source_identity)
    with _cache_guard:
        if key in _image_cache:
            _image_cache.move_to_end(key)
            check_cancel(cancel)
            return _image_cache[key]
    if fingerprint(page.source, cancel=cancel) != page.source_sha256:
        raise ValueError('원본 파일이 변경되었습니다. 다시 열고 가림 위치를 확인하세요.')
    if page.pdf_index is not None:
        document = QPdfDocument()
        if document.load(str(page.source)) != QPdfDocument.Error.None_:
            raise ValueError('PDF를 열 수 없습니다.')
        size = document.pagePointSize(page.pdf_index)
        dimensions = QSize(round(size.width() * 2), round(size.height() * 2))
        if dimensions.width() <= 0 or dimensions.height() <= 0 or dimensions.width() * dimensions.height() > 24_000_000:
            document.close()
            raise ValueError('PDF 페이지 해상도가 너무 큽니다.')
        options = QPdfDocumentRenderOptions()
        options.setRenderFlags(QPdfDocumentRenderOptions.RenderFlag.Annotations)
        check_cancel(cancel)
        image = document.render(page.pdf_index, dimensions, options)
        document.close()
    elif page.source.suffix.lower() in {'.heic', '.heif'}:
        from .heif_codec import read_heif
        image = read_heif(page.source)
    else:
        reader = QImageReader(str(page.source))
        reader.setAutoTransform(True)
        image = reader.read()
    if image.isNull():
        raise ValueError('원본 페이지를 렌더링할 수 없습니다.')
    if image.width() * image.height() > 24_000_000:
        raise ValueError('페이지 렌더링 한도는 24MP입니다.')
    check_cancel(cancel)
    _check_identity(page.source, page.source_identity)
    if fingerprint(page.source, cancel=cancel) != page.source_sha256:
        raise ValueError('원본이 렌더링 중 변경되었습니다.')
    _check_identity(page.source, page.source_identity)
    check_cancel(cancel)
    with _cache_guard:
        _image_cache[key] = image
        while sum(value.width() * value.height() for value in _image_cache.values()) > 48_000_000:
            _image_cache.popitem(last=False)
    return image


def load_pages(paths, cancel=None):
    if not paths:
        raise ValueError('파일을 선택하세요.')
    if len(paths) > 200:
        raise ValueError('PDF와 이미지 전체는 최대 200페이지입니다.')
    total_bytes = 0
    identities = set()
    inputs = []
    pages = []
    for value in paths:
        check_cancel(cancel)
        source = Path(value).absolute()
        captured = _capture_identity(source)
        file_bytes = captured.metadata[3]
        limit = 512 * 1024 ** 2 if source.suffix.lower() == '.pdf' else 128 * 1024 ** 2
        if file_bytes > limit:
            raise ValueError('PDF 한 파일은 512MB 이하로 선택하세요.' if source.suffix.lower() == '.pdf'
                             else '이미지 한 파일은 128MB 이하로 선택하세요.')
        identity = captured.canonical
        if identity not in identities:
            identities.add(identity)
            total_bytes += file_bytes
        if total_bytes > MAX_SOURCE_BYTES:
            raise ValueError('전체 입력은 1GB 이하로 선택하세요.')
        inputs.append((source, captured, limit))
    # Reject an oversized input set before reading any content or decoding it.
    for source, captured, limit in inputs:
        check_cancel(cancel)
        digest = fingerprint(source, max_bytes=limit, cancel=cancel)
        _check_identity(source, captured)
        if source.suffix.lower() == '.pdf':
            document = QPdfDocument()
            error = document.load(str(source))
            if error != QPdfDocument.Error.None_:
                raise ValueError(f'PDF를 열 수 없습니다: {error.name}')
            if document.pageCount() < 1 or len(pages) + document.pageCount() > 200:
                raise ValueError('PDF와 이미지 전체는 최대 200페이지입니다.')
            for index in range(document.pageCount()):
                check_cancel(cancel)
                size = document.pagePointSize(index)
                # PDFium applies the effective crop/rotation. Work at 144dpi.
                pixels = QSize(round(size.width() * 2), round(size.height() * 2))
                if pixels.width() * pixels.height() > 24_000_000:
                    raise ValueError('PDF 페이지 해상도가 너무 큽니다.')
                pages.append(Page(source, digest, None, index, (size.width(), size.height()), source_identity=captured))
            document.close()
        else:
            if len(pages) >= 200:
                raise ValueError('PDF와 이미지 전체는 최대 200페이지입니다.')
            if source.suffix.lower() in {'.heic', '.heif'}:
                from .heif_codec import inspect_heif
                size = QSize(*inspect_heif(source).size)
            else:
                reader = QImageReader(str(source))
                reader.setAutoTransform(True)
                size = reader.size()
                if reader.transformation() & QImageIOHandler.Transformation.TransformationRotate90:
                    size = size.transposed()
                if not reader.canRead():
                    raise ValueError(f'이미지를 열 수 없습니다: {reader.errorString()}')
            if size.width() * size.height() > 24_000_000:
                raise ValueError('이미지 해상도가 너무 큽니다.')
            pages.append(Page(source, digest, None, point_size=(size.width() / 2, size.height() / 2), source_identity=captured))
    # Detect changes during decoding as well as during hashing.
    validate_sources(pages, cancel)
    if pages:
        _ = page_image(pages[0], cancel)  # Do not commit a workspace that cannot show its first page.
    check_cancel(cancel)
    return pages


def validate_sources(pages, cancel=None):
    checked = {}
    for page in pages:
        check_cancel(cancel)
        _check_identity(page.source, page.source_identity)
        digest = checked.setdefault(page.source, page.source_sha256)
        if digest != page.source_sha256:
            raise ValueError('같은 원본의 지문이 서로 다릅니다.')
    for source, expected in checked.items():
        # Sources loaded as PDF/images have already passed their input limits.
        # An inline video preview Page may refer to a larger video: bound its
        # read to the captured size without imposing the image-set 1GB policy.
        captured_size = next(page.source_identity.metadata[3] for page in pages if page.source == source)
        if fingerprint(source, max_bytes=captured_size, cancel=cancel) != expected:
            raise ValueError('원본 파일이 변경되었습니다. 가림 위치를 다시 확인하세요.')
        check_cancel(cancel)
    for page in pages:
        _check_identity(page.source, page.source_identity)
    check_cancel(cancel)


def validate_source_identities(pages):
    """Cheap GUI commit guard after a worker's complete fingerprint checks."""
    for page in pages:
        _check_identity(page.source, page.source_identity)


def fresh_target(path):
    validate_output_path(path, platform='windows')
    path = Path(path).absolute()
    if path.exists() or path.is_symlink():
        raise FileExistsError('기존 파일을 덮어쓰지 않습니다. 새 이름을 선택하세요.')
    if not path.parent.is_dir():
        raise ValueError('저장 폴더가 없습니다.')
    return path


def publish_new(temporary, destination):
    """Exclusive creation protects against a collision after the save panel."""
    temporary, destination = Path(temporary), fresh_target(destination)
    try:
        os.link(temporary, destination)
    except FileExistsError:
        raise
    except OSError:
        created = False
        try:
            with destination.open('xb') as out:
                created = True
                with temporary.open('rb') as src:
                    for data in iter(lambda: src.read(1024 * 1024), b''):
                        out.write(data)
                    out.flush()
                    os.fsync(out.fileno())
        except BaseException as error:
            # Even an lstat/dev/inode comparison cannot make a subsequent
            # public-path unlink atomic. A rival may replace it between those
            # operations. Leave the path intact and report the incomplete copy.
            if created:
                raise IncompleteOutputError(destination) from error
            raise


def save_bytes_new(path, data, cancel=None):
    check_cancel(cancel)
    target = fresh_target(path)
    fd, name = tempfile.mkstemp(prefix='.bluraction-', suffix='.tmp', dir=target.parent)
    try:
        with os.fdopen(fd, 'wb') as out:
            for offset in range(0, len(data), 1024 * 1024):
                check_cancel(cancel)
                out.write(data[offset:offset + 1024 * 1024])
            out.flush()
            os.fsync(out.fileno())
        check_cancel(cancel)
        publish_new(name, target)
    finally:
        Path(name).unlink(missing_ok=True)


def export_image(page, path, format='png', quality=95, cancel=None):
    validate_sources([page], cancel)
    target = fresh_target(path)
    check_cancel(cancel)
    image = render(page_image(page, cancel), page.state)
    check_cancel(cancel)
    fd, name = tempfile.mkstemp(prefix='.bluraction-', suffix='.' + format.lower(), dir=target.parent)
    os.close(fd)
    try:
        if format.lower() in {'heic', 'heif'}:
            from .heif_codec import encode_heic
            payload = encode_heic(image, quality)
            check_cancel(cancel)
            with open(name, 'wb') as output:
                output.write(payload)
                output.flush()
                os.fsync(output.fileno())
        else:
            writer = QImageWriter(name, format.encode('ascii'))
            writer.setQuality(quality)
            if not writer.write(image):
                raise ValueError('이미지 저장 실패: ' + writer.errorString())
        validate_sources([page], cancel)
        check_cancel(cancel)
        publish_new(name, target)
    finally:
        Path(name).unlink(missing_ok=True)


def export_pdf(pages, path, cancel=None, progress=None):
    validate_sources(pages, cancel)
    target = fresh_target(path)
    # Metadata preflight must not decode every page merely to count pixels.
    sizes = [_page_point_size(page) for page in pages]
    if sum(round(width * 2) * round(height * 2) for width, height in sizes) > 500_000_000:
        raise ValueError('PDF 출력은 전체 5억 화소 이하로 나누어 저장하세요.')
    fd, name = tempfile.mkstemp(prefix='.bluraction-', suffix='.pdf', dir=target.parent)
    os.close(fd)
    painter = None
    try:
        writer = QPdfWriter(name)
        writer.setResolution(144)
        writer.setTitle('BlurAction 평탄화 결과')
        for index, page in enumerate(pages):
            check_cancel(cancel)
            size = sizes[index]
            from PySide6.QtCore import QSizeF
            writer.setPageSize(QPageSize(QSizeF(*size), QPageSize.Unit.Point))
            writer.setPageMargins(QMarginsF(), QPageLayout.Unit.Point)
            if painter is None:
                painter = QPainter(writer)
                if not painter.isActive():
                    raise ValueError('PDF 저장을 시작할 수 없습니다.')
            elif not writer.newPage():
                raise ValueError('PDF 페이지 저장에 실패했습니다.')
            image = page_image(page, cancel)
            check_cancel(cancel)
            painter.drawImage(QRectFForWriter(writer), render(image, page.state))
            if progress:
                progress((index + 1) / len(pages))
        if painter:
            painter.end()
            painter = None
        validate_sources(pages, cancel)
        check_cancel(cancel)
        publish_new(name, target)
    finally:
        if painter:
            painter.end()
        Path(name).unlink(missing_ok=True)


def _page_point_size(page):
    size = page.point_size
    if size is None and page._image is not None:
        size = (page._image.width() / 2, page._image.height() / 2)
    if size is None or len(size) != 2 or not all(isinstance(value, (int, float)) and not isinstance(value, bool)
                                               and math.isfinite(value) and value > 0 for value in size):
        raise ValueError('페이지 크기 정보가 올바르지 않습니다. 원본을 다시 여세요.')
    return size


def QRectFForWriter(writer):
    from PySide6.QtCore import QRectF
    return QRectF(0, 0, writer.width(), writer.height())


def safe_stem(stem, suffix='', byte_limit=240):
    cleaned = ''.join('_' if c in '<>:"/\\|?*' or ord(c) < 32 else c for c in stem).rstrip(' .') or 'BlurAction'
    if windows_reserved_name(cleaned):
        cleaned = '_' + cleaned
    while len((cleaned + suffix).encode('utf-8')) > byte_limit:
        cleaned = cleaned[:-1]
    return cleaned + suffix


def export_documents(pages, path, cancel=None, progress=None):
    """PDF plus per-image PNGs. Completed outputs survive a later cancellation.

    This matches the existing Mac contract: a completed PDF is not rolled back
    if the subsequent image-folder phase is cancelled.
    """
    target = fresh_target(path)
    images = [page for page in pages if page.pdf_index is None]
    folder = target.parent / safe_stem(target.stem, '_images')
    if images and (folder.exists() or folder.is_symlink()):
        raise FileExistsError('이미지 결과 폴더가 이미 있습니다. 다른 PDF 이름을 선택하세요.')
    validate_sources(pages, cancel)
    outputs = []
    try:
        export_pdf(pages, target, cancel, (lambda p: progress(p * .7)) if progress else None)
        outputs.append(target)
        if images:
            check_cancel(cancel)
            folder.mkdir()  # Exclusive creation, including a rival after the panel.
            try:
                for index, page in enumerate(images):
                    check_cancel(cancel)
                    name = safe_stem(f'{index + 1:03d}_{page.source.stem}', '.png')
                    image_target = folder / name
                    export_image(page, image_target, cancel=cancel)
                    outputs.append(image_target)
                    if progress:
                        progress(.7 + .3 * (index + 1) / len(images))
            finally:
                if not any(folder.iterdir()):
                    folder.rmdir()
    except Exception as error:
        error.completed_outputs = list(outputs)
        raise
    return outputs
