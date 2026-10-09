"""Offline face/text area detection; portable boxes have a bottom-left origin.

Uses the pinned OpenCV Zoo YuNet and PP-OCRv3 detection models. No network,
identity recognition, OCR transcription, or media modification occurs here.
"""
from dataclasses import dataclass
import hashlib
import math
from pathlib import Path
import sys

from .media import check_cancel
from .renderer import to_pillow


MAX_FINDS = 512


def configure_cv():
    import cv2
    # Bound CPU workers for the small, sequential detection/tracking jobs.
    # Excessive parallelism slowed down the packaged Windows runtime.
    if cv2.getNumThreads()!=2:
        cv2.setNumThreads(2)
    return cv2


MODELS = {
    'faces': ('face_detection_yunet_2023mar.onnx',
              '8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4'),
    'text': ('text_detection_cn_ppocrv3_2023may.onnx',
             '03f550c6b406fda8bf54bd8327815f6c7e2edd98cea02348c93d879254366587'),
}


@dataclass(frozen=True)
class Detection:
    rect: tuple
    kind: str
    confidence: float


def model_directory():
    if getattr(sys, 'frozen', False):
        return Path(sys._MEIPASS) / 'auto-find-models'
    return Path(__file__).resolve().parents[3] / 'Resources' / 'windows-auto-find'


def model_path(kind):
    if kind not in MODELS:
        raise ValueError('얼굴 또는 글자 찾기를 선택하세요.')
    name, digest = MODELS[kind]
    path = model_directory() / name
    if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
        raise ValueError('자동 찾기 모델이 없거나 변경되었습니다. 모델이 포함된 앱을 사용하세요.')
    return path


def intersection(a, b):
    return max(0, min(a[0]+a[2], b[0]+b[2])-max(a[0], b[0])) * max(
        0, min(a[1]+a[3], b[1]+b[3])-max(a[1], b[1]))


def normalized_box(left, top, right, bottom, width, height, kind, score):
    if not all(math.isfinite(float(v)) for v in (left, top, right, bottom, score)):
        return None
    w, h = right-left, bottom-top
    if w <= 0 or h <= 0:
        return None
    if kind == 'faces':
        left, right = left-w*.2, right+w*.2
        top, bottom = top-h*.35, bottom+h*.15
    else:
        padding = h*.20
        left, right, top, bottom = left-padding, right+padding, top-padding, bottom+padding
    x0, x1 = max(0, left/width), min(1, right/width)
    y0, y1 = max(0, top/height), min(1, bottom/height)
    if x1 <= x0 or y1 <= y0:
        return None
    w, h = max(.0101, x1-x0), max(.0101, y1-y0)
    x = min(1-w, max(0, (x0+x1-w)/2))
    top = min(1-h, max(0, (y0+y1-h)/2))
    return Detection((x, 1-top-h, w, h), kind, min(1., max(0., float(score))))


def deduplicate(detections, cancel=None):
    result = []
    for found in sorted(detections, key=lambda d: (d.confidence, d.rect[2]*d.rect[3]), reverse=True):
        check_cancel(cancel)
        area = found.rect[2]*found.rect[3]
        if any(intersection(found.rect, old.rect) >= .75*min(area, old.rect[2]*old.rect[3])
               for old in result):
            continue
        result.append(found)
        if len(result) > MAX_FINDS:
            raise ValueError('찾은 영역이 512개를 넘습니다. 페이지나 화면을 나눠 확인하세요.')
    return sorted(result, key=lambda d: d.rect[2]*d.rect[3], reverse=True)


def _tiles(width, height, grid):
    for row in range(grid):
        for col in range(grid):
            left = max(0, int((col-.1)*width/grid))
            top = max(0, int((row-.1)*height/grid))
            right = min(width, math.ceil((col+1.1)*width/grid))
            bottom = min(height, math.ceil((row+1.1)*height/grid))
            yield left, top, right, bottom


def text_lines(detections, width, height, cancel=None):
    """Join nearby word anchors on one baseline, including missed middle words."""
    boxes = deduplicate(detections, cancel)
    parents = list(range(len(boxes)))
    def root(index):
        while parents[index] != index:
            parents[index] = parents[parents[index]]
            index = parents[index]
        return index
    for i, first in enumerate(boxes):
        check_cancel(cancel)
        x,y,w,h=first.rect
        for j in range(i):
            a,b,c,d=boxes[j].rect
            if max(h,d)>1.8*min(h,d):
                continue
            if abs(y+h/2-b-d/2)>.30*min(h,d):
                continue
            gap=max(0., max(x,a)-min(x+w,a+c))*width
            if gap<=4.*min(h,d)*height:
                parents[root(i)]=root(j)
    groups={}
    for i,box in enumerate(boxes):
        groups.setdefault(root(i),[]).append(box)
    result=[]
    for group in groups.values():
        left=min(d.rect[0] for d in group)
        bottom=min(d.rect[1] for d in group)
        right=max(d.rect[0]+d.rect[2] for d in group)
        top=max(d.rect[1]+d.rect[3] for d in group)
        result.append(Detection((left,bottom,right-left,top-bottom),'text',
                                max(d.confidence for d in group)))
    return deduplicate(result,cancel)


def detect(image, kind, cancel=None, progress=None):
    """Return padded areas for the unedited, displayed source frame/page."""
    check_cancel(cancel)
    if image.isNull() or image.width()*image.height() > 24_000_000:
        raise ValueError('자동 찾기는 24MP 이하의 원본 프레임에서 실행하세요.')
    cv2 = configure_cv()
    import numpy as np
    path = model_path(kind)
    # Transparent images are inspected as they appear on white paper, without
    # changing the original image's alpha or the shared renderer.
    from PIL import Image
    rgba = to_pillow(image)
    paper = Image.new('RGBA', rgba.size, 'white')
    paper.alpha_composite(rgba)
    bgr = np.ascontiguousarray(np.asarray(paper.convert('RGB'))[:, :, ::-1])
    height, width = bgr.shape[:2]
    found = []
    if kind == 'faces':
        scale = min(1., 1280/max(width, height))
        small = cv2.resize(bgr, (max(32, round(width*scale)), max(32, round(height*scale))))
        # Buffer overloads avoid OpenCV's narrow Windows filename handling.
        detector = cv2.FaceDetectorYN.create('onnx', np.frombuffer(path.read_bytes(), dtype=np.uint8),
            np.empty(0, dtype=np.uint8), (small.shape[1], small.shape[0]), .65, .3, 1000)
        check_cancel(cancel)
        _, faces = detector.detect(small)
        check_cancel(cancel)
        if faces is not None:
            sx, sy = width/small.shape[1], height/small.shape[0]
            for face in faces:
                x, y, w, h = map(float, face[:4])
                box = normalized_box(x*sx, y*sy, (x+w)*sx, (y+h)*sy, width, height, kind, face[-1])
                if box is not None:
                    found.append(box)
    else:
        detector = cv2.dnn_TextDetectionModel_DB(cv2.dnn.readNetFromONNX(
            np.frombuffer(path.read_bytes(), dtype=np.uint8)))
        detector.setBinaryThreshold(.3)
        detector.setPolygonThreshold(.45)
        detector.setUnclipRatio(1.8)
        detector.setMaxCandidates(1000)
        detector.setInputSize((736, 736))
        detector.setInputMean((123.675, 116.28, 103.53))
        detector.setInputScale((1/255/.229, 1/255/.224, 1/255/.225))
        passes = [(0, 0, width, height, False)]
        if max(width, height) >= 800:
            passes += [(*tile, enhanced) for enhanced in (False, True)
                       for tile in _tiles(width, height, 2)]
        if max(width, height) >= 1600:
            passes += [(*tile, False) for tile in _tiles(width, height, 4)]
        for index, (left, top, right, bottom, enhanced) in enumerate(passes):
            check_cancel(cancel)
            tile = bgr[top:bottom, left:right]
            if enhanced:
                gray = cv2.cvtColor(tile, cv2.COLOR_BGR2GRAY)
                gray = cv2.createCLAHE(2., (8, 8)).apply(gray)
                tile = cv2.cvtColor(gray, cv2.COLOR_GRAY2BGR)
            tw, th = tile.shape[1], tile.shape[0]
            scale = min(736/tw, 736/th)
            rw, rh = max(1, round(tw*scale)), max(1, round(th*scale))
            padded = np.full((736, 736, 3), 255, dtype=np.uint8)
            padded[:rh, :rw] = cv2.resize(tile, (rw, rh))
            boxes, scores = detector.detect(padded)
            check_cancel(cancel)
            for box, score in zip(boxes, scores):
                x0, y0 = box.min(axis=0)
                x1, y1 = box.max(axis=0)
                if x0 >= rw or y0 >= rh:
                    continue
                detection = normalized_box(left+x0*tw/rw, top+y0*th/rh,
                    left+min(x1, rw)*tw/rw, top+min(y1, rh)*th/rh, width, height, kind, score)
                if detection is not None:
                    found.append(detection)
            if progress:
                progress((index+1)/len(passes))
    result = text_lines(found,width,height,cancel) if kind=='text' else deduplicate(found,cancel)
    check_cancel(cancel)
    if progress:
        progress(1.)
    return result
