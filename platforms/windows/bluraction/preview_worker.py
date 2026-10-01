"""Full-resolution preview jobs: one running, one replaceable pending request.

The coordinator and result slots live on the GUI thread. Workers own only value
snapshots, never Widgets, the mutable Workspace or a QMediaPlayer.
"""
from dataclasses import dataclass, field
import threading

from PySide6.QtCore import QObject, QThread, Signal, Slot, Qt
from PySide6.QtGui import QImage
from . import renderer
from .media import check_cancel


@dataclass
class PreviewRequest:
    context: object
    image: QImage
    state: dict
    time: object
    decode: object = None
    cancel: threading.Event = field(default_factory=threading.Event)


class _Worker(QObject):
    finished = Signal(object)

    def __init__(self, request):
        super().__init__()
        self.request = request

    @Slot()
    def run(self):
        request = self.request
        try:
            check_cancel(request.cancel.is_set)
            image, time = request.image, request.time
            if request.decode is not None:
                decoded = request.decode(request.cancel.is_set)
                image, time = decoded.image, float(decoded.time)
            check_cancel(request.cancel.is_set)
            pixels = renderer.render(image, request.state, time)
            check_cancel(request.cancel.is_set)
            self.finished.emit((request, image, time, pixels, None))
        except Exception as error:
            self.finished.emit((request, QImage(), None, QImage(), error))


class PreviewQueue(QObject):
    completed = Signal(object)
    idle = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self.active = None
        self.pending = None
        self._thread = None
        self._worker = None
        self._result = None
        self.closed = False

    @property
    def busy(self):
        return self.active is not None

    def submit(self, request):
        if self.closed:
            return
        if self.active is not None:
            self.pending = request
        else:
            self._start(request)

    def discard_pending(self, cancel_active=False):
        self.pending = None
        if cancel_active and self.active is not None:
            self.active.cancel.set()

    def shutdown(self):
        self.closed = True
        self.discard_pending(cancel_active=True)

    def _start(self, request):
        self.active = request
        self._result = None
        thread = QThread(self)
        worker = _Worker(request)
        self._thread, self._worker = thread, worker
        worker.moveToThread(thread)
        thread.started.connect(worker.run)
        worker.finished.connect(self._received, Qt.ConnectionType.QueuedConnection)
        worker.finished.connect(worker.deleteLater)
        worker.finished.connect(thread.quit)
        thread.finished.connect(self._stopped, Qt.ConnectionType.QueuedConnection)
        thread.finished.connect(thread.deleteLater)
        thread.start()

    @Slot(object)
    def _received(self, result):
        self._result = result

    @Slot()
    def _stopped(self):
        result = self._result
        self.active = None
        self._thread = self._worker = self._result = None
        if result is not None and not self.closed:
            self.completed.emit(result)
        # A completion handler may replace pending or start a preparation worker.
        pending = self.pending
        if self.active is not None:
            return
        self.pending = None
        if pending is not None and not self.closed:
            self._start(pending)
        elif self.active is None:
            self.idle.emit()
