"""Lossless v1/v2 project JSON validation; no renderer and no implicit media reads.

Read COMPATIBILITY.md before using this as an application boundary. A valid JSON
contract does not mean sources exist, PDF geometry is safe, or export is approved.
"""
from __future__ import annotations

import copy
import json
import math
import os
import re
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Literal, Mapping

MAX_V1_BYTES = 20 * 1024 * 1024
MAX_V2_BYTES = 50 * 1024 * 1024
MAX_PAGES = 200
JSONValue = Any


class ProjectError(ValueError):
    """A bounded JSON contract violation; no input is evaluated or executed."""


def windows_reserved_name(name: str) -> bool:
    base = name.split('.')[0].rstrip(' ').upper()
    return base in {'CON', 'PRN', 'AUX', 'NUL', 'CONIN$', 'CONOUT$', 'CLOCK$',
                    *(f'{prefix}{digit}' for prefix in ('COM', 'LPT')
                      for digit in '123456789¹²³')}


def validate_output_path(destination, *, platform: str | None = None) -> None:
    """Reject Windows device/stream aliases before filesystem normalization.

    Ordinary drive and UNC paths remain supported. OS long-path handling is
    left to the filesystem; user-supplied device namespace paths are refused.
    See https://learn.microsoft.com/windows/win32/fileio/naming-a-file.
    """
    if (platform or ('windows' if os.name == 'nt' else 'posix')) != 'windows':
        return
    raw = os.fspath(destination).replace('\\', '/')
    if raw.startswith(('//?/', '//./', '/??/')) or not raw or raw.endswith('/'):
        raise ProjectError('지원하지 않는 Windows 출력 경로입니다.')
    if re.match(r'^[A-Za-z]:', raw):
        if len(raw) < 3 or raw[2] != '/':
            raise ProjectError('Windows 드라이브의 전체 경로를 선택하세요.')
        raw = raw[3:]
    for component in raw.split('/'):
        if component in ('', '.', '..'):
            continue
        if (component.endswith((' ', '.')) or windows_reserved_name(component)
                or any(character in '<>:"|?*' or ord(character) < 32 for character in component)):
            raise ProjectError('Windows에서 사용할 수 없는 파일 또는 폴더 이름입니다.')


def _fail(path: str, reason: str) -> None:
    raise ProjectError(f"{path}: {reason}")


def _object(value: Any, path: str, required: set[str], allowed: set[str], reviews: list[str]) -> dict:
    if not isinstance(value, dict):
        _fail(path, "expected object")
    if missing := required - value.keys():
        _fail(path, f"missing fields {sorted(missing)}")
    if unknown := value.keys() - allowed:
        reviews.append(f"{path}: unknown fields retained; host review required: {sorted(unknown)}")
    return value


def _array(value: Any, path: str, maximum: int, count: int | None = None) -> list:
    if not isinstance(value, list) or len(value) > maximum or (count is not None and len(value) != count):
        _fail(path, "invalid array size/type")
    return value


def _number(value: Any, path: str, low: float = -16, high: float = 16, *, positive: bool = False) -> None:
    if isinstance(value, bool) or not isinstance(value, (float, int)):
        _fail(path, "expected number")
    try:
        valid = math.isfinite(value) and low <= value <= high and (not positive or value > 0)
    except OverflowError:
        valid = False
    if not valid:
        _fail(path, "number outside finite allowed range")


def _integer(value: Any, path: str, low: int, high: int) -> None:
    if isinstance(value, bool) or not isinstance(value, (float, int)) or not low <= value <= high or value != int(value):
        _fail(path, "expected bounded integer")


def _text(value: Any, path: str, maximum: int, reviews: list[str], *, nonempty: bool = False, no_nul: bool = False) -> None:
    if not isinstance(value, str) or (nonempty and not value) or (no_nul and "\0" in value):
        _fail(path, "invalid string")
    # Swift String.count uses extended grapheme clusters. Python len counts code points.
    # ASCII limits are exact; potentially composed Unicode beyond the scalar limit is
    # retained for native grapheme validation rather than wrongly rejecting old files.
    if len(value) > maximum:
        if value.isascii() and '\r\n' not in value:
            _fail(path, "string too long")
        reviews.append(f"{path}: native grapheme-count limit {maximum} requires validation")


def _uuid(value: Any, path: str) -> str:
    if not isinstance(value, str) or re.fullmatch(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", value) is None:
        _fail(path, "invalid UUID")
    return str(uuid.UUID(value))


def _point(value: Any, path: str, *, size: bool = False) -> None:
    for i, number in enumerate(_array(value, path, 2, 2)):
        _number(number, f"{path}[{i}]", 0 if size else -16, 16)


def _points(value: Any, path: str) -> None:
    for i, point in enumerate(_array(value, path, 100_000)):
        _point(point, f"{path}[{i}]")


def _range(value: Any, path: str) -> None:
    bounds = _array(value, path, 2, 2)
    for i, number in enumerate(bounds):
        _number(number, f"{path}[{i}]", 0, math.inf)
    if bounds[0] > bounds[1]:
        _fail(path, "reversed ClosedRange")


def _color(value: Any, path: str, reviews: list[str]) -> None:
    channels = {"red", "green", "blue", "alpha"}
    value = _object(value, path, channels, channels, reviews)
    for key in channels:
        _number(value[key], f"{path}.{key}", 0, 1)


def _frames(value: Any, path: str, reviews: list[str]) -> None:
    for i, frame in enumerate(_array(value, path, 100_000)):
        loc = f"{path}[{i}]"
        frame = _object(frame, loc, {"time", "rect"}, {"time", "rect"}, reviews)
        _number(frame["time"], loc + ".time", 0, math.inf)
        rect = _array(frame["rect"], loc + ".rect", 2, 2)
        _point(rect[0], loc + ".rect.origin")
        _point(rect[1], loc + ".rect.size", size=True)
    # Preserve order, including legacy unsorted/duplicate frames. Never silently retime.


def _erasures(value: Any, path: str, reviews: list[str]) -> None:
    for i, stroke in enumerate(_array(value, path, 10_000)):
        loc = f"{path}[{i}]"
        stroke = _object(stroke, loc, {"points", "width"}, {"points", "width", "from"}, reviews)
        _points(stroke["points"], loc + ".points")
        _number(stroke["width"], loc + ".width", 0, 16, positive=True)
        if stroke.get("from") is not None:
            _number(stroke["from"], loc + ".from", 0, math.inf)


def _optional(value: dict, key: str, validator, path: str) -> None:
    if value.get(key) is not None:
        validator(value[key], path + "." + key)


def _bool(value: Any, path: str) -> None:
    if type(value) is not bool:
        _fail(path, "expected boolean")


def _effect(value: Any, path: str, reviews: list[str]) -> None:
    required = {"blurRadius", "featherRadius", "timeRange", "enabled", "keyframes"}
    value = _object(value, path, required, required | {"style", "color", "groupID", "erasures", "name", "locked"}, reviews)
    for key in ("blurRadius", "featherRadius"):
        _number(value[key], path + "." + key, 0, 500)
    _range(value["timeRange"], path + ".timeRange")
    _bool(value["enabled"], path + ".enabled")
    _frames(value["keyframes"], path + ".keyframes", reviews)
    if value.get("style") is not None and value["style"] not in ("blur", "mosaic", "solid"):
        _fail(path + ".style", "unsupported cover style")
    _optional(value, "color", lambda v, p: _color(v, p, reviews), path)
    _optional(value, "groupID", _uuid, path)
    _optional(value, "erasures", lambda v, p: _erasures(v, p, reviews), path)
    _optional(value, "locked", _bool, path)
    _optional(value, "name", lambda v, p: _text(v, p, 200, reviews), path)


def _shape(value: Any, path: str, reviews: list[str]) -> str:
    if not isinstance(value, dict) or len(value) != 1:
        _fail(path, "expected exactly one Swift enum case")
    kind, body = next(iter(value.items()))
    if kind not in ("rectangle", "ellipse", "polygon"):
        _fail(path, "unsupported region shape")
    required = {"id", "points"} if kind == "polygon" else {"id", "origin", "size"}
    body = _object(body, path + "." + kind, required, required, reviews)
    identity = _uuid(body["id"], path + ".id")
    if kind == "polygon":
        _points(body["points"], path + ".points")
        points = body["points"]
        if points:
            for axis in (0, 1):
                span = max(p[axis] for p in points) - min(p[axis] for p in points)
                _number(span, path + ".boundingSize", 0, 16)
    else:
        _point(body["origin"], path + ".origin")
        _point(body["size"], path + ".size", size=True)
    return identity


def _drawing(value: Any, path: str, reviews: list[str]) -> str:
    required = {"id", "kind", "points", "red", "green", "blue", "alpha", "lineWidth"}
    allowed = required | {"fillOpacity", "timeRange", "keyframes", "text", "groupID", "erasures", "name", "hidden", "locked", "fontName", "bold", "textBackground"}
    value = _object(value, path, required, allowed, reviews)
    identity = _uuid(value["id"], path + ".id")
    if value["kind"] not in ("rectangle", "ellipse", "line", "freehand", "arrow", "text"):
        _fail(path + ".kind", "unsupported drawing kind")
    _points(value["points"], path + ".points")
    for key in ("red", "green", "blue", "alpha"):
        _number(value[key], path + "." + key, 0, 1)
    _number(value["lineWidth"], path + ".lineWidth", 0, 16, positive=True)
    _optional(value, "fillOpacity", lambda v, p: _number(v, p, 0, 1), path)
    _optional(value, "timeRange", _range, path)
    _optional(value, "keyframes", lambda v, p: _frames(v, p, reviews), path)
    _optional(value, "groupID", _uuid, path)
    _optional(value, "erasures", lambda v, p: _erasures(v, p, reviews), path)
    for key, limit in (("name", 200), ("fontName", 200), ("text", 1000)):
        _optional(value, key, lambda v, p, n=limit: _text(v, p, n, reviews), path)
    for key in ("hidden", "locked", "bold"):
        _optional(value, key, _bool, path)
    _optional(value, "textBackground", lambda v, p: _color(v, p, reviews), path)
    return identity


def _edits(page: dict, path: str, reviews: list[str]) -> None:
    ids: set[str] = set()
    regions = _array(page["regions"], path + ".regions", 1000)
    drawings = _array(page["drawings"], path + ".drawings", 5000)
    for i, region in enumerate(regions):
        loc = f"{path}.regions[{i}]"
        region = _object(region, loc, {"shape", "effect"}, {"shape", "effect"}, reviews)
        identity = _shape(region["shape"], loc + ".shape", reviews)
        _effect(region["effect"], loc + ".effect", reviews)
        if identity in ids:
            _fail(loc, "duplicate item ID within page")
        ids.add(identity)
    for i, drawing in enumerate(drawings):
        loc = f"{path}.drawings[{i}]"
        identity = _drawing(drawing, loc, reviews)
        if identity in ids:
            _fail(loc, "duplicate item ID within page")
        ids.add(identity)


def _json_tree(value: Any, path: str = "$", depth: int = 0) -> None:
    if depth > 64:
        _fail(path, "nesting limit exceeded")
    if isinstance(value, dict):
        for key, item in value.items():
            if not isinstance(key, str):
                _fail(path, "non-string JSON key")
            _json_tree(item, path + "." + key, depth + 1)
    elif isinstance(value, list):
        for i, item in enumerate(value):
            _json_tree(item, f"{path}[{i}]", depth + 1)
    elif isinstance(value, float) and not math.isfinite(value):
        _fail(path, "nonfinite JSON number")
    elif value is not None and not isinstance(value, (str, int, float, bool)):
        _fail(path, "unsupported JSON value")


def validate_project(data: Mapping[str, JSONValue]) -> tuple[str, ...]:
    """Validate known fields; return host-review reasons while retaining unknown keys."""
    _json_tree(data)
    reviews: list[str] = []
    if not isinstance(data, dict):
        _fail("$", "expected object")
    _integer(data.get("version"), "$.version", 1, 2)
    if data["version"] == 1:
        fields = {"version", "mediaPath", "regions", "drawings"}
        _object(data, "$", fields, fields | {"sourceSHA256"}, reviews)
        if data.get("sourceSHA256") is not None and (not isinstance(data["sourceSHA256"], str) or re.fullmatch(r"[0-9a-f]{64}", data["sourceSHA256"]) is None):
            _fail("$.sourceSHA256", "expected lowercase SHA-256")
        _text(data["mediaPath"], "$.mediaPath", 4096, reviews, nonempty=True, no_nul=True)
        _edits(data, "$", reviews)
    else:
        fields = {"version", "title", "currentIndex", "pages"}
        _object(data, "$", fields, fields, reviews)
        _text(data["title"], "$.title", 255, reviews, nonempty=True)
        pages = _array(data["pages"], "$.pages", MAX_PAGES)
        if not pages:
            _fail("$.pages", "empty workspace")
        _integer(data["currentIndex"], "$.currentIndex", 0, len(pages) - 1)
        for i, page in enumerate(pages):
            path = f"$.pages[{i}]"
            fields = {"mediaPath", "regions", "drawings"}
            page = _object(page, path, fields, fields | {"pdfPageIndex", "sourceSHA256", "pdfGeometryVersion"}, reviews)
            _text(page["mediaPath"], path + ".mediaPath", 4096, reviews, nonempty=True, no_nul=True)
            _optional(page, "pdfPageIndex", lambda v, p: _integer(v, p, 0, 199), path)
            if page.get("pdfGeometryVersion") is not None:
                _integer(page["pdfGeometryVersion"], path + ".pdfGeometryVersion", 1, 1)
                if page.get("pdfPageIndex") is None:
                    _fail(path, "PDF geometry version on an image page")
            if page.get("sourceSHA256") is not None and (not isinstance(page["sourceSHA256"], str) or re.fullmatch(r"[0-9a-f]{64}", page["sourceSHA256"]) is None):
                _fail(path + ".sourceSHA256", "expected lowercase SHA-256")
            _edits(page, path, reviews)
            if page.get("pdfPageIndex") is not None and page.get("pdfGeometryVersion") is None and (page["regions"] or page["drawings"]):
                reviews.append(path + ": legacy edited PDF requires host crop/rotation geometry check before render/export")
    return tuple(reviews)


@dataclass(frozen=True)
class SourceReference:
    media_path: str
    page_index: int | None = None
    expected_sha256: str | None = None
    pdf_geometry_version: int | None = None


class PortableProject:
    """Validated tree with lossless unknown/default/array preservation and copy access."""
    def __init__(self, data: Mapping[str, JSONValue]):
        self._data = copy.deepcopy(data)
        self.required_reviews = validate_project(self._data)

    @property
    def version(self) -> Literal[1, 2]:
        return int(self._data["version"])

    def to_dict(self) -> dict:
        return copy.deepcopy(self._data)

    @property
    def sources(self) -> tuple[SourceReference, ...]:
        pages = [self._data] if self.version == 1 else self._data["pages"]
        return tuple(SourceReference(p["mediaPath"], int(p["pdfPageIndex"]) if p.get("pdfPageIndex") is not None else None,
            p.get("sourceSHA256"), int(p["pdfGeometryVersion"]) if p.get("pdfGeometryVersion") is not None else None) for p in pages)


def _unique_object(pairs: list[tuple[str, Any]]) -> dict:
    result: dict = {}
    for key, value in pairs:
        if key in result:
            _fail("$", "duplicate JSON key: " + key)
        result[key] = value
    return result


def load_project(payload: bytes | str) -> PortableProject:
    if not isinstance(payload, (bytes, str)):
        raise ProjectError("project payload must be bytes or UTF-8 text")
    try:
        raw = payload.encode("utf-8") if isinstance(payload, str) else payload
        if len(raw) > MAX_V2_BYTES:
            raise ProjectError("project exceeds 50 MiB")
        data = json.loads(raw.decode("utf-8"), object_pairs_hook=_unique_object,
            parse_constant=lambda token: _fail("$", "nonfinite JSON token: " + token))
        project = PortableProject(data)
    except (UnicodeError, json.JSONDecodeError, RecursionError, OverflowError) as error:
        raise ProjectError("invalid bounded UTF-8 JSON") from error
    if len(raw) > (MAX_V1_BYTES if project.version == 1 else MAX_V2_BYTES):
        raise ProjectError("project exceeds version byte limit")
    return project


def dump_project(project: PortableProject) -> bytes:
    data = project.to_dict()
    validate_project(data)
    try:
        payload = (json.dumps(data, ensure_ascii=False, allow_nan=False, sort_keys=True, indent=2) + "\n").encode("utf-8")
    except (ValueError, UnicodeError, RecursionError) as error:
        raise ProjectError("invalid JSON output") from error
    if len(payload) > (MAX_V1_BYTES if project.version == 1 else MAX_V2_BYTES):
        raise ProjectError("encoded project exceeds version byte limit")
    return payload


class IncompleteProjectError(ProjectError):
    def __init__(self, destination):
        self.partial_output = Path(destination)
        super().__init__('Project write did not complete; inspect the preserved output: ' + str(destination))


def save_project_new(project: PortableProject, destination: Path) -> None:
    """Write exclusively to a new project path. Never replace a file or bundle media.

    Creation is exclusive; visibility of the completed contents is not atomic. A
    consumer must wait for this function to return. Failed writes leave the
    public destination intact and report its incomplete state. A metadata check
    followed by unlink cannot atomically protect a concurrently replaced path.
    """
    validate_output_path(destination)
    payload = dump_project(project)
    descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
    except BaseException as error:
        raise IncompleteProjectError(destination) from error
