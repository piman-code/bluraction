"""Fail-closed legacy PDF coordinates, using optional pypdf 6.19.0 metadata.

No content stream parsing, rendering, or geometry migration is performed here.
Qt's actual displayed point sizes are supplied by the caller, never inferred.
The legacy predicate matches PageWorkspace.legacyPDFEditGeometryChanged (Mac).

Backend references:
https://pypdf.readthedocs.io/en/6.19.0/modules/PageObject.html
https://pypdf.readthedocs.io/en/6.19.0/modules/PdfReader.html
"""
from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal
import importlib
import math
import os
from pathlib import Path

MAX_PDF_BYTES = 512 * 1024 ** 2
MAX_PAGES = 200
MAX_TREE_NODES = 1000
MAX_TREE_DEPTH = 32
EPSILON = 0.000001


class PDFGeometryError(ValueError):
    pass


class PDFGeometryDependencyError(PDFGeometryError):
    pass


def _number(value, label):
    if isinstance(value, bool) or not isinstance(value, (int, float, Decimal)):
        raise PDFGeometryError(f'PDF {label} 값이 숫자가 아닙니다.')
    try:
        number = float(value)
    except (OverflowError, ValueError) as error:
        raise PDFGeometryError(f'PDF {label} 값이 올바르지 않습니다.') from error
    if not math.isfinite(number) or abs(number) > 1_000_000:
        raise PDFGeometryError(f'PDF {label} 값이 유한 기하 한도를 넘습니다.')
    return number


def _box(value, label):
    if not isinstance(value, (list, tuple)) or len(value) != 4:
        raise PDFGeometryError(f'PDF {label}는 좌표 네 개여야 합니다.')
    result = tuple(_number(item, label) for item in value)
    if result[2] <= result[0] or result[3] <= result[1]:
        raise PDFGeometryError(f'PDF {label} 크기가 올바르지 않습니다.')
    return result


@dataclass(frozen=True)
class PDFPageGeometry:
    media_box: tuple[float, float, float, float]
    crop_box: tuple[float, float, float, float]
    rotation: int
    user_unit: float
    displayed_point_size: tuple[float, float]
    legacy_edits_need_review: bool


def analyze_geometry(media_box, crop_box, rotation, user_unit, qt_point_size):
    """Pure numeric policy, not a PDF parser or substitute for backend readback."""
    media = _box(media_box, 'MediaBox')
    crop = _box(crop_box, 'CropBox')
    if (crop[0] < media[0] - EPSILON or crop[1] < media[1] - EPSILON
            or crop[2] > media[2] + EPSILON or crop[3] > media[3] + EPSILON):
        raise PDFGeometryError('CropBox가 MediaBox 밖에 있어 표시 기하를 확정할 수 없습니다.')
    if isinstance(rotation, bool) or not isinstance(rotation, int) or rotation % 90:
        raise PDFGeometryError('PDF 회전은 정수 90도 단위여야 합니다.')
    if abs(rotation) > 360_000:
        raise PDFGeometryError('PDF 회전 값이 한도를 넘습니다.')
    rotation %= 360
    unit = _number(user_unit, 'UserUnit')
    # PDFKit/UserUnit behavior has not been cross-verified. Do not claim ordinary
    # legacy coordinates are safe by assuming both engines scale them identically.
    if unit != 1:
        raise PDFGeometryError('UserUnit이 1이 아닌 PDF의 이전 편집 좌표는 직접 검토해야 합니다.')
    if not isinstance(qt_point_size, (tuple, list)) or len(qt_point_size) != 2:
        raise PDFGeometryError('Qt의 실제 PDF 표시 크기가 필요합니다.')
    qt_size = tuple(_number(value, 'Qt 표시 크기') for value in qt_point_size)
    if any(value <= 0 for value in qt_size):
        raise PDFGeometryError('Qt PDF 표시 크기가 비어 있습니다.')
    width, height = crop[2] - crop[0], crop[3] - crop[1]
    display = (height, width) if rotation in (90, 270) else (width, height)
    # Qt/PDFium can round point sizes; this is a backend consistency check,
    # separate from Mac's exact 1e-6 legacy-change predicate below.
    if any(not math.isclose(actual, expected, rel_tol=1e-7, abs_tol=1e-4)
           for actual, expected in zip(qt_size, display)):
        raise PDFGeometryError('Qt 표시 크기와 PDF 원시 crop·회전 기하가 일치하지 않습니다.')
    review = (abs(crop[0]) > EPSILON or abs(crop[1]) > EPSILON
              or abs(width - display[0]) > EPSILON or abs(height - display[1]) > EPSILON)
    return PDFPageGeometry(media, crop, rotation, unit, display, review)


def _backend():
    try:
        backend = importlib.import_module('pypdf')
    except ImportError as error:
        raise PDFGeometryDependencyError('이전 PDF 좌표 검증에는 승인된 pypdf 6.19.0 설치가 필요합니다.') from error
    if getattr(backend, '__version__', None) != '6.19.0':
        raise PDFGeometryDependencyError('PDF 좌표 검증은 검토된 pypdf 6.19.0 버전이 필요합니다.')
    return backend


def _raw_pages(reader, generic, cancel_check):
    """Bound the page tree before PdfReader.pages can flatten an unbounded tree.

    Dictionary/array/indirect objects are exclusively decoded by pypdf. This
    walker only applies page-tree inheritance; it does not parse PDF bytes.
    UserUnit is page-local, unlike MediaBox/CropBox/Rotate.
    """
    root = reader.root_object
    stack = [(root.get('/Pages'), {}, 0)]
    leaves, seen, nodes = [], set(), 0
    while stack:
        cancel_check()
        item, inherited, depth = stack.pop()
        nodes += 1
        if nodes > MAX_TREE_NODES:
            raise PDFGeometryError('PDF 페이지 트리 노드 한도를 넘습니다.')
        if isinstance(item, generic.IndirectObject):
            key = ('indirect', item.idnum, item.generation)
            if key in seen:
                raise PDFGeometryError('PDF 페이지 트리가 순환하거나 페이지를 중복 참조합니다.')
            seen.add(key)
            item = item.get_object()
        key = ('object', id(item))
        if key in seen or len(seen) > MAX_TREE_NODES * 2 or depth > MAX_TREE_DEPTH:
            raise PDFGeometryError('PDF 페이지 트리 한도 또는 순환 검사를 통과하지 못했습니다.')
        seen.add(key)
        if not isinstance(item, generic.DictionaryObject) or isinstance(item, generic.StreamObject):
            raise PDFGeometryError('PDF 페이지 트리가 올바른 사전이 아닙니다.')
        values = dict(inherited)
        for field in ('/MediaBox', '/CropBox', '/Rotate'):
            if field in item:
                values[field] = item[field]
        kind = item.get('/Type')
        if kind == '/Pages':
            count = item.get('/Count')
            if isinstance(count, bool) or not isinstance(count, int) or not 1 <= count <= MAX_PAGES:
                raise PDFGeometryError('PDF 페이지 수가 1–200 범위를 벗어납니다.')
            children = item.get('/Kids')
            if isinstance(children, generic.IndirectObject):
                children = children.get_object()
            if not isinstance(children, generic.ArrayObject) or not 1 <= len(children) <= MAX_PAGES:
                raise PDFGeometryError('PDF 페이지 자식 목록이 올바르지 않습니다.')
            stack.extend((child, values, depth + 1) for child in reversed(children))
        elif kind == '/Page':
            leaves.append((item, values))
            if len(leaves) > MAX_PAGES:
                raise PDFGeometryError('PDF 전체 페이지 수는 200 이하이어야 합니다.')
        else:
            raise PDFGeometryError('PDF 페이지 노드 종류를 확정할 수 없습니다.')
    if not leaves or len(leaves) != root['/Pages'].get_object().get('/Count'):
        raise PDFGeometryError('PDF 페이지 수와 원시 트리가 일치하지 않습니다.')
    return leaves


class _BoundedReader:
    """Bound seek/read IO and observe cancellation, without claiming a total
    pypdf decompression/CPU memory limit. Production UI must run this off-thread.
    """
    def __init__(self, stream, size, cancel_check):
        self.stream, self.size, self.cancel_check = stream, size, cancel_check
        self.remaining = size * 4 + 1024 ** 2

    def read(self, size=-1):
        self.cancel_check()
        available = self.size - self.tell()
        size = available if size < 0 else min(size, available)
        if size > self.remaining:
            raise PDFGeometryError('PDF 메타데이터 읽기 작업 한도를 넘습니다.')
        data = self.stream.read(size)
        self.remaining -= len(data)
        self.cancel_check()
        return data

    def seek(self, offset, whence=0):
        self.cancel_check()
        target = offset if whence == 0 else self.tell() + offset if whence == 1 else self.size + offset if whence == 2 else -1
        if not 0 <= target <= self.size:
            raise PDFGeometryError('PDF 메타데이터 읽기가 파일 범위를 벗어났습니다.')
        return self.stream.seek(target)

    def tell(self):
        return self.stream.tell()

    def readline(self, size=-1):
        self.cancel_check()
        available = self.size - self.tell()
        limit = available if size < 0 else min(size, available)
        if limit > self.remaining:
            raise PDFGeometryError('PDF 메타데이터 줄 읽기 작업 한도를 넘습니다.')
        data = self.stream.readline(limit)
        self.remaining -= len(data)
        self.cancel_check()
        return data


def inspect_pdf_geometry(path, qt_point_sizes, *, expected_identity=None, expected_sha256=None, cancel=None):
    """Inspect all raw pages and cross-check caller-supplied actual Qt sizes.

    Parent should pass the load baseline identity AND SHA and reject an affected
    legacy edited page before replacing its operating Workspace. New projects
    marked pdfGeometryVersion=1 never need a legacy policy decision. Return
    metadata only; this function never changes a PDF, project, or editor.
    """
    from .media import _capture_identity, _check_identity, check_cancel, fingerprint
    from shared.source_identity import stat_snapshot, same_domain, path_matches_descriptor
    path = Path(path).absolute()
    check = lambda: check_cancel(cancel)
    check()
    if not isinstance(qt_point_sizes, (list, tuple)) or not 1 <= len(qt_point_sizes) <= MAX_PAGES:
        raise PDFGeometryError('실제 Qt PDF 페이지 크기 1–200개가 필요합니다.')
    before = _capture_identity(path)
    if expected_identity is not None and before != expected_identity:
        raise PDFGeometryError('PDF 원본 identity가 로드 기준과 다릅니다.')
    size = before.metadata[3]
    if not 0 < size <= MAX_PDF_BYTES:
        raise PDFGeometryError('PDF 원본은 비어 있지 않은 512MB 이하 파일이어야 합니다.')
    backend = _backend()
    generic = importlib.import_module('pypdf.generic')
    digest = fingerprint(path, max_bytes=size, cancel=cancel)
    if expected_sha256 is not None and digest != expected_sha256:
        raise PDFGeometryError('PDF 원본 지문이 로드 기준과 다릅니다.')
    flags = os.O_RDONLY | getattr(os, 'O_BINARY', 0) | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_NONBLOCK', 0)
    descriptor = os.open(path, flags)
    result = []
    try:
        with os.fdopen(descriptor, 'rb') as stream:
            descriptor_baseline = stat_snapshot(os.fstat(stream.fileno()), domain='descriptor')
            if not path_matches_descriptor(before.stat_snapshot, descriptor_baseline):
                raise PDFGeometryError('PDF 원본이 열리는 동안 변경되었습니다.')
            _check_identity(path, before)
            reader = backend.PdfReader(_BoundedReader(stream, size, check), strict=True, root_object_recovery_limit=1000)
            if reader.is_encrypted:
                raise PDFGeometryError('암호화된 PDF의 이전 편집 기하는 자동 검증하지 않습니다.')
            pages = _raw_pages(reader, generic, check)
            if len(pages) != len(qt_point_sizes):
                raise PDFGeometryError('Qt와 원시 PDF 페이지 수가 다릅니다.')
            for (page, inherited), qt_size in zip(pages, qt_point_sizes):
                check()
                media = inherited.get('/MediaBox')
                crop = inherited.get('/CropBox', media)
                result.append(analyze_geometry(media, crop, inherited.get('/Rotate', 0), page.get('/UserUnit', 1), qt_size))
            descriptor_current = stat_snapshot(os.fstat(stream.fileno()), domain='descriptor')
            if (not same_domain(descriptor_baseline, descriptor_current)
                    or not path_matches_descriptor(before.stat_snapshot, descriptor_current)):
                raise PDFGeometryError('PDF 원본이 메타데이터 검증 중 변경되었습니다.')
    except PDFGeometryError:
        raise
    except Exception as error:
        from .media import Cancelled
        if isinstance(error, Cancelled):
            raise
        raise PDFGeometryError('PDF 원시 메타데이터가 손상되었거나 기하를 확정할 수 없습니다.') from error
    _check_identity(path, before)
    if fingerprint(path, max_bytes=size, cancel=cancel) != digest:
        raise PDFGeometryError('PDF 원본이 기하 검증 중 변경되었습니다.')
    _check_identity(path, before)
    check()
    return tuple(result)
