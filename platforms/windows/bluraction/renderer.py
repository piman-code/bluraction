"""One flattened renderer shared by preview and file/video exports.

Persisted geometry is normalized, with a bottom-left origin, as on macOS.
QImage and Pillow buffers use top-left pixels. Convert once at this boundary.
"""
from __future__ import annotations

from copy import deepcopy
import math
from PIL import Image, ImageFilter
import numpy as np
from PySide6.QtCore import QPointF, QRectF, Qt
from PySide6.QtGui import QColor, QColorSpace, QFont, QFontDatabase, QFontInfo, QFontMetricsF, QImage, QPainter, QPainterPath, QPen


PORTABLE_FONT_REQUESTS = ('System', 'Sans Serif', 'sans-serif', 'Monospace', 'Serif', 'Cursive', 'Fantasy')


def generic_font_request(name):
    """Recognize complete ASCII requests, retaining every saved named value."""
    if not name:
        return 'sans serif'
    if name.isascii() and name.lower() in {request.lower() for request in PORTABLE_FONT_REQUESTS}:
        return name.lower()
    return None


def text_bold(item):
    """Swift's legacy absent/null weight is true; do not rewrite the record."""
    value = item.get('bold')
    return True if value is None else value


def text_font(name):
    """Resolve portable generic requests without changing saved named fonts.

    Windows need not have a font family literally named Monospace. Qt's fixed
    system font is the documented native choice for that generic request.
    https://doc.qt.io/qt-6/qfontdatabase.html#systemFont
    """
    generic = generic_font_request(name)
    if generic == 'monospace':
        fixed = QFontDatabase.systemFont(QFontDatabase.SystemFont.FixedFont)
        if QFontInfo(fixed).fixedPitch():
            return fixed
        # Offscreen/native backends can advertise an unresolved system alias.
        # Select an actually installed fixed family instead of proportional
        # fallback, using the same font for availability, preview and export.
        for family in sorted(QFontDatabase.families(), key=str.casefold):
            if QFontDatabase.isFixedPitch(family):
                candidate = QFont(family)
                if QFontInfo(candidate).fixedPitch():
                    return candidate
        fixed.setStyleHint(QFont.StyleHint.Monospace)
        fixed.setFixedPitch(True)
        return fixed
    if generic == 'system':
        return QFontDatabase.systemFont(QFontDatabase.SystemFont.GeneralFont)
    font = QFont(name or 'Sans Serif')
    hints = {'sans serif': QFont.StyleHint.SansSerif, 'sans-serif': QFont.StyleHint.SansSerif,
             'serif': QFont.StyleHint.Serif, 'cursive': QFont.StyleHint.Cursive,
             'fantasy': QFont.StyleHint.Fantasy}
    if generic in hints:
        font.setStyleHint(hints[generic])
    return font


def active(interval, time):
    return time is None or interval == [0, 0] or interval[0] <= time <= interval[1]


def bounds(points):
    if not points:
        return [0, 0, 0, 0]
    xs, ys = zip(*points)
    return [min(xs), min(ys), max(xs) - min(xs), max(ys) - min(ys)]


def rect_at(base, frames, time):
    if time is None:
        return list(base)
    frames = sorted(enumerate(frames), key=lambda p: (p[1]['time'], p[0]))
    earlier = [frame for _, frame in frames if frame['time'] <= time]
    if not earlier:
        return list(base)
    a = earlier[-1]
    later = [frame for _, frame in frames if frame['time'] > time]
    ra = a['rect'][0] + a['rect'][1]
    if not later:
        return ra
    b = later[0]
    rb = b['rect'][0] + b['rect'][1]
    u = (time - a['time']) / (b['time'] - a['time'])
    return [x + (y - x) * u for x, y in zip(ra, rb)]


def map_point(p, old, new):
    return [new[i] + ((p[i] - old[i]) / old[i + 2] * new[i + 2]
                     if old[i + 2] else p[i] - old[i]) for i in range(2)]


def shape_points(region):
    kind, shape = next(iter(region['shape'].items()))
    if kind == 'polygon':
        return kind, shape['points']
    o, s = shape['origin'], shape['size']
    return kind, [o, [o[0] + s[0], o[1] + s[1]]]


def positioned(item, region, time):
    result = deepcopy(item)
    if region:
        kind, points = shape_points(item)
        effect = result['effect']
        old = bounds(points)
    else:
        points = item['points']
        old = bounds(points)
        effect = result
    new = rect_at(old, effect.get('keyframes', []), time)
    points = [map_point(p, old, new) for p in points]
    if region:
        shape = next(iter(result['shape'].values()))
        if kind == 'polygon':
            shape['points'] = points
        else:
            shape['origin'] = points[0]
            shape['size'] = [points[1][i] - points[0][i] for i in range(2)]
    else:
        result['points'] = points
    for hole in effect.get('erasures', []):
        hole['points'] = [map_point(p, old, new) for p in hole['points']]
    return result


def point(p, width, height):
    return QPointF(p[0] * width, (1 - p[1]) * height)


def path_for(kind, points, width, height):
    path = QPainterPath()
    # CGContext.fillPath uses nonzero winding, including self-intersecting
    # polygons and closed freehand fills. Qt's default is odd-even.
    path.setFillRule(Qt.FillRule.WindingFill)
    if not points:
        return path
    a = point(points[0], width, height)
    if kind in ('rectangle', 'ellipse', 'text') and len(points) >= 2:
        rect = QRectF(a, point(points[1], width, height)).normalized()
        path.addEllipse(rect) if kind == 'ellipse' else path.addRect(rect)
    else:
        path.moveTo(a)
        for p in (points[1:2] if kind in ('line', 'arrow') else points[1:]):
            path.lineTo(point(p, width, height))
        if kind == 'polygon':
            path.closeSubpath()
    return path


def arrow_head(points, width, height, line_width):
    head = QPainterPath()
    if len(points) < 2:
        return head
    a, b = [point(p, width, height) for p in points[:2]]
    length = math.hypot(b.x() - a.x(), b.y() - a.y())
    if length:
        ux, uy = (b.x() - a.x()) / length, (b.y() - a.y()) / length
        size = max(10, line_width * 3.5)
        head.moveTo(b)
        head.lineTo(b.x() - ux * size - uy * size * .55,
                    b.y() - uy * size + ux * size * .55)
        head.lineTo(b.x() - ux * size + uy * size * .55,
                    b.y() - uy * size - ux * size * .55)
        head.closeSubpath()
    return head


def to_pillow(image):
    if image.colorSpace().isValid():
        image = image.convertedToColorSpace(QColorSpace(QColorSpace.NamedColorSpace.SRgb))
    image = image.convertToFormat(QImage.Format.Format_RGBA8888)
    raw = bytes(image.constBits())
    return Image.frombytes('RGBA', (image.width(), image.height()), raw,
                           'raw', 'RGBA', image.bytesPerLine(), 1)


def to_qimage(image):
    image = image.convert('RGBA')
    raw = image.tobytes()
    result = QImage(raw, image.width, image.height, image.width * 4,
                    QImage.Format.Format_RGBA8888).copy()
    result.setColorSpace(QColorSpace(QColorSpace.NamedColorSpace.SRgb))
    return result


def erase_layer(layer, erasures, time):
    painter = QPainter(layer)
    painter.setRenderHint(QPainter.RenderHint.Antialiasing)
    painter.setCompositionMode(QPainter.CompositionMode.CompositionMode_Clear)
    scale = math.sqrt(layer.width() * layer.height())
    for stroke in erasures:
        if (time is not None and stroke.get('from') is not None and time < stroke['from']) or not stroke['points']:
            continue
        pen = QPen(Qt.GlobalColor.black, stroke['width'] * scale,
                   Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap, Qt.PenJoinStyle.RoundJoin)
        painter.setPen(pen)
        painter.setBrush(Qt.BrushStyle.NoBrush)
        pts = stroke['points']
        if len(pts) == 1:
            painter.drawPoint(point(pts[0], layer.width(), layer.height()))
        else:
            painter.drawPath(path_for('freehand', pts, layer.width(), layer.height()))
    painter.end()


def color(value, opacity=1):
    return QColor.fromRgbF(value.get('red', 0), value.get('green', 0),
                          value.get('blue', 0), value.get('alpha', 1) * opacity)


_FLOAT_WORK_BYTES = 8 * 1024 * 1024
_MAX_EFFECT_PIXELS = 24_000_000
_encoded = np.arange(256, dtype=np.float32) / 255
# sRGB transfer functions: https://www.w3.org/Graphics/Color/srgb
_SRGB_TO_LINEAR = np.where(_encoded <= .04045, _encoded / 12.92,
                           ((_encoded + .055) / 1.055) ** 2.4).astype(np.float32)


def _rows(width, bytes_per_pixel=64):
    return max(1, _FLOAT_WORK_BYTES // max(1, width * bytes_per_pixel))


def _source_channel(source, channel):
    """One float plane, premultiplied in linear light; no full RGB temporary."""
    height, width = source.shape[:2]
    result = np.empty((height, width), dtype=np.float32)
    step = _rows(width)
    for start in range(0, height, step):
        part = source[start:start + step]
        alpha = part[:, :, 3].astype(np.float32) / 255
        result[start:start + step] = (alpha if channel == 3
            else _SRGB_TO_LINEAR[part[:, :, channel]] * alpha)
    return result


def _source_linear(source):
    height, width = source.shape[:2]
    result = np.empty((height, width, 4), dtype=np.float32)
    step = _rows(width)
    for start in range(0, height, step):
        part = source[start:start + step]
        alpha = part[:, :, 3].astype(np.float32) / 255
        result[start:start + step, :, 3] = alpha
        for channel in range(3):
            result[start:start + step, :, channel] = _SRGB_TO_LINEAR[part[:, :, channel]] * alpha
    return result


def _constant_alpha(source):
    value = int(source[0, 0, 3])
    step = _rows(source.shape[1])
    for start in range(0, source.shape[0], step):
        if not np.all(source[start:start + step, :, 3] == value):
            return None
    return value / 255


def _box_axis_inplace(values, radius, outer_weight, axis):
    """Extended box, edge-clamped, with bounded float64 prefix tiles.

    Rows (or whole columns through a transpose view) are independent. Build
    each prefix before writing that tile; never allocate an image-sized prefix
    or pad. The smallest possible tile is one line plus its finite halo.
    """
    if radius == 0 and outer_weight == 0:
        return
    lines = values if axis == 1 else values.T
    length = lines.shape[1]
    pad = radius + 1
    step = max(1, _FLOAT_WORK_BYTES // ((length + 2 * pad + 1) * 32))
    width = 2 * radius + 1
    denominator = width + 2 * outer_weight
    for start in range(0, lines.shape[0], step):
        padded = np.pad(lines[start:start + step], ((0, 0), (pad, pad)), mode='edge')
        prefix = np.empty((len(padded), padded.shape[1] + 1), dtype=np.float64)
        prefix[:, 0] = 0
        np.cumsum(padded, axis=1, dtype=np.float64, out=prefix[:, 1:])
        summed = prefix[:, width + 1:width + 1 + length] - prefix[:, 1:1 + length]
        if outer_weight:
            summed += outer_weight * (padded[:, :length] + padded[:, width + 1:width + 1 + length])
        lines[start:start + step] = summed / denominator


def _gaussian_inplace(values, sigma):
    """Three separable extended boxes, in float, approximating a Gaussian.

    Match the second moment sigma**2, including small/fractional sigma. A
    box with unit taps -r..r and weighted taps +/- (r+1) has variance
    (r*(r+1)*(2*r+1)/3 + 2*a*(r+1)**2)/(2*r+1+2*a).
    Setting this to sigma**2/3 gives the outer weight below. Three passes
    approximate, rather than reproduce, Core Image's Gaussian kernel.
    https://peterkovesi.com/papers/FastGaussianSmoothing.pdf
    """
    if not math.isfinite(sigma) or not 0 <= sigma <= 250:
        raise ValueError('블러 반경이 올바르지 않습니다.')
    if values.ndim != 2 or values.dtype != np.float32 or not values.size or values.size > _MAX_EFFECT_PIXELS:
        raise ValueError('효과 이미지 크기 또는 형식이 올바르지 않습니다.')
    step = _rows(values.shape[1])
    for start in range(0, values.shape[0], step):
        if not np.isfinite(values[start:start + step]).all():
            raise ValueError('효과 이미지에 유효하지 않은 값이 있습니다.')
    if sigma == 0:
        return values
    radius = max(0, math.floor((math.sqrt(1 + 4 * sigma * sigma) - 1) / 2))
    variance = sigma * sigma / 3
    numerator = variance * (2 * radius + 1) - radius * (radius + 1) * (2 * radius + 1) / 3
    outer = max(0, min(1, numerator / (2 * ((radius + 1) ** 2 - variance))))
    for _ in range(3):
        _box_axis_inplace(values, radius, outer, 1)
        _box_axis_inplace(values, radius, outer, 0)
    return values


def _mosaic_channel(source, cell):
    """Bilinear samples of a linear-premultiplied plane; original grid kept."""
    if not math.isfinite(cell) or not 0 <= cell <= 500:
        raise ValueError('모자이크 크기가 올바르지 않습니다.')
    cell = max(2, cell)
    height, width = source.shape
    xs = np.clip(np.floor((np.arange(width) + .5) / cell) * cell + cell / 2 - .5, 0, width - 1)
    x0 = xs.astype(int)
    x1 = np.minimum(x0 + 1, width - 1)
    wx = (xs - x0).astype(np.float32)
    output = np.empty_like(source)
    previous_y, row = None, None
    for y in range(height):
        sy = min(height - 1, max(0, height - (math.floor((height - y - .5) / cell) * cell + cell / 2) - .5))
        if sy != previous_y:
            y0, y1 = int(sy), min(int(sy) + 1, height - 1)
            wy = sy - y0
            a = source[y0, x0] * (1 - wx) + source[y0, x1] * wx
            b = source[y1, x0] * (1 - wx) + source[y1, x1] * wx
            row = a * (1 - wy) + b * wy
            previous_y = sy
        output[y] = row
    return output


def _blend_channel(output, cover, coverage, channel):
    """Lerp premultiplied color AND alpha; coverage is not an sRGB color."""
    height, width = coverage.shape
    step = _rows(width)
    for start in range(0, height, step):
        target = output[start:start + step, :, channel]
        weight = coverage[start:start + step].astype(np.float32) / 255
        value = cover if np.isscalar(cover) else cover[start:start + step]
        target += (value - target) * weight


def _linear_bytes(linear, original=None, touched=None):
    """Quantize once after all regions; untouched pixels remain exact bytes."""
    height, width = linear.shape[:2]
    result = (np.empty((height, width, 4), dtype=np.uint8) if original is None else original.copy())
    step = _rows(width)
    for start in range(0, height, step):
        part = linear[start:start + step]
        alpha = np.clip(part[:, :, 3], 0, 1)
        encoded = np.empty(part.shape, dtype=np.uint8)
        encoded[:, :, 3] = np.rint(alpha * 255).astype(np.uint8)
        for channel in range(3):
            straight = np.zeros(alpha.shape, dtype=np.float32)
            np.divide(part[:, :, channel], alpha, out=straight, where=alpha > 0)
            np.clip(straight, 0, 1, out=straight)
            srgb = np.where(straight <= .0031308, straight * 12.92,
                            1.055 * straight ** (1 / 2.4) - .055)
            encoded[:, :, channel] = np.rint(np.clip(srgb, 0, 1) * 255).astype(np.uint8)
        # Derived pixels with quantized alpha0 must not retain hidden color.
        encoded[encoded[:, :, 3] == 0, :3] = 0
        if touched is None:
            result[start:start + step] = encoded
        else:
            selected = touched[start:start + step]
            result[start:start + step][selected] = encoded[selected]
    return result


def _composite_annotations(background, overlay):
    """One linear-light source-over of the completed encoded drawing overlay.

    Mac draws all annotations into one sRGB8 premultiplied CGContext, then
    Core Image composites that overlay over the effects in linear light.
    Decode the *premultiplied bytes* without an intermediate 8bit straight
    RGB conversion. Only tile-sized floats are needed; alpha0 pixels retain
    the background bytes, including untouched transparent hidden RGB.
    """
    original = np.asarray(background)
    height, width = original.shape[:2]
    raw = np.frombuffer(overlay.constBits(), dtype=np.uint8).reshape(height, overlay.bytesPerLine())
    raw = raw[:, :width * 4].reshape(height, width, 4)
    result = original.copy()
    # Budget covers the RGBA float tile plus transfer-function temporaries.
    step = _rows(width, bytes_per_pixel=128)
    for start in range(0, height, step):
        top = raw[start:start + step]
        selected = top[:, :, 3] != 0
        if not np.any(selected):
            continue
        linear = _source_linear(original[start:start + step])
        alpha = top[:, :, 3].astype(np.float32) / 255
        inverse = 1 - alpha
        for channel in range(3):
            straight = np.zeros(alpha.shape, dtype=np.float32)
            np.divide(top[:, :, channel], top[:, :, 3], out=straight, where=selected)
            np.clip(straight, 0, 1, out=straight)
            foreground = np.where(straight <= .04045, straight / 12.92,
                                  ((straight + .055) / 1.055) ** 2.4)
            linear[:, :, channel] *= inverse
            linear[:, :, channel] += foreground * alpha
        linear[:, :, 3] *= inverse
        linear[:, :, 3] += alpha
        encoded = _linear_bytes(linear)
        result[start:start + step][selected] = encoded[selected]
    return Image.fromarray(result)


def mosaic(image, cell):
    """Pixelate fixed-size cells anchored at the bottom-left image origin.

    Sample each tile at its center, including clamped partial edge tiles;
    resizing the whole image would move every tile when dimensions aren't
    divisible by cell size. Process rows to keep large-image memory bounded.
    """
    if not math.isfinite(cell) or not 0 <= cell <= 500:
        raise ValueError('모자이크 크기가 올바르지 않습니다.')
    source = np.asarray(image.convert('RGBA'))
    height, width = source.shape[:2]
    if height * width > _MAX_EFFECT_PIXELS:
        raise ValueError('효과 이미지가 너무 큽니다.')
    output = np.empty((height, width, 4), dtype=np.float32)
    for channel in range(4):
        plane = _source_channel(source, channel)
        output[:, :, channel] = _mosaic_channel(plane, cell)
        del plane
    return Image.fromarray(_linear_bytes(output))


def render(image, state, time=None):
    """No selection overlays and no second annotation composition."""
    if image.isNull():
        raise ValueError('원본 프레임을 읽을 수 없습니다.')
    source = to_pillow(image)
    width, height = source.size
    if width * height > _MAX_EFFECT_PIXELS:
        raise ValueError('효과 이미지가 너무 큽니다.')
    source_bytes, linear, touched, constant_alpha = None, None, None, None
    for base in state.get('regions', []):
        effect = base['effect']
        if not effect.get('enabled', True) or not active(effect.get('timeRange', [0, 0]), time):
            continue
        item = positioned(base, True, time)
        effect = item['effect']
        style = effect.get('style', 'blur')
        radius = effect.get('blurRadius', 25)
        feather = effect.get('featherRadius', 12)
        if not all(math.isfinite(value) and 0 <= value <= 500 for value in (radius, feather)):
            raise ValueError('효과 반경이 올바르지 않습니다.')
        kind, points = shape_points(item)
        mask = QImage(width, height, QImage.Format.Format_ARGB32_Premultiplied)
        mask.fill(Qt.GlobalColor.transparent)
        painter = QPainter(mask)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        painter.fillPath(path_for(kind, points, width, height), Qt.GlobalColor.white)
        painter.end()
        erase_layer(mask, effect.get('erasures', []), time)
        alpha = to_pillow(mask).getchannel('A')
        del mask
        if feather:
            sigma = feather / 3.29
            pad = max(1, math.ceil(sigma * 4))
            clamped = Image.fromarray(np.pad(np.asarray(alpha), pad, mode='edge'))
            alpha = clamped.filter(ImageFilter.GaussianBlur(sigma)).crop((pad, pad, width + pad, height + pad))
            alpha = alpha.point([max(0, min(255, round((value - 255 * .05) / .9))) for value in range(256)])
        if style not in ('blur', 'mosaic', 'solid'):
            raise ValueError('알 수 없는 가리기 효과입니다.')
        coverage = np.asarray(alpha)
        if not np.any(coverage):
            continue
        if linear is None:
            source_bytes = np.asarray(source)
            linear = _source_linear(source_bytes)
            touched = np.zeros((height, width), dtype=bool)
            constant_alpha = _constant_alpha(source_bytes)
        np.logical_or(touched, coverage > 0, out=touched)
        for channel in range(4):
            if style == 'solid':
                c = effect.get('color', {})
                value = c.get(('red', 'green', 'blue')[channel], 0) if channel < 3 else 1
                if not math.isfinite(value) or not 0 <= value <= 1:
                    raise ValueError('가림 색상이 올바르지 않습니다.')
                cover = (value / 12.92 if value <= .04045 else ((value + .055) / 1.055) ** 2.4) if channel < 3 else 1
            elif channel == 3 and constant_alpha is not None:
                # Filtering/interpolating a constant alpha cannot change it.
                cover = constant_alpha
            else:
                cover = _source_channel(source_bytes, channel)
                if style == 'blur':
                    _gaussian_inplace(cover, radius / 2)
                else:
                    cover = _mosaic_channel(cover, radius)
            _blend_channel(linear, cover, coverage, channel)
            del cover
    output = source if linear is None else Image.fromarray(_linear_bytes(linear, source_bytes, touched))
    # Release effect float buffers before allocating annotation layers.
    del linear, source_bytes, touched
    overlay = None
    scale = math.sqrt(width * height)
    for base in state.get('drawings', []):
        if base.get('hidden', False) or not active(base.get('timeRange', [0, 0]), time):
            continue
        item = positioned(base, False, time)
        kind, points = item['kind'], item['points']
        if overlay is None:
            overlay = QImage(width, height, QImage.Format.Format_RGBA8888_Premultiplied)
            overlay.fill(Qt.GlobalColor.transparent)
        erasures = [stroke for stroke in item.get('erasures', []) if stroke['points']
                    and (time is None or stroke.get('from') is None or time >= stroke['from'])]
        # Erasures clear this annotation alone. Without erasures, paint
        # directly into the shared overlay, as CGContext does on macOS.
        layer = overlay
        if erasures:
            layer = QImage(width, height, QImage.Format.Format_RGBA8888_Premultiplied)
            layer.fill(Qt.GlobalColor.transparent)
        painter = QPainter(layer)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        stroke = color(item)
        line_width = item['lineWidth'] * scale
        painter.setPen(QPen(stroke, line_width, Qt.PenStyle.SolidLine,
                            Qt.PenCapStyle.RoundCap, Qt.PenJoinStyle.RoundJoin))
        path = path_for(kind, points, width, height)
        if kind == 'text':
            box = path.boundingRect()
            text = item.get('text', '')
            if text and box.width() > 0 and box.height() > 0:
                lines = [line or ' ' for line in text.split('\n')]
                line_height = box.height() / len(lines)
                size = line_height / 1.25
                if item.get('textBackground'):
                    pad = size * .2
                    background = QPainterPath()
                    background.addRoundedRect(box.adjusted(-pad, -pad / 2, pad, pad / 2), pad, pad)
                    painter.fillPath(background, color(item['textBackground']))
                font = text_font(item.get('fontName'))
                font.setBold(text_bold(item))
                # A fixed font size and painter transform retain fractional sizes.
                font.setPixelSize(100)
                painter.setFont(font)
                metrics = QFontMetricsF(font)
                widest = max(metrics.horizontalAdvance(line) for line in lines)
                if widest > 0:
                    sy = size / 100
                    for index, line in enumerate(lines):
                        baseline = (box.top() + (index + 1) * line_height
                                    - metrics.descent() * sy - (line_height - size * 1.2) / 2)
                        painter.save()
                        painter.translate(box.left(), baseline)
                        painter.scale(box.width() / widest, sy)
                        painter.drawText(QPointF(0, 0), line)
                        painter.restore()
        else:
            fill = item.get('fillOpacity', 0)
            if fill and kind in ('rectangle', 'ellipse', 'freehand'):
                filled = QPainterPath(path)
                if kind == 'freehand':
                    filled.closeSubpath()
                painter.fillPath(filled, color(item, fill))
            painter.setBrush(Qt.BrushStyle.NoBrush)
            painter.drawPath(path)
            if kind == 'arrow' and len(points) >= 2:
                painter.fillPath(arrow_head(points, width, height, line_width), stroke)
        painter.end()
        if erasures:
            erase_layer(layer, erasures, time)
            painter = QPainter(overlay)
            painter.drawImage(0, 0, layer)
            painter.end()
    return to_qimage(output if overlay is None else _composite_annotations(output, overlay))
