"""Local PTS-based video decoding, flattened export and CSRT tracking.

Runtime requirements: PyAV >=19 and OpenCV with TrackerCSRT. Nothing is installed
here. Encoder registration is distinct from successfully opening a hardware/API
encoder: Windows uses h264_mf, macOS uses h264_videotoolbox, without libx264/GPL
fallback. Full audio support currently means compatible-container packet remux;
unsupported audio codecs/extra stream types raise instead of silently disappearing.
Actual Windows encoding/device/package verification is still required.

Official API references used for implementation:
https://pyav.basswood.io/docs/stable/api/frame.html
https://pyav.basswood.io/docs/stable/api/video.html
https://pyav.basswood.io/docs/stable/api/container.html
https://pyav.org/docs/develop/api/time.html
https://docs.opencv.org/4.x/d2/da2/classcv_1_1TrackerCSRT.html
"""
from __future__ import annotations

from copy import deepcopy
from contextlib import contextmanager
from contextvars import ContextVar
from dataclasses import dataclass
from enum import Enum
from fractions import Fraction
import math
import hashlib
import os
from pathlib import Path
import struct
import sys
import tempfile

from PIL import Image
from PySide6.QtGui import QImage

from .media import (Page, Cancelled, IncompleteOutputError, _capture_identity,
                    _check_identity, check_cancel, fingerprint, fresh_target, publish_new)
from .renderer import bounds, positioned, render, shape_points, to_pillow, to_qimage


class VideoError(ValueError):
    pass


class QualityPreset(str, Enum):
    """Same compression and bitrate targets as the macOS QualityPreset.

    'Original' still re-encodes edited pixels; it does not promise lossless H.264.
    PNG/TIFF use their format's lossless pixel encoding, independent of this value.
    """
    ORIGINAL = 'original'
    HIGH = 'high'
    MEDIUM = 'medium'
    LOW = 'low'

    @property
    def label(self):
        return {'original': '원본', 'high': '고품질', 'medium': '중간', 'low': '낮음'}[self.value]

    @property
    def image_quality(self):
        return {'original': 100, 'high': 92, 'medium': 75, 'low': 50}[self.value]

    @property
    def bits_per_pixel_per_second(self):
        return {'original': 0, 'high': .10, 'medium': .05, 'low': .025}[self.value]


def output_bit_rate(quality, estimated_rate, frame_rate, width, height):
    """Bounded Mac-compatible H.264 target, without guessing frame timestamps."""
    quality = QualityPreset(quality)
    values = (estimated_rate, frame_rate, width, height)
    if any(isinstance(value, bool) or not isinstance(value, (int, float, Fraction))
           or not math.isfinite(value) for value in values):
        raise VideoError('출력 화질에 필요한 영상 정보가 유한하지 않습니다.')
    if not 0 <= estimated_rate <= 500_000_000 or not 0 <= frame_rate <= 240:
        raise VideoError('영상 비트레이트 또는 프레임률이 지원 범위를 벗어났습니다.')
    if not 0 < width <= 32_768 or not 0 < height <= 32_768 or width * height > 134_217_728:
        raise VideoError('영상 출력 크기가 지원 범위를 벗어났습니다.')
    raw_rate = (max(500_000, estimated_rate) if quality == QualityPreset.ORIGINAL else
                width * height * max(1, frame_rate) * quality.bits_per_pixel_per_second)
    return int(min(500_000_000, max(500_000, raw_rate)))


_ASSET_LOAD=ContextVar('bluraction_owned_asset_load',default=False)
_ASSET_CREATED=ContextVar('bluraction_owned_asset_created',default=None)


@contextmanager
def asset_transport_load():
    """Desktop prepare-worker opt-in, before ANY native constructor decode.

    Scoped to this worker/context; direct decoder/legacy test callers retain
    their API. No global process setting or native-player timestamp inference.
    """
    token=_ASSET_LOAD.set(True)
    outer=_ASSET_CREATED.get()
    created=[]
    created_token=_ASSET_CREATED.set(created)
    try:
        yield
    except BaseException as primary:
        # Only successful constructors in THIS transaction are registered.
        # A candidate can fail before Workspace._replace has assigned video;
        # retaining it in the context closes that otherwise invisible owner.
        # Borrowed operating VideoSources are never registered or closed here.
        failed=[]
        for source in reversed(created):
            session=getattr(source,'asset_session',None)
            if session is None: continue
            try: session.close()
            except BaseException as cleanup:
                if cleanup is not primary:
                    primary.add_note(f'unadopted asset source cleanup also failed: {cleanup!r}')
                    primary.__cause__=cleanup
                failed.append(session)
            else: source.asset_session=None
        if failed:
            def retry():
                for session in tuple(failed):
                    session.close()
                    failed.remove(session)
            primary.retry_transport_close=retry
        raise
    else:
        if outer is not None: outer.extend(created)
    finally:
        _ASSET_CREATED.reset(created_token)
        _ASSET_LOAD.reset(token)


class TrackingLost(VideoError):
    """No partial keyframes are applied to the editor on tracking failure."""


def _av():
    try:
        import av
    except ImportError as error:
        raise VideoError('영상 기능에는 별도 승인한 PyAV 19 이상 런타임이 필요합니다.') from error
    if int(av.__version__.split('.')[0]) < 19:
        raise VideoError('현재 PyAV는 영상 시간·회전 보존에 필요한 19 이상 버전이 아닙니다.')
    return av


def encoder_capability(platform=None):
    """Registration only; encoder/device opening must separately succeed at export."""
    platform = platform or sys.platform
    name = 'h264_mf' if platform == 'win32' else 'h264_videotoolbox' if platform == 'darwin' else None
    if name is None:
        return {'encoder': None, 'registered': False, 'reason': '검증 대상은 Windows와 macOS입니다.'}
    try:
        _av().codec.Codec(name, 'w')
    except Exception as error:
        return {'encoder': name, 'registered': False, 'reason': str(error)}
    return {'encoder': name, 'registered': True, 'reason': '코덱 등록 확인; 실제 인코더 열기는 별도 검증 필요'}


def _timestamp(frame):
    if frame.pts is None or frame.time_base is None or frame.time_base <= 0:
        raise VideoError('프레임의 실제 PTS 또는 시간 기준이 없습니다. FPS로 추측해 저장하지 않습니다.')
    return Fraction(frame.pts) * frame.time_base


def _signature(path):
    path = Path(path)
    if path.is_symlink() or not path.is_file():
        raise VideoError('원본 영상 경로가 변경되었습니다.')
    info = path.stat()
    return (str(path.resolve()), info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


PIXEL_CONTRACT_V2 = 'opaque-yuv420p-accurate-rgb24-v2'
LEGACY_PIXEL_CONTRACT = 'legacy-to-image-rgb-unverified'


def pixel_contract(frame):
    """Only opaque8-bit yuv420p has this two-host RGB byte contract.

    Other formats retain the existing conversion. Their alpha/color/HDR parity
    remains separate work, not a declaration of support exclusion. Known HDR
    never receives this SDR contract; provider HDR holds remain unchanged.
    """
    supported = (getattr(getattr(frame, 'format', None), 'name', None) == 'yuv420p'
                 and getattr(frame, 'color_trc', None) not in (16, 18))
    return PIXEL_CONTRACT_V2 if supported else LEGACY_PIXEL_CONTRACT


def _decoded_pixel_image(frame):
    if pixel_contract(frame) != PIXEL_CONTRACT_V2:
        return frame.to_image().convert('RGB')
    from av.video.reformatter import Interpolation, VideoReformatter
    width, height = frame.width, frame.height
    if (type(width) is not int or type(height) is not int or not 0 < width <= 16384
            or not 0 < height <= 16384 or width * height > 33_177_600):
        raise VideoError('영상 표시 해상도가 지원 범위를 넘습니다.')
    # Native color metadata stays unchanged. No CPU/global setting or tag
    # rewrite. BOTH precise flags accompany the existing bilinear conversion.
    rgb = VideoReformatter().reformat(frame, format='rgb24',
        interpolation=Interpolation.BILINEAR | Interpolation.BITEXACT | Interpolation.ACCURATE_RND)
    if rgb.format.name != 'rgb24' or (rgb.width, rgb.height) != (width, height) or len(rgb.planes) != 1:
        raise VideoError('정확 RGB24 변환 결과의 형식이나 크기가 변경되었습니다.')
    plane = rgb.planes[0]
    stride = plane.line_size
    if type(stride) is not int or stride < width * 3:
        raise VideoError('RGB24 행 크기가 올바르지 않습니다.')
    raw = bytes(plane)
    if len(raw) < stride * height:
        raise VideoError('RGB24 변환 결과가 잘렸습니다.')
    tight = b''.join(raw[y * stride:y * stride + width * 3] for y in range(height))
    return Image.frombytes('RGB', (width, height), tight)


def _display_image(frame, sample_aspect_ratio=Fraction(1), metadata=None):
    """Decode raw pixels; normalize SAR and display rotation exactly once.

    PyAV's frame.rotation is counterclockwise. Pillow uses the same convention.
    New export frames carry no input display matrix, preventing double rotation.
    Mirrored/scaled/perspective display matrices need dedicated support and fail
    explicitly rather than producing incorrectly aligned privacy masks.
    """
    # PyAV 19 side_data is a Mapping: iteration yields Type keys, not values.
    matrix = frame.side_data.get('DISPLAYMATRIX')
    if matrix is not None:
        raw = bytes(matrix)
        if len(raw) != 36:
            raise VideoError('영상 표시 행렬을 해석할 수 없습니다.')
        m = struct.unpack('=9i', raw)
        if m[0] * m[4] - m[1] * m[3] <= 0 or m[2] or m[5]:
            raise VideoError('반사 또는 투시 변환 영상은 표시 위치 검토가 필요합니다.')
        # FFmpeg stores w in 2.30 fixed point. Rotation-only normalization
        # cannot represent division by a non-unit homogeneous coordinate.
        if m[8] != 1 << 30:
            raise VideoError('정규화되지 않은 영상 표시 행렬은 위치 검토가 필요합니다.')
        if abs(math.hypot(m[0], m[1]) / 65536 - 1) > .001 or abs(math.hypot(m[3], m[4]) / 65536 - 1) > .001:
            raise VideoError('크기 변환이 포함된 영상 표시 행렬은 검토가 필요합니다.')
        # Unit row lengths alone admit shear. Keep the existing .001 fixed-
        # point rounding allowance while requiring perpendicular basis rows.
        if abs(m[0] * m[3] + m[1] * m[4]) * 1000 > 65536 ** 2:
            raise VideoError('직교하지 않은 영상 표시 행렬은 위치 검토가 필요합니다.')
    angle = frame.rotation
    if matrix is None and not angle:
        rotate = next((v for k, v in (metadata or {}).items() if k.lower() == 'rotate'), 0)
        try:
            angle = float(rotate)
        except (ValueError, TypeError) as error:
            raise VideoError('영상 회전 정보를 해석할 수 없습니다.') from error
    if not math.isfinite(angle) or abs(angle / 90 - round(angle / 90)) > .00001:
        raise VideoError('직각 이외 회전은 표시 위치 검토가 필요합니다.')
    image = _decoded_pixel_image(frame)
    if sample_aspect_ratio <= 0:
        raise VideoError('영상 화소의 종횡비가 올바르지 않습니다.')
    width = round(image.width * sample_aspect_ratio)
    if not 0 < width <= 16384 or image.height > 16384 or width * image.height > 33_177_600:
        raise VideoError('영상 표시 해상도가 지원 범위를 넘습니다.')
    if width != image.width:
        image = image.resize((width, image.height), Image.Resampling.BICUBIC)
    turns = round(angle / 90) % 4
    if turns:
        image = image.transpose({1: Image.Transpose.ROTATE_90, 2: Image.Transpose.ROTATE_180, 3: Image.Transpose.ROTATE_270}[turns])
    return to_qimage(image)


@dataclass(frozen=True)
class TimedImage:
    time: Fraction
    image: QImage
    presence: str = 'content'
    interval_end: Fraction | None = None
    source_index: int | None = None
    interval_start: Fraction | None = None


class VideoSource:
    def __init__(self, path, cancel=None, *, require_asset_presentation=False):
        check_cancel(cancel)
        self.path = Path(path).absolute()
        self._source_identity = _capture_identity(self.path)
        self._identity = _signature(self.path)
        self._guard()
        # Video size is not an image/PDF input-set limit. Hash a streaming read
        # bounded by the original captured size and reject any growth/change.
        self.source_sha256 = fingerprint(self.path, max_bytes=self._source_identity.metadata[3], cancel=cancel)
        check_cancel(cancel)
        if require_asset_presentation or (_ASSET_LOAD.get() and self.path.suffix.lower() in ('.mov','.mp4','.m4v')):
            self._load_owned_asset(cancel)
            created=_ASSET_CREATED.get()
            if created is not None: created.append(self)
            return
        av = _av()
        with av.open(str(self.path)) as container:
            videos = list(container.streams.video)
            if len(videos) != 1:
                raise VideoError('영상 스트림이 정확히 하나인 파일을 선택하세요.')
            video = videos[0]
            self.stream_index = video.index
            self.time_base = video.time_base
            if self.time_base is None or self.time_base <= 0:
                raise VideoError('영상 시간 기준을 읽을 수 없습니다.')
            if video.width <= 0 or video.height <= 0 or video.width > 16384 or video.height > 16384 or video.width * video.height > 33_177_600:
                raise VideoError('영상 원본 해상도가 지원 범위를 넘습니다.')
            self.sample_aspect_ratio = video.sample_aspect_ratio or Fraction(1)
            self.metadata = dict(video.metadata)
            self.average_rate = video.average_rate  # encoder hint only; never frame timestamps
            self.audio_codecs = tuple(s.codec_context.name for s in container.streams.audio)
            starts = [Fraction(s.start_time) * s.time_base for s in container.streams
                      if s.type in ('video', 'audio') and s.start_time is not None and s.time_base is not None]
            first = next(container.decode(video), None)
            check_cancel(cancel)
            if first is None:
                raise VideoError('영상 첫 프레임을 읽을 수 없습니다.')
            first_time = _timestamp(first)
            self.origin = min(starts) if starts else first_time
            self.first_frame_time = first_time - self.origin
            self.video_end = (Fraction(video.start_time) * video.time_base + Fraction(video.duration) * video.time_base
                              if video.start_time is not None and video.duration is not None else None)
            ends = [Fraction(s.start_time + s.duration) * s.time_base for s in container.streams
                    if s.type in ('video', 'audio') and s.start_time is not None and s.duration is not None and s.time_base is not None]
            if ends:
                duration = max(ends) - self.origin
            elif container.duration is not None:
                duration = Fraction(container.duration, av.time_base)
            else:
                # No FPS fallback: derive EOF from actual decoded PTS + frame duration.
                last = None
                with av.open(str(self.path)) as duration_input:
                    for frame in duration_input.decode(duration_input.streams[self.stream_index]):
                        check_cancel(cancel)
                        if last is not None and _timestamp(frame) <= _timestamp(last):
                            raise VideoError('영상 프레임 시간 순서를 해석할 수 없습니다.')
                        last = frame
                if last is None:
                    raise VideoError('영상 프레임을 읽을 수 없습니다.')
                if last.duration <= 0:
                    raise VideoError('마지막 프레임 길이를 읽을 수 없어 전체 길이를 추측하지 않습니다.')
                self.video_end = _timestamp(last) + last.duration * last.time_base
                duration = self.video_end - self.origin
            if duration <= 0 or not math.isfinite(duration):
                raise VideoError('영상의 실제 길이를 읽을 수 없습니다.')
            self.duration = float(duration)
            if not math.isfinite(self.first_frame_time) or not 0 <= self.first_frame_time < duration:
                raise VideoError('첫 프레임의 실제 시각이 영상 범위 밖입니다.')
            check_cancel(cancel)
            self._first_image = _display_image(first, self.sample_aspect_ratio, self.metadata)
        self.validate(cancel)

    def _load_owned_asset(self,cancel):
        from .canonical_transport import CanonicalSession
        candidate=CanonicalSession(self.path,self.source_sha256,cancel=cancel)
        try:
            meta=candidate.metadata['decoder']
            if (type(meta['timeBase']) is not Fraction or meta['timeBase']<=0
                    or type(meta['sar']) is not Fraction or meta['sar']<=0
                    or type(meta['legacyOrigin']) is not Fraction):
                raise VideoError('완료된 asset decoder metadata 검토가 필요합니다.')
            pixels,buffers=candidate.frame(candidate.first_time,cancel)
            image=self._asset_image(pixels,buffers)
            if pixels['presence']!='content' or image.isNull():
                raise VideoError('첫 실제 asset 프레임을 준비하지 못했습니다.')
            self._guard(); check_cancel(cancel)
            self.stream_index=meta['streamIndex']; self.time_base=meta['timeBase']
            self.sample_aspect_ratio=meta['sar']; self.metadata=dict(meta['metadata'])
            self.average_rate=meta['averageRate']; self.audio_codecs=meta['audioCodecs']
            self.origin=meta['legacyOrigin']  # v1 compatibility hold ONLY.
            self.video_end=meta['videoEnd']; self.asset_duration=candidate.duration
            self.duration=float(candidate.duration); self.first_frame_time=candidate.first_time
            self._first_image=image; self.asset_session=candidate
            self.validate(cancel)
        except BaseException as primary:
            self.asset_session=None
            try: candidate.close()
            except BaseException as cleanup:
                if cleanup is not primary:
                    primary.add_note(f'owned source load cleanup also failed: {cleanup!r}')
                    primary.__cause__=cleanup
                primary.retry_transport_close=candidate.close
            raise

    def _guard(self):
        if getattr(getattr(self,'asset_session',None),'_closed',False):
            raise VideoError('asset 디코더 세션이 무효화되었습니다. 원본을 다시 열어 주세요.')
        try:
            _check_identity(self.path, self._source_identity)
        except ValueError as error:
            raise VideoError('원본 영상이 변경되었습니다. 가림 위치를 다시 확인하세요.') from error
        if _signature(self.path) != self._identity:
            raise VideoError('원본 영상이 변경되었습니다. 가림 위치를 다시 확인하세요.')

    def validate(self, cancel=None):
        check_cancel(cancel)
        self._guard()
        if fingerprint(self.path, max_bytes=self._source_identity.metadata[3], cancel=cancel) != self.source_sha256:
            raise VideoError('원본 영상 지문이 바뀌었습니다. 기존 편집을 자동 적용하지 않습니다.')
        self._guard()
        check_cancel(cancel)
        session=getattr(self,'asset_session',None)
        if session is not None: session.validate(cancel)

    def page(self):
        self._guard()
        return Page(self.path, self.source_sha256, self._first_image.copy(), source_identity=self._source_identity)

    def verified_asset_binding(self, cancel=None):
        """Source-bound v3 authority. Never infer a timeline from file suffix/Qt."""
        session=getattr(self,'asset_session',None)
        if session is None:
            raise VideoError('이 영상의 실제 asset 시간축 검수가 필요합니다. 저장된 기간은 이동하지 않습니다.')
        self.validate(cancel)
        binding=session.verified_asset_binding(cancel)
        if binding.source_sha256 != self.source_sha256:
            raise VideoError('영상 프로젝트 원본 지문이 변경되었습니다.')
        self._guard(); check_cancel(cancel)
        return binding

    def enable_asset_transport(self, cancel=None):
        """UI load-worker transaction; preserve the legacy origin/save guard.

        Standalone decoder callers retain their existing API. The desktop opts
        into the verified MOV descriptor/complete EOF provider before commit.
        No v3 project binding or legacy producer is invented here.
        """
        if self.path.suffix.lower() not in ('.mov', '.mp4', '.m4v'):
            return False  # Existing other formats continue their explicit path.
        if getattr(self, 'asset_session', None) is not None: return True
        from .canonical_transport import CanonicalSession
        self.validate(cancel)
        candidate=CanonicalSession(self.path,self.source_sha256,cancel=cancel)
        try:
            metadata,buffers=candidate.frame(candidate.first_time,cancel)
            image=self._asset_image(metadata,buffers)
            if metadata['presence']!='content' or image.isNull():
                raise VideoError('asset 첫 실제 프레임을 확인하지 못했습니다.')
            self._guard(); check_cancel(cancel)
        except BaseException as primary:
            try: candidate.close()
            except BaseException as cleanup:
                if cleanup is not primary:
                    primary.add_note(f'asset candidate cleanup also failed: {cleanup!r}')
                    primary.__cause__=cleanup
                primary.retry_transport_close=candidate.close
            raise
        self.asset_session=candidate
        self.asset_duration=candidate.duration
        self.duration=float(candidate.duration)
        self.first_frame_time=candidate.first_time
        self._first_image=image
        return True

    @staticmethod
    def _asset_image(metadata,buffers):
        if metadata['presence']!='content': return QImage()
        width,height=metadata.get('width'),metadata.get('height')
        if (type(width) is not int or type(height) is not int or not 0<width<=16384 or
                not 0<height<=16384 or width*height>33_177_600 or len(buffers)!=1 or
                len(buffers[0])!=width*height*4):
            raise VideoError('asset 프레임의 실제 크기 또는 pixel bytes가 올바르지 않습니다.')
        return QImage(buffers[0],width,height,width*4,QImage.Format.Format_RGBA8888).copy()

    def close_asset_transport(self):
        session=getattr(self,'asset_session',None)
        self.asset_session=None
        if session is not None: session.close_async()

    def render_time(self, stamp):
        return stamp if getattr(self,'asset_session',None) is not None else stamp-self.origin

    def frame_at(self, time, cancel=None):
        """Backwards-compatible image-only wrapper; new previews use actual PTS."""
        return self.frame_at_timed(time, cancel=cancel).image

    def frame_at_timed(self, time, cancel=None):
        """Frame displayed at time: hold preceding actual PTS, not nearest frame/FPS."""
        session=getattr(self,'asset_session',None)
        if session is not None:
            from .canonical_transport import exact_time
            stamp=exact_time(time)
            if stamp>session.duration: raise VideoError('asset 영상 구간 밖입니다.')
            self._guard()
            metadata,buffers=session.frame(stamp,cancel)
            image=self._asset_image(metadata,buffers)
            if metadata['presence']!='content':
                # Explicit absence, NOT a decoded frame or a guessed held image.
                # The canvas shows its normal blank background at asset time.
                image=QImage(self._first_image.size(),QImage.Format.Format_RGBA8888)
                image.fill(0)
            self._guard(); check_cancel(cancel)
            return TimedImage(metadata['time'] if metadata['time'] is not None else stamp,
                              image,metadata['presence'],metadata.get('intervalEnd'),
                              metadata.get('sourceIndex'),metadata.get('intervalStart'))
        if not math.isfinite(time):
            raise VideoError('재생 시각이 올바르지 않습니다.')
        target = self.origin + Fraction(str(max(0, min(self.duration, time))))
        check_cancel(cancel)
        self._guard()
        with _av().open(str(self.path)) as container:
            stream = container.streams[self.stream_index]
            try:
                container.seek(math.floor(target / stream.time_base), stream=stream, backward=True, any_frame=False)
            except Exception:
                # A fresh container has no reused decoder state; unsupported seeks decode from start.
                container.close()
                with _av().open(str(self.path)) as beginning:
                    image = self._frame_from_decode(beginning.decode(beginning.streams[self.stream_index]), target, cancel)
                self._guard()
                check_cancel(cancel)
                return image
            image = self._frame_from_decode(container.decode(stream), target, cancel)
        self._guard()
        check_cancel(cancel)
        return image

    def _frame_from_decode(self, frames, target, cancel=None):
        chosen = None
        last_time = None
        for frame in frames:
            check_cancel(cancel)
            stamp = _timestamp(frame)
            if last_time is not None and stamp <= last_time:
                raise VideoError('영상 프레임 PTS가 증가하지 않습니다.')
            last_time = stamp
            if chosen is not None and stamp > target:
                break
            chosen = frame
            if stamp > target:
                break
        if chosen is None:
            # Exact EOF seeks can return no frame; decode from start rather than guess an index.
            with _av().open(str(self.path)) as beginning:
                for frame in beginning.decode(beginning.streams[self.stream_index]):
                    check_cancel(cancel)
                    stamp = _timestamp(frame)
                    if chosen is not None and stamp > target:
                        break
                    chosen = frame
                    if stamp > target:
                        break
                if chosen is None:
                    raise VideoError('요청 시각의 프레임을 읽을 수 없습니다.')
        time = _timestamp(chosen) - self.origin
        if not math.isfinite(time) or not 0 <= time <= self.duration:
            raise VideoError('선택한 프레임의 실제 시각이 영상 범위 밖입니다.')
        check_cancel(cancel)
        return TimedImage(time, _display_image(chosen, self.sample_aspect_ratio, self.metadata))

    def iter_frames(self, start=0, end=None, cancel=None):
        """Chronological source frames with presentation seconds relative to origin."""
        self._guard()
        end = self.duration if end is None else end
        if not all(math.isfinite(t) for t in (start, end)) or not 0 <= start <= end <= self.duration:
            raise VideoError('프레임 구간이 원래 영상 길이 밖입니다.')
        session=getattr(self,'asset_session',None)
        if session is not None:
            from .canonical_transport import exact_time
            cursor=session.iter_frames(exact_time(start),exact_time(end),cancel)
            try:
                for meta,buffers in cursor:
                    self._guard(); check_cancel(cancel)
                    if meta.get('presence')!='content' or type(meta.get('time')) is not Fraction:
                        raise VideoError('canonical tracking frame membership changed')
                    yield TimedImage(meta['time'],self._asset_image(meta,buffers),'content',
                        meta.get('intervalEnd'),meta.get('sourceIndex'),meta.get('intervalStart'))
            finally:
                from .media import _cleanup_preserving_primary
                _cleanup_preserving_primary(cursor.close,'canonical frame cursor close')
            self.validate(cancel)
            return
        previous = None
        with _av().open(str(self.path)) as container:
            for frame in container.decode(container.streams[self.stream_index]):
                check_cancel(cancel)
                stamp = _timestamp(frame)
                if previous is not None and stamp <= previous:
                    raise VideoError('영상 프레임 PTS가 증가하지 않습니다.')
                previous = stamp
                time = self.render_time(stamp)
                if time > Fraction(str(end)):
                    break
                if time >= Fraction(str(start)):
                    yield TimedImage(time, _display_image(frame, self.sample_aspect_ratio, self.metadata))
        self._guard()


def _export_asset_video(source,state,target,cancel,progress,quality):
    """Dedicated native attempt; cancellation preserves the live preview owner."""
    from .canonical_transport import CanonicalSession
    from .media import _cleanup_preserving_primary
    source.validate(cancel); check_cancel(cancel)
    expected=source.verified_asset_binding(cancel)
    attempt=None; temporary=None
    try:
        attempt=CanonicalSession(source.path,source.source_sha256,cancel=cancel)
        actual=attempt.verified_asset_binding(cancel)
        if actual!=expected:
            raise VideoError('내보내기 원본·asset 시간축이 기존 편집과 다릅니다.')
        artifact,report=attempt.export_private(deepcopy(state),quality.value,target.suffix.lower(),cancel,progress)
        fd,name=tempfile.mkstemp(prefix='.bluraction-video-',suffix=target.suffix,dir=target.parent)
        temporary=Path(name)
        digest=hashlib.sha256()
        flags=os.O_RDONLY|getattr(os,'O_BINARY',0)|getattr(os,'O_NOFOLLOW',0)
        with os.fdopen(fd,'wb') as out, os.fdopen(os.open(artifact,flags),'rb') as stream:
            before=os.fstat(stream.fileno())
            while True:
                check_cancel(cancel); source._guard()
                data=stream.read(1024*1024)
                if not data: break
                digest.update(data); out.write(data)
            after=os.fstat(stream.fileno())
            if (before.st_dev,before.st_ino,before.st_size,before.st_mtime_ns,before.st_ctime_ns) != (after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns,after.st_ctime_ns):
                raise VideoError('검수한 영상 출력 후보가 복사 중 변경되었습니다.')
            out.flush(); os.fsync(out.fileno())
        if digest.hexdigest()!=report['outputSHA256']:
            raise VideoError('검수한 출력 후보의 전체 지문이 다릅니다.')
        copy_identity=_capture_identity(temporary)
        if fingerprint(temporary,max_bytes=copy_identity.metadata[3],cancel=cancel)!=report['outputSHA256']:
            raise VideoError('발행할 출력 복사본의 지문이 변경되었습니다.')
        _check_identity(temporary,copy_identity)
        source.validate(cancel); attempt.validate(cancel); check_cancel(cancel)
        attempt.close(); attempt=None  # Reap before public output can exist.
        source.validate(cancel); check_cancel(cancel)
        _check_identity(temporary,copy_identity)
        publish_new(temporary,target)
    finally:
        if attempt is not None:
            _cleanup_preserving_primary(attempt.close,'owned export process reap')
        if temporary is not None:
            _cleanup_preserving_primary(lambda:temporary.unlink(missing_ok=True),'owned video temp cleanup')
    if progress is not None: progress(1.0)
    return target


def export_video(source, state, path, cancel=None, progress=None, *, quality=QualityPreset.HIGH):
    """Fresh verified MOV/MP4 output using the source's declared clock.

    Owned asset sources use canonical content/empty scenes, all PCM schedules
    and exact EOF readback. MOV preserves meaningful PCM bytes; MP4 explicitly
    encodes AAC and verifies sample coverage. Legacy generic sources retain the
    existing raw packet route until their asset contracts are proven.
    """
    quality = QualityPreset(quality)
    target = fresh_target(path)
    if target.suffix.lower() not in ('.mp4', '.mov', '.m4v'):
        raise VideoError('영상 출력은 MP4 또는 MOV의 새 파일 이름을 선택하세요.')
    if getattr(source,'asset_session',None) is not None:
        return _export_asset_video(source,state,target,cancel,progress,quality)
    source.validate(cancel); check_cancel(cancel)
    capability = encoder_capability()
    if not capability['registered']:
        raise VideoError(f"승인된 영상 인코더 {capability['encoder']}를 사용할 수 없습니다: {capability['reason']}")
    state = deepcopy(state)
    fd, name = tempfile.mkstemp(prefix='.bluraction-video-', suffix=target.suffix, dir=target.parent)
    os.close(fd)
    av = _av()
    try:
        with av.open(str(source.path)) as input_, av.open(name, 'w', options={'avoid_negative_ts': 'disabled'}) as output:
            video = input_.streams[source.stream_index]
            if any(s.type not in ('video', 'audio') for s in input_.streams):
                raise VideoError('자막·데이터 등 추가 스트림은 보존 방식 검토가 필요합니다. 삭제하여 저장하지 않습니다.')
            result = output.add_stream(capability['encoder'], rate=source.average_rate)
            result.width, result.height = source._first_image.width(), source._first_image.height()
            if result.width % 2 or result.height % 2:
                raise VideoError('현재 H.264 인코더는 짝수 영상 크기가 필요합니다. 자동으로 자르지 않습니다.')
            result.pix_fmt = 'nv12' if capability['encoder'] == 'h264_mf' else 'yuv420p'
            result.time_base = video.time_base
            result.codec_context.time_base = video.time_base
            result.codec_context.max_b_frames = 0
            result.codec_context.sample_aspect_ratio = Fraction(1)
            result.bit_rate = output_bit_rate(quality, video.bit_rate or 0,
                                              float(source.average_rate) if source.average_rate is not None else 0,
                                              result.width, result.height)
            result.set_display_rotation(0)
            audio = {}
            for stream in input_.streams.audio:
                try:
                    audio[stream.index] = output.add_stream_from_template(stream)
                except Exception as error:
                    raise VideoError(f'원래 오디오 {stream.codec_context.name}를 이 형식에 그대로 보존할 수 없습니다. 다른 형식을 검토하세요.') from error
            output.start_encoding()  # actual encoder/device/format capability, before publication
            durations = {}
            last_time = None
            pending = None
            reported = 0.0
            def report(stamp):
                nonlocal reported
                reported = max(reported, min(.98, max(0, float(source.render_time(stamp)) / source.duration)))
                if progress:
                    progress(reported)
                check_cancel(cancel)
            def mux_video(packets):
                for packet in packets:
                    check_cancel(cancel)
                    if packet.pts is None or packet.time_base is None:
                        raise VideoError('인코더가 원래 프레임의 표시 시각을 보존하지 못했습니다.')
                    stamp = packet.pts * packet.time_base
                    duration = durations.pop(stamp, None)
                    if duration is None:
                        raise VideoError('인코더가 프레임 PTS를 변경하여 원래 시간축을 보존하지 못했습니다.')
                    ticks = duration / packet.time_base
                    if ticks.denominator != 1:
                        raise VideoError('인코더 시간 기준에서 프레임 길이를 정확히 표현할 수 없습니다.')
                    packet.duration = int(ticks)
                    output.mux(packet)
            def encode(frame, end_stamp):
                stamp = _timestamp(frame)
                duration = (frame.duration * frame.time_base) if frame.duration > 0 else end_stamp - stamp
                if duration <= 0:
                    raise VideoError('원래 프레임의 길이를 보존할 수 없습니다.')
                image = _display_image(frame, source.sample_aspect_ratio, source.metadata)
                flattened = render(image, state, time=float(source.render_time(stamp)))
                converted = av.VideoFrame.from_image(to_pillow(flattened).convert('RGB'))
                converted.pts, converted.time_base = frame.pts, frame.time_base
                converted.duration = max(1, round(duration / frame.time_base))
                durations[stamp] = duration
                mux_video(result.encode(converted))
                report(stamp)
            selected = [video, *input_.streams.audio]
            for packet in input_.demux(selected):
                check_cancel(cancel); source._guard()
                if packet.stream.index in audio:
                    if packet.dts is None:
                        if packet.size:
                            raise VideoError('오디오 패킷의 실제 DTS가 없어 보존할 수 없습니다.')
                        continue  # demux flush packet
                    if packet.pts is None:
                        raise VideoError('오디오 패킷의 실제 PTS가 없어 보존할 수 없습니다.')
                    packet.stream = audio[packet.stream.index]
                    output.mux(packet)  # original PTS/DTS/time_base/duration and encoded bytes
                    continue
                for frame in packet.decode():
                    stamp = _timestamp(frame)
                    if last_time is not None and stamp <= last_time:
                        raise VideoError('원래 영상의 프레임 PTS가 증가하지 않습니다.')
                    if pending is not None:
                        encode(pending, stamp)
                    pending, last_time = frame, stamp
            if pending is None:
                raise VideoError('내보낼 영상 프레임이 없습니다.')
            end_stamp = source.video_end
            if end_stamp is None and pending.duration > 0:
                end_stamp = _timestamp(pending) + pending.duration * pending.time_base
            if end_stamp is None:
                raise VideoError('마지막 프레임 길이를 알 수 없어 FPS로 추측하지 않습니다.')
            encode(pending, end_stamp)
            mux_video(result.encode(None))
            if durations:
                raise VideoError('인코더에서 일부 프레임이 누락되었습니다.')
        source.validate(cancel); check_cancel(cancel)
        publish_new(name, target)
    except (VideoError, Cancelled, FileExistsError, IncompleteOutputError):
        raise
    except Exception as error:
        raise VideoError('영상·오디오의 시간 또는 인코더 지원을 보존하지 못해 새 파일을 발행하지 않았습니다: ' + str(error)) from error
    finally:
        Path(name).unlink(missing_ok=True)
    # Publication is complete. A progress callback failure must not be reported
    # as an encoding failure claiming that no output was published.
    if progress:
        progress(1.0)
    return target


def _csrt():
    try:
        import cv2
    except ImportError as error:
        raise VideoError('자동 추적에는 별도 승인한 OpenCV CSRT 런타임이 필요합니다.') from error
    factory = getattr(cv2, 'TrackerCSRT_create', None)
    if factory is None:
        factory = getattr(getattr(cv2, 'legacy', None), 'TrackerCSRT_create', None)
    if factory is None:
        raise VideoError('이 OpenCV 구성에는 CSRT 추적기가 없습니다. 다른 알고리즘으로 바꾸지 않습니다.')
    return cv2, factory()


def _bgr(image):
    try:
        import numpy as np  # OpenCV/PyAV frame-array runtime dependency
    except ImportError as error:
        raise VideoError('추적 프레임 변환에는 승인한 OpenCV의 NumPy 런타임이 필요합니다.') from error
    return np.ascontiguousarray(np.asarray(to_pillow(image).convert('RGB'))[:, :, ::-1])


def track(source, item, region, start, end, cancel=None, progress=None):
    """Track regions' boxes, but translate drawings without changing their size."""
    if not all(math.isfinite(t) for t in (start, end)) or not 0 <= start < end <= source.duration:
        raise VideoError('추적 시작·끝 시각을 원래 영상 길이 안에서 지정하세요.')
    item = deepcopy(item)
    properties = item['effect'] if region else item
    if properties.get('locked') or (region and not properties.get('enabled', True)) or (not region and properties.get('hidden')):
        raise VideoError('잠금 또는 숨김 항목은 추적하지 않습니다.')
    source.validate(cancel); check_cancel(cancel)
    _, tracker = _csrt()
    initial_timed = source.frame_at_timed(start, cancel=cancel)
    if initial_timed.presence != 'content':
        raise TrackingLost('추적 시작 시각에 실제 영상 프레임이 없습니다. 기존 편집은 유지됩니다.')
    initial = initial_timed.image
    shown = positioned(item, region, float(initial_timed.time))
    points = shape_points(shown)[1] if region else shown['points']
    x, y, w, h = bounds(points)
    width, height = initial.width(), initial.height()
    roi = (math.floor(x * width), math.floor((1 - y - h) * height), math.ceil(w * width), math.ceil(h * height))
    if roi[2] < 2 or roi[3] < 2 or roi[0] < 0 or roi[1] < 0 or roi[0] + roi[2] > width or roi[1] + roi[3] > height:
        raise VideoError('추적 영역은 영상 안에 있는 2화소 이상 영역이어야 합니다.')
    if tracker.init(_bgr(initial), roi) is False:
        raise TrackingLost('추적 영역을 초기화하지 못했습니다. 기존 편집은 유지됩니다.')
    initial_center = (roi[0] + roi[2] / 2, roi[1] + roi[3] / 2)
    frames = [{'time': start, 'rect': [[x, y], [w, h]]}]
    interval_end = initial_timed.interval_end
    initial_index = initial_timed.source_index
    cursor = iter(source.iter_frames(start, end, cancel))
    try:
        for timed in cursor:
            time = float(timed.time)
            if time <= start or (initial_index is not None and timed.source_index == initial_index):
                continue  # the initialized presentation frame
            if timed.presence != 'content' or (interval_end is not None and timed.time > interval_end):
                raise TrackingLost('추적 구간의 실제 영상이 끊겼습니다. 부분 경로를 적용하지 않습니다.')
            interval_end = timed.interval_end
            check_cancel(cancel)
            if timed.image.size() != initial.size():
                raise TrackingLost('추적 중 영상 크기가 바뀌었습니다. 기존 편집은 유지됩니다.')
            success, box = tracker.update(_bgr(timed.image))
            if not success:
                raise TrackingLost(f'{time:.3f}초에서 대상을 잃었습니다. 부분 추적을 적용하지 않습니다.')
            left, top, box_width, box_height = box
            if not all(math.isfinite(v) for v in box) or box_width < 2 or box_height < 2 or left < 0 or top < 0 or left + box_width > width or top + box_height > height:
                raise TrackingLost('추적 영역이 영상 밖으로 벗어났습니다. 부분 추적을 적용하지 않습니다.')
            if region:
                rect = [[left / width, 1 - (top + box_height) / height], [box_width / width, box_height / height]]
            else:
                # The tracked target may grow/shrink. As on macOS, a drawing keeps
                # its displayed starting dimensions and follows only the center.
                # Subtract the initialized integer ROI center to avoid a rounding
                # jump between normalized annotation points and CSRT pixel boxes.
                moved_x = x + (left + box_width / 2 - initial_center[0]) / width
                moved_y = y - (top + box_height / 2 - initial_center[1]) / height
                if moved_x < -1e-9 or moved_y < -1e-9 or moved_x + w > 1 + 1e-9 or moved_y + h > 1 + 1e-9:
                    raise TrackingLost('추적한 그림이 영상 밖으로 벗어났습니다. 부분 추적을 적용하지 않습니다.')
                rect = [[moved_x, moved_y], [w, h]]
            frames.append({'time': time, 'rect': rect})
            if len(frames) > 100_000:
                raise VideoError('추적 키프레임은 최대 100,000개입니다.')
            if progress:
                progress(min(.99, (time - start) / (end - start)))
            check_cancel(cancel)
    finally:
        close = getattr(cursor, 'close', None)
        if close is not None:
            from .media import _cleanup_preserving_primary
            _cleanup_preserving_primary(close, 'tracking canonical cursor close')
    if interval_end is not None and end > interval_end:
        raise TrackingLost('추적 끝 시각까지 실제 영상이 이어지지 않습니다. 부분 경로를 적용하지 않습니다.')
    if len(frames) < 2:
        raise TrackingLost('추적 구간에 실제 프레임이 부족합니다. 기존 편집은 유지됩니다.')
    source.validate(cancel); check_cancel(cancel)
    # Preserve the recorded path outside the requested range; no item/model mutation.
    frames.extend(deepcopy(f) for f in properties.get('keyframes', []) if f['time'] < start or f['time'] > end)
    frames.sort(key=lambda f: f['time'])
    if len(frames) > 100_000:
        raise VideoError('기존 기록과 추적 결과가 키프레임 제한을 넘습니다.')
    if progress:
        progress(1.0)
    check_cancel(cancel)
    return frames
