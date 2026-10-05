"""Optional HEIC/HEIF SDR adapter; installing/importing is never automatic.

Public boundary: inspect_heif(path), read_heif(path), encode_heic(QImage, quality,
alpha_policy='preserve')->bytes. The media controller owns source fingerprints,
cancellation, temporary files and no-replace publication. Fresh output contains
only rendered pixels and a newly generated sRGB profile, never source metadata.

The primary image is decoded lazily after the size preflight. libheif already
applies HEIF crop/rotation/mirroring; to_pillow resets EXIF orientation. Do not
apply ImageOps.exif_transpose or original_orientation again. PQ/HLG needs a
verified Mac-compatible SDR tone map and is explicitly unfinished, not removed
from the final support contract. Eight-bit conversion alone is not tone mapping.

Primary API/source references (checked 2026-10-02):
https://pillow-heif.readthedocs.io/en/stable/heif-file.html
https://pillow-heif.readthedocs.io/en/stable/_modules/pillow_heif/heif.html
https://pillow-heif.readthedocs.io/en/stable/_modules/pillow_heif/misc.html
https://github.com/bigcat88/pillow_heif/blob/master/CHANGELOG.md
https://doc.qt.io/qt-6/qcolorspace.html
Alpha identifiers: https://aomedia.googlesource.com/libavif/+/refs/heads/main/include/avif/internal.h

Mac BlurredImageExporter.swift renders fresh pixels with quality/orientation1;
it does not explicitly composite white. Preserve alpha by default, sanitize RGB
under fully transparent pixels, and offer white flattening only explicitly.
Actual Mac transparent-HEIC comparison and Windows codec/encoder tests remain
required. Python source licensing does not approve bundled libheif/x265 DLLs.
"""
from __future__ import annotations

from dataclasses import dataclass
import importlib
from io import BytesIO
from pathlib import Path
import re
import stat

from PIL import Image
from PySide6.QtGui import QColorSpace, QImage

from .renderer import to_pillow, to_qimage

MAX_PIXELS = 24_000_000
MAX_SIDE = 16_384
MAX_ENCODED_BYTES = 128 * 1024 * 1024
_ALPHA_TYPES = {'urn:mpeg:hevc:2015:auxid:1',
                'urn:mpeg:mpegB:cicp:systems:auxiliary:alpha'}


class HeifCodecError(ValueError):
    pass


class HeifUnavailable(HeifCodecError):
    pass


@dataclass(frozen=True)
class HeifMetadata:
    size: tuple[int, int]
    bit_depth: int
    has_alpha: bool
    item_count: int


def _backend():
    try:
        backend = importlib.import_module('pillow_heif')
    except (ImportError, OSError) as error:
        raise HeifUnavailable('HEIC/HEIF에는 별도로 승인한 pillow-heif 코덱이 필요합니다. 자동 설치하지 않았습니다.') from error
    version = re.match(r'^(\d+)\.(\d+)', getattr(backend, '__version__', ''))
    if not version or tuple(map(int, version.groups())) < (1, 8):
        raise HeifUnavailable('HEIC/HEIF 코덱은 검증 대상 pillow-heif 1.8 이상이 필요합니다.')
    return backend


def _size(size):
    if len(size) != 2 or any(type(side) is not int or side <= 0 or side > MAX_SIDE for side in size) \
            or size[0] * size[1] > MAX_PIXELS:
        raise HeifCodecError('HEIC/HEIF 이미지 한도는 24MP, 한 변 16384픽셀입니다.')
    return tuple(size)


def _metadata(container):
    size = _size(container.size)  # Metadata access must not request .data/.stride.
    return HeifMetadata(size, int(container.info.get('bit_depth', 8)), bool(container.has_alpha), len(container))


def _open_path(path):
    path = Path(path)
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_ENCODED_BYTES:
        raise HeifCodecError('HEIC/HEIF 원본은 regular file, 128MiB 이하여야 합니다.')
    backend = _backend()
    try:
        container = backend.open_heif(path, convert_hdr_to_8bit=True, bgr_mode=False)
        if container.mimetype not in ('image/heic', 'image/heif', 'image/heic-sequence', 'image/heif-sequence'):
            raise HeifCodecError('지원되는 HEIC/HEIF 컨테이너가 아닙니다.')
        metadata = _metadata(container)
        return container, metadata
    except HeifCodecError:
        raise
    except (ValueError, EOFError, SyntaxError, RuntimeError, OSError, IndexError) as error:
        raise HeifCodecError('HEIC/HEIF 정보를 읽을 수 없습니다: ' + str(error)) from error


def inspect_heif(path):
    """Read primary-image dimensions without decoding any item pixels."""
    return _open_path(path)[1]


def _srgb():
    return QColorSpace(QColorSpace.NamedColorSpace.SRgb)


def _color_space(info):
    nclx = info.get('nclx_profile') or {}
    transfer = nclx.get('transfer_characteristics', 13)
    if transfer in (16, 18):
        raise HeifCodecError('HDR HEIC의 PQ/HLG → SDR 톤 매핑은 아직 검증되지 않았습니다. 이 원본을 sRGB로 잘못 저장하지 않았습니다.')
    icc = info.get('icc_profile')
    if icc:
        result = QColorSpace.fromIccProfile(icc)
        if not result.isValid():
            raise HeifCodecError('HEIC/HEIF ICC 색상 프로파일을 처리할 수 없습니다.')
        if result.transferFunction() in (QColorSpace.TransferFunction.St2084, QColorSpace.TransferFunction.Hlg):
            raise HeifCodecError('HDR ICC → SDR 톤 매핑은 아직 검증되지 않았습니다.')
        return result
    if not nclx:
        return _srgb()  # Untagged SDR follows the existing image editor's sRGB policy.
    primaries = {1: QColorSpace.Primaries.SRgb, 9: QColorSpace.Primaries.Bt2020,
                 12: QColorSpace.Primaries.DciP3D65}.get(nclx.get('color_primaries', 1))
    functions = {1: QColorSpace.TransferFunction.Bt2020, 6: QColorSpace.TransferFunction.Bt2020,
                 8: QColorSpace.TransferFunction.Linear, 13: QColorSpace.TransferFunction.SRgb,
                 14: QColorSpace.TransferFunction.Bt2020, 15: QColorSpace.TransferFunction.Bt2020}
    function = functions.get(transfer)
    if primaries is None or function is None:
        raise HeifCodecError('HEIC/HEIF NCLX 색상 변환을 아직 지원하지 않습니다. 프로파일을 무시하지 않았습니다.')
    return QColorSpace(primaries, function)


def _decode(container):
    _metadata(container)
    color = _color_space(container.info)  # HDR rejection also precedes full decode.
    image = container.to_pillow()  # Only primary; libheif transforms it exactly once.
    _size(image.size)
    if image.mode not in ('RGB', 'RGBA', 'RGBa', 'L', 'LA'):
        raise HeifCodecError('8비트 SDR로 처리할 수 없는 HEIC/HEIF 픽셀 형식입니다.')
    result = to_qimage(image)
    result.setColorSpace(color)
    result = result.convertedToColorSpace(_srgb())
    if result.isNull():
        raise HeifCodecError('HEIC/HEIF 색상 변환에 실패했습니다.')
    return result


def read_heif(path):
    """Return the displayed primary image as sRGB RGBA8; no source metadata."""
    container, _ = _open_path(path)
    try:
        return _decode(container)
    except HeifCodecError:
        raise
    except (ValueError, EOFError, SyntaxError, RuntimeError, OSError) as error:
        raise HeifCodecError('HEIC/HEIF 픽셀을 읽을 수 없습니다: ' + str(error)) from error


def _verify_output(container, size, has_alpha):
    metadata = _metadata(container)
    if metadata.size != size or metadata.item_count != 1 or metadata.bit_depth != 8 or metadata.has_alpha != has_alpha:
        raise HeifCodecError('HEIC 재열기 결과의 크기·단일 이미지·8비트·투명도가 저장 정책과 다릅니다.')
    info = container.info
    if container.mimetype not in ('image/heic', 'image/heif') or info.get('chroma') != 444:
        raise HeifCodecError('HEIC 출력 형식/4:4:4 정책이 재열기 metadata와 다릅니다.')
    for field in ('exif', 'xmp', 'metadata', 'thumbnails', 'depth_images', 'heif', 'entity_groups'):
        if info.get(field):
            raise HeifCodecError('HEIC 출력에 원본/추가 이미지 metadata가 남아 있습니다: ' + field)
    if any(kind not in _ALPHA_TYPES or not has_alpha for kind in info.get('aux', {})):
        raise HeifCodecError('HEIC 출력에는 새 픽셀의 alpha 외 auxiliary를 보존할 수 없습니다.')
    _decode(container)  # Registered encoder alone is insufficient: decode the actual bytes.


def encode_heic(image, quality=95, *, alpha_policy='preserve'):
    """Encode fresh rendered RGBA8 bytes; caller publishes them with source guards.

    quality is an explicit HEIF integer 0..100 (not JPEG's scale or lossless -1).
    Preserve alpha by default; RGB under fully transparent pixels is zeroed.
    Explicit 'white' composites alpha onto white. Both use 4:4:4, without a
    silent 4:2:0 fallback. Fresh source-free container prevents thumbnail/auxiliary
    or unmasked sibling images from being carried through.
    """
    if not isinstance(image, QImage) or image.isNull():
        raise HeifCodecError('HEIC으로 저장할 이미지가 없습니다.')
    size = _size((image.width(), image.height()))
    if type(quality) is not int or not 0 <= quality <= 100 or alpha_policy not in ('preserve', 'white'):
        raise HeifCodecError('HEIC 품질은 0–100 정수, alpha 정책은 preserve 또는 white여야 합니다.')
    color = image.colorSpace()
    if color.isValid() and color.transferFunction() in (QColorSpace.TransferFunction.St2084, QColorSpace.TransferFunction.Hlg):
        raise HeifCodecError('HDR → SDR 톤 매핑이 검증되지 않아 HEIC 저장을 중단했습니다.')
    backend = _backend()
    rgba = to_pillow(image)
    alpha = rgba.getchannel('A')
    if alpha_policy == 'white':
        pixels = Image.new('RGB', size, 'white')
        pixels.paste(rgba.convert('RGB'), mask=alpha)
    else:
        pixels = rgba.copy()
        pixels.paste((0, 0, 0, 0), mask=alpha.point(lambda value: 255 if value == 0 else 0))
    has_alpha = pixels.mode == 'RGBA'
    try:
        container = backend.from_bytes(pixels.mode, size, pixels.tobytes())
        output = BytesIO()
        container.save(output, quality=quality, save_all=False, chroma=444, bit_depth=8,
                       tile_size=0, exif=None, xmp=None,
                       icc_profile=bytes(_srgb().iccProfile()), color_primaries=1,
                       transfer_characteristics=13, matrix_coefficients=6, full_range_flag=1)
        payload = output.getvalue()
        if not payload or len(payload) > MAX_ENCODED_BYTES:
            raise HeifCodecError('HEIC 출력 크기가 유효하지 않습니다.')
        reopened = backend.open_heif(payload, convert_hdr_to_8bit=True, bgr_mode=False)
        _verify_output(reopened, size, has_alpha)
        return payload
    except HeifCodecError:
        raise
    except (ValueError, EOFError, SyntaxError, RuntimeError, OSError) as error:
        raise HeifCodecError('HEIC 인코더/재열기 검증에 실패했습니다. 다른 코덱으로 대체하지 않았습니다: ' + str(error)) from error
