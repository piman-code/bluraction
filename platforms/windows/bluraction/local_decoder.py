"""Borrowed bounded primary IO plus latched PyAV19 secondary-open denial.

Official versioned API/implementation:
https://github.com/PyAV-Org/PyAV/blob/v19.0.0/av/container/core.pyi
https://raw.githubusercontent.com/PyAV-Org/PyAV/v19.0.0/av/container/core.py
io_open(url, flags, options) is installed on AVFormatContext before native open;
callback exceptions are stashed by PyAV. A demuxer may ignore an optional-open
failure, so returning/decoding/closing also checks an independent sticky latch.

No pathname, URL, output mode or arbitrary file-like primary is accepted. The
caller owns the readonly descriptor, original SHA/identity/generation checks,
authorization and process deadline. We NEVER close that borrowed primary.
This boundary is not an OS sandbox or proof about IO outside this PyAV callback.
HLS references are unsupported here explicitly; this does not silently limit
other self-contained local media formats or declare original feature scope gone.
"""
from __future__ import annotations

from contextlib import contextmanager
from threading import RLock

from .frame_inventory import _BoundedInput


class LocalDecoderError(ValueError):
    pass


class SecondaryIODenied(PermissionError):
    def __init__(self, count):
        self.request_count = count
        super().__init__('원본 이외의 보조 파일·네트워크 요청을 차단했습니다. 결과를 적용하지 않습니다.')


class LocalDecoderCancelled(LocalDecoderError):
    pass


def _av():
    try:
        import av
    except ImportError as error:
        raise LocalDecoderError('PyAV19 local decoder runtime unavailable') from error
    try:
        major = int(av.__version__.split('.')[0])
    except (ValueError, AttributeError) as error:
        raise LocalDecoderError('cannot establish PyAV decoder API version') from error
    if major != 19:
        raise LocalDecoderError('this secondary IO boundary requires the reviewed PyAV19 API')
    return av


class _BorrowedPrimary:
    """PyAV must not close the caller's original descriptor, even on failure."""
    def __init__(self, file):
        self._file = file
    name = '<bluraction-bounded-primary>'
    mode = 'rb'
    def read(self, count=-1): return self._file.read(count)
    def seek(self, offset, whence=0): return self._file.seek(offset, whence)
    def tell(self): return self._file.tell()
    def readable(self): return True
    def seekable(self): return True
    def writable(self): return False
    def close(self): pass


class _GuardedIterator:
    def __init__(self, owner, inner):
        self._owner, self._inner = owner, iter(inner)
    def __iter__(self): return self
    def __next__(self):
        owner = self._owner
        with owner._lock:
            owner._operation_guard()
            if self._inner is None:
                raise StopIteration
            try:
                value = next(self._inner)
            except StopIteration:
                # EOF is publishable only if the optional IO latch/check is clear.
                owner._checkpoint()
                self.close()
                raise
            except BaseException as error:
                owner._annotate(error)
                owner._failed = True
                raise
            owner._checkpoint()
            return value
    def close(self):
        owner = self._owner
        with owner._lock:
            if self._inner is None:
                return
            primary = owner._check_error()
            inner = self._inner
            closed = False
            try:
                close = getattr(inner, 'close', None)
                if close is not None:
                    close()
                closed = True
            except BaseException as error:
                if primary is None:
                    primary = error
                else:
                    primary.add_note(f'decoder iterator close also failed: {error!r}')
                    if error is not primary:
                        primary.__cause__ = error
            finally:
                if closed:
                    self._inner = None
                if closed and owner._active is self:
                    owner._active = None
            primary = owner._merge_check(primary, 'after iterator close')
            if primary is not None:
                owner._failed = True
                raise primary


class _LocalDecoder:
    def __init__(self, check):
        self._lock = RLock()
        # Native calls hold the operation lock. io_open may arrive on another
        # native thread: it must never wait for that call to finish before deny.
        self._latch_lock = RLock()
        self._check = check
        self._requests = 0
        self._native = None
        self._active = None
        self._closed = self._failed = False

    def _deny(self, url, flags, options):
        # Never open/log/store the target. Every invocation sets the latch before
        # raising, including requests with unusual arguments or ignored failures.
        with self._latch_lock:
            self._requests += 1
            raise SecondaryIODenied(self._requests)

    @property
    def secondary_request_count(self):
        with self._latch_lock:
            return self._requests

    def _checkpoint(self):
        try:
            count = self.secondary_request_count
            if count:
                raise SecondaryIODenied(count)
            result = self._check()
            if result is True:
                raise LocalDecoderCancelled('local decoder cancelled; no result may be applied')
            if result is not None and result is not False:
                raise LocalDecoderError('decoder check must return None/False or raise')
            count = self.secondary_request_count
            if count:
                raise SecondaryIODenied(count)
        except BaseException:
            self._failed = True
            raise

    def _operation_guard(self):
        if self._closed or self._failed:
            raise LocalDecoderError('local decoder closed or invalidated')
        self._checkpoint()

    def _annotate(self, error):
        count = self.secondary_request_count
        if count and not isinstance(error, SecondaryIODenied):
            error.add_note(f'secondary decoder IO was denied ({count} requests); no result is usable')

    def _check_error(self):
        try:
            self._checkpoint()
        except BaseException as error:
            return error
        return None

    def _merge_check(self, primary, phase):
        error = self._check_error()
        if error is None:
            return primary
        if primary is None:
            return error
        if error is not primary:
            primary.add_note(f'{phase} guard also failed: {error!r}')
            if primary.__cause__ is None:
                primary.__cause__ = error
        return primary

    def _call(self, function, *args, **kwargs):
        with self._lock:
            self._operation_guard()
            try:
                result = function(*args, **kwargs)
            except BaseException as error:
                self._annotate(error)
                self._failed = True
                raise
            self._checkpoint()
            return result

    def _iterator(self, method, *args, **kwargs):
        with self._lock:
            self._operation_guard()
            if self._active is not None:
                raise LocalDecoderError('close/finish the active decoder iterator before creating another')
            inner = self._call(getattr(self._native, method), *args, **kwargs)
            try:
                result = _GuardedIterator(self, inner)
            except BaseException:
                self._failed = True
                raise
            self._active = result
            return result

    def decode(self, *args, **kwargs): return self._iterator('decode', *args, **kwargs)
    def demux(self, *args, **kwargs): return self._iterator('demux', *args, **kwargs)
    def seek(self, *args, **kwargs):
        with self._lock:
            self._operation_guard()
            return self._call(self._native.seek, *args, **kwargs)

    def check_boundary(self):
        """Check the sticky IO/source guard after a failed native operation.

        This performs no decoder IO and never revives the failed decoder.
        Callers may consider a fresh seek fallback only after this succeeds.
        """
        with self._lock:
            self._checkpoint()

    def __getattr__(self, name):
        if name.startswith('_') or name in ('file', 'io_open', 'open_files'):
            raise AttributeError(name)
        with self._lock:
            self._operation_guard()
            try:
                value = getattr(self._native, name)
            except BaseException as error:
                self._annotate(error)
                self._failed = True
                raise
            self._checkpoint()
            if callable(value):
                return lambda *args, **kwargs: self._call(value, *args, **kwargs)
            return value

    def close(self):
        with self._lock:
            self._closed = True
            if self._native is None and self._active is None:
                return
            primary = self._check_error()
            if self._active is not None:
                try:
                    self._active.close()
                except BaseException as error:
                    if primary is None:
                        primary = error
                    else:
                        primary.add_note(f'active decoder iterator cleanup also failed: {error!r}')
                        if error is not primary:
                            primary.__cause__ = error
            native = self._native
            try:
                if native is not None:
                    native.close()
            except BaseException as error:
                if primary is None:
                    primary = error
                else:
                    primary.add_note(f'native decoder close also failed: {error!r}')
                    if error is not primary:
                        primary.__cause__ = error
            else:
                self._native = None  # retain only a failed close for owned retry
            primary = self._merge_check(primary, 'after native close')
            if primary is not None:
                self._annotate(primary)
                primary.retry_local_decoder_close = self.close
                raise primary


@contextmanager
def open_local_decoder(file, *, mode='r', options=None, check=None):
    """Use only a caller-owned bounded readonly file; complete context exit is mandatory.

    No source bytes/URI/flags are logged. check defaults to the bounded reader's
    caller guard and runs around native open/decode/seek/close. It cannot preempt
    a blocking native call; callers retain a process deadline. Do not publish a
    decode result until the containing transaction/context has fully succeeded.
    """
    if type(file) is not _BoundedInput or mode != 'r':
        raise LocalDecoderError('borrowed bounded readonly primary required; paths/URLs/output are rejected')
    check = file.check if check is None else check
    if not callable(check):
        raise LocalDecoderError('caller source/cancellation check must be callable')
    if options is not None and (type(options) is not dict or
            any(type(k) is not str or type(v) is not str for k, v in options.items())):
        raise LocalDecoderError('decoder options must be a string mapping')
    local = _LocalDecoder(check)
    primary = None
    try:
        local._checkpoint()
        local._native = _av().open(_BorrowedPrimary(file), mode='r',
                                   options=None if options is None else options.copy(), io_open=local._deny)
        local._checkpoint()
        names = local._native.format.name.split(',')
        if 'hls' in names or 'applehttp' in names:
            raise LocalDecoderError('HLS 보조 참조는 로컬 단일 원본 계약에서 명시적으로 보류합니다.')
        # FFmpeg's automatic frame threading allocates a large decoded-frame
        # pool on many-core laptops. Slice threading keeps low preview latency
        # and a bounded worker count without changing decoded observations.
        for stream in local._native.streams.video:
            codec = getattr(stream, 'codec_context', None)
            if codec is not None and not getattr(codec, 'is_open', False):
                codec.thread_count = 2
                codec.thread_type = 'SLICE'
        local._checkpoint()
        yield local
        local._checkpoint()
    except BaseException as error:
        primary = error
        local._annotate(error)
        raise
    finally:
        try:
            local.close()
        except BaseException as error:
            if primary is not None:
                primary.add_note(f'local decoder context cleanup also failed: {error!r}')
                primary.retry_local_decoder_close = local.close
                if error is primary:
                    raise primary  # Repeated caller guards may raise one object.
                raise primary from error
            raise
