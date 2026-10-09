"""Korean native Qt window following the approved macOS editor layout.

Canvas geometry is normalized in the persisted bottom-left coordinate system.
This module does not decode media or implement the document renderer.
"""
from __future__ import annotations

from copy import deepcopy
from pathlib import Path
import threading
import math
import weakref
from fractions import Fraction
import time as transport_time

from PySide6.QtCore import QObject, QPointF, QRectF, Qt, QThread, QUrl, Signal, Slot, QTimer
from PySide6.QtGui import QAction, QActionGroup, QColor, QColorSpace, QFont, QFontDatabase, QFontInfo, QImage, QKeySequence, QPainter, QPen, QTransform
from PySide6.QtMultimedia import QAudioOutput, QMediaPlayer, QVideoSink, QAudioSink, QAudioFormat, QMediaDevices
from PySide6.QtWidgets import (
    QApplication, QCheckBox, QColorDialog, QComboBox, QDoubleSpinBox,
    QAbstractItemView, QFileDialog, QFormLayout, QHBoxLayout, QInputDialog, QLabel, QLineEdit, QListWidget,
    QListWidgetItem, QMainWindow, QMessageBox, QPlainTextEdit, QProgressBar,
    QPushButton, QScrollArea, QSlider, QSpinBox, QSplitter, QToolBar, QVBoxLayout, QWidget,
)

from . import renderer
from .media import Cancelled, Page, export_documents, export_image, safe_stem
from .preview_worker import PreviewQueue, PreviewRequest, ValueQueue, ValueRequest
from .canonical_transport import AssetClock, PCMBuffer, PCMPlaybackPlan, TransportReview, exact_time
from .video import QualityPreset, output_bit_rate


TOOLS = (
    ('select', '선택'), ('cover_rectangle', '사각 가리기'),
    ('cover_ellipse', '타원 가리기'), ('cover_polygon', '자유형 가리기'),
    ('line', '선'), ('freehand', '펜'), ('rectangle', '사각형'),
    ('ellipse', '타원'), ('arrow', '화살표'), ('text', '글자'), ('eraser', '지우개'),
)


def item_identity(item, region):
    return next(iter(item['shape'].values()))['id'] if region else item['id']


def font_available(name, families=None):
    """Accept explicit system/generic requests; detect missing named families.

    QFontInfo also resolves real aliases omitted by QFontDatabase.families().
    https://doc.qt.io/qt-6/qfontinfo.html#details
    """
    generic = renderer.generic_font_request(name)
    if generic is not None:
        info = QFontInfo(renderer.text_font(name))
        return bool(info.family()) and (generic != 'monospace' or info.fixedPitch())
    families = families if families is not None else {f.lower() for f in QFontDatabase.families()}
    if name.lower() in families or name == QApplication.font().family():
        return True
    return QFontInfo(QFont(name)).exactMatch()


def fitted_rect(container: QRectF, size) -> QRectF:
    """One aspect-fit rectangle for source, effects and mouse hit-testing."""
    width, height = size.width(), size.height()
    if width <= 0 or height <= 0 or container.width() <= 0 or container.height() <= 0:
        return QRectF()
    scale = min(container.width() / width, container.height() / height)
    fitted = QRectF(0, 0, width * scale, height * scale)
    fitted.moveCenter(container.center())
    return fitted


class EditorCanvas(QWidget):
    created = Signal(str, object)
    picked = Signal(object)
    moved = Signal(float, float)
    nudged = Signal(int, object)
    erased = Signal(object)
    message = Signal(str)
    presented = Signal(object)
    color_pick_requested = Signal()
    color_picked = Signal(object)
    color_pick_cancelled = Signal(str)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setMinimumSize(240, 180)
        self.setFocusPolicy(Qt.FocusPolicy.StrongFocus)
        self.setAccessibleName('가리기·그리기 편집 캔버스')
        self.image = QImage()
        self.state = {'regions': [], 'drawings': []}
        self.time = None
        self.tool = 'select'
        self.selection_ids = set()
        self.busy = False
        self._preview = QImage()
        self._preview_source_key = 0
        self.preview_context = None
        self._accepted_context = None
        self._desired = None
        self.preview_queue = PreviewQueue(self)
        self.preview_queue.completed.connect(self._preview_completed)
        self.preview_queue.idle.connect(self._preview_idle)
        self._closing = False
        self.accept_guard = None
        self._stroke = []
        self._drag_start = None
        self._drag_item = None
        self._color_pick = None

    def arm_color_pick(self):
        if (self.busy or self.preview_pending or self.preview_queue.busy or self._preview.isNull()
                or self._stroke or self._drag_start is not None):
            return False
        self.cancel_color_pick(notify=False)
        self._color_pick = (self._accepted_context, self._preview.cacheKey(), self.time,
                            self.tool, frozenset(self.selection_ids), deepcopy(self.state), self.cursor())
        self.setCursor(Qt.CursorShape.CrossCursor)
        self.setFocus()
        return True

    def cancel_color_pick(self, reason='색 고르기를 취소했습니다.', *, notify=True):
        if self._color_pick is None:
            return
        cursor = self._color_pick[-1]
        self._color_pick = None
        self.setCursor(cursor)
        if notify:
            self.color_pick_cancelled.emit(reason)

    def _color_snapshot_valid(self):
        pick = self._color_pick
        return bool(pick is not None and not self.busy and not self.preview_pending and not self.preview_queue.busy
            and self._accepted_context == self.preview_context
            and pick[:5] == (self._accepted_context, self._preview.cacheKey(), self.time,
                            self.tool, frozenset(self.selection_ids)) and pick[5] == self.state)

    def sample_composite_at(self, position):
        """Read the displayed composite pixel, excluding selection decorations."""
        if self.busy or self.preview_pending or self.preview_queue.busy or self._preview.isNull():
            raise ValueError('합성 미리보기가 준비된 뒤 색을 가져오세요.')
        if not math.isfinite(position.x()) or not math.isfinite(position.y()):
            raise ValueError('색을 가져올 위치를 확인하세요.')
        point = self.normalized(position)
        if point is None:
            return None  # The letterbox is not a media pixel.
        x = min(self._preview.width() - 1, math.floor(point[0] * self._preview.width()))
        y = min(self._preview.height() - 1, math.floor((1 - point[1]) * self._preview.height()))
        pixel = self._preview.copy(x, y, 1, 1)
        space = QColorSpace(QColorSpace.NamedColorSpace.SRgb)
        if not pixel.colorSpace().isValid():
            raise ValueError('합성 미리보기의 색 공간을 확인할 수 없습니다.')
        if pixel.colorSpace() != space:
            pixel = pixel.convertedToColorSpace(space)
        color = pixel.pixelColor(0, 0)
        if not color.isValid() or color.alphaF() <= 0:
            raise ValueError('투명한 위치에서는 색을 가져올 수 없습니다.')
        color.setAlphaF(1)  # Mac eyedropper's straight sRGB / opaque-brush contract.
        return color

    def keyPressEvent(self, event):
        if event.key() == Qt.Key.Key_Escape and self._color_pick is not None:
            self.cancel_color_pick()
            event.accept()
            return
        if event.key() == Qt.Key.Key_I and event.modifiers() == Qt.KeyboardModifier.NoModifier:
            self.color_pick_requested.emit()
            event.accept()
            return
        arrows = (Qt.Key.Key_Left, Qt.Key.Key_Right, Qt.Key.Key_Up, Qt.Key.Key_Down)
        allowed = Qt.KeyboardModifier.ShiftModifier | Qt.KeyboardModifier.ControlModifier
        if event.key() in arrows and not (event.modifiers().value & ~allowed.value):
            if self._color_pick is None and not self.busy and not self._stroke and self._drag_start is None:
                self.nudged.emit(event.key(), event.modifiers())
            event.accept()
            return
        super().keyPressEvent(event)

    @property
    def display_rect(self):
        return fitted_rect(QRectF(self.rect()), self.image.size())

    def normalized(self, position, clamp=False):
        rect = self.display_rect
        if rect.isEmpty() or (not clamp and not rect.contains(position)):
            return None
        x = (position.x() - rect.x()) / rect.width()
        y = 1 - (position.y() - rect.y()) / rect.height()
        return [max(0, min(1, x)), max(0, min(1, y))]

    def display_point(self, point):
        rect = self.display_rect
        return QPointF(rect.x() + point[0] * rect.width(),
                       rect.y() + (1 - point[1]) * rect.height())

    def set_document(self, image, state, selection_ids=(), time=None):
        if self._color_pick is not None and (self._accepted_context != self.preview_context
                or image.cacheKey() != self.image.cacheKey() or state != self.state
                or time != self.time or frozenset(selection_ids) != self._color_pick[4]):
            self.cancel_color_pick('미리보기 또는 선택이 바뀌어 색 고르기를 취소했습니다.')
        # Selection, inspector and busy-state refreshes do not change pixels.
        # Keep the full-resolution result rather than recomputing a large effect
        # on every such update. QImage.cacheKey also changes on pixel mutation.
        self.selection_ids = set(selection_ids)
        request = PreviewRequest(self.preview_context, QImage(image), deepcopy(state), time)
        accepted = (self._accepted_context == request.context and image.cacheKey() == self._preview_source_key
                    and state == self.state and time == self.time)
        # A selection refresh of the displayed frame must not replace a newer
        # video frame already in the bounded queue.
        if accepted:
            self.busy = self.preview_pending
            self.update()
            return
        previous = self._desired
        self._desired = request
        if image.isNull():
            self.preview_queue.discard_pending(cancel_active=True)
            self.image, self.state, self.time = QImage(), deepcopy(state), time
            self._preview, self._preview_source_key = QImage(), -1
            self._accepted_context = self.preview_context
        else:
            duplicate = (previous is not None and previous.context == request.context
                         and previous.image.cacheKey() == image.cacheKey()
                         and previous.state == state and previous.time == time)
            if not duplicate or not self.preview_queue.busy:
                if previous is not None and (previous.context != request.context or previous.state != state):
                    self.preview_queue.discard_pending(cancel_active=True)
                self.preview_queue.submit(request)
        self.busy = self.preview_pending
        if self.busy:
            self._stroke, self._drag_start, self._drag_item = [], None, None
        self.update()

    @property
    def preview_pending(self):
        return self._desired is not None and (self._preview.isNull()
            or self._accepted_context != self._desired.context or self.state != self._desired.state)

    def request_video_seek(self, source, seconds, state, selection_ids=(), *, playback=False):
        self.cancel_color_pick('영상 탐색으로 색 고르기를 취소했습니다.')
        self.selection_ids = set(selection_ids)
        previous = self._desired
        if (previous is not None and previous.decode is not None and previous.context == self.preview_context
                and previous.time == seconds and previous.state == state and self.preview_queue.busy):
            self.busy = True
            self.update()
            return
        request = PreviewRequest(self.preview_context, QImage(), deepcopy(state), seconds,
            decode=lambda cancel: (source.frame_at_timed(seconds, cancel=cancel, preview=True) if playback
                                   else source.frame_at_timed(seconds, cancel=cancel)),
            source_size=(source._first_image.width(),source._first_image.height()) if playback else None)
        self._desired = request
        self.preview_queue.discard_pending(cancel_active=True)
        self.preview_queue.submit(request)
        self.busy = True
        self._stroke, self._drag_start, self._drag_item = [], None, None
        self.update()

    def accept_prepared(self, image, state, pixels, time, context):
        self.cancel_color_pick('새 미디어로 색 고르기를 취소했습니다.')
        self.preview_queue.discard_pending(cancel_active=True)
        self.preview_context = self._accepted_context = context
        self.image, self.state, self.time = QImage(image), deepcopy(state), time
        self._preview, self._preview_source_key = QImage(pixels), image.cacheKey()
        self._desired = PreviewRequest(context, QImage(image), deepcopy(state), time)
        self.busy = False
        self.update()

    @Slot(object)
    def _preview_completed(self, result):
        request, image, time, pixels, error = result
        desired = self._desired
        if desired is None or request.context != desired.context or request.state != desired.state:
            return
        self.cancel_color_pick('미리보기가 바뀌어 색 고르기를 취소했습니다.')
        if error is not None:
            if (request.image.cacheKey() != desired.image.cacheKey() or request.time != desired.time
                    or isinstance(error, Cancelled)):
                return
            self._preview, self._preview_source_key = QImage(), -1
            self.message.emit(str(error))
        else:
            try:
                if self.accept_guard is not None:
                    self.accept_guard(request)
            except (ValueError, OSError) as error:
                self._preview, self._preview_source_key = QImage(), -1
                self.busy = True
                self.message.emit(str(error))
                self.update()
                return
            # Source pixels, state and actual PTS become one displayed snapshot.
            self.image, self.state, self.time = QImage(image), request.state, time
            self._preview, self._preview_source_key = QImage(pixels), image.cacheKey()
            self._accepted_context = request.context
        self.busy = self.preview_pending
        self.update()
        if error is None:
            # The window can add its IO/export busy gate after this local update.
            self.presented.emit((image, time, request.context))

    @Slot()
    def _preview_idle(self):
        if self._closing:
            self.close()

    def closeEvent(self, event):
        self.cancel_color_pick()
        self.preview_queue.shutdown()
        if self.preview_queue.busy:
            self._closing = True
            event.ignore()
        else:
            event.accept()

    def set_tool(self, tool):
        self.cancel_color_pick('도구 변경으로 색 고르기를 취소했습니다.')
        self.tool = tool
        self._stroke = []
        self._drag_start = None
        self.update()

    def _items(self):
        # Drawings are rendered above all covers in the existing project format.
        for region, items in ((False, self.state.get('drawings', [])),
                              (True, self.state.get('regions', []))):
            for item in reversed(items):
                properties = item['effect'] if region else item
                if properties.get('hidden', False) or not properties.get('enabled', True):
                    continue
                if not renderer.active(properties.get('timeRange', [0, 0]), self.time):
                    continue
                yield renderer.positioned(item, region, self.time), region

    def hit_test(self, position):
        point = self.normalized(position)
        if point is None:
            return None
        for item, region in self._items():
            kind, points = renderer.shape_points(item) if region else (item['kind'], item['points'])
            path = renderer.path_for(kind, points, self.display_rect.width(), self.display_rect.height())
            local = QPointF(position.x() - self.display_rect.x(), position.y() - self.display_rect.y())
            if path.contains(local):
                return item_identity(item, region)
            from PySide6.QtGui import QPainterPathStroker
            stroker = QPainterPathStroker()
            stroker.setWidth(12)
            if stroker.createStroke(path).contains(local):
                return item_identity(item, region)
        return None

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.fillRect(self.rect(), Qt.GlobalColor.black)
        if self._preview.isNull():
            painter.setPen(Qt.GlobalColor.lightGray)
            painter.drawText(self.rect(), Qt.AlignmentFlag.AlignCenter,
                             '파일을 열거나 여기로 끌어 놓으세요.')
            return
        painter.drawImage(self.display_rect, self._preview)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        painter.setPen(QPen(QColor('#4da3ff'), 1.5, Qt.PenStyle.DashLine))
        painter.setBrush(Qt.BrushStyle.NoBrush)
        for item, region in self._items():
            if item_identity(item, region) not in self.selection_ids:
                continue
            points = renderer.shape_points(item)[1] if region else item['points']
            if points:
                x, y, width, height = renderer.bounds(points)
                painter.drawRect(QRectF(self.display_point([x, y]),
                                        self.display_point([x + width, y + height])).normalized())
        if self._stroke:
            if self.tool in ('freehand', 'eraser', 'cover_polygon'):
                for a, b in zip(self._stroke, self._stroke[1:]):
                    painter.drawLine(self.display_point(a), self.display_point(b))
            elif len(self._stroke) > 1:
                rect = QRectF(self.display_point(self._stroke[0]), self.display_point(self._stroke[-1])).normalized()
                if self.tool.endswith('ellipse'):
                    painter.drawEllipse(rect)
                elif self.tool in ('line', 'arrow'):
                    painter.drawLine(self.display_point(self._stroke[0]), self.display_point(self._stroke[-1]))
                else:
                    painter.drawRect(rect)

    def mousePressEvent(self, event):
        if self._color_pick is not None:
            if event.button() != Qt.MouseButton.LeftButton:
                return
            if not self._color_snapshot_valid():
                self.cancel_color_pick('미리보기 또는 선택이 바뀌어 색 고르기를 취소했습니다.')
                return
            if self.normalized(event.position()) is None:
                return
            try:
                if self.accept_guard is not None:
                    self.accept_guard(self._desired)
                color = self.sample_composite_at(event.position())
            except (ValueError, OSError) as error:
                self.cancel_color_pick(str(error))
                return
            self.cancel_color_pick(notify=False)
            self._stroke, self._drag_start, self._drag_item = [], None, None
            self.color_picked.emit(color)
            return
        if self.busy or event.button() != Qt.MouseButton.LeftButton:
            return
        point = self.normalized(event.position())
        if point is None:
            return
        self.setFocus()
        if self.tool == 'select':
            self._drag_item = self.hit_test(event.position())
            self.picked.emit(self._drag_item)
            self._drag_start = point if self._drag_item else None
        else:
            self._stroke = [point]
        self.update()

    def mouseMoveEvent(self, event):
        if self.busy or not (event.buttons() & Qt.MouseButton.LeftButton):
            return
        point = self.normalized(event.position(), clamp=True)
        if point is None or not self._stroke:
            return
        if self.tool in ('freehand', 'eraser', 'cover_polygon'):
            if point != self._stroke[-1]:
                self._stroke.append(point)
        else:
            self._stroke = [self._stroke[0], point]
        self.update()

    def mouseReleaseEvent(self, event):
        if self.busy or event.button() != Qt.MouseButton.LeftButton:
            return
        end = self.normalized(event.position(), clamp=True)
        if self.tool == 'select' and self._drag_start and end:
            dx, dy = end[0] - self._drag_start[0], end[1] - self._drag_start[1]
            if dx or dy:
                self.moved.emit(dx, dy)
        elif self._stroke and end:
            stroke = self._stroke[:]
            if self.tool == 'eraser':
                if end != stroke[-1]:
                    stroke.append(end)
                self.erased.emit(stroke)
            elif self.tool in ('freehand', 'cover_polygon'):
                if end != stroke[-1]:
                    stroke.append(end)
                if len(stroke) >= (3 if self.tool == 'cover_polygon' else 2):
                    self.created.emit(self.tool, stroke)
            elif stroke[0] != end:
                self.created.emit(self.tool, [stroke[0], end])
        self._stroke, self._drag_start, self._drag_item = [], None, None
        self.update()


class ExportWorker(QObject):
    progress = Signal(float)
    finished = Signal(object)

    def __init__(self, task):
        super().__init__()
        self.task = task
        self.cancelled = threading.Event()

    def run(self):
        try:
            result = self.task(self.cancelled.is_set, self.progress.emit)
            self.finished.emit((result, None))
        except Exception as error:
            self.finished.emit((None, error))


class _OperationReceiver(QObject):
    """Unique GUI slots receive queued data before calling window overrides."""
    def __init__(self, window):
        super().__init__(window)
        self.window = weakref.ref(window)

    @Slot(object)
    def receive_outcome(self, outcome):
        window = self.window()
        if window is not None:
            window.export_finished(outcome)

    @Slot(float)
    def receive_progress(self, value):
        window = self.window()
        if window is not None:
            window.operation_progress(value)

    @Slot()
    def receive_stopped(self):
        window = self.window()
        if window is not None:
            window.operation_stopped()


class _AssetAudio(QObject):
    """GUI device owner; only bounded completed-spool jobs run off thread.

    QAudioSink push mode copies already prepared bytes into its native buffer.
    There is no Python device callback, native decode, hash or source IO here.
    https://doc.qt.io/qt-6/qaudiosink.html#start
    """
    started = Signal(object)
    ended = Signal(object)
    failed = Signal(object)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.queue=ValueQueue(self)
        self.queue.completed.connect(self._completed)
        self.timer=QTimer(self); self.timer.setInterval(20)
        self.timer.timeout.connect(self._tick)
        self.buffer=PCMBuffer(262144)
        self.epoch=0; self.wanted=False; self.sink=None; self.output=None
        self.plan=None; self._pending=b''; self._finished=False; self._written=0
        self._active_seen=False

    def stop(self):
        self.epoch+=1; self.wanted=False; self.timer.stop()
        self.queue.discard_pending(cancel_active=True)
        self.buffer.reset(); self._pending=b''; self.plan=None
        if self.sink is not None:
            self.sink.reset(); self.sink.deleteLater()
        self.sink=self.output=None

    def start(self, session, target, volume=1.0):
        self.stop(); self.wanted=True; self.volume=volume
        epoch=self.epoch
        def prepare(cancel):
            plan=PCMPlaybackPlan(session,target,cancel)
            data,next_time,finished=plan.next_block(cancel)
            return plan,data,next_time,finished
        self.queue.submit(ValueRequest(epoch,prepare))

    def shutdown(self):
        self.stop(); self.queue.shutdown()

    @property
    def running(self): return self.sink is not None and self.wanted

    def position(self):
        if not self.running: return None
        return min(self.plan.cursor,self.plan.anchor+Fraction(self.sink.processedUSecs(),1_000_000))

    @Slot(object)
    def _completed(self, result):
        request,value,error=result
        if request.context!=self.epoch or not self.wanted: return
        if error is not None:
            self.stop(); self.failed.emit(error); return
        plan,data,next_time,finished=value
        first=self.plan is None
        self.plan=plan; self._finished=finished
        self.buffer.append(self.buffer.epoch,data)
        if first:
            if finished and not data:
                position=plan.anchor; self.stop(); self.ended.emit(position); return
            fmt=QAudioFormat()
            names={'u8':QAudioFormat.SampleFormat.UInt8,'s16':QAudioFormat.SampleFormat.Int16,
                   's32':QAudioFormat.SampleFormat.Int32,'flt':QAudioFormat.SampleFormat.Float}
            fmt.setSampleRate(plan.format['sample_rate'])
            fmt.setChannelCount(len(plan.format['channels']))
            fmt.setSampleFormat(names[plan.format['name'].removesuffix('p')])
            device=QMediaDevices.defaultAudioOutput()
            if device.isNull() or not device.isFormatSupported(fmt):
                self.stop(); self.failed.emit(TransportReview('장치에서 이 정확 PCM 형식의 재생을 지원하지 않습니다.')); return
            self.sink=QAudioSink(device,fmt,self)
            self.sink.stateChanged.connect(self._device_state)
            self.sink.setVolume(self.volume)
            self.sink.setBufferSize(min(262144,plan.format['sample_rate']*fmt.bytesPerFrame()//2))
            self.output=self.sink.start()
            if self.output is None or self.sink.error().value!=0:
                self.stop(); self.failed.emit(TransportReview('오디오 출력 장치를 시작하지 못했습니다.')); return
            self._written=0; self._device_deadline=transport_time.monotonic()+5
            self._active_seen=False
            self._tick()
            if self.running:
                self.timer.start(); self.started.emit(plan.anchor)
        self._prefetch()

    def _prefetch(self):
        if not self.wanted or self._finished or self.queue.busy or self.buffer.size()>=131072: return
        plan,epoch=self.plan,self.epoch
        def read(cancel):
            data,next_time,finished=plan.next_block(cancel)
            return plan,data,next_time,finished
        self.queue.submit(ValueRequest(epoch,read))

    @Slot(object)
    def _device_state(self,state):
        if state.name=='ActiveState': self._active_seen=True

    @Slot()
    def _tick(self):
        if not self.running: return
        if self.sink.error().value!=0:
            self.stop(); self.failed.emit(TransportReview('오디오 장치 오류로 재생을 멈췄습니다.')); return
        if not self._active_seen and transport_time.monotonic()>self._device_deadline:
            self.stop(); self.failed.emit(TransportReview('오디오 장치가 제한 시간 안에 PCM 재생을 시작하지 않았습니다.')); return
        free=self.sink.bytesFree()
        if free>0:
            if not self._pending: self._pending=self.buffer.read(min(free,65536))
            if self._pending:
                written=self.output.write(self._pending[:free])
                if written<0:
                    self.stop(); self.failed.emit(TransportReview('PCM 장치 쓰기에 실패했습니다.')); return
                self._written+=written; self._pending=self._pending[written:]
        idle=self.sink.state().name=='IdleState'
        if self.sink.state().name=='ActiveState': self._active_seen=True
        if idle and self._active_seen and not self._pending and self.buffer.size()==0 and self._written:
            if self._finished:
                end=self.plan.cursor; self.stop(); self.ended.emit(end); return
            self.stop(); self.failed.emit(TransportReview('PCM 준비가 재생을 따라가지 못해 멈췄습니다. 원본 내용 대신 무음을 만들지 않습니다.')); return
        self._prefetch()


class BlurActionWindow(QMainWindow):
    def __init__(self, workspace=None):
        super().__init__()
        if workspace is None:
            from .editor import Workspace
            workspace = Workspace()
        self.workspace = workspace
        self._refreshing = False
        self._text_editor_baseline = None
        self._text_changed_fields = set()
        self._thread = None
        self._worker = None
        self._operation_receiver = _OperationReceiver(self)
        self._outcome = None
        self._after_operation = None
        self._operation_error_handler = None
        self._discard_cancelled_result = False
        self._operation_cancelled = None
        self._project_path = None
        self._video_source_path = None
        self._video_source = None
        self._video_generation = 0
        self._video_image = QImage()
        self._video_image_source = None
        self._seek_epoch = 0
        self._paused_seek = False
        self._seek_target = None
        self._play_after_seek = False
        self._transport_time = 0.0
        self._video_pts = None
        self._last_sink_pts_us = None
        self._native_loaded = False
        self._native_seek_ms = None
        self._native_seek_sent = False
        self._deferred_operation = None
        self._closing = False
        self._asset_clock = None
        self._asset_timer = QTimer(self)
        self._asset_timer.setInterval(16)
        self._asset_timer.timeout.connect(self._asset_tick)
        self._asset_audio = _AssetAudio(self)
        self._asset_audio.started.connect(self._asset_audio_started)
        self._asset_audio.ended.connect(self._asset_audio_ended)
        self._asset_audio.failed.connect(self._asset_audio_failed)
        self._asset_audio.queue.idle.connect(self.preview_idle)
        self._operation_label = '새 파일 저장'
        self._last_find_page = None
        self._last_find_ids = set()
        self.audio = QAudioOutput(self)
        self._create_video_player()
        self.cover_color = QColor('black')
        self.drawing_color = QColor('red')
        self.setWindowTitle('BlurAction 0.9.1 Windows 성능 개선 검수 (local4)')
        self.resize(1220, 820)
        self.setAcceptDrops(True)
        self.canvas = EditorCanvas()
        self.canvas.created.connect(self.create_item)
        self.canvas.picked.connect(self.pick_item)
        self.canvas.moved.connect(self.move_items)
        self.canvas.nudged.connect(self.nudge_items)
        self._pick_context = None
        self.canvas.color_pick_requested.connect(self.start_color_pick_from_key)
        self.canvas.color_picked.connect(self.apply_picked_color)
        self.canvas.color_pick_cancelled.connect(self.color_pick_cancelled)
        self.canvas.erased.connect(self.erase_points)
        self.canvas.message.connect(lambda text: self.statusBar().showMessage(text))
        self.canvas.presented.connect(self.preview_presented)
        self.canvas.accept_guard = self.validate_preview_source
        self.canvas.preview_queue.idle.connect(self.preview_idle)
        self.actions = {}
        self._make_actions()
        self._make_layout()
        self.refresh()

    def _action(self, name, text, callback, shortcut=None):
        action = QAction(text, self)
        if shortcut:
            action.setShortcut(QKeySequence(shortcut))
        action.triggered.connect(callback)
        self.actions[name] = action
        return action

    def _make_actions(self):
        file_menu = self.menuBar().addMenu('파일(&F)')
        edit_menu = self.menuBar().addMenu('편집(&E)')
        toolbar = QToolBar('작업', self)
        toolbar.setMovable(False)
        self.addToolBar(toolbar)
        for name, label, handler, key in (
            ('open', '파일 열기…', self.open_dialog, 'Ctrl+O'),
            ('open_project', '프로젝트 열기…', self.open_project_dialog, 'Ctrl+Shift+O'),
            ('save', '프로젝트 저장…', self.save_dialog, 'Ctrl+S'),
            ('export', '내보내기…', self.export_dialog, 'Ctrl+E'),
            ('relink', '원본 다시 연결…', self.relink_dialog, None),
            ('import_items', '프로젝트 항목 가져오기…', self.import_items_dialog, 'Ctrl+Shift+I'),
            ('template', '다른 미디어에 프로젝트 적용…', self.template_dialog, None),
        ):
            action = self._action(name, label, handler, key)
            file_menu.addAction(action)
            if name in ('open', 'save', 'export'):
                toolbar.addAction(action)
        for name, label, handler, key in (
            ('undo', '실행취소', lambda: self.perform(self.workspace.undo), 'Ctrl+Z'),
            ('redo', '다시실행', lambda: self.perform(self.workspace.redo), 'Ctrl+Shift+Z'),
            ('delete', '선택 항목 삭제', lambda: self.perform(self.workspace.delete_selected), 'Delete'),
            ('duplicate', '선택 항목·그룹 복제', lambda: self.perform(self.workspace.duplicate_selected), 'Ctrl+D'),
        ):
            action = self._action(name, label, handler, key)
            edit_menu.addAction(action)
            if name in ('undo', 'redo'):
                toolbar.addAction(action)
        for name, label, callback in (
            ('front', '한 단계 앞으로', lambda: self.perform(lambda: self.workspace.reorder_selected(1))),
            ('back', '한 단계 뒤로', lambda: self.perform(lambda: self.workspace.reorder_selected(-1))),
            ('to_front', '맨 앞으로', lambda: self.perform(lambda: self.workspace.reorder_selected(len(self.workspace.items())))),
            ('to_back', '맨 뒤로', lambda: self.perform(lambda: self.workspace.reorder_selected(-len(self.workspace.items())))),
            ('group', '선택 항목 그룹', lambda: self.perform(self.workspace.group_selected)),
            ('ungroup', '그룹 풀기', lambda: self.perform(self.workspace.ungroup_selected)),
        ):
            edit_menu.addAction(self._action(name, label, callback))
        toolbar.addSeparator()
        group = QActionGroup(self)
        group.setExclusive(True)
        for tool, label in TOOLS:
            action = QAction(label, self)
            action.setCheckable(True)
            action.setChecked(tool == 'select')
            action.triggered.connect(lambda checked, name=tool: self.canvas.set_tool(name))
            group.addAction(action)
            toolbar.addAction(action)
            self.actions['tool_' + tool] = action

    def _make_layout(self):
        center = QWidget()
        center_layout = QVBoxLayout(center)
        center_layout.setContentsMargins(0, 0, 0, 0)
        center_layout.addWidget(self.canvas, 1)
        self.pager = QWidget()
        pager_layout = QHBoxLayout(self.pager)
        self.previous = QPushButton('◀ 이전')
        self.next = QPushButton('다음 ▶')
        self.page_label = QLabel('0 / 0')
        self.previous.clicked.connect(lambda: self.change_page(-1))
        self.next.clicked.connect(lambda: self.change_page(1))
        pager_layout.addWidget(self.previous)
        pager_layout.addWidget(self.page_label)
        pager_layout.addWidget(self.next)
        pager_layout.addStretch()
        center_layout.addWidget(self.pager)
        self.video_controls = QWidget()
        transport = QHBoxLayout(self.video_controls)
        self.play_button = QPushButton('▶ 재생')
        self.play_button.clicked.connect(self.toggle_playback)
        self.scrubber = QSlider(Qt.Orientation.Horizontal)
        self.scrubber.setRange(0, 0)
        self.scrubber.sliderReleased.connect(lambda: self.seek_video(self.scrubber.value() / 1000))
        self.time_label = QLabel('00:00.00 / 00:00.00')
        transport.addWidget(self.play_button)
        transport.addWidget(self.scrubber, 1)
        transport.addWidget(self.time_label)
        center_layout.addWidget(self.video_controls)
        inspector = QWidget()
        form = QFormLayout(inspector)
        form.setRowWrapPolicy(QFormLayout.RowWrapPolicy.WrapLongRows)
        form.setContentsMargins(12, 12, 12, 12)
        self.source_label = QLabel('파일을 열면 원본 정보가 표시됩니다.')
        self.source_label.setWordWrap(True)
        form.addRow(self.source_label)
        self.style = QComboBox()
        for label, value in (('블러', 'blur'), ('모자이크', 'mosaic'), ('단색', 'solid')):
            self.style.addItem(label, value)
        self.radius = QDoubleSpinBox()
        self.radius.setDecimals(6)
        self.radius.setRange(0, 500)
        self.radius.setValue(25)
        self.feather = QDoubleSpinBox()
        self.feather.setDecimals(6)
        self.feather.setRange(0, 500)
        self.feather.setValue(12)
        self.width = QDoubleSpinBox()
        self.width.setDecimals(6)
        self.width.setRange(.000001, 16000)
        self.width.setValue(4)
        self.fill = QDoubleSpinBox()
        self.fill.setDecimals(6)
        self.fill.setRange(0, 1)
        self.fill.setSingleStep(.1)
        self.eraser_width = QSpinBox()
        self.eraser_width.setRange(1, 200)
        self.eraser_width.setValue(24)
        form.addRow('가리기 방식', self.style)
        form.addRow('강도 / 칸 크기', self.radius)
        form.addRow('경계 부드럽게', self.feather)
        find_controls = QWidget()
        find_form = QFormLayout(find_controls)
        find_form.setContentsMargins(0, 0, 0, 0)
        self.find_faces_button = QPushButton('얼굴 찾기')
        self.find_text_button = QPushButton('글자 찾기')
        self.find_faces_button.clicked.connect(lambda: self.auto_find('faces'))
        self.find_text_button.clicked.connect(lambda: self.auto_find('text'))
        find_form.addRow(self.find_faces_button, self.find_text_button)
        self.find_then_track = QCheckBox('영상에서 찾은 뒤 앞뒤로 추적')
        self.find_then_track.setChecked(False)
        find_form.addRow(self.find_then_track)
        self.pick_finds_button = QPushButton('찾은 것 고르기')
        self.remove_finds_button = QPushButton('찾은 것 지우기')
        self.pick_finds_button.clicked.connect(self.select_latest_finds)
        self.remove_finds_button.clicked.connect(self.remove_latest_finds)
        find_form.addRow(self.pick_finds_button, self.remove_finds_button)
        form.addRow('자동 찾기', find_controls)
        cover_color = QPushButton('가리기 색…')
        cover_color.clicked.connect(lambda: self.choose_color(True))
        self.cover_pick = QPushButton('스포이드')
        self.cover_pick.setAccessibleName('가리기 색 스포이드')
        self.cover_pick.clicked.connect(lambda: self.start_color_pick(True))
        cover_row = QWidget()
        cover_row_layout = QHBoxLayout(cover_row)
        cover_row_layout.setContentsMargins(0, 0, 0, 0)
        cover_row_layout.addWidget(cover_color)
        cover_row_layout.addWidget(self.cover_pick)
        form.addRow(cover_row)
        drawing_color = QPushButton('그림·글자 색…')
        drawing_color.clicked.connect(lambda: self.choose_color(False))
        self.drawing_pick = QPushButton('스포이드')
        self.drawing_pick.setAccessibleName('그림·글자 색 스포이드')
        self.drawing_pick.clicked.connect(lambda: self.start_color_pick(False))
        drawing_row = QWidget()
        drawing_row_layout = QHBoxLayout(drawing_row)
        drawing_row_layout.setContentsMargins(0, 0, 0, 0)
        drawing_row_layout.addWidget(drawing_color)
        drawing_row_layout.addWidget(self.drawing_pick)
        form.addRow(drawing_row)
        form.addRow('선 굵기', self.width)
        form.addRow('채우기', self.fill)
        self.eraser_mode = QComboBox()
        self.eraser_mode.addItem('부분 지우기', 'partial')
        self.eraser_mode.addItem('닿은 항목 삭제', 'item')
        self.eraser_mode.currentIndexChanged.connect(lambda: self.refresh() if not self._refreshing else None)
        self.eraser_target = QComboBox()
        for label, target in (('영역·그림 모두', 'all'), ('가리기 영역만', 'regions'), ('그림·글자만', 'drawings')):
            self.eraser_target.addItem(label, target)
        form.addRow('지우개 방식', self.eraser_mode)
        form.addRow('지우개 대상', self.eraser_target)
        form.addRow('지우개 크기', self.eraser_width)
        self.erase_from_now = QCheckBox('영상: 지금 시점부터 지우기')
        form.addRow(self.erase_from_now)
        self.text = QPlainTextEdit()
        self.text.setPlaceholderText('여러 줄 글자')
        self.text.setMaximumHeight(100)
        form.addRow('글자', self.text)
        self.font = QComboBox()
        self.font.setSizeAdjustPolicy(QComboBox.SizeAdjustPolicy.AdjustToMinimumContentsLengthWithIcon)
        self.font.setMinimumContentsLength(12)
        self.font.addItems(QFontDatabase.families())
        default_family = QApplication.font().family()
        if self.font.findText(default_family) < 0:
            self.font.addItem(default_family)
        for request in renderer.PORTABLE_FONT_REQUESTS:
            if self.font.findText(request) < 0:
                self.font.addItem(request)
        self.font.setCurrentText(default_family)
        self.font.currentIndexChanged.connect(lambda: self._mark_text_field('fontName'))
        # Qt emits activated for an explicit same-index choice too. A null/raw
        # default may therefore be intentionally replaced by its displayed name.
        # https://doc.qt.io/qt-6/qcombobox.html#activated
        self.font.activated.connect(lambda: self._mark_text_field('fontName'))
        self.text.textChanged.connect(lambda: self._mark_text_field('text'))
        form.addRow('글꼴', self.font)
        self.font_warning = QLabel()
        self.font_warning.setWordWrap(True)
        form.addRow(self.font_warning)
        self.bold = QCheckBox('굵게')
        self.bold.setChecked(True)
        self.bold.toggled.connect(lambda: self._mark_text_field('bold'))
        form.addRow(self.bold)
        self.text_apply = QPushButton('선택 글자 내용·글꼴 적용')
        self.text_apply.clicked.connect(self.apply_text_changes)
        form.addRow(self.text_apply)
        self.layers = QListWidget()
        self.layers.setAccessibleName('레이어 목록 — 위가 앞')
        self.layers.setSelectionMode(QAbstractItemView.SelectionMode.ExtendedSelection)
        self.layers.itemSelectionChanged.connect(self.layers_changed)
        form.addRow('레이어 (위가 앞)', self.layers)
        self.layer_name = QLineEdit()
        self.layer_name.editingFinished.connect(lambda: self.update_selection(name=self.layer_name.text()))
        self.hidden = QCheckBox('숨기기')
        self.locked = QCheckBox('잠금')
        self.hidden.toggled.connect(lambda value: self.update_selection(hidden=value))
        self.locked.toggled.connect(lambda value: self.update_selection(locked=value))
        form.addRow('이름', self.layer_name)
        form.addRow(self.hidden, self.locked)
        self.position_controls = QWidget()
        position_form = QFormLayout(self.position_controls)
        position_form.setContentsMargins(0, 0, 0, 0)
        self.coordinates = []
        for label in ('X', 'Y', '너비', '높이'):
            value = QDoubleSpinBox()
            value.setDecimals(4)
            value.setRange(-16, 16)
            value.setSingleStep(.01)
            self.coordinates.append(value)
            position_form.addRow(label, value)
        position_apply = QPushButton('좌표·크기 적용')
        position_apply.clicked.connect(self.apply_position)
        position_form.addRow(position_apply)
        form.addRow(self.position_controls)
        self.time_controls = QWidget()
        time_form = QFormLayout(self.time_controls)
        time_form.setContentsMargins(0, 0, 0, 0)
        self.range_start, self.range_end = QDoubleSpinBox(), QDoubleSpinBox()
        for control in (self.range_start, self.range_end):
            control.setDecimals(3)
            control.setRange(0, 1_000_000)
        time_form.addRow('시작(초)', self.range_start)
        time_form.addRow('끝(초)', self.range_end)
        range_apply = QPushButton('구간 적용')
        range_apply.clicked.connect(self.apply_time_range)
        time_form.addRow(range_apply)
        self.record_motion = QCheckBox('움직임 기록')
        self.record_motion.toggled.connect(lambda enabled: setattr(self.workspace, 'record_motion', enabled))
        time_form.addRow(self.record_motion)
        record = QPushButton('현재 위치 기록')
        record.clicked.connect(self.record_position)
        time_form.addRow(record)
        self.keyframes = QListWidget()
        self.keyframes.setMaximumHeight(130)
        self.keyframes.itemActivated.connect(lambda item: self.seek_video(item.data(Qt.ItemDataRole.UserRole)))
        self.keyframes.currentItemChanged.connect(self.keyframe_selected)
        time_form.addRow('위치 기록', self.keyframes)
        self.keyframe_time = QDoubleSpinBox()
        self.keyframe_time.setDecimals(3)
        self.keyframe_time.setRange(0, 1_000_000)
        time_form.addRow('선택 기록 시각(초)', self.keyframe_time)
        self.retime_button = QPushButton('기록 시각 적용')
        self.retime_button.clicked.connect(self.retime_keyframe)
        time_form.addRow(self.retime_button)
        remove_key = QPushButton('선택 기록 삭제')
        remove_key.clicked.connect(self.remove_keyframe)
        time_form.addRow(remove_key)
        self.track_button = QPushButton('선택 항목 자동 추적')
        self.track_direction = QComboBox()
        for label, value in (('앞으로','forward'),('뒤로','backward'),('앞뒤로','both')):
            self.track_direction.addItem(label, value)
        self.track_direction.setCurrentIndex(2)
        time_form.addRow('추적 방향', self.track_direction)
        self.track_smoothing = QCheckBox('추적 흔들림 줄이기')
        self.track_smoothing.setChecked(True)
        self.track_reacquire = QCheckBox('놓친 얼굴 다시 찾기')
        self.track_reacquire.setChecked(True)
        time_form.addRow(self.track_smoothing)
        time_form.addRow(self.track_reacquire)
        self.track_button.clicked.connect(self.auto_track)
        time_form.addRow(self.track_button)
        form.addRow(self.time_controls)
        self.copy_all_button = QPushButton('현재 페이지 작업을 모든 페이지에 적용…')
        self.copy_all_button.clicked.connect(self.copy_all)
        form.addRow(self.copy_all_button)
        self.quality = QComboBox()
        self.quality.setAccessibleName('내보내기 화질')
        for preset in QualityPreset:
            self.quality.addItem(preset.label, preset.value)
        self.quality.setCurrentIndex(self.quality.findData(QualityPreset.HIGH.value))
        self.quality.currentIndexChanged.connect(self.update_quality_info)
        form.addRow('내보내기 화질', self.quality)
        self.quality_info = QLabel()
        self.quality_info.setWordWrap(True)
        form.addRow(self.quality_info)
        self.export_button = QPushButton('내보내기…')
        self.export_button.clicked.connect(self.export_dialog)
        self.cancel_button = QPushButton('취소')
        self.cancel_button.clicked.connect(self.cancel_operation)
        self.cancel_button.setEnabled(False)
        self.progress = QProgressBar()
        self.progress.setRange(0, 100)
        self.progress.setValue(0)
        form.addRow(self.export_button, self.cancel_button)
        form.addRow(self.progress)
        self.inspector = inspector
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setWidget(inspector)
        scroll.setMinimumWidth(280)
        split = QSplitter(Qt.Orientation.Horizontal)
        split.addWidget(center)
        split.addWidget(scroll)
        split.setStretchFactor(0, 1)
        split.setStretchFactor(1, 0)
        split.setSizes([900, 300])
        self.setCentralWidget(split)
        for control, field in ((self.style, 'style'), (self.radius, 'blurRadius'),
                               (self.feather, 'featherRadius'), (self.width, 'lineWidth'),
                               (self.fill, 'fillOpacity')):
            signal = control.currentIndexChanged if isinstance(control, QComboBox) else control.valueChanged
            signal.connect(lambda value, key=field: self.style_changed(key))

    def perform(self, task):
        if self.workspace.busy:
            return
        try:
            task()
            self.refresh()
        except Exception as error:
            self.show_error(error)

    def show_error(self, error):
        QMessageBox.warning(self, 'BlurAction', str(error))

    def _color_dict(self, color):
        return dict(zip(('red', 'green', 'blue', 'alpha'), color.getRgbF()))

    def create_item(self, tool, points):
        if self.canvas.preview_pending:
            return
        def create():
            if tool.startswith('cover_'):
                kind = tool.removeprefix('cover_')
                self.workspace.add_cover(kind, points, self.style.currentData(), self.radius.value(),
                                         self.feather.value(), self._color_dict(self.cover_color))
            else:
                self.workspace.add_drawing(tool, points, self._color_dict(self.drawing_color),
                                           self.width.value() / 1000, self.fill.value(),
                                           self.text.toPlainText(), self.font.currentText(), bold=self.bold.isChecked())
        self.perform(create)

    def erase_points(self, points):
        if self.canvas.preview_pending:
            return
        self.perform(lambda: self.workspace.erase(points, self.eraser_width.value() / 1000,
            self.workspace.time, from_now=self.erase_from_now.isChecked(),
            mode=self.eraser_mode.currentData(), target=self.eraser_target.currentData()))

    def move_items(self, dx, dy):
        if not self.canvas.preview_pending:
            self.perform(lambda: self.workspace.move_selected(dx, dy, self.workspace.time))

    def nudge_items(self, key, modifiers=Qt.KeyboardModifier.NoModifier):
        """A single source-unit transaction, scoped to canvas keyboard focus.

        Document units are page points; images/video use displayed source pixels.
        Fit/zoom and the surrounding letterbox never enter persisted coordinates.
        Group members share the bounded delta; locked members stay unchanged.
        """
        if (self.workspace.busy or self.canvas.busy or self.canvas.preview_pending
                or self.canvas._color_pick is not None
                or QApplication.focusWidget() is not self.canvas
                or QApplication.activeModalWidget() is not None
                or not self.workspace.page or not self.workspace.selected()):
            return
        allowed = Qt.KeyboardModifier.ShiftModifier | Qt.KeyboardModifier.ControlModifier
        # Enforce the bit policy with Python integers, independent of the
        # native Qt flag complement width and signedness on each platform.
        if modifiers.value & ~allowed.value:
            return
        anchor, region = self.workspace.selected()
        if (anchor['effect'] if region else anchor).get('locked', False):
            return
        page = self.workspace.page
        # Image point_size describes its PDF-export layout (normally half its
        # pixel dimensions), not the editing pixel grid. Only a PDF page uses
        # page points for keyboard movement.
        dimensions = (page.point_size if page.pdf_index is not None and page.point_size else
                      (self.canvas.image.width(), self.canvas.image.height()))
        if any(not math.isfinite(value) or value <= 0 for value in dimensions):
            return
        step = (10 if modifiers & Qt.KeyboardModifier.ShiftModifier else
                .1 if modifiers & Qt.KeyboardModifier.ControlModifier else 1)
        directions = {Qt.Key.Key_Left: (-1, 0), Qt.Key.Key_Right: (1, 0),
                      Qt.Key.Key_Up: (0, 1), Qt.Key.Key_Down: (0, -1)}
        if key not in directions:
            return
        delta = [directions[key][axis] * step / dimensions[axis] for axis in range(2)]
        identities = self.workspace._selected_ids_with_groups()
        rectangles = []
        for item, is_region in self.workspace.items():
            target = item['effect'] if is_region else item
            if self.workspace.item_id(item, is_region) not in identities or target.get('locked', False):
                continue
            shown = renderer.positioned(item, is_region, self.workspace.time)
            points = renderer.shape_points(shown)[1] if is_region else shown['points']
            rectangles.append(renderer.bounds(points))
        if not rectangles:
            return
        for axis in range(2):
            lower = -min(rect[axis] for rect in rectangles)
            upper = 1 - max(rect[axis] + rect[axis + 2] for rect in rectangles)
            # Imported off-page geometry may move toward the page gradually;
            # do not teleport it or alter its shape to make it fit.
            delta[axis] = max(min(0, lower), min(max(0, upper), delta[axis]))
        if not any(delta):
            return  # Boundary/locked no-ops do not create an undo entry.
        self._pause_asset()
        self.player.pause()
        self.perform(lambda: self.workspace.move_selected(*delta, self.workspace.time))

    def update_quality_info(self, *_):
        preset = QualityPreset(self.quality.currentData())
        page, video = self.workspace.page, self.workspace.video
        if not page:
            self.quality_info.setText('파일을 열면 출력 사양이 표시됩니다.')
            return
        if not video:
            self.quality_info.setText('PDF·PNG·TIFF: 평탄화 출력 · JPEG·HEIC: 압축 품질 '
                                      f'{preset.image_quality}%')
            return
        if preset == QualityPreset.ORIGINAL:
            target = '원본 비트레이트 기준 (최소 0.50 Mb/s)'
        else:
            try:
                image = getattr(video, '_first_image', self.canvas.image)
                rate = output_bit_rate(preset, 0, float(getattr(video, 'average_rate', None) or 0),
                                       image.width(), image.height())
                target = f'목표 {rate / 1_000_000:.2f} Mb/s'
            except ValueError:
                target = '영상 정보 확인 필요'
        self.quality_info.setText(f'H.264 · {target} · 원본 화질도 재인코딩\n오디오는 원본 형식·시간 보존')

    def apply_position(self):
        if not self.canvas.preview_pending:
            self.perform(lambda: self.workspace.resize_selected(
                [control.value() for control in self.coordinates], self.workspace.time))

    def missing_fonts(self):
        families = {family.lower() for family in QFontDatabase.families()}
        return [(index + 1, item['fontName']) for index, page in enumerate(self.workspace.pages)
                for item in page.state['drawings']
                if item['kind'] == 'text' and not item.get('hidden', False)
                and not font_available(item.get('fontName'), families)]

    def pick_item(self, identity):
        self.workspace.selectionID = identity
        self.refresh()

    def layers_changed(self):
        if self._refreshing or self.workspace.busy:
            return
        selected = self.layers.selectedItems()
        self.workspace.selection_ids = {item.data(Qt.ItemDataRole.UserRole) for item in selected}
        self.canvas.selection_ids = set(self.workspace.selection_ids)
        self.refresh()

    def update_selection(self, **properties):
        if not self._refreshing and self.workspace.selectionID:
            self.perform(lambda: self.workspace.update_selected(**properties))

    def _mark_text_field(self, key):
        if not self._refreshing:
            self._text_changed_fields.add(key)

    def _selected_text_for_inspector(self):
        texts = [item for item, region in self.workspace.items()
                 if not region and item['kind'] == 'text' and item['id'] in self.workspace.selection_ids]
        unlocked = [item for item in texts if not item.get('locked', False)]
        choices = unlocked or texts
        return next((item for item in choices if item['id'] == self.workspace.selectionID),
                    choices[0] if choices else None)

    def _text_context(self, representative):
        def raw(item, key):
            return key in item, item.get(key)
        # A different selected text or lock state can change the transaction
        # target without changing the representative's displayed properties.
        targets = tuple((item['id'], item['kind'], raw(item, 'locked'),
                         tuple(raw(item, key) for key in ('text', 'fontName', 'bold')))
                        for item, region in self.workspace.items()
                        if not region and item['id'] in self.workspace.selection_ids)
        return (id(self.workspace.page), self.workspace.index,
                tuple(sorted(self.workspace.selection_ids)), representative['id'], targets)

    def apply_text_changes(self):
        if self._refreshing or self.workspace.busy:
            return
        item = self._selected_text_for_inspector()
        if item is None or item.get('locked', False):
            return
        if self._text_context(item) != self._text_editor_baseline:
            self.refresh()
            return
        values = {'text': self.text.toPlainText(), 'fontName': self.font.currentText(),
                  'bold': self.bold.isChecked()}
        properties = {key: values[key] for key in self._text_changed_fields}
        if not properties:
            return
        def apply():
            self.workspace.apply_text_properties(**properties)
            self._text_changed_fields.clear()
        self.perform(apply)

    def style_changed(self, field):
        if self._refreshing:
            return
        chosen = self.workspace.selected()
        if not chosen:
            return
        controls = {'style': self.style, 'blurRadius': self.radius,
                    'featherRadius': self.feather, 'lineWidth': self.width,
                    'fillOpacity': self.fill}
        region_fields = {'style', 'blurRadius', 'featherRadius'}
        if chosen[1] != (field in region_fields):
            return
        control = controls[field]
        value = control.currentData() if field == 'style' else control.value()
        if field == 'lineWidth':
            value /= 1000
        # A rounded inspector display must never rewrite untouched project data.
        self.update_selection(**{field: value})

    def choose_color(self, cover):
        if self.workspace.busy:
            return
        self.canvas.cancel_color_pick()
        value = QColorDialog.getColor(self.cover_color if cover else self.drawing_color,
                                      self, '가리기 색' if cover else '그림·글자 색',
                                      QColorDialog.ColorDialogOption.ShowAlphaChannel)
        if value.isValid():
            self.apply_color(cover, value)

    def apply_color(self, cover, value):
        if self.workspace.busy or not value.isValid():
            return
        if cover:
            self.cover_color = QColor(value)
        else:
            self.drawing_color = QColor(value)
        if self.workspace.page:
            self.perform(lambda: self.workspace.set_selected_color(self._color_dict(value), cover))

    def start_color_pick_from_key(self):
        if QApplication.focusWidget() is not self.canvas:
            return
        chosen = self.workspace.selected()
        cover = chosen[1] if chosen else self.canvas.tool.startswith('cover_') or self.canvas.tool == 'select'
        self.start_color_pick(cover)

    def _update_color_pick_buttons(self):
        enabled = bool(self.workspace.page and not self.workspace.busy and not self.canvas.busy
                       and not self.canvas.preview_pending and not self.canvas.preview_queue.busy)
        for button in (self.cover_pick, self.drawing_pick):
            button.setEnabled(enabled)

    def start_color_pick(self, cover):
        if (self.workspace.busy or not self.workspace.page or self.canvas.busy
                or self.canvas.preview_pending or self.canvas.preview_queue.busy
                or QApplication.activeModalWidget() is not None
                or self.canvas._stroke or self.canvas._drag_start is not None):
            return False
        self._play_after_seek = False
        self._pause_asset()
        self.player.pause()
        if not self.canvas.arm_color_pick():
            return False
        self._pick_context = (cover, self.workspace.page, self._video_generation, self._seek_epoch,
                              frozenset(self.workspace.selection_ids), self.workspace.time,
                              deepcopy(self.workspace.page.state))
        self.statusBar().showMessage('캔버스의 합성 색을 클릭하세요. Esc로 취소합니다.')
        return True

    def color_pick_cancelled(self, reason):
        self._pick_context = None
        self.statusBar().showMessage(reason)

    def apply_picked_color(self, color):
        context, self._pick_context = self._pick_context, None
        if context is None:
            return
        cover, page, generation, epoch, selection, stamp, state = context
        if (self.workspace.busy or self.workspace.page is not page or generation != self._video_generation
                or epoch != self._seek_epoch or selection != frozenset(self.workspace.selection_ids)
                or stamp != self.workspace.time or state != self.workspace.page.state
                or QApplication.activeModalWidget() is not None):
            self.statusBar().showMessage('작업 또는 선택이 바뀌어 색 고르기를 취소했습니다.')
            return
        self.apply_color(cover, color)
        self.statusBar().showMessage('색을 가져왔습니다.')

    def _create_video_player(self):
        self.player = QMediaPlayer(self)
        self.player.setAudioOutput(self.audio)
        self.video_sink = QVideoSink(self)
        self.player.setVideoSink(self.video_sink)
        generation = self._video_generation
        self.video_sink.videoFrameChanged.connect(
            lambda frame: self.video_frame_changed(frame, generation))
        self.player.positionChanged.connect(
            lambda milliseconds: self.playback_position_changed(milliseconds, generation))
        self.player.mediaStatusChanged.connect(
            lambda status: self.playback_media_status_changed(status, generation))
        self.player.seekableChanged.connect(
            lambda available: self._apply_native_seek(generation))
        self.player.errorOccurred.connect(lambda error, text:
            self.statusBar().showMessage('영상 재생 오류: ' + text)
            if generation == self._video_generation else None)

    def _sync_video_source(self, page):
        video = self.workspace.video
        path = str(page.source) if video and page else None
        if self._video_source is video and self._video_source_path == path:
            return
        # A committed engine source, even at the same path, starts a separate
        # playback pipeline. Queued old sink/player callbacks cannot paint it.
        previous=self._video_source
        self._pause_asset()
        self._video_source = video
        self._video_source_path = path
        self._video_image = QImage()
        self._video_image_source = None
        self._video_pts = None
        self._transport_time = 0.0
        self._seek_epoch += 1
        self._paused_seek = False
        self._seek_target = None
        self._play_after_seek = False
        session=getattr(video,'asset_session',None)
        self._asset_clock=AssetClock(session.duration) if session is not None else None
        if self._asset_clock is not None:
            self._asset_clock.seek(video.first_frame_time)
            self._transport_time=float(self._asset_clock.anchor)
        self._replace_video_player(None if session is not None else path)
        if previous is not None and previous is not video:
            close=getattr(previous,'close_asset_transport',None)
            if close is not None: close()

    def _pause_asset(self):
        clock=self._asset_clock
        if clock is not None:
            position=self._asset_audio.position()
            if position is None: position=clock.position()
            clock.seek(min(clock.duration,position))
            self._transport_time=float(clock.anchor)
        self._asset_timer.stop(); self._asset_audio.stop()

    @Slot(object)
    def _asset_audio_started(self,anchor):
        if self._asset_clock is None or not self._play_after_seek or self._closing: return
        self._asset_clock.seek(anchor); self._asset_clock.play()
        self._play_after_seek=False; self._paused_seek=False
        self._asset_timer.start(); self.play_button.setText('⏸ 일시정지')

    @Slot(object)
    def _asset_audio_ended(self,position):
        if self._asset_clock is None or self._closing or self.workspace.busy: return
        # The track's exact scheduled end is not the video's asset end.
        self._asset_clock.seek(position); self._asset_clock.play()
        self._play_after_seek=False; self._paused_seek=False
        self._asset_timer.start(); self.play_button.setText('⏸ 일시정지')

    @Slot(object)
    def _asset_audio_failed(self,error):
        self._play_after_seek=False
        self._pause_asset()
        self.play_button.setText('▶ 재생')
        self.statusBar().showMessage(str(error))

    @Slot()
    def _asset_tick(self):
        clock=self._asset_clock
        if clock is None or not clock.playing or self.workspace.busy or self._closing: return
        try:
            # Frame IO and the GUI acceptance guard validate the source. Avoid
            # repeating filesystem work on every clock tick while decoding.
            position=self._asset_audio.position()
            if position is None: position=clock.position()
            position=min(clock.duration,position)
            self._transport_time=float(position)
            if not self.scrubber.isSliderDown(): self.scrubber.setValue(round(self._transport_time*1000))
            self.time_label.setText(f'{self._transport_time:.2f} / {self.workspace.video.duration:.2f} 초')
            if not self.canvas.preview_queue.busy:
                self.canvas.preview_context=(self._video_generation,id(self.workspace.page),self._seek_epoch)
                self.canvas.request_video_seek(self.workspace.video,position,self.workspace.page.state,
                                                 self.workspace.selection_ids,playback=True)
            if position==clock.duration:
                self._pause_asset(); self.play_button.setText('▶ 재생')
        except Exception as error:
            self._asset_audio_failed(error)

    def _replace_video_player(self, path):
        # A backwards seek makes timestamp-only rejection ambiguous. A fresh
        # sink also invalidates queued callbacks from the old same-source item.
        self._video_generation += 1
        self._last_sink_pts_us = None
        self._native_loaded = False
        self._native_seek_ms = 0 if path is not None else None
        self._native_seek_sent = False
        self._play_after_seek = False
        old_player, old_sink = self.player, self.video_sink
        old_player.stop()
        old_player.setSource(QUrl())
        old_player.deleteLater()
        old_sink.deleteLater()
        self._create_video_player()
        self.play_button.setText('▶ 재생')
        if path is not None:
            self.player.setSource(QUrl.fromLocalFile(path))

    def _request_native_seek(self, seconds):
        if self._asset_clock is not None: return
        self._native_seek_ms = round(seconds * 1000)
        self._native_seek_sent = False
        self._apply_native_seek(self._video_generation)

    def playback_media_status_changed(self, status, generation):
        if self._asset_clock is not None: return
        if generation != self._video_generation or self._closing:
            return
        self._native_loaded = status in (QMediaPlayer.MediaStatus.LoadedMedia,
            QMediaPlayer.MediaStatus.BufferingMedia, QMediaPlayer.MediaStatus.BufferedMedia)
        if status == QMediaPlayer.MediaStatus.InvalidMedia:
            self._play_after_seek = False
            self._native_seek_ms = None
            self._native_seek_sent = False
            self.play_button.setText('▶ 재생')
            return
        self._apply_native_seek(generation)

    def _apply_native_seek(self, generation):
        if generation != self._video_generation or self._closing or not self._native_loaded:
            return
        if self._native_seek_ms is None:
            self._try_start_playback()
            return
        if not self.player.isSeekable():
            return  # A later seekableChanged signal retries; no sleep or guessed delay.
        target = self._native_seek_ms
        if not self._native_seek_sent:
            self._native_seek_sent = True  # setPosition can synchronously emit positionChanged.
            self.player.setPosition(target)
        if self._native_seek_ms == target and self.player.position() == target:
            self._native_seek_ms = None
            self._native_seek_sent = False
        self._try_start_playback()

    def _try_start_playback(self):
        if self._asset_clock is not None:
            if (not self._play_after_seek or self._closing or self.workspace.busy
                    or self._seek_target is not None or self.canvas.preview_pending): return
            session=self.workspace.video.asset_session
            if session.metadata['audioTracks']:
                if not self._asset_audio.wanted:
                    self._asset_audio.start(session,self._asset_clock.anchor,self.audio.volume())
            else:
                self._play_after_seek=False; self._paused_seek=False
                self._asset_clock.play(); self._asset_timer.start()
                self.play_button.setText('⏸ 일시정지')
            return
        if (not self._play_after_seek or self._closing or self.workspace.busy
                or not self.workspace.video or not self._native_loaded
                or self._native_seek_ms is not None or self._seek_target is not None
                or self.canvas.preview_pending):
            return
        self._play_after_seek = False
        self._paused_seek = False
        self.player.play()
        self.play_button.setText('⏸ 일시정지')

    def refresh(self):
        self._refreshing = True
        page = self.workspace.page
        if self.workspace.busy:
            self.canvas.cancel_color_pick('작업 시작으로 색 고르기를 취소했습니다.')
        selected = self.workspace.selectionID
        self._sync_video_source(page)
        try:
            if self.workspace.video and self._video_image_source is self.workspace.video and not self._video_image.isNull():
                image = self._video_image
            elif self.workspace.busy and page and self.canvas.state is page.state and not self.canvas.image.isNull():
                image = self.canvas.image  # An IO worker must not cause a GUI cache-miss decode.
            else:
                image = page.image if page else QImage()
        except (ValueError, RuntimeError, OSError) as error:
            image = QImage()
            self.statusBar().showMessage(str(error))
        self.canvas.preview_context = (self._video_generation, id(page), self._seek_epoch)
        shown_time = self._video_pts if self.workspace.video and self._video_pts is not None else self.workspace.time
        if self.workspace.video and self._seek_target is not None:
            self.canvas.request_video_seek(self.workspace.video, self._seek_target,
                                          page.state, self.workspace.selection_ids)
        else:
            self.canvas.set_document(image, page.state if page else {}, self.workspace.selection_ids, shown_time)
        count = len(self.workspace.pages)
        self.page_label.setText(f'{self.workspace.index + 1 if count else 0} / {count}')
        self.previous.setEnabled(bool(count and self.workspace.index > 0 and not self.workspace.busy))
        self.next.setEnabled(bool(count and self.workspace.index + 1 < count and not self.workspace.busy))
        self.copy_all_button.setEnabled(count > 1 and not self.workspace.busy)
        self.source_label.setText(str(page.source.name) if page else '파일을 열면 원본 정보가 표시됩니다.')
        self.layers.clear()
        chosen = None
        if page:
            for is_region, items in ((False, page.state['drawings']), (True, page.state['regions'])):
                for item in reversed(items):
                    properties = item['effect'] if is_region else item
                    identity = item_identity(item, is_region)
                    label = properties.get('name') or ('가리기 영역' if is_region else dict(TOOLS).get(item['kind'], '그림'))
                    if properties.get('hidden') or not properties.get('enabled', True):
                        label += ' · 숨김'
                    if properties.get('locked'):
                        label += ' · 잠금'
                    row = QListWidgetItem(label)
                    row.setData(Qt.ItemDataRole.UserRole, identity)
                    self.layers.addItem(row)
                    if identity in self.workspace.selection_ids:
                        row.setSelected(True)
                    if identity == selected:
                        chosen = properties
        self.layer_name.setText(chosen.get('name', '') if chosen else '')
        self.hidden.setChecked(bool(chosen and (chosen.get('hidden') or not chosen.get('enabled', True))))
        self.locked.setChecked(bool(chosen and chosen.get('locked')))
        self.layer_name.setEnabled(chosen is not None)
        self.hidden.setEnabled(chosen is not None)
        self.locked.setEnabled(chosen is not None)
        current = self.workspace.selected()
        if current:
            item, region = current
            shown = renderer.positioned(item, region, self.workspace.time)
            points = renderer.shape_points(shown)[1] if region else shown['points']
            for control, value in zip(self.coordinates, renderer.bounds(points)):
                control.setValue(value)
            if region:
                self.style.setCurrentIndex(max(0, self.style.findData(chosen.get('style', 'blur'))))
                self.radius.setValue(chosen.get('blurRadius', 25))
                self.feather.setValue(chosen.get('featherRadius', 12))
            else:
                self.width.setValue(chosen.get('lineWidth', .004) * 1000)
                self.fill.setValue(chosen.get('fillOpacity', 0))
            interval = chosen.get('timeRange', [0, 0])
            self.range_start.setValue(interval[0])
            self.range_end.setValue(interval[1])
        text_item = self._selected_text_for_inspector()
        if text_item is not None:
            baseline = self._text_context(text_item)
            # Keep unapplied choices only while their complete edit context
            # remains current. Loading the panel never changes raw null/defaults.
            if self._text_editor_baseline != baseline:
                family = text_item.get('fontName') or QApplication.font().family()
                self.text.setPlainText(text_item.get('text') or '')
                if self.font.findText(family) < 0:
                    self.font.addItem(family)
                self.font.setCurrentText(family)
                self.bold.setChecked(renderer.text_bold(text_item))
                self._text_editor_baseline = baseline
                self._text_changed_fields.clear()
        else:
            self._text_editor_baseline = None
            self._text_changed_fields.clear()
        text_controls_enabled = not self.workspace.busy and not (text_item and text_item.get('locked', False))
        for control in (self.text, self.font, self.bold):
            control.setEnabled(text_controls_enabled)
        self.text_apply.setEnabled(text_item is not None and text_controls_enabled)
        self.position_controls.setEnabled(current is not None and not self.workspace.busy)
        prior_keyframe = self.keyframes.currentItem()
        prior_time = prior_keyframe.data(Qt.ItemDataRole.UserRole) if prior_keyframe else None
        self.keyframes.clear()
        for frame in chosen.get('keyframes', []) if chosen else []:
            row = QListWidgetItem(f"{frame['time']:.3f} 초")
            row.setData(Qt.ItemDataRole.UserRole, frame['time'])
            self.keyframes.addItem(row)
            if frame['time'] == prior_time:
                self.keyframes.setCurrentItem(row)
        if self.keyframes.count() and self.keyframes.currentItem() is None:
            self.keyframes.setCurrentRow(0)
        video = self.workspace.video
        self.keyframe_time.setMaximum(video.duration if video else 1_000_000)
        self.keyframe_time.setEnabled(bool(video and self.keyframes.currentItem() and not self.workspace.busy))
        self.retime_button.setEnabled(self.keyframe_time.isEnabled())
        self.video_controls.setVisible(video is not None)
        self.time_controls.setVisible(video is not None)
        self.pager.setVisible(video is None)
        self.erase_from_now.setVisible(video is not None)
        self.erase_from_now.setEnabled(bool(video and not self.workspace.busy))
        self.track_button.setEnabled(bool(video and selected and not self.workspace.busy))
        can_find = bool(page and not self.workspace.busy and not self.canvas.preview_pending)
        self.find_faces_button.setEnabled(can_find)
        self.find_text_button.setEnabled(can_find)
        self.find_then_track.setVisible(video is not None)
        recent = bool(self._last_find_page is page and self._last_find_ids and not self.workspace.busy)
        self.pick_finds_button.setEnabled(recent)
        self.remove_finds_button.setEnabled(recent)
        if video:
            self.scrubber.setRange(0, round(video.duration * 1000))
            self.time_label.setText(f'{self._transport_time:.2f} / {video.duration:.2f} 초')
        for name, action in self.actions.items():
            action.setEnabled(not self.workspace.busy and (bool(page) if name not in ('open', 'open_project', 'template') else True))
        self.export_button.setEnabled(bool(page) and not self.workspace.busy)
        self.quality.setEnabled(bool(page) and not self.workspace.busy)
        self._update_color_pick_buttons()
        self.update_quality_info()
        self.actions['delete'].setEnabled(bool(selected) and not self.workspace.busy)
        self.actions['duplicate'].setEnabled(bool(selected) and not self.workspace.busy)
        reorderable = any(self.workspace.item_id(item, region) in self.workspace.selection_ids
                          and not (item['effect'] if region else item).get('locked', False)
                          for item, region in self.workspace.items())
        for name in ('front', 'back', 'to_front', 'to_back'):
            self.actions[name].setEnabled(reorderable and not self.workspace.busy)
        self.actions['undo'].setEnabled(self.workspace.can_undo)
        self.actions['redo'].setEnabled(self.workspace.can_redo)
        self.canvas.busy = self.workspace.busy or self.canvas.preview_pending
        missing = self.missing_fonts()
        self.font_warning.setText('이 PC에 없는 글꼴: ' + ', '.join(sorted({name for _, name in missing}))
            + '\n미리보기의 대체 글꼴은 배치를 바꿀 수 있습니다. 설치된 글꼴을 선택하고 적용한 뒤 출력하세요.' if missing else '')
        self.font_warning.setVisible(bool(missing))
        self.setWindowTitle((self.workspace.title + ' — ' if page else '') + 'BlurAction 0.9.1 Windows 성능 개선 검수 (local4)')
        self._refreshing = False

    def change_page(self, offset):
        if self.workspace.busy or not self.workspace.pages:
            return
        snapshot = self.workspace.clone_for_io()
        snapshot._undo, snapshot._redo = deepcopy(self.workspace._undo), deepcopy(self.workspace._redo)
        snapshot.selection_ids = set(self.workspace.selection_ids)
        snapshot.record_motion = self.workspace.record_motion
        index = max(0, min(len(snapshot.pages) - 1, snapshot.index + offset))
        if index == snapshot.index:
            return
        def change(candidate, cancel):
            candidate.__dict__.update(snapshot.__dict__)
            candidate.set_page(index)
        self._prepare_workspace(change, self._project_path)

    def open_paths(self, paths):
        if self.workspace.busy:
            self.statusBar().showMessage('작업이 끝나거나 취소한 뒤 파일을 열어 주세요.')
            return
        if not self.confirm_discard():
            return
        paths = [Path(path) for path in paths]
        self._prepare_workspace(lambda candidate, cancel: candidate.load(paths, cancel=cancel), None)

    def _prepare_workspace(self, prepare, project_path, on_error=None):
        from .editor import Workspace
        from .media import check_cancel, page_image, validate_source_identities
        if self.workspace.busy:
            return
        operating_video=self.workspace.video

        def task(cancel, progress):
            candidate = Workspace()
            try:
                from .video import asset_transport_load
                with asset_transport_load(): prepare(candidate, cancel)
                check_cancel(cancel)
                enable=getattr(candidate.video,'enable_asset_transport',None)
                if enable is not None: enable(cancel)
                # Keep only the displayed page alive across worker/cache handoff.
                if candidate.page:
                    if getattr(candidate.video,'asset_session',None) is not None:
                        candidate.page._image=candidate.video._first_image.copy()
                    else: candidate.page._image = page_image(candidate.page, cancel)
                    image = candidate.page._image
                    time = float(candidate.video.first_frame_time) if candidate.video else None
                    if time is not None and (not math.isfinite(time) or not 0 <= time < candidate.video.duration):
                        raise ValueError('첫 프레임의 실제 PTS가 올바르지 않습니다.')
                    pixels = renderer.render(image, candidate.page.state, time)
                    check_cancel(cancel)
                    validate_source_identities(candidate.pages)
                    if candidate.video: candidate.video.validate(cancel)
                else: raise ValueError('표시할 첫 페이지가 없습니다.')
                check_cancel(cancel)
                return candidate, image, pixels, time
            except BaseException:
                close=getattr(candidate.video,'close_asset_transport',None)
                if close is not None and candidate.video is not operating_video: close()
                raise

        def commit(prepared):
            candidate, image, pixels, time = prepared
            validate_source_identities(candidate.pages)  # Cheap metadata-only GUI guard.
            self.workspace.adopt(candidate)
            self.workspace.time = time
            self._seek_target = None
            self._project_path = Path(project_path) if project_path is not None else None
            self._sync_video_source(candidate.page)
            self._video_pts = time
            self._transport_time = time or 0.0
            if candidate.video:
                if self._asset_clock is not None:
                    self._asset_clock.seek(candidate.video.first_frame_time)
                self._request_native_seek(self._transport_time)
            context = (self._video_generation, id(candidate.page), self._seek_epoch)
            self.canvas.accept_prepared(image, candidate.page.state, pixels, time, context)
            self.refresh()  # Invalidate the old player before any nested review dialog.
            if candidate.review_required:
                QMessageBox.warning(self, '이전 PDF 편집 확인 필요',
                    '이전 PDF 좌표 방식의 편집은 확인이 필요합니다.\n'
                    + '\n'.join(map(str, candidate.review_required)))

        self._after_operation = commit
        self._operation_error_handler = on_error
        self._discard_cancelled_result = True
        self._operation_label = '원본과 프로젝트 준비'
        self.start_export(task)

    def open_dialog(self):
        paths, _ = QFileDialog.getOpenFileNames(self, 'PDF·이미지·영상 열기', '', '미디어 파일 (*)')
        if paths:
            self.open_paths(paths)

    def open_project_dialog(self):
        path, _ = QFileDialog.getOpenFileName(self, '프로젝트 열기', '', 'BlurAction 프로젝트 (*.bluraction)')
        if path:
            self.open_project(Path(path))

    def save_dialog(self):
        if self.workspace.busy or not self.workspace.page:
            return
        path, _ = QFileDialog.getSaveFileName(self, '프로젝트를 새 파일로 저장',
                                             safe_stem(self.workspace.title, '.bluraction'),
                                             'BlurAction 프로젝트 (*.bluraction)')
        if path:
            try:
                snapshot = self.workspace.clone_for_io()
            except Exception as error:
                self.show_error(error)
                return

            def save(cancel, progress):
                snapshot.save_project(Path(path), cancel=cancel)
                return snapshot

            def saved(candidate):
                from .media import validate_source_identities
                try:
                    validate_source_identities(candidate.pages)
                except Exception as error:
                    error.completed_outputs = [Path(path)]
                    raise
                self.workspace._project_tree = deepcopy(candidate._project_tree)
                self.workspace.dirty = False
                self._project_path = Path(path)

            self._after_operation = saved
            self._operation_label = '프로젝트 저장'
            self.start_export(save)

    def relink_dialog(self):
        if self._project_path:
            self.open_project(self._project_path)
        else:
            self.open_project_dialog()

    def choose_item_project(self):
        path, _ = QFileDialog.getOpenFileName(self, '항목을 가져올 프로젝트 선택', '',
                                            'BlurAction 프로젝트 (*.bluraction)')
        if not path:
            return None
        # Use the same bounded decoder/review gate as the actual engine action.
        project = self.workspace._read_project(Path(path))
        tree = project.to_dict()
        index = 0
        if project.version == 2 and len(tree['pages']) > 1:
            number, accepted = QInputDialog.getInt(self, '프로젝트 페이지 선택',
                f"가져올 페이지 (1–{len(tree['pages'])})", int(tree.get('currentIndex', 0)) + 1,
                1, len(tree['pages']), 1)
            if not accepted:
                return None
            index = number - 1
        return Path(path), index

    def import_items_dialog(self):
        if self.workspace.busy or not self.workspace.page:
            return
        try:
            chosen = self.choose_item_project()
            if chosen:
                self.import_item_project(chosen[0], chosen[1])
        except Exception as error:
            self.show_error(error)

    def import_item_project(self, path, page_index=0):
        """Worker-owned verification; a single prepared edit transaction.

        Source is borrowed: success/failure must not retire the playing session.
        Existing exact presented time, histories and source identity survive.
        """
        if self.workspace.busy or not self.workspace.page:
            return
        from .media import check_cancel, validate_source_identities
        operating_video=self.workspace.video
        candidate=self.workspace.clone_for_io()
        candidate._undo=deepcopy(self.workspace._undo)
        candidate._redo=deepcopy(self.workspace._redo)
        candidate.selection_ids=set(self.workspace.selection_ids)
        candidate.record_motion=self.workspace.record_motion
        # Own a Qt value copy; never cause a GUI-thread cache-miss decode.
        candidate.page._image=QImage(self.canvas.image)

        def prepare(cancel, progress):
            candidate.import_project_items(path,page_index,cancel=cancel)
            validate_source_identities(candidate.pages)
            check_cancel(cancel)
            return candidate

        def commit(prepared):
            if self.workspace.video is not operating_video:
                raise ValueError('항목 준비 중 원본 작업이 변경되었습니다.')
            validate_source_identities(prepared.pages)
            self.workspace.adopt(prepared)

        self._after_operation=commit
        self._discard_cancelled_result=True
        self._operation_label='프로젝트 항목 가져오기'
        self.start_export(prepare)

    def template_dialog(self):
        if self.workspace.busy or not self.confirm_discard():
            return
        path, _ = QFileDialog.getOpenFileName(self, '항목을 가져올 프로젝트 선택', '',
                                            'BlurAction 프로젝트 (*.bluraction)')
        if not path:
            return
        project_path = Path(path)

        def inspect(cancel, progress):
            from .media import check_cancel
            check_cancel(cancel)
            tree = self.workspace._read_project(project_path, cancel=cancel).to_dict()
            check_cancel(cancel)
            return tree

        def choose(tree):
            index = 0
            if tree['version'] == 2 and len(tree['pages']) > 1:
                number, accepted = QInputDialog.getInt(self, '프로젝트 페이지 선택',
                    f"가져올 페이지 (1–{len(tree['pages'])})", int(tree.get('currentIndex', 0)) + 1,
                    1, len(tree['pages']), 1)
                if not accepted:
                    return
                index = number - 1
            paths, _ = QFileDialog.getOpenFileNames(self, '프로젝트 항목을 적용할 새 미디어', '', '미디어 파일 (*)')
            if not paths:
                return
            media_paths = tuple(Path(media_path) for media_path in paths)
            self._prepare_workspace(lambda candidate, cancel, project_path=project_path,
                media_paths=media_paths, page_index=index: candidate.apply_project_template(
                    project_path, media_paths, page_index, cancel=cancel), None)

        self._after_operation = choose
        self._discard_cancelled_result = True
        self._operation_label = '템플릿 확인'
        self.start_export(inspect)

    def open_project(self, path):
        if self.workspace.busy or not self.confirm_discard():
            return
        self._prepare_project(Path(path), {}, set())

    def _prepare_project(self, path, relinks, acknowledged):
        from .editor import MissingSources, UnverifiedSources

        def failed(error):
            # This runs only on the GUI thread after the worker has stopped.
            if isinstance(error, MissingSources):
                for reference in error.references:
                    replacement, _ = QFileDialog.getOpenFileName(self, '원본 다시 연결: ' + reference, '', '원본 파일 (*)')
                    if not replacement:
                        return True
                    relinks[reference] = replacement
            elif isinstance(error, UnverifiedSources):
                reply = QMessageBox.question(self, '원본 지문이 없는 이전 프로젝트',
                    '이 프로젝트에는 원본 SHA-256 지문이 없어 선택한 파일이 같은 원본인지 증명할 수 없습니다.\n'
                    + '\n'.join(error.references)
                    + '\n원본 내용과 가림 위치를 직접 확인해야 합니다. 이 조건을 알고 편집을 불러올까요?',
                    QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
                    QMessageBox.StandardButton.No)
                if reply != QMessageBox.StandardButton.Yes:
                    return True
                acknowledged.update(error.references)
            else:
                return False
            self._prepare_project(path, relinks, acknowledged)
            return True

        self._prepare_workspace(lambda candidate, cancel: candidate.load_project(
            path, dict(relinks), acknowledged_unverified=set(acknowledged), cancel=cancel), path, failed)

    def copy_all(self):
        reply = QMessageBox.question(self, '전체 페이지에 적용',
                                     '다른 페이지의 기존 편집을 현재 페이지 편집으로 바꿉니다. 적용할까요?',
                                     QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
                                     QMessageBox.StandardButton.No)
        if reply == QMessageBox.StandardButton.Yes:
            self.perform(self.workspace.copy_all)

    def export_dialog(self):
        if self.workspace.busy or not self.workspace.page:
            return
        missing = self.missing_fonts()
        if missing:
            self.show_error('출력 전에 없는 글꼴을 확인하세요. 원래 글꼴 이름은 보존되어 있습니다.\n'
                + '\n'.join(f'{page}페이지: {name}' for page, name in sorted(set(missing)))
                + '\n설치된 글꼴을 선택하고 「선택 글자 내용·글꼴 적용」을 눌러 주세요.')
            return
        if self.workspace.video:
            path, _ = QFileDialog.getSaveFileName(self, '영상 새 파일로 내보내기',
                                                  safe_stem(self.workspace.title, '_blurred.mp4'),
                                                  'MP4 영상 (*.mp4);;MOV 영상 (*.mov)')
            if path:
                from .video import export_video
                source, state = self.workspace.video, deepcopy(self.workspace.page.state)
                quality = QualityPreset(self.quality.currentData())
                self.start_export(lambda cancel, progress: export_video(source, state, Path(path), cancel, progress,
                                                                       quality=quality))
            return
        pdf = len(self.workspace.pages) > 1 or self.workspace.page.pdf_index is not None
        filters = '평탄화 PDF (*.pdf)' if pdf else 'PNG 이미지 (*.png);;JPEG 이미지 (*.jpg);;HEIC 이미지 (*.heic);;TIFF 이미지 (*.tiff)'
        ending = '.pdf' if pdf else '.png'
        path, selected = QFileDialog.getSaveFileName(self, '새 파일로 내보내기',
                                                    safe_stem(self.workspace.title, '_blurred' + ending), filters)
        if not path:
            return
        # Freeze edits, not hundreds of decoded pages. Workers lazily decode
        # immutable, hash-checked source metadata through the bounded cache.
        pages = [Page(page.source, page.source_sha256, None, page.pdf_index,
                      page.point_size, deepcopy(page.state), source_identity=page.source_identity)
                 for page in self.workspace.pages]
        if pdf:
            task = lambda cancel, progress: export_documents(pages, Path(path), cancel, progress)
        else:
            kind = ('jpeg' if selected.startswith('JPEG') else 'heic' if selected.startswith('HEIC')
                    else 'tiff' if selected.startswith('TIFF') else 'png')
            quality = QualityPreset(self.quality.currentData()).image_quality
            task = lambda cancel, progress: export_image(pages[0], Path(path), kind, quality, cancel)
        self.start_export(task)

    def start_export(self, task):
        if self.workspace.busy:
            return
        self.workspace.busy = True
        self._outcome = None
        self.progress.setRange(0, 0 if self._discard_cancelled_result else 100)
        self.progress.setValue(0)
        self.cancel_button.setEnabled(True)
        self._play_after_seek=False
        self._pause_asset()
        self.player.pause()
        self._set_editing_enabled(False)
        self.refresh()
        # Do not run a second full-resolution renderer/decode alongside preview.
        self.canvas.preview_queue.discard_pending(cancel_active=True)
        if self.canvas.preview_queue.busy or self._asset_audio.queue.busy:
            self._deferred_operation = task
            self._operation_cancelled = threading.Event()
            return
        self._begin_operation(task)

    def _begin_operation(self, task):
        self._thread = QThread(self)
        self._worker = ExportWorker(task)
        self._operation_cancelled = self._worker.cancelled
        self._worker.moveToThread(self._thread)
        self._thread.started.connect(self._worker.run)
        self._worker.progress.connect(self._operation_receiver.receive_progress, Qt.ConnectionType.QueuedConnection)
        self._worker.finished.connect(self._operation_receiver.receive_outcome, Qt.ConnectionType.QueuedConnection)
        self._worker.finished.connect(self._worker.deleteLater)
        self._worker.finished.connect(self._thread.quit)
        self._thread.finished.connect(self._operation_receiver.receive_stopped, Qt.ConnectionType.QueuedConnection)
        self._thread.finished.connect(self._thread.deleteLater)
        self._thread.start()

    @Slot()
    def preview_idle(self):
        if self.canvas.preview_queue.busy or self._asset_audio.queue.busy: return
        self._update_color_pick_buttons()
        self._update_find_buttons()
        if self._deferred_operation is not None:
            task, self._deferred_operation = self._deferred_operation, None
            if self._operation_cancelled is not None and self._operation_cancelled.is_set():
                self._outcome = (None, Cancelled('원본 준비를 취소했습니다.'))
                self.operation_stopped()
            else:
                self._begin_operation(task)
        if self._closing and not self.workspace.busy and not self.canvas.preview_queue.busy:
            QTimer.singleShot(0, self.close)

    @Slot(object)
    def preview_presented(self, result):
        image, time, context = result
        if context != (self._video_generation, id(self.workspace.page), self._seek_epoch):
            return
        if self.workspace.video:
            if time is None or not math.isfinite(time) or not 0 <= time <= self.workspace.video.duration:
                return
            self.workspace.time = time
            self._seek_target = None
            self._video_pts = time
            self._video_image, self._video_image_source = QImage(image), self.workspace.video
            current = self.workspace.selected()
            if current and not any(control.hasFocus() for control in self.coordinates):
                item, region = current
                shown = renderer.positioned(item, region, time)
                points = renderer.shape_points(shown)[1] if region else shown['points']
                for control, value in zip(self.coordinates, renderer.bounds(points)):
                    blocked = control.blockSignals(True)
                    control.setValue(value)
                    control.blockSignals(blocked)
        self.canvas.busy = self.workspace.busy or self.canvas.preview_pending
        self._update_find_buttons()
        self._try_start_playback()

    def _update_find_buttons(self):
        ready = bool(self.workspace.page and not self.workspace.busy
                     and not self.canvas.preview_pending and not self.canvas.image.isNull())
        self.find_faces_button.setEnabled(ready)
        self.find_text_button.setEnabled(ready)

    def validate_preview_source(self, request):
        from .media import validate_source_identities
        if request.context != (self._video_generation, id(self.workspace.page), self._seek_epoch):
            raise ValueError('이전 원본의 미리보기 결과입니다.')
        if self.workspace.page:
            validate_source_identities([self.workspace.page])

    def cancel_operation(self):
        if self._operation_cancelled is not None:
            self._operation_cancelled.set()
            self.statusBar().showMessage('취소하는 중…')

    @Slot(float)
    def operation_progress(self, value):
        self.progress.setValue(round(value * 100))

    @Slot(object)
    def export_finished(self, outcome):
        self._outcome = outcome

    @Slot()
    def operation_stopped(self):
        result, error = self._outcome or (None, RuntimeError('작업 결과를 받지 못했습니다.'))
        if self._discard_cancelled_result and self._operation_cancelled is not None and self._operation_cancelled.is_set():
            if isinstance(result,tuple) and result and hasattr(result[0],'video'):
                close=getattr(result[0].video,'close_asset_transport',None)
                if close is not None and result[0].video is not self.workspace.video: close()
            result, error = None, Cancelled('원본 준비를 취소했습니다.')
        self.workspace.busy = False
        self._set_editing_enabled(True)
        self.cancel_button.setEnabled(False)
        self._worker = None
        self._thread = None
        after = self._after_operation
        self._after_operation = None
        error_handler = self._operation_error_handler
        self._operation_error_handler = None
        self._discard_cancelled_result = False
        self._operation_cancelled = None
        label = self._operation_label
        self._operation_label = '새 파일 저장'
        self.progress.setRange(0, 100)
        if after and error is None:
            try:
                after(result)
            except Exception as exception:
                error = exception
                if isinstance(result,tuple) and result and hasattr(result[0],'video') and self.workspace.video is not result[0].video:
                    close=getattr(result[0].video,'close_asset_transport',None)
                    if close is not None: close()
        if self.workspace.busy:
            return  # A GUI continuation started the next preparation worker.
        self.refresh()
        if error_handler and error and not isinstance(error, Cancelled):
            try:
                if error_handler(error):
                    return
            except Exception as exception:
                error = exception
        completed = getattr(error, 'completed_outputs', []) if error else []
        if isinstance(error, Cancelled):
            self.statusBar().showMessage('작업을 취소했습니다.' + (f' 저장된 결과 {len(completed)}개는 유지됩니다.' if completed else ''))
            if completed:
                QMessageBox.information(self, '일부 결과 저장됨',
                    '취소하기 전에 저장된 파일은 유지됩니다.\n' + '\n'.join(map(str, completed)))
        elif error:
            self.show_error(str(error) + ('\n저장된 결과는 유지됩니다:\n' + '\n'.join(map(str, completed)) if completed else ''))
        else:
            self.progress.setValue(100)
            detail = f' ({len(result)}개 결과)' if isinstance(result, list) and label == '새 파일 저장' else ''
            self.statusBar().showMessage(label + '을 마쳤습니다.' + detail)
        if self._closing:
            self.preview_idle()

    def _set_editing_enabled(self, enabled):
        for widget in self.inspector.findChildren(QWidget):
            if widget not in (self.cancel_button, self.progress):
                widget.setEnabled(enabled)
        self.play_button.setEnabled(enabled)
        self.scrubber.setEnabled(enabled)
        self.cancel_button.setEnabled(not enabled)

    def toggle_playback(self):
        if self.workspace.busy or not self.workspace.video:
            return
        if self._asset_clock is not None:
            if self._asset_clock.playing or self._play_after_seek:
                self._play_after_seek=False; self._pause_asset()
                self.play_button.setText('▶ 재생')
                self.seek_video(float(self._asset_clock.anchor))
            elif not self.canvas.preview_pending:
                if self._asset_clock.anchor>=self._asset_clock.duration:
                    self.seek_video(0,resume=True)
                else:
                    self._play_after_seek=True; self.play_button.setText('재생 준비 중…')
                    self._try_start_playback()
            return
        if self.player.playbackState() == QMediaPlayer.PlaybackState.PlayingState:
            self._play_after_seek = False
            self.player.pause()
            self.play_button.setText('▶ 재생')
        elif self._play_after_seek:
            self._play_after_seek = False  # A second click cancels a pending load/seek resume.
            self.play_button.setText('▶ 재생')
        else:
            if self.canvas.preview_pending:
                return  # A new play still requires a coherent displayed frame.
            if self._transport_time >= self.workspace.video.duration:
                self.seek_video(0, resume=True)
                return
            self._play_after_seek = True
            self.play_button.setText('재생 준비 중…')
            self._apply_native_seek(self._video_generation)

    def playback_position_changed(self, milliseconds, generation=None):
        if self._asset_clock is not None: return
        if generation is not None and generation != self._video_generation:
            return
        if not self.workspace.video or self.workspace.busy or self._closing:
            return
        if self._native_seek_ms is not None:
            if not self._native_seek_sent or milliseconds != self._native_seek_ms:
                return  # Loading/reset clocks must not overwrite the explicit transport target.
            self._native_seek_ms = None
            self._native_seek_sent = False
        self._transport_time = milliseconds / 1000
        if not self.scrubber.isSliderDown():
            self.scrubber.setValue(milliseconds)
        self.time_label.setText(f'{milliseconds / 1000:.2f} / {self.workspace.video.duration:.2f} 초')
        self._try_start_playback()

    def video_frame_changed(self, frame, generation=None):
        if self._asset_clock is not None: return
        if generation is not None and generation != self._video_generation:
            return
        if not frame.isValid() or not self.workspace.video or self.workspace.busy or self._closing:
            return
        # The paused seek's PyAV result is authoritative. An already queued Qt
        # sink frame cannot replace it with pixels from before the seek.
        if self._paused_seek:
            return
        if frame.startTime() < 0:
            self.statusBar().showMessage('프레임의 실제 PTS가 없어 표시하지 않습니다.')
            return
        stamp = frame.startTime()
        time = stamp / 1_000_000
        if not math.isfinite(time) or not 0 <= time <= self.workspace.video.duration:
            return
        floor_us = math.floor(self._video_pts * 1_000_000) if self._video_pts is not None else 0
        if stamp < max(floor_us, self._last_sink_pts_us or 0):
            return
        # Native frame callbacks can precede positionChanged. Their real PTS
        # is authoritative; transport is not an upper bound for a valid frame.
        image = frame.toImage()
        if image.isNull():
            return
        rotation = frame.rotation().value if hasattr(frame, 'rotation') else 0
        if rotation:
            image = image.transformed(QTransform().rotate(rotation))
        if frame.mirrored():
            image = image.mirrored(True, False)
        self._last_sink_pts_us = stamp
        self.canvas.preview_context = (self._video_generation, id(self.workspace.page), self._seek_epoch)
        self.canvas.set_document(image, self.workspace.page.state,
                                 self.workspace.selection_ids, time)

    def seek_video(self, seconds, resume=False):
        if self.workspace.busy or not self.workspace.video:
            return
        if not math.isfinite(seconds):
            return
        seconds = max(0, min(self.workspace.video.duration, seconds))
        if self._asset_clock is not None:
            self._pause_asset()
            self._asset_clock.seek(exact_time(seconds))
            self._video_generation+=1; self._seek_epoch+=1
            self._play_after_seek=resume; self._paused_seek=True
            self._transport_time=seconds; self._seek_target=seconds
            self.play_button.setText('재생 준비 중…' if resume else '▶ 재생')
            self.canvas.preview_context=(self._video_generation,id(self.workspace.page),self._seek_epoch)
            self.canvas.request_video_seek(self.workspace.video,seconds,self.workspace.page.state,
                                           self.workspace.selection_ids)
            return
        self.player.pause()
        self._seek_epoch += 1
        self._replace_video_player(self._video_source_path)
        self._play_after_seek = resume
        self._paused_seek = True
        self._transport_time = seconds
        self._seek_target = seconds
        self._request_native_seek(seconds)
        self.canvas.preview_context = (self._video_generation, id(self.workspace.page), self._seek_epoch)
        self.canvas.request_video_seek(self.workspace.video, seconds, self.workspace.page.state,
                                       self.workspace.selection_ids)

    def apply_time_range(self):
        if self.range_end.value() < self.range_start.value():
            self.show_error(ValueError('끝 시각은 시작 시각 이후로 지정하세요.'))
            return
        self.update_selection(timeRange=[self.range_start.value(), self.range_end.value()])

    def record_position(self):
        if not self.workspace.selected() or not self.workspace.video or self.canvas.preview_pending:
            return
        prior = self.workspace.record_motion
        self.workspace.record_motion = True
        try:
            self.perform(lambda: self.workspace.resize_selected([control.value() for control in self.coordinates], self.workspace.time))
        finally:
            self.workspace.record_motion = prior

    def remove_keyframe(self):
        selected = self.workspace.selected()
        row = self.keyframes.currentItem()
        if selected and row:
            properties = selected[0]['effect'] if selected[1] else selected[0]
            time = row.data(Qt.ItemDataRole.UserRole)
            self.update_selection(keyframes=[frame for frame in properties.get('keyframes', [])
                                             if frame['time'] != time])

    def keyframe_selected(self, row, previous=None):
        if row:
            self.keyframe_time.setValue(row.data(Qt.ItemDataRole.UserRole))

    def retime_keyframe(self):
        row = self.keyframes.currentItem()
        if row and self.workspace.video:
            self.perform(lambda: self.workspace.retime_keyframe(
                row.data(Qt.ItemDataRole.UserRole), self.keyframe_time.value()))

    def auto_track(self):
        selected = self.workspace._selected_ids_with_groups()
        targets = [(deepcopy(item), region) for item, region in self.workspace.items()
                   if self.workspace.item_id(item, region) in selected]
        if not targets or not self.workspace.video or self.workspace.busy or self.canvas.preview_pending:
            return
        from .auto_tracking import track_many
        from .find_actions import commit_tracking
        source, start = self.workspace.video, self.workspace.time or 0
        page = self.workspace.page
        direction = self.track_direction.currentData()
        smoothing, reacquire = self.track_smoothing.isChecked(), self.track_reacquire.isChecked()
        def commit(results):
            if self.workspace.page is not page or self.workspace.video is not source:
                raise ValueError('원본이 바뀌어 이전 추적 결과를 적용하지 않았습니다.')
            source.validate()
            commit_tracking(self.workspace, results)
            self.tracking_summary(results)
        self._after_operation = commit
        self._discard_cancelled_result = True
        self._operation_label = '자동 추적'
        self.start_export(lambda cancel, progress: track_many(source, targets, start,
            direction=direction, smoothing=smoothing, reacquire_faces=reacquire, cancel=cancel, progress=progress))

    def _current_find_ids(self):
        if self._last_find_page is not self.workspace.page:
            return set()
        return self._last_find_ids & {self.workspace.item_id(item, region) for item,region in self.workspace.items()}

    def select_latest_finds(self):
        if not self.workspace.busy:
            self.workspace.selection_ids = self._current_find_ids()
            self.refresh()

    def remove_latest_finds(self):
        if not self.workspace.busy:
            identifiers = self._current_find_ids()
            if identifiers:
                self.workspace.selection_ids = identifiers
                self.perform(self.workspace.delete_selected)

    def tracking_summary(self, results):
        lost = sum(r.lost for r in results)
        skipped = sum(r.skipped for r in results)
        if lost or skipped:
            QMessageBox.information(self, '추적 결과 확인',
                f'{lost}개 대상의 추적이 중단됐고 {skipped}개 항목을 건너뛰었습니다.\n'
                '중단된 대상은 확인된 구간만 적용했습니다. 영상 전체를 재생하며 가림을 확인하세요.')

    def auto_find(self, kind):
        if not self.workspace.page or self.workspace.busy or self.canvas.preview_pending:
            return
        from .auto_find import detect
        from .find_actions import prepared_regions, apply_tracks_to_items, commit_find
        page, source = self.workspace.page, self.workspace.video
        start = self.workspace.time or 0.
        image = QImage(self.canvas.image)
        if image.isNull():
            return
        state = deepcopy(page.state)
        style, radius, feather = self.style.currentData(), self.radius.value(), self.feather.value()
        color = {'red':self.cover_color.redF(),'green':self.cover_color.greenF(),
                 'blue':self.cover_color.blueF(),'alpha':self.cover_color.alphaF()}
        tracking = bool(source and self.find_then_track.isChecked() and start < source.duration)
        smoothing, reacquire = self.track_smoothing.isChecked(), self.track_reacquire.isChecked()
        def task(cancel, progress):
            from .media import validate_sources, check_cancel
            validate_sources([page], cancel)
            detection_image = source.frame_at_timed(start,cancel=cancel).image if source else image
            found = detect(detection_image, kind, cancel, lambda v: progress(v*(.25 if tracking else 1.)))
            regions = prepared_regions(found,state,start,source.duration if source else None,
                style=style,radius=radius,feather=feather,color=color)
            results = []
            if tracking and regions:
                from .auto_tracking import track_many
                results = track_many(source,[(item,True) for item in regions],start,direction='both',
                    smoothing=smoothing,reacquire_faces=reacquire,cancel=cancel,
                    progress=lambda v: progress(.25+.75*v))
                apply_tracks_to_items([(item,True) for item in regions],results)
            validate_sources([page], cancel)
            check_cancel(cancel)
            return regions, results
        def commit(result):
            from .media import validate_source_identities
            if self.workspace.page is not page or self.workspace.video is not source or page.state != state:
                raise ValueError('편집 원본이 바뀌어 찾은 결과를 적용하지 않았습니다.')
            validate_source_identities([page])
            regions, results = result
            identifiers = commit_find(self.workspace, regions)
            # Selection is cleared in place by undo/redo. Keep a separate set
            # so redone finds can still be selected/removed as one operation.
            self._last_find_page, self._last_find_ids = page, set(identifiers)
            self.statusBar().showMessage(f'{len(identifiers)}개 영역을 찾았습니다.')
            if not identifiers:
                QMessageBox.information(self,'자동 찾기','새로 가릴 영역을 찾지 못했습니다. 작은 얼굴·흐린 글자는 직접 확인하세요.')
            if results:
                self.tracking_summary(results)
        self._after_operation = commit
        self._discard_cancelled_result = True
        self._operation_label = '얼굴 자동 찾기' if kind == 'faces' else '글자 자동 찾기'
        self.start_export(task)

    def confirm_discard(self):
        if not self.workspace.dirty:
            return True
        response = QMessageBox.question(self, '저장하지 않은 편집',
            '저장하지 않은 편집이 있습니다. 현재 편집을 버리고 계속할까요?',
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
            QMessageBox.StandardButton.No)
        return response == QMessageBox.StandardButton.Yes

    def dragEnterEvent(self, event):
        if not self.workspace.busy and event.mimeData().hasUrls() and all(url.isLocalFile() for url in event.mimeData().urls()):
            event.acceptProposedAction()

    def dropEvent(self, event):
        if self.workspace.busy:
            event.ignore()
            return
        if event.mimeData().hasUrls() and all(url.isLocalFile() for url in event.mimeData().urls()):
            paths = [Path(url.toLocalFile()) for url in event.mimeData().urls()]
            projects = [path for path in paths if path.suffix.lower() == '.bluraction']
            if projects and len(paths) != 1:
                self.show_error('프로젝트는 한 파일씩 열어 주세요. 원본 파일과 함께 놓을 수 없습니다.')
                event.ignore()
                return
            if projects:
                self.open_project(projects[0])
            else:
                self.open_paths(paths)
            event.acceptProposedAction()

    def closeEvent(self, event):
        if self._closing:
            if self.workspace.busy or self.canvas.preview_queue.busy or self._asset_audio.queue.busy:
                event.ignore()
            else:
                event.accept()
            return
        if self.workspace.busy:
            self.cancel_operation()
            self.statusBar().showMessage('작업 취소가 끝난 뒤 창을 닫아 주세요.')
            event.ignore()
            return
        if not self.confirm_discard():
            event.ignore()
            return
        self.canvas.cancel_color_pick()
        self._closing = True
        self._video_generation += 1
        self._native_seek_ms = None
        self._play_after_seek = False
        self._pause_asset(); self._asset_audio.shutdown()
        close=getattr(self.workspace.video,'close_asset_transport',None)
        if close is not None: close()
        self.player.stop()
        self.canvas.preview_queue.shutdown()
        if self.canvas.preview_queue.busy or self._asset_audio.queue.busy:
            event.ignore()
        else:
            event.accept()
