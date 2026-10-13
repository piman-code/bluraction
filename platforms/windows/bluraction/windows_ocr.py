"""Preserved OCR prototype; not imported or bundled by the local candidate.

The frozen prototype could not start the external host. Production detection
uses the in-process DB model and text-line grouping in auto_find.py instead.
"""
import base64
import json
import os
from pathlib import Path
import subprocess
import time

from PySide6.QtCore import QByteArray, QBuffer, QIODevice, Qt
from .media import check_cancel


def text_boxes(image, resource_directory, cancel=None, diagnostics=None):
    def record(**values):
        if diagnostics is not None:
            diagnostics.update(values)
    if os.name != 'nt':
        return []
    script = Path(resource_directory) / 'windows-ocr.ps1'
    if not script.is_file():
        record(reason='bridge-missing')
        return []
    small = image.scaled(2048,2048,Qt.AspectRatioMode.KeepAspectRatio,Qt.TransformationMode.SmoothTransformation) if max(image.width(),image.height())>2048 else image
    data = QByteArray()
    buffer = QBuffer(data)
    buffer.open(QIODevice.OpenModeFlag.WriteOnly)
    if not small.save(buffer,'PNG'):
        return []
    buffer.close()
    payload = json.dumps({'png':base64.b64encode(bytes(data)).decode('ascii')}).encode('ascii')
    if len(payload)>32*1024*1024:
        return []
    # This is a command invocation of Windows' preinstalled host. No execution
    # policy override, script-file launch, disk media or global process kill.
    encoded = base64.b64encode(script.read_text(encoding='utf-8-sig').encode('utf-16-le')).decode('ascii')
    executable = Path(os.environ.get('SystemRoot','C:/Windows'))/'System32/WindowsPowerShell/v1.0/powershell.exe'
    check_cancel(cancel)
    try:
        process = subprocess.Popen([str(executable),'-NoLogo','-NoProfile','-NonInteractive','-EncodedCommand',encoded],
            stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,creationflags=subprocess.CREATE_NO_WINDOW)
    except OSError as error:
        record(reason='process-start-failed', errorType=type(error).__name__)
        return []
    started = time.monotonic()
    try:
        first = True
        while True:
            check_cancel(cancel)
            if time.monotonic()-started>20:
                record(reason='timeout')
                return []
            try:
                stdout,stderr = process.communicate(payload if first else None,timeout=.1)
                break
            except subprocess.TimeoutExpired:
                first = False
        if process.returncode or len(stdout)>1024*1024:
            record(reason='process-failed',exitCode=process.returncode)
            return []
        try:
            result = json.loads(stdout.decode('utf-8-sig'))
        except (ValueError,UnicodeError):
            record(reason='invalid-response',stdoutBytes=len(stdout),stderrBytes=len(stderr))
            return []
        boxes = result.get('boxes',[]) if result.get('available') else []
        record(reason=result.get('reason','available' if result.get('available') else 'unavailable'),
               available=bool(result.get('available')),boxes=len(boxes) if isinstance(boxes,list) else 0)
        if not isinstance(boxes,list) or len(boxes)>2048:
            return []
        sx,sy = image.width()/small.width(),image.height()/small.height()
        return [(float(b[0])*sx,float(b[1])*sy,float(b[2])*sx,float(b[3])*sy)
                for b in boxes if isinstance(b,list) and len(b)==4]
    finally:
        if process.poll() is None:
            process.kill()
        process.communicate()
