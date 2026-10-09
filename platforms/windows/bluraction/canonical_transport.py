"""Owned MOV asset transport. Native decoding runs in a deadline-owned process.

No Qt player's duration/offset is a source clock. PCM queries use the completed
private spool snapshot under the provider's metadata/generation guards; full SHA
is required at build, explicit validation and save/export, never in an audio
device callback. This internal adapter will move behind the provider API when
that independently owned module is unfrozen. Device/mixing/resampling support is
separate from these exact bytes. Unsupported cases remain visible review holds.
"""
from __future__ import annotations
from dataclasses import dataclass, asdict
from fractions import Fraction
import json
import hashlib
import os
import stat
import math
import multiprocessing
from multiprocessing.reduction import ForkingPickler
from pathlib import Path
import socket
import struct
import tempfile
import threading
import time

from .media import Cancelled, check_cancel, _capture_identity, _check_identity


class TransportReview(ValueError):
    pass


@dataclass(frozen=True)
class VideoAssetBinding:
    """Immutable completed-source descriptor; public dicts are never authority.

    Construction validates a child observation, not arbitrary saved metadata.
    The owning session still performs full source validation before returning it.
    """
    source_sha256: str
    descriptor_sha256: str
    _timeline_json: bytes

    @classmethod
    def observed(cls, metadata, source_sha256, duration):
        from shared.video_timeline import validate_timeline, rational
        from .canonical_frames import descriptor_sha256
        timeline=metadata.get('timeline')
        validate_timeline(timeline)
        digest=descriptor_sha256(timeline)
        if (metadata.get('sha256') != source_sha256 or
                metadata.get('descriptorSHA256') != digest or
                rational(timeline['assetDuration']) != duration):
            raise TransportReview('completed source/timeline binding changed')
        frozen=json.dumps(timeline,sort_keys=True,separators=(',', ':'),ensure_ascii=True).encode('ascii')
        return cls(source_sha256,digest,frozen)

    @property
    def timeline(self):
        return json.loads(self._timeline_json)


class _TransportChannel:
    """Private socket framing; deadlines cover header AND every body byte.

    Spawn transfers only this owned socket. Unlike Connection.poll()+recv(), a
    partial header/body cannot move the caller into an unbounded read. Both OS
    backends use the same framing; no Windows named-pipe internals are assumed.
    """
    def __init__(self, sock):
        self.socket = sock
        # Windows socketpair uses loopback TCP. Tiny RPC/header messages must
        # not wait for Nagle + delayed ACK before every video frame.
        if getattr(sock,'family',None) in (socket.AF_INET,socket.AF_INET6):
            sock.setsockopt(socket.IPPROTO_TCP,socket.TCP_NODELAY,1)
        # A plain process-local bool is spawn-pickleable. Only the parent
        # channel's own shutdown interrupts its worker; no Event/global state
        # is shared with a decoder or an unrelated session.
        self._interrupted = False

    def fileno(self): return self.socket.fileno()

    def _timeout(self, deadline, cancel=None):
        if self._interrupted:
            raise TransportReview('owned decoder channel interrupted')
        check_cancel(cancel)
        remaining = None if deadline is None else deadline - time.monotonic()
        if remaining is not None and remaining <= 0:
            raise TransportReview('native media deadline exceeded')
        self.socket.settimeout(None if remaining is None else min(.05, remaining))

    def _read(self, count, deadline, cancel):
        data = bytearray()
        while len(data) < count:
            self._timeout(deadline, cancel)
            try: block = self.socket.recv(min(count-len(data), 65536))
            except TimeoutError as error:
                if deadline is not None and time.monotonic() < deadline:
                    continue
                raise TransportReview('native media deadline exceeded') from error
            if not block: raise EOFError('owned decoder stream ended before completion')
            data.extend(block)
        return bytes(data)

    def recv_bytes(self, maximum=1_048_576, *, deadline=None, cancel=None):
        size, = struct.unpack('!I', self._read(4, deadline, cancel))
        if size > maximum: raise TransportReview('bounded native message required')
        return self._read(size, deadline, cancel)

    def recv(self, *, deadline=None, cancel=None):
        return ForkingPickler.loads(self.recv_bytes(deadline=deadline, cancel=cancel))

    def send_bytes(self, data, *, deadline=None):
        if len(data) > 1_048_576: raise TransportReview('bounded native message required')
        view=memoryview(struct.pack('!I', len(data)) + bytes(data))
        while view:
            self._timeout(deadline)
            try: count=self.socket.send(view)
            except TimeoutError as error:
                if deadline is not None and time.monotonic()<deadline: continue
                raise TransportReview('native media deadline exceeded') from error
            if not count: raise EOFError('owned decoder stream ended during send')
            view=view[count:]

    def send(self, value, *, deadline=None):
        self.send_bytes(ForkingPickler.dumps(value), deadline=deadline)

    def interrupt(self):
        # May be called without the RPC lock to wake a partial-body read/send.
        # Windows shutdown may fail/not wake the current receive. Each bounded
        # timeout/chunk observes this latch regardless of native wake behavior.
        self._interrupted = True
        try: self.socket.shutdown(socket.SHUT_RDWR)
        except OSError: pass

    def close(self): self.socket.close()


def exact_time(value):
    if type(value) is Fraction:
        result = value
    elif type(value) is int:
        result = Fraction(value)
    elif type(value) is float and math.isfinite(value):
        result = Fraction(str(value))
    else:
        raise TransportReview('유효한 asset 시각이 필요합니다.')
    if result < 0: raise TransportReview('asset 시각은 음수일 수 없습니다.')
    return result


class AssetClock:
    """Continuous transport target, separate from the actually presented PTS."""
    def __init__(self, duration, monotonic=time.monotonic):
        self.duration = exact_time(duration)
        if self.duration <= 0: raise TransportReview('positive asset duration required')
        self._now = monotonic
        self.anchor = Fraction(0)
        self.started = None
        self.epoch = 0

    @property
    def playing(self): return self.started is not None

    def position(self):
        if self.started is None: return self.anchor
        elapsed = self._now()-self.started
        if not math.isfinite(elapsed) or elapsed < 0: raise TransportReview('monotonic clock changed')
        return min(self.duration, self.anchor+Fraction(str(elapsed)))

    def seek(self, target):
        target = exact_time(target)
        if target > self.duration: raise TransportReview('seek outside asset duration')
        self.anchor, self.started = target, None
        self.epoch += 1
        return self.epoch

    def play(self):
        if self.started is None and self.anchor < self.duration: self.started = self._now()

    def pause(self):
        self.anchor, self.started = self.position(), None
        return self.anchor


def snapshot_pcm(provider, identity, stamp, count):
    """Completed spool API; native original-source IO stays on the child worker."""
    return provider.read_snapshot_samples(identity, stamp, count)


def packed_pcm(chunk):
    """Byte-preserving interleave; no float conversion or guessed silence."""
    fmt=chunk.format
    if chunk.presence!='content': raise TransportReview('only observed PCM is packed')
    channels,width=len(fmt.channels),fmt.bytes_per_sample
    if chunk.samples*channels*width > 1_048_576: raise TransportReview('PCM ring query exceeds 1MiB')
    if not fmt.planar: return chunk.planes[0]
    if len(chunk.planes)!=channels or any(len(p)!=chunk.samples*width for p in chunk.planes):
        raise TransportReview('PCM plane shape changed')
    data=bytearray(chunk.samples*channels*width)
    for sample in range(chunk.samples):
        for channel in range(channels):
            offset=(sample*channels+channel)*width
            data[offset:offset+width]=chunk.planes[channel][sample*width:(sample+1)*width]
    return bytes(data)


def snapshot_frame(provider, stamp, maximum_edge=None):
    """Provider-bound pixels; completed index plus metadata guards at each decode.

    Full source revalidation is an explicit worker transaction, not a per-frame
    UI hash. The raw inventory row and fresh decoded row must STILL be equal.
    """
    from .canonical_video import CanonicalPixels, _SeekUnavailable
    with provider._lock:
        try:
            provider._guard()
            presence=provider._index.presence(stamp)
            sample=presence.sample
            image=None
            if sample is not None:
                if provider._cached_index!=sample.source_index or provider._cached_edge!=maximum_edge:
                    image=provider.preview_pixels(sample,maximum_edge=maximum_edge)
                    provider._cached_index,provider._cached_image=sample.source_index,image
                    provider._cached_edge=maximum_edge
                image=provider._cached_image.copy()
            provider._guard()
            return CanonicalPixels(presence.kind,stamp,None if sample is None else sample.asset_pts,
                None if sample is None else sample.interval_start,None if sample is None else sample.interval_end,
                None if sample is None else sample.source_index,image,provider._sha,provider._descriptor_sha,
                provider._generation)
        except BaseException as error:
            provider._discard(error); raise


def _send(connection, metadata, buffers=()):
    connection.send((metadata,tuple(len(b) for b in buffers)))
    for buffer in buffers:
        for start in range(0,len(buffer),65536): connection.send_bytes(buffer[start:start+65536])


def _pixel_reply(sequence, result, kind='frame', maximum_edge=None):
    from PySide6.QtGui import QImage
    meta = dict(sequence=sequence, kind=kind, presence=result.presence,
        time=result.asset_pts, requested=result.requested_time,
        intervalStart=result.interval_start, intervalEnd=result.interval_end,
        sourceIndex=result.source_index, sha256=result.source_sha256,
        descriptorSHA256=result.descriptor_sha256)
    buffers = ()
    if result.image is not None:
        image = result.image.convertToFormat(QImage.Format.Format_RGBA8888)
        if maximum_edge is not None and max(image.width(),image.height()) > maximum_edge:
            from PySide6.QtCore import Qt
            image=image.scaled(maximum_edge,maximum_edge,Qt.AspectRatioMode.KeepAspectRatio,
                               Qt.TransformationMode.SmoothTransformation)
        meta.update(width=image.width(), height=image.height())
        view = image.constBits()
        buffers = ((bytes(view) if image.bytesPerLine()==image.width()*4 else
            b''.join(bytes(view[y*image.bytesPerLine():y*image.bytesPerLine()+image.width()*4])
                for y in range(image.height()))),)
    return meta, buffers


def _export_state(work, digest):
    """The request is a new parent-owned file in this private process tree."""
    path = Path(work)/'export-state.json'
    before = path.lstat()
    if not stat.S_ISREG(before.st_mode) or before.st_size > 20*1024*1024:
        raise TransportReview('bounded regular export-state request required')
    flags = os.O_RDONLY | getattr(os,'O_BINARY',0) | getattr(os,'O_NOFOLLOW',0)
    with os.fdopen(os.open(path,flags),'rb') as stream:
        opened = os.fstat(stream.fileno())
        if (opened.st_dev,opened.st_ino,opened.st_size) != (before.st_dev,before.st_ino,before.st_size):
            raise TransportReview('export state replaced before read')
        data = stream.read(20*1024*1024+1)
        if hashlib.sha256(data).hexdigest() != digest:
            raise TransportReview('immutable export-state SHA changed')
        identity=lambda row:(row.st_dev,row.st_ino,row.st_mode,row.st_size,row.st_mtime_ns,row.st_ctime_ns)
        if identity(os.fstat(stream.fileno())) != identity(opened) or identity(path.lstat()) != identity(before):
            raise TransportReview('export-state request changed during read')
    from shared.portable_project import _edits, _json_tree
    value = json.loads(data)
    _json_tree(value)
    reviews=[]
    _edits(value, '$', reviews)
    if reviews: raise TransportReview('unknown export edit fields require explicit review')
    return value


def _decoder_process(connection, path, sha, work):
    """No QApplication, audio device, network or outside output path."""
    tempfile.tempdir=work  # This child only; parent owns/reaps/cleans this tree.
    video=audio=cursor=None
    try:
        from .canonical_video import OwnedCanonicalVideoProvider, DecoderAccess
        from .canonical_audio import OwnedCanonicalAudioProvider
        from .frame_inventory import FrameInventory, _exact_fraction
        from .local_decoder import open_local_decoder
        from PySide6.QtGui import QImage
        video=OwnedCanonicalVideoProvider.build(path,expected_sha256=sha,generation=1,
            decoder_access=DecoderAccess(FrameInventory.build,open_local_decoder))
        audio=OwnedCanonicalAudioProvider.build(path,expected_sha256=sha,generation=1,
            decoder_clock_mode='ffmpeg-editlist-applied',expected_timeline=video.timeline)
        first=next(video._index.iter_samples(),None)
        if first is None: raise TransportReview('MOV has no actual content video sample')
        # Metadata only, from the SAME guarded child decoder. Legacy origin is
        # retained solely for rejecting ambiguous v1 edits, never a frame clock.
        with video._decoder() as container:
            streams=list(container.streams)
            stream=container.streams[video._inventory.decoder.stream_index]
            starts=[Fraction(s.start_time)*_exact_fraction(s.time_base,'stream time base') for s in streams
                    if s.type in ('video','audio') and s.start_time is not None and s.time_base is not None]
            raw_first=video._inventory[0]
            raw_last=video._inventory[-1]
            time_base=_exact_fraction(stream.time_base,'video time base')
            # Handshake, preview, tracking and export share one display policy.
            from .display_geometry import resolve_display_sar, DisplayGeometryError
            try:
                sar=resolve_display_sar(first.observation.frame_sar,
                    video._inventory.decoder.codec_sar, video._inventory.decoder.guessed_stream_sar)
            except DisplayGeometryError as error:
                raise TransportReview(str(error)) from error
            average_rate=None if stream.average_rate is None else _exact_fraction(stream.average_rate,'average rate')
            decoder_meta=dict(streamIndex=stream.index,timeBase=time_base,
                sar=sar,
                metadata=dict(stream.metadata),averageRate=average_rate,
                audioCodecs=tuple(s.codec_context.name for s in container.streams.audio),
                bitRate=stream.bit_rate or 0,
                legacyOrigin=min(starts) if starts else raw_first.pts,
                videoEnd=(Fraction(stream.start_time+stream.duration)*time_base
                    if stream.start_time is not None and stream.duration is not None else raw_last.pts+raw_last.duration))
        _send(connection,{'kind':'ready','duration':video.asset_duration,'firstTime':first.asset_pts,
            'timeline':video.timeline,'descriptorSHA256':video.descriptor_sha256,
            'audioTracks':tuple(asdict(t) for t in audio.tracks),'sha256':sha,'decoder':decoder_meta})
        while True:
            request=connection.recv()
            sequence,operation,args=request
            if operation=='close': break
            if operation=='validate':
                video._guard(hash_source=True); audio._guard(hash_source=True)
                _send(connection,{'sequence':sequence,'kind':'validated','sha256':sha})
            elif operation in ('frame','preview'):
                result=snapshot_frame(video,args[0],maximum_edge=640 if operation=='preview' else None)
                if result.presence=='content-no-sample':
                    raise TransportReview('content video sample missing; no future/last substitute')
                meta,buffers=_pixel_reply(sequence,result,maximum_edge=640 if operation=='preview' else None)
                _send(connection,meta,buffers)
            elif operation=='cursor_open':
                if cursor is not None: raise TransportReview('only one sequential cursor per owned decoder')
                cursor=iter(video.iter_content(*args))
                _send(connection,{'sequence':sequence,'kind':'cursor_ready','sha256':sha})
            elif operation=='cursor_next':
                if cursor is None: raise TransportReview('sequential cursor missing')
                result=next(cursor,None)
                if result is None:
                    cursor.close(); cursor=None
                    _send(connection,{'sequence':sequence,'kind':'cursor_EOF','sha256':sha})
                else:
                    meta,buffers=_pixel_reply(sequence,result,'cursor_frame')
                    _send(connection,meta,buffers)
            elif operation=='cursor_close':
                if cursor is not None: cursor.close(); cursor=None
                _send(connection,{'sequence':sequence,'kind':'cursor_closed','sha256':sha})
            elif operation=='export':
                if cursor is not None: raise TransportReview('export cannot share an active pixel cursor')
                quality,suffix,state_sha=args
                if suffix not in ('.mov','.mp4','.m4v'): raise TransportReview('exclusive MOV/MP4 export required')
                from .canonical_export import encode_from_providers
                from .video import encoder_capability
                capability=encoder_capability()
                if not capability['registered']: raise TransportReview(capability['reason'])
                state=_export_state(work,state_sha)
                result=encode_from_providers(video,audio,state,Path(work)/('export'+suffix),
                    decoder_meta,quality,capability['encoder'],
                    progress=lambda fraction:_send(connection,{'sequence':sequence,
                        'kind':'export_progress','fraction':fraction,'sha256':sha}))
                _send(connection,{'sequence':sequence,'kind':'export_complete','sha256':sha,
                    'report':result,'filename':'export'+suffix})
            elif operation=='audio':
                chunk=snapshot_pcm(audio,*args)
                _send(connection,{'sequence':sequence,'kind':'audio','chunk':chunk.__class__(
                    chunk.presence,chunk.track_id,chunk.requested_time,chunk.interval_start,chunk.interval_end,
                    chunk.asset_pts,chunk.source_frame_index,chunk.source_sample_offset,chunk.samples,
                    chunk.format,(),chunk.source_sha256,chunk.descriptor_sha256,chunk.generation)},
                    (packed_pcm(chunk),) if chunk.presence=='content' else ())
            elif operation=='audio_anchor':
                stamp=audio.snapshot_anchor(*args)
                _send(connection,{'sequence':sequence,'kind':'audio_anchor','time':stamp,'sha256':sha})
            else: raise TransportReview('unknown bounded transport operation')
    except EOFError:
        pass
    except BaseException as error:
        try: _send(connection,{'kind':'error','error':str(error),'type':type(error).__name__})
        except BaseException: pass
    finally:
        if cursor is not None:
            try: cursor.close()
            except BaseException: pass
        for provider in (audio,video):
            if provider is not None:
                try: provider.close()
                except BaseException: pass  # Parent reaps before owned tree cleanup.
        connection.close()


class CanonicalSession:
    """Blocking worker API, NEVER call frame/audio/validate on a GUI/device thread.

    One native process, one RPC at a time; caller's latest-pending preview queue
    coalesces requests. Cancellation drains the read-only reply before rejecting
    it, so a superseded seek never poisons an otherwise unchanged source. Native
    hangs terminate this attempt and cannot commit stale pixels or partial PCM.
    """
    def __init__(self,path,sha,*,cancel=None,build_timeout=180,query_timeout=30,_decoder_target=None):
        if not all(type(t) in (int,float) and math.isfinite(t) and 0<t<=3600
                   for t in (build_timeout,query_timeout)): raise TransportReview('bounded native deadlines required')
        check_cancel(cancel)
        self.path=Path(path).absolute(); self.sha=sha
        self._identity=_capture_identity(self.path)
        self._lock=threading.RLock(); self._closed=False; self._sequence=0
        self.query_timeout=query_timeout
        self._directory=tempfile.TemporaryDirectory(prefix='bluraction-asset-transport-')
        ctx=multiprocessing.get_context('spawn')
        self._connection=self._process=None
        child=None
        # Explicit synthetic process seam; production always uses the owned
        # descriptor/EOF decoder above. The seam never disables parent guards.
        target=_decoder_process if _decoder_target is None else _decoder_target
        try:
            parent_socket,child_socket=socket.socketpair()
            self._connection,child=_TransportChannel(parent_socket),_TransportChannel(child_socket)
            self._process=ctx.Process(target=target,args=(child,str(self.path),sha,self._directory.name),daemon=True)
            self._process.start(); child.close()
            self.metadata,_=self._receive(time.monotonic()+build_timeout,cancel,abort_cancel=True)
            if self.metadata.get('kind')!='ready' or self.metadata.get('sha256')!=sha:
                raise TransportReview('canonical candidate handshake failed')
            self.duration=self.metadata['duration']; self.first_time=self.metadata['firstTime']
            if (type(self.duration) is not Fraction or type(self.first_time) is not Fraction
                    or not 0<=self.first_time<self.duration):
                raise TransportReview('canonical candidate exact duration/PTS invalid')
            # Synthetic deadline seams intentionally have no source descriptor.
            # They can exercise IPC but can never provide a project binding.
            self._asset_binding=(VideoAssetBinding.observed(self.metadata,sha,self.duration)
                if 'timeline' in self.metadata or 'descriptorSHA256' in self.metadata else None)
            self._guard(); check_cancel(cancel)
        except BaseException as primary:
            try: self.close()
            except BaseException as cleanup:
                if cleanup is not primary:
                    primary.add_note(f'owned native candidate cleanup also failed: {cleanup!r}')
                    primary.__cause__=cleanup
                primary.retry_transport_close=self.close
            raise
        finally:
            if child is not None: child.close()

    def _guard(self):
        if self._closed: raise TransportReview('owned transport source closed')
        _check_identity(self.path,self._identity)

    def _receive(self,deadline,cancel,abort_cancel=False):
        receive_cancel=cancel if abort_cancel else None
        metadata,sizes=self._connection.recv(deadline=deadline,cancel=receive_cancel)
        if not isinstance(metadata,dict) or metadata.get('kind')=='error':
            raise TransportReview(metadata.get('error','owned decoder error') if isinstance(metadata,dict) else 'invalid native reply')
        if not isinstance(sizes,tuple) or len(sizes)>1 or any(type(n) is not int or not 0<=n<=132_710_400 for n in sizes):
            raise TransportReview('bounded native payload required')
        buffers=[]
        for size in sizes:
            result=bytearray()
            while len(result)<size:
                block=self._connection.recv_bytes(65536,deadline=deadline,cancel=receive_cancel)
                if not block or len(result)+len(block)>size: raise TransportReview('native payload length changed')
                result.extend(block)
            buffers.append(bytes(result))
        return metadata,tuple(buffers)

    def _rpc(self,operation,args=(),cancel=None):
        with self._lock:
            check_cancel(cancel)
            try:
                self._guard()
                self._sequence+=1; sequence=self._sequence
                deadline=time.monotonic()+self.query_timeout
                self._connection.send((sequence,operation,args),deadline=deadline)
                metadata,buffers=self._receive(deadline,cancel)
                self._guard()
                if metadata.get('sequence')!=sequence: raise TransportReview('stale native reply')
                check_cancel(cancel)
                return metadata,buffers
            except Cancelled:
                raise  # Reply was drained; a new seek may still use this source.
            except BaseException as primary:
                try: self.close()
                except BaseException as cleanup:
                    if cleanup is not primary:
                        primary.add_note(f'owned native query cleanup also failed: {cleanup!r}')
                        primary.__cause__=cleanup
                    primary.retry_transport_close=self.close
                raise

    def frame(self,stamp,cancel=None):
        return self._rpc('frame',(exact_time(stamp),),cancel)

    def preview(self,stamp,cancel=None):
        return self._rpc('preview',(exact_time(stamp),),cancel)

    def iter_frames(self,start=Fraction(0),end=None,cancel=None):
        """Bounded content cursor; IPC EOF checks the entire raw inventory."""
        end=self.duration if end is None else exact_time(end)
        start=exact_time(start)
        if not start<=end<=self.duration: raise TransportReview('canonical cursor range invalid')
        with self._lock:
            failure=None
            try:
                # A cancelled request may have been drained after the child
                # created its cursor. The finally must cover cursor_open too.
                self._rpc('cursor_open',(start,end),cancel)
                while True:
                    meta,buffers=self._rpc('cursor_next',cancel=cancel)
                    if meta['kind']=='cursor_EOF': break
                    if meta['kind']!='cursor_frame' or meta.get('sha256')!=self.sha:
                        raise TransportReview('cursor reply changed')
                    yield meta,buffers
            except BaseException as error:
                failure=error
                raise
            finally:
                if not self._closed:
                    try: self._rpc('cursor_close')
                    except BaseException as cleanup:
                        if failure is not None:
                            failure.add_note(f'sequential RPC cleanup also failed: {cleanup!r}')
                            if cleanup is failure: raise failure
                            raise failure from cleanup
                        raise

    def export_private(self,state,quality,suffix,cancel=None,progress=None,timeout=3600):
        """Use ONLY a new export-owned session, never the live preview session.

        Cancellation interrupts and reaps this attempt; all recv chunks/progress
        share one absolute operation deadline. Only a verified private artifact
        path and manifest are returned; the caller owns final publication.
        """
        if type(timeout) not in (int,float) or not math.isfinite(timeout) or not 0<timeout<=3600:
            raise TransportReview('bounded export operation deadline required')
        data=json.dumps(state,separators=(',', ':'),allow_nan=False).encode('utf-8')
        if len(data)>20*1024*1024: raise TransportReview('export state exceeds project byte bound')
        digest=hashlib.sha256(data).hexdigest()
        request=Path(self._directory.name)/'export-state.json'
        with request.open('xb') as stream:
            stream.write(data); stream.flush(); os.fsync(stream.fileno())
        with self._lock:
            check_cancel(cancel)
            try:
                self._guard(); self._sequence+=1; sequence=self._sequence
                deadline=time.monotonic()+timeout
                self._connection.send((sequence,'export',(quality,suffix,digest)),deadline=deadline)
                while True:
                    meta,buffers=self._receive(deadline,cancel,abort_cancel=True)
                    self._guard(); check_cancel(cancel)
                    if meta.get('sequence')!=sequence or meta.get('sha256')!=self.sha or buffers:
                        raise TransportReview('export operation reply identity changed')
                    if meta.get('kind')=='export_progress':
                        value=meta.get('fraction')
                        if type(value) not in (int,float) or not math.isfinite(value) or not 0<=value<=1:
                            raise TransportReview('invalid bounded export progress')
                        if progress is not None: progress(value)
                        continue
                    if meta.get('kind')!='export_complete' or meta.get('filename')!='export'+suffix:
                        raise TransportReview('private export completion missing')
                    report=meta['report']
                    if (report.get('outputVerified') is not True or report.get('sourceSHA256')!=self.sha
                            or report.get('descriptorSHA256')!=self._asset_binding.descriptor_sha256):
                        raise TransportReview('verified export binding differs')
                    artifact=Path(self._directory.name)/meta['filename']
                    if not stat.S_ISREG(artifact.lstat().st_mode): raise TransportReview('private output is not a regular file')
                    return artifact,report
            except BaseException as primary:
                try: self.close()
                except BaseException as cleanup:
                    if cleanup is not primary:
                        primary.add_note(f'export process cleanup also failed: {cleanup!r}')
                        primary.__cause__=cleanup
                    primary.retry_transport_close=self.close
                raise

    def audio(self,identity,stamp,count=4096,cancel=None):
        return self._rpc('audio',(identity,exact_time(stamp),count),cancel)

    def audio_anchor(self,identity,stamp,cancel=None):
        meta,_=self._rpc('audio_anchor',(identity,exact_time(stamp)),cancel)
        return meta['time']

    def validate(self,cancel=None): self._rpc('validate',cancel=cancel)

    def verified_asset_binding(self,cancel=None):
        """IO-worker only: validate actual completed decoder and original SHA."""
        with self._lock:
            self.validate(cancel)
            self._guard(); check_cancel(cancel)
            binding=self._asset_binding
            if binding is None:
                raise TransportReview('completed exact asset descriptor unavailable')
            return binding

    def close(self):
        self._closed=True
        connection=getattr(self,'_connection',None)
        if connection is not None: connection.interrupt()
        with self._lock:
            self._closed=True
            process=getattr(self,'_process',None)
            if process is not None:
                if process.pid is not None:
                    if process.is_alive(): process.terminate()
                    process.join(5)
                    if process.is_alive(): process.kill(); process.join(5)
                    if process.is_alive(): raise TransportReview('owned native process not reaped; cleanup retained')
                process.close(); self._process=None
            connection=getattr(self,'_connection',None)
            if connection is not None: connection.close(); self._connection=None
            directory=getattr(self,'_directory',None)
            if directory is not None: directory.cleanup(); self._directory=None

    def close_async(self):
        # Closing/source-generation invalidation must never wait on a GUI thread.
        self._closed=True
        connection=getattr(self,'_connection',None)
        if connection is not None: connection.interrupt()
        with _RETIRE_LOCK: _RETIRED.add(self)
        def retire():
            try: self.close()
            except BaseException as error:
                # Keep this owned attempt available for an explicit IO-worker
                # retry. Never lose an unreaped process/directory on failure.
                self.retirement_error=error
            else:
                with _RETIRE_LOCK: _RETIRED.discard(self)
        threading.Thread(target=retire,daemon=True,name='owned-asset-retire').start()


_RETIRE_LOCK=threading.Lock()
_RETIRED=set()


def retry_retired_transport_cleanup():
    """Explicit IO-worker retry, no GUI callback or original-source mutation."""
    with _RETIRE_LOCK: retained=tuple(_RETIRED)
    failures=[]
    for session in retained:
        try: session.close()
        except BaseException as error: failures.append(error)
        else:
            with _RETIRE_LOCK: _RETIRED.discard(session)
    return tuple(failures)


class PCMBuffer:
    """Device-thread bounded bytes only; neither source IO nor native decoder."""
    def __init__(self,maximum=1_048_576):
        self.maximum=maximum; self._lock=threading.Lock(); self.data=bytearray(); self.epoch=0
        self.finished=False

    def reset(self):
        with self._lock:
            self.epoch+=1; self.data.clear(); self.finished=False
            return self.epoch

    def append(self,epoch,data):
        with self._lock:
            if epoch!=self.epoch: return False
            if len(self.data)+len(data)>self.maximum: raise TransportReview('bounded PCM ring full')
            self.data.extend(data); return True

    def read(self,maximum):
        with self._lock:
            count=min(max(0,maximum),65536,len(self.data))
            result=bytes(self.data[:count]); del self.data[:count]
            return result  # Missing content/underrun is NEVER synthesized silence.

    def size(self):
        with self._lock: return len(self.data)


class PCMPlaybackPlan:
    """One declared track, exact PCM/empty-edit scheduling, IO worker only.

    Device support/mixing/resampling remain explicit capabilities, never a
    silent stereo downmix. Actual sample-grid anchor is exposed to transport;
    arbitrary seek/edit-range numbers themselves are not rewritten.
    """
    def __init__(self,session,target,cancel=None):
        tracks=session.metadata['audioTracks']
        if len(tracks)!=1: raise TransportReview('여러 오디오 트랙의 혼합 재생은 추가 검증이 필요합니다.')
        track=tracks[0]; self.identity=track['track_id']; self.format=track['format']
        fmt=self.format
        base=fmt['name'].removesuffix('p')
        if (base not in ('u8','s16','s32','flt') or fmt['byte_order'] not in ('little','not-applicable')
                or tuple(fmt['channels']) not in (('FC',),('FL','FR'))):
            raise TransportReview('이 PCM 형식의 장치 재생·변환은 추가 검증이 필요합니다.')
        self.session=session
        self.anchor=self.cursor=session.audio_anchor(self.identity,exact_time(target),cancel)
        self.finished=False
        self.samples=0

    def next_block(self,cancel=None,count=4096):
        if self.finished: return b'',self.cursor,True
        if type(count) is not int or not 0<count<=4096: raise TransportReview('bounded PCM count required')
        meta,buffers=self.session.audio(self.identity,self.cursor,count,cancel)
        chunk=meta['chunk']; rate=self.format['sample_rate']
        if chunk.format.__dict__!=self.format or chunk.requested_time!=self.cursor:
            raise TransportReview('PCM format/seek transaction changed')
        stride=self.format['bytes_per_sample']*len(self.format['channels'])
        if chunk.presence=='content':
            if len(buffers)!=1 or not 0<chunk.samples<=count or len(buffers[0])!=chunk.samples*stride:
                raise TransportReview('observed meaningful PCM bytes incomplete')
            data=buffers[0]; samples=chunk.samples
            next_time=self.cursor+Fraction(samples,rate)
            if next_time!=chunk.interval_end: raise TransportReview('PCM exact interval changed')
        elif chunk.presence=='empty':
            remaining=(chunk.interval_end-self.cursor)*rate
            if remaining.denominator!=1 or remaining<=0 or buffers:
                raise TransportReview('declared empty edit lacks exact PCM grid')
            samples=min(count,remaining.numerator)
            # Unsigned 8-bit silence is the midpoint, not byte zero.
            silence=b'\x80' if self.format['name'].removesuffix('p')=='u8' else b'\0'*self.format['bytes_per_sample']
            data=silence*(samples*len(self.format['channels']))
            next_time=self.cursor+Fraction(samples,rate)
        elif chunk.presence in ('suffix','EOF'):
            self.finished=True
            return b'',self.cursor,True  # Not manufactured content or suffix silence.
        else: raise TransportReview('PCM content missing; playback held instead of silence')
        self.samples+=samples; self.cursor=next_time
        return data,next_time,False
