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
from PySide6.QtGui import QColor, QColorSpace, QFont, QFontMetricsF, QImage, QPainter, QPainterPath, QPen


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


def mosaic(image, cell):
    """Pixelate fixed-size cells anchored at the bottom-left image origin.

    Sample each tile at its center, including clamped partial edge tiles;
    resizing the whole image would move every tile when dimensions aren't
    divisible by cell size. Process rows to keep large-image memory bounded.
    """
    cell = max(2, cell)
    source = np.asarray(image)
    height, width = source.shape[:2]
    xs = np.clip(np.floor((np.arange(width) + .5) / cell) * cell + cell / 2 - .5, 0, width - 1)
    x0 = xs.astype(int)
    x1 = np.minimum(x0 + 1, width - 1)
    wx = (xs - x0).astype(np.float32)[:, None]
    output = np.empty_like(source)
    previous_y, row = None, None
    for y in range(height):
        sy = min(height - 1, max(0, height - (math.floor((height - y - .5) / cell) * cell + cell / 2) - .5))
        if sy != previous_y:
            y0, y1 = int(sy), min(int(sy) + 1, height - 1)
            wy = sy - y0
            a = source[y0, x0].astype(np.float32) * (1 - wx) + source[y0, x1].astype(np.float32) * wx
            b = source[y1, x0].astype(np.float32) * (1 - wx) + source[y1, x1].astype(np.float32) * wx
            row = np.clip(np.rint(a * (1 - wy) + b * wy), 0, 255).astype(np.uint8)
            previous_y = sy
        output[y] = row
    return Image.fromarray(output)


def render(image, state, time=None):
    """No selection overlays and no second annotation composition."""
    if image.isNull():
        raise ValueError('원본 프레임을 읽을 수 없습니다.')
    source = to_pillow(image)
    output = source.copy()
    width, height = source.size
    for base in state.get('regions', []):
        effect = base['effect']
        if not effect.get('enabled', True) or not active(effect.get('timeRange', [0, 0]), time):
            continue
        item = positioned(base, True, time)
        effect = item['effect']
        style = effect.get('style', 'blur')
        radius = effect.get('blurRadius', 25)
        kind, points = shape_points(item)
        mask = QImage(width, height, QImage.Format.Format_ARGB32_Premultiplied)
        mask.fill(Qt.GlobalColor.transparent)
        painter = QPainter(mask)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        painter.fillPath(path_for(kind, points, width, height), Qt.GlobalColor.white)
        painter.end()
        erase_layer(mask, effect.get('erasures', []), time)
        alpha = to_pillow(mask).getchannel('A')
        feather = effect.get('featherRadius', 12)
        if feather:
            sigma = feather / 3.29
            pad = max(1, math.ceil(sigma * 4))
            clamped = Image.fromarray(np.pad(np.asarray(alpha), pad, mode='edge'))
            alpha = clamped.filter(ImageFilter.GaussianBlur(sigma)).crop((pad, pad, width + pad, height + pad))
            alpha = alpha.point([max(0, min(255, round((value - 255 * .05) / .9))) for value in range(256)])
        if style == 'blur':
            cover = source.filter(ImageFilter.GaussianBlur(radius / 2))
        elif style == 'mosaic':
            cover = mosaic(source, radius)
        elif style == 'solid':
            c = effect.get('color', {})
            rgba = tuple(round(c.get(k, 0) * 255) for k in ('red', 'green', 'blue')) + (255,)
            cover = Image.new('RGBA', source.size, rgba)
        else:
            raise ValueError('알 수 없는 가리기 효과입니다.')
        output = Image.composite(cover, output, alpha)
    flattened = to_qimage(output)
    scale = math.sqrt(width * height)
    for base in state.get('drawings', []):
        if base.get('hidden', False) or not active(base.get('timeRange', [0, 0]), time):
            continue
        item = positioned(base, False, time)
        kind, points = item['kind'], item['points']
        layer = QImage(width, height, QImage.Format.Format_ARGB32_Premultiplied)
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
                font = QFont(item.get('fontName') or 'Sans Serif')
                font.setBold(item.get('bold', True))
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
        erase_layer(layer, item.get('erasures', []), time)
        painter = QPainter(flattened)
        painter.drawImage(0, 0, layer)
        painter.end()
    return flattened
