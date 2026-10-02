"""Pure cross-OS path planning and explicitly scoped source checks.

Nothing here searches a disk, opens media at project-load time, decodes a PDF,
changes a hash baseline, or automatically accepts a changed/legacy source.
"""
from __future__ import annotations

import hashlib
import os
import stat
from dataclasses import dataclass
from pathlib import Path, PurePosixPath, PureWindowsPath
from typing import Iterable, Literal

from .portable_project import PortableProject, ProjectError, windows_reserved_name, validate_output_path
from .source_identity import stat_snapshot, same_domain, path_matches_descriptor, same_path_binding

Platform = Literal["macos", "windows"]
MAX_SOURCE_BYTES = 1024 * 1024 * 1024


@dataclass(frozen=True)
class PathResolution:
    reference: str
    platform: Platform
    path: str | None
    state: Literal["resolved", "needs_relink", "invalid"]
    reason: str


def resolve_reference(reference: str, project_location: str, platform: Platform) -> PathResolution:
    """Lexical only: no existence check or source read, and no cross-OS guessing.

    Relative references are flattened to their last filename, matching Mac v1
    mediaURL(relativeTo:). Both separator syntaxes are recognized so traversal
    cannot escape the destination project folder on another OS.
    """
    if platform not in ("macos", "windows"):
        raise ValueError("platform must be macos or windows")
    def result(state, reason, path=None):
        return PathResolution(reference, platform, path, state, reason)
    if not isinstance(reference, str) or not reference or "\0" in reference:
        return result("invalid", "empty or NUL-containing media reference")
    def invalid_windows_leaf(leaf: str) -> bool:
        reserved = windows_reserved_name(leaf)
        return reserved or leaf.endswith((" ", ".")) or any(c in leaf for c in '<>:"|?*') or any(ord(c) < 32 for c in leaf)
    if reference.startswith(("\\\\?\\", "\\\\.\\")):
        return result("needs_relink", "Windows device/extended namespace requires explicit host handling")
    windows = PureWindowsPath(reference)
    posix = PurePosixPath(reference)
    is_unc = reference.startswith("\\\\") or (reference.startswith("//") and bool(windows.drive))
    if windows.drive or is_unc:
        if not windows.is_absolute():
            return result("needs_relink", "drive-relative reference is ambiguous")
        if platform != "windows":
            return result("needs_relink", "Windows drive/UNC source requires explicit relink on macOS")
        try:
            validate_output_path(reference, platform='windows')
        except ProjectError:
            return result("needs_relink", "Windows source namespace/name requires explicit relink")
        if invalid_windows_leaf(windows.name):
            return result("needs_relink", "filename is not directly portable to Windows")
        return result("resolved", "native absolute Windows reference", str(windows))
    if reference.startswith("\\"):
        return result("needs_relink", "root-relative Windows reference has no explicit drive")
    if posix.is_absolute():
        if platform != "macos":
            return result("needs_relink", "POSIX absolute source requires explicit relink on Windows")
        return result("resolved", "native absolute POSIX reference", str(posix))
    leaf = reference.replace("\\", "/").rsplit("/", 1)[-1]
    if leaf in ("", ".", ".."):
        return result("invalid", "reference has no safe filename")
    if platform == "windows":
        project = PureWindowsPath(project_location)
        if not project.is_absolute():
            return result("invalid", "project location must have an absolute drive or UNC share")
        # NTFS aliases/reserved names cannot be transparently mapped to a media filename.
        if invalid_windows_leaf(leaf):
            return result("needs_relink", "filename is not directly portable to Windows")
    else:
        project = PurePosixPath(project_location)
        if not project.is_absolute():
            return result("invalid", "project location must be absolute")
    return result("resolved", "relative source filename next to project (no traversal)", str(project.parent / leaf))


@dataclass(frozen=True)
class SourceCheck:
    path: str | None
    expected_sha256: str | None
    actual_sha256: str | None
    state: Literal["verified", "unverified", "changed", "missing", "blocked", "needs_relink"]
    reason: str
    byte_count: int = 0


def check_source(resolution: PathResolution, expected_sha256: str | None, *,
                 approved_roots: Iterable[Path], maximum_bytes: int = MAX_SOURCE_BYTES) -> SourceCheck:
    """Opt-in: hashes only a selected regular file inside explicit approved roots.

    Host app/user chooses sources and roots. No roots means no media access.
    Leaf or intermediate symlinks are refused. Inode, size, mtime and canonical
    path are checked before/after reading; these are integrity checks, not a
    substitute for the app's pre-export source and PDF-geometry checks.
    """
    def result(state, reason, actual=None, size=0):
        return SourceCheck(resolution.path, expected_sha256, actual, state, reason, size)
    if resolution.state != "resolved" or resolution.path is None:
        return result("needs_relink" if resolution.state == "needs_relink" else "blocked", resolution.reason)
    native = "windows" if os.name == "nt" else "macos"
    if resolution.platform != native:
        return result("blocked", "foreign platform planning is metadata-only")
    if expected_sha256 is not None:
        import re
        if not isinstance(expected_sha256, str) or re.fullmatch(r"[0-9a-f]{64}", expected_sha256) is None:
            return result("blocked", "invalid expected SHA-256")
    if isinstance(maximum_bytes, bool) or not isinstance(maximum_bytes, int) or not 0 < maximum_bytes <= MAX_SOURCE_BYTES:
        return result("blocked", "invalid source byte limit")
    path = Path(resolution.path)
    roots = [Path(root).absolute() for root in approved_roots]
    # The lexical scope gate runs before inspecting the proposed source.
    if not any(path.is_relative_to(root) for root in roots):
        return result("blocked", "source is outside explicit approved roots")
    try:
        canonical = path.resolve(strict=True)
        approved_canonical = [root.resolve(strict=True) for root in roots]
        if not any(canonical.is_relative_to(root) for root in approved_canonical):
            return result("blocked", "source resolves outside approved roots")
        root = next(root for root in roots if path.is_relative_to(root))
        if root.is_symlink():
            return result("blocked", "approved root cannot be a symlink")
        cursor = path
        while cursor != root:
            if cursor.is_symlink():
                return result("blocked", "source path contains a symlink")
            cursor = cursor.parent
        metadata = path.stat(follow_symlinks=False)
        if not stat.S_ISREG(metadata.st_mode) or not 0 < metadata.st_size <= maximum_bytes:
            return result("blocked", "source must be a nonempty bounded regular file")
        path_baseline = stat_snapshot(metadata, domain='path')
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_BINARY", 0) | getattr(os, "O_NONBLOCK", 0)
        descriptor = os.open(path, flags)
        with os.fdopen(descriptor, "rb") as stream:
            before = os.fstat(stream.fileno())
            if not stat.S_ISREG(before.st_mode) or not 0 < before.st_size <= maximum_bytes:
                return result("blocked", "source must be a nonempty bounded regular file")
            descriptor_baseline = stat_snapshot(before, domain='descriptor')
            if not path_matches_descriptor(path_baseline, descriptor_baseline):
                return result("changed", "source identity changed before verification")
            opened_path = stat_snapshot(path.stat(follow_symlinks=False), domain='path')
            if (not same_path_binding(path_baseline, opened_path, str(canonical), str(path.resolve(strict=True)))
                    or not path_matches_descriptor(opened_path, descriptor_baseline)):
                return result("changed", "source path changed before verification")
            digest = hashlib.sha256()
            count = 0
            while block := stream.read(1024 * 1024):
                count += len(block)
                if count > maximum_bytes:
                    return result("blocked", "source grew beyond byte limit")
                digest.update(block)
            after = os.fstat(stream.fileno())
        current = path.stat(follow_symlinks=False)
        descriptor_current = stat_snapshot(after, domain='descriptor')
        path_current = stat_snapshot(current, domain='path')
        if (not same_domain(descriptor_baseline, descriptor_current)
                or not same_path_binding(path_baseline, path_current, str(canonical), str(path.resolve(strict=True)))
                or not path_matches_descriptor(path_current, descriptor_current) or count != after.st_size):
            return result("changed", "source identity changed during verification")
        actual = digest.hexdigest()
        if expected_sha256 is None:
            return result("unverified", "legacy/v1 source has no saved hash baseline; review required", actual, count)
        if actual != expected_sha256:
            return result("changed", "saved source bytes differ; do not migrate edits or update the baseline", actual, count)
        return result("verified", "saved hash and selected source bytes match", actual, count)
    except FileNotFoundError:
        return result("missing", "selected source is missing")
    except (OSError, ValueError, RuntimeError) as error:
        return result("blocked", "source inspection refused: " + type(error).__name__)


def relink_media(project: PortableProject, old_reference: str, new_reference: str, *,
                 project_location: str, platform: Platform, checked: SourceCheck,
                 allow_unverified_reviewed_source: bool = False) -> PortableProject:
    """Return a new tree with only matching mediaPath fields replaced.

    Requires a check of the exact replacement path. All existing SHA baselines,
    geometry tags, edits, unknown fields and orders remain unchanged. A changed
    source cannot be accepted through this API, even with the review flag.
    """
    replacement = resolve_reference(new_reference, project_location, platform)
    if replacement.state != "resolved" or checked.path != replacement.path:
        raise ProjectError("relink check does not match the exact replacement path")
    references = [s for s in project.sources if s.media_path == old_reference]
    if not references:
        raise ProjectError("old reference not found")
    for source in references:
        if source.expected_sha256 is not None:
            if checked.state != "verified" or checked.expected_sha256 != source.expected_sha256 or checked.actual_sha256 != source.expected_sha256:
                raise ProjectError("relink blocked: source SHA-256 must match each saved baseline")
        elif checked.state != "unverified" or not allow_unverified_reviewed_source:
            raise ProjectError("relink blocked: no baseline; explicit source review required")
    data = project.to_dict()
    pages = [data] if project.version in (1, 3) else data["pages"]
    for page in pages:
        if page["mediaPath"] == old_reference:
            page["mediaPath"] = new_reference
    return PortableProject(data)
