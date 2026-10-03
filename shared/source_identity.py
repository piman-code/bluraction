"""Pure, domain-aware regular-source metadata comparisons (no file access).

CPython v3.14.7 Windows path stat/lstat copies birthtime into deprecated ctime,
whereas fstat retains FILE_BASIC_INFO.ChangeTime. Both are integer nanoseconds
but are different clocks. Path modes also add executable bits from the suffix.
Never erase ctime or round timestamps to make these different views agree.

Keep complete path-to-path and descriptor-to-descriptor baselines separately;
cross-compare only fields with the same meaning. POSIX retains the full original
metadata comparison. On Windows, missing birthtime/attributes or zero file IDs
are unsupported, never a reason to weaken a source guard. Callers must still
check canonical paths, cancellation, byte bounds and saved SHA-256 baselines.
This module does not authorize paths, open handles, decode or read media.

Primary implementation/field references:
https://github.com/python/cpython/blob/v3.14.7/Modules/posixmodule.c
https://github.com/python/cpython/blob/v3.14.7/Python/fileutils.c
https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-file_basic_info
https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-file_id_info
The CI mismatch hypothesis requires actual Windows observations; source reading
and synthetic stat objects alone do not prove an actual Windows runtime fix.
"""
from __future__ import annotations

from dataclasses import dataclass
import os
import stat
from typing import Literal

Domain = Literal['path', 'descriptor']
Platform = Literal['posix', 'windows']
_READONLY = 0x1
_REPARSE_POINT = 0x400
_NAME_SURROGATE = 0x20000000


class SourceIdentityError(ValueError):
    """Unsupported metadata; messages deliberately contain no source paths."""


def metadata(info) -> tuple[int, int, int, int, int, int]:
    """Retain existing six-field layout: size is index 3; timestamps are ns."""
    try:
        values = tuple(getattr(info, name) for name in
                       ('st_dev', 'st_ino', 'st_mode', 'st_size', 'st_mtime_ns', 'st_ctime_ns'))
    except AttributeError:
        raise SourceIdentityError('source metadata is incomplete') from None
    if any(type(value) is not int for value in values):
        raise SourceIdentityError('source metadata must use exact integers')
    if any(values[index] < 0 for index in (0, 1, 2, 3)):
        raise SourceIdentityError('source identity or size is invalid')
    return values


@dataclass(frozen=True)
class StatSnapshot:
    platform: Platform
    domain: Domain
    metadata: tuple[int, int, int, int, int, int]
    birthtime_ns: int | None = None
    file_attributes: int | None = None
    reparse_tag: int | None = None

    def __post_init__(self):
        if self.platform not in ('posix', 'windows') or self.domain not in ('path', 'descriptor'):
            raise SourceIdentityError('source metadata domain is unsupported')
        if (type(self.metadata) is not tuple or len(self.metadata) != 6
                or any(type(value) is not int for value in self.metadata)
                or any(self.metadata[index] < 0 for index in (0, 1, 2, 3))
                or not stat.S_ISREG(self.metadata[2])):
            raise SourceIdentityError('source metadata must describe an exact regular-file identity')
        if self.platform == 'windows':
            if self.metadata[0] <= 0 or self.metadata[1] <= 0:
                raise SourceIdentityError('stable Windows volume and file IDs are required')
            if (type(self.birthtime_ns) is not int
                    or type(self.file_attributes) is not int or not 0 <= self.file_attributes <= 0xffffffff
                    or type(self.reparse_tag) is not int or not 0 <= self.reparse_tag <= 0xffffffff):
                raise SourceIdentityError('Windows birthtime and file attributes are required')
            if (self.domain == 'path' and self.file_attributes & _REPARSE_POINT
                    and self.reparse_tag & _NAME_SURROGATE):
                raise SourceIdentityError('source leaf is a name-surrogate reparse point')
        elif any(value is not None for value in (self.birthtime_ns, self.file_attributes, self.reparse_tag)):
            raise SourceIdentityError('POSIX snapshot must retain its full native metadata domain')


def stat_snapshot(info, *, domain: Domain, platform: Platform | None = None) -> StatSnapshot:
    """Capture an already obtained stat object; explicit platform aids pure QA.

    Production callers use the default current OS. Explicit platform describes
    the supplied observation, never selects an OS path or authorizes a source.
    """
    selected = ('windows' if os.name == 'nt' else 'posix') if platform is None else platform
    if selected == 'windows':
        return StatSnapshot(selected, domain, metadata(info),
                            getattr(info, 'st_birthtime_ns', None),
                            getattr(info, 'st_file_attributes', None),
                            getattr(info, 'st_reparse_tag', None))
    return StatSnapshot(selected, domain, metadata(info))


def _snapshots(left, right):
    if type(left) is not StatSnapshot or type(right) is not StatSnapshot:
        raise SourceIdentityError('captured source snapshots are required')
    if left.platform != right.platform:
        raise SourceIdentityError('source snapshot platforms differ')


def same_domain(left: StatSnapshot, right: StatSnapshot) -> bool:
    """Full path/path or fd/fd comparison, including raw ctime and mode."""
    _snapshots(left, right)
    if left.domain != right.domain:
        raise SourceIdentityError('full source comparison requires the same metadata domain')
    return left == right


def path_matches_descriptor(path: StatSnapshot, descriptor: StatSnapshot) -> bool:
    """Same file/content metadata across views; no Windows ctime conversion.

    Windows raw ctime/mode are still mandatory in each same-domain baseline.
    Full Python inode integers are kept (including 128-bit file IDs).
    """
    _snapshots(path, descriptor)
    if path.domain != 'path' or descriptor.domain != 'descriptor':
        raise SourceIdentityError('path and descriptor metadata domains are required')
    if path.platform == 'posix':
        return path.metadata == descriptor.metadata
    def common(value):
        dev, ino, mode, size, mtime_ns, _ctime_ns = value.metadata
        return (dev, ino, stat.S_IFMT(mode), size, mtime_ns, value.birthtime_ns,
                value.file_attributes & _READONLY)
    return common(path) == common(descriptor)


def same_path_binding(expected: StatSnapshot, current: StatSnapshot,
                      expected_canonical: str, current_canonical: str) -> bool:
    """Reject parent retargets even if both targets have identical metadata."""
    _snapshots(expected, current)
    if expected.domain != 'path' or current.domain != 'path':
        raise SourceIdentityError('canonical binding requires path metadata')
    if type(expected_canonical) is not str or type(current_canonical) is not str:
        raise SourceIdentityError('captured canonical paths are required')
    return same_domain(expected, current) and expected_canonical == current_canonical
