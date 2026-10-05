"""Page-isolated editing transactions; portable JSON remains the source of truth."""
from __future__ import annotations

from copy import deepcopy
from functools import wraps
import json
import math
import os
import re
from pathlib import Path
import uuid

from shared.portable_project import PortableProject, dump_project, load_project as decode_project, MAX_V2_BYTES, validate_output_path
from shared.source_relink import resolve_reference
from .media import Page, load_pages, save_bytes_new, fingerprint, check_cancel, validate_source_identities
from .renderer import bounds, shape_points, positioned, map_point, rect_at
from .project_compatibility import validate_host_reviews, bounded_name_with_suffix


def _owned_asset_transaction(operation):
    """Own newly constructed sessions even before a candidate assigns video.

    Failed/cancelled preparation closes only this context's new sources; an
    operating or IO-snapshot video is borrowed and never registered here.
    """
    @wraps(operation)
    def prepare(*args, **kwargs):
        from .video import asset_transport_load
        with asset_transport_load():
            return operation(*args, **kwargs)
    return prepare


class MissingSources(ValueError):
    def __init__(self, references):
        self.references = references
        super().__init__('원본을 찾을 수 없습니다. 원본 파일을 다시 연결하세요.')


class UnverifiedSources(ValueError):
    def __init__(self, references):
        self.references = references
        super().__init__('이전 프로젝트에 원본 지문이 없습니다. 재연결 파일과 가림 위치를 직접 확인해야 합니다.')


class Workspace:
    def __init__(self):
        self.pages = []
        self.index = 0
        self.title = 'BlurAction'
        self.busy = False
        self.selection_ids = set()
        self.time = None
        self.video = None
        self.record_motion = False
        self._undo = {}
        self._redo = {}
        self._project_tree = None
        self.review_required = []
        self.dirty = False

    @property
    def page(self):
        return self.pages[self.index] if self.pages else None

    @property
    def selectionID(self):
        return next(iter(self.selection_ids), None)

    @selectionID.setter
    def selectionID(self, value):
        self.selection_ids = {value} if value else set()

    def _available(self):
        if self.busy:
            raise ValueError('작업을 마치거나 취소한 뒤 편집하세요.')
        if not self.page:
            raise ValueError('먼저 원본을 열어 주세요.')

    def _checkpoint(self):
        self._available()
        history = self._undo.setdefault(self.index, [])
        history.append(deepcopy(self.page.state))
        if len(history) > 200:
            history.pop(0)
        self._redo[self.index] = []
        self.dirty = True

    def _replace(self, pages, title, video=None):
        self.pages, self.title, self.video = pages, title, video
        self.index = 0
        self.time = 0.0 if video else None
        self.selection_ids.clear()
        self._undo.clear()
        self._redo.clear()
        self._project_tree = None
        self.review_required = []
        self.dirty = False

    def adopt(self, candidate):
        """Commit an already prepared session without media IO; keep owner identity."""
        self._available_for_adopt(candidate)
        validate_source_identities(candidate.pages)
        state = dict(candidate.__dict__)
        self.__dict__.update(state)

    def _available_for_adopt(self, candidate):
        if self.busy or not isinstance(candidate, Workspace) or candidate.busy or not candidate.pages:
            raise ValueError('완료된 후보 작업만 현재 편집에 적용할 수 있습니다.')

    def clone_for_io(self):
        """Freeze edits/metadata for a worker; retain at most its decoded first page."""
        candidate = Workspace()
        candidate.pages = [Page(page.source, page.source_sha256, None, page.pdf_index,
                                page.point_size, deepcopy(page.state), source_identity=page.source_identity)
                           for page in self.pages]
        candidate.index, candidate.title, candidate.video, candidate.time = self.index, self.title, self.video, self.time
        candidate._project_tree = deepcopy(self._project_tree)
        candidate.dirty = self.dirty
        return candidate

    def load(self, paths, cancel=None):
        if self.busy:
            raise ValueError('진행 중인 작업이 끝난 뒤 새 파일을 열어 주세요.')
        check_cancel(cancel)
        suffixes = {Path(p).suffix.lower() for p in paths}
        videos = suffixes & {'.mp4', '.mov', '.m4v', '.avi', '.mkv', '.webm'}
        if videos:
            if len(paths) != 1:
                raise ValueError('영상은 한 파일씩 열어 주세요.')
            from .video import VideoSource
            video = VideoSource(paths[0], cancel=cancel)
            check_cancel(cancel)
            self._replace([video.page()], Path(paths[0]).stem[:255], video)
        else:
            pages = load_pages(paths, cancel=cancel) if cancel is not None else load_pages(paths)
            check_cancel(cancel)
            self._replace(pages, Path(paths[0]).stem[:255])

    def set_page(self, index):
        self._available()
        if not 0 <= index < len(self.pages):
            raise IndexError('페이지 번호가 올바르지 않습니다.')
        self.index = index
        self.selection_ids.clear()

    @property
    def can_undo(self):
        return bool(self._undo.get(self.index)) and not self.busy

    @property
    def can_redo(self):
        return bool(self._redo.get(self.index)) and not self.busy

    def undo(self):
        self._available()
        if self.can_undo:
            self._redo.setdefault(self.index, []).append(deepcopy(self.page.state))
            self.page.state = self._undo[self.index].pop()
            self.selection_ids.clear()
            self.dirty = True

    def redo(self):
        self._available()
        if self.can_redo:
            self._undo.setdefault(self.index, []).append(deepcopy(self.page.state))
            self.page.state = self._redo[self.index].pop()
            self.selection_ids.clear()
            self.dirty = True

    def _range(self):
        return [self.time or 0, self.video.duration] if self.video else [0, 0]

    def add_cover(self, kind, points, style='blur', radius=25, feather=12, color=None):
        self._checkpoint()
        item_id = str(uuid.uuid4()).upper()
        if kind == 'polygon':
            shape = {kind: {'id': item_id, 'points': deepcopy(points)}}
        else:
            rect = bounds(points)
            shape = {kind: {'id': item_id, 'origin': rect[:2], 'size': rect[2:]}}
        self.page.state['regions'].append({'shape': shape, 'effect': {
            'blurRadius': radius, 'featherRadius': feather, 'timeRange': self._range(),
            'enabled': True, 'style': style, 'color': color or {'red': 0, 'green': 0, 'blue': 0, 'alpha': 1},
            'keyframes': [], 'erasures': [], 'locked': False}})
        self.selectionID = item_id
        return item_id

    def add_drawing(self, kind, points, color=None, width=.006, fill=0, text='', font=None, bold=True):
        self._checkpoint()
        item_id = str(uuid.uuid4()).upper()
        self.page.state['drawings'].append({'id': item_id, 'kind': kind, 'points': deepcopy(points),
            **(color or {'red': 1, 'green': 1, 'blue': 0, 'alpha': 1}), 'lineWidth': width,
            'fillOpacity': fill, 'timeRange': self._range(), 'keyframes': [], 'erasures': [],
            'hidden': False, 'locked': False, 'text': text, 'bold': bold,
            **({'fontName': font} if font else {})})
        self.selectionID = item_id
        return item_id

    def items(self):
        if not self.page:
            return []
        return [(item, True) for item in self.page.state['regions']] + [(item, False) for item in self.page.state['drawings']]

    @staticmethod
    def item_id(item, region):
        return next(iter(item['shape'].values()))['id'] if region else item['id']

    def selected(self):
        return next(((item, region) for item, region in self.items()
                     if self.item_id(item, region) == self.selectionID), None)

    def _selected_ids_with_groups(self):
        groups = {(item['effect'] if region else item).get('groupID')
                  for item, region in self.items() if self.item_id(item, region) in self.selection_ids}
        groups.discard(None)
        return self.selection_ids | {self.item_id(item, region) for item, region in self.items()
            if (item['effect'] if region else item).get('groupID') in groups}

    def update_selected(self, **properties):
        self._available()
        common = {'name', 'locked', 'hidden', 'groupID', 'timeRange', 'keyframes', 'erasures'}
        region_fields = common | {'style', 'color', 'blurRadius', 'featherRadius', 'enabled'}
        drawing_fields = common | {'red', 'green', 'blue', 'alpha', 'lineWidth', 'fillOpacity',
                                   'text', 'fontName', 'bold', 'textBackground'}
        if properties.keys() - region_fields - drawing_fields:
            raise ValueError('지원하지 않는 편집 속성입니다.')
        updates = []
        for item, region in self.items():
            if self.item_id(item, region) not in self.selection_ids:
                continue
            fields = region_fields if region else drawing_fields
            applicable = {key: value for key, value in properties.items() if key in fields}
            if applicable:
                updates.append((item['effect'] if region else item, region, applicable))
        if not updates:
            return
        self._checkpoint()
        for target, region, applicable in updates:
            for key, value in applicable.items():
                if region and key == 'hidden':
                    target['enabled'] = not value
                elif value is None:
                    target.pop(key, None)
                else:
                    target[key] = deepcopy(value)

    def apply_text_properties(self, **properties):
        """Apply explicit text fields to unlocked selections in one undo.

        Missing keys and explicit nulls remain distinct. This transaction never
        expands a selection to its group or changes the general layer policy.
        """
        self._available()
        if properties.keys() - {'text', 'fontName', 'bold'}:
            raise ValueError('지원하지 않는 글자 편집 속성입니다.')
        for key, value in properties.items():
            if value is not None and (type(value) is not bool if key == 'bold' else not isinstance(value, str)):
                raise ValueError('글자·글꼴은 문자열, 굵게는 참/거짓 값을 사용하세요.')
        updates = []
        for item, region in self.items():
            if (region or item['kind'] != 'text' or item['id'] not in self.selection_ids
                    or item.get('locked', False)):
                continue
            changed = {key: value for key, value in properties.items()
                       if key not in item or item[key] != value}
            if changed:
                updates.append((item, changed))
        if not updates:
            return False
        self._checkpoint()
        for item, changed in updates:
            item.update(deepcopy(changed))
        return True

    def set_selected_color(self, color, region):
        """Restyle only matching, unlocked explicit selections, in one undo.

        Brush defaults belong to the window. This transaction preserves every
        other persisted field and does not expand a selection to its group.
        """
        self._available()
        channels = ('red', 'green', 'blue', 'alpha')
        if set(color) != set(channels) or any(isinstance(color[key], bool)
                or not isinstance(color[key], (int, float)) or not math.isfinite(color[key])
                or not 0 <= color[key] <= 1 for key in channels):
            raise ValueError('색상은 유한한 RGBA 0~1 값을 사용하세요.')
        updates = []
        for item, is_region in self.items():
            target = item['effect'] if is_region else item
            if (is_region != region or self.item_id(item, is_region) not in self.selection_ids
                    or target.get('locked', False)):
                continue
            previous = target.get('color', {'red': 0, 'green': 0, 'blue': 0, 'alpha': 1}) if region else {
                key: target.get(key, 1) for key in channels}
            if previous != color:
                updates.append(target)
        if not updates:
            return False
        self._checkpoint()
        for target in updates:
            if region:
                target['color'] = deepcopy(color)
            else:
                target.update(deepcopy(color))
        return True

    def delete_selected(self):
        self._checkpoint()
        for key, region in [('regions', True), ('drawings', False)]:
            self.page.state[key] = [item for item in self.page.state[key]
                                   if self.item_id(item, region) not in self.selection_ids
                                   or (item['effect'] if region else item).get('locked', False)]
        self.selection_ids.clear()

    def erase(self, points, width, time=None, from_now=True, mode='partial', target='all'):
        if mode not in ('partial', 'item') or target not in ('all', 'regions', 'drawings'):
            raise ValueError('지우개 종류 또는 대상이 올바르지 않습니다.')
        if not points or not math.isfinite(width) or not 0 < width <= 16:
            raise ValueError('지우개 크기와 경로를 확인하세요.')
        if any(len(p) != 2 or any(not math.isfinite(v) for v in p) for p in points):
            raise ValueError('지우개 좌표를 확인하세요.')
        if time is not None and (not math.isfinite(time) or time < 0):
            raise ValueError('지우개 시각을 확인하세요.')
        erase_target = target
        self._checkpoint()
        removed = set()
        for item, region in self.items():
            if (region and erase_target == 'drawings') or (not region and erase_target == 'regions'):
                continue
            target = item['effect'] if region else item
            if target.get('locked', False):
                continue
            from .renderer import active
            if (region and not target.get('enabled', True)) or (not region and target.get('hidden', False)):
                continue
            if not active(target.get('timeRange', [0, 0]), time):
                continue
            base_points = shape_points(item)[1] if region else item['points']
            old = bounds(base_points)
            shown = rect_at(old, target.get('keyframes', []), time)
            if mode == 'item':
                from PySide6.QtGui import QPainterPathStroker
                from .renderer import path_for, arrow_head
                displayed = positioned(item, region, time)
                kind, item_points = shape_points(displayed) if region else (displayed['kind'], displayed['points'])
                pixels = (self.page.image.width(), self.page.image.height())
                scale = math.sqrt(pixels[0] * pixels[1])
                area = path_for(kind, item_points, *pixels)
                pen = QPainterPathStroker()
                pen.setWidth(width * scale)
                from PySide6.QtCore import Qt
                pen.setCapStyle(Qt.PenCapStyle.RoundCap)
                pen.setJoinStyle(Qt.PenJoinStyle.RoundJoin)
                eraser = pen.createStroke(path_for('freehand', points if len(points) > 1 else points * 2, *pixels))
                if len(points) == 1:
                    from PySide6.QtCore import QRectF
                    p = points[0]
                    diameter = width * scale
                    eraser.addEllipse(QRectF(p[0] * pixels[0] - diameter / 2,
                                            (1 - p[1]) * pixels[1] - diameter / 2, diameter, diameter))
                if not region and kind != 'text':
                    pen.setWidth(displayed['lineWidth'] * scale)
                    painted = pen.createStroke(area)
                    if displayed.get('fillOpacity', 0):
                        from PySide6.QtGui import QPainterPath
                        filled = QPainterPath(area)
                        if kind == 'freehand':
                            filled.closeSubpath()
                        painted = painted.united(filled)
                    area = painted
                    if kind == 'arrow':
                        area = area.united(arrow_head(item_points, *pixels, displayed['lineWidth'] * scale))
                if eraser.intersects(area):
                    # A time-based whole-item erasure preserves all earlier frames.
                    start = target.get('timeRange', [0, 0])[0]
                    cutoff = time - .0005 if time is not None else 0
                    if self.video and from_now and time is not None and cutoff - start > .001:
                        target['timeRange'] = [start, cutoff]
                    else:
                        removed.add(self.item_id(item, region))
                continue
            base_stroke = [map_point(p, shown, old) for p in points]
            target.setdefault('erasures', []).append({'points': base_stroke, 'width': width,
                                                       **({'from': time} if time is not None and from_now else {})})
        if removed:
            for key, is_region in [('regions', True), ('drawings', False)]:
                self.page.state[key] = [item for item in self.page.state[key] if self.item_id(item, is_region) not in removed]
            self.selection_ids -= removed

    def retime_keyframe(self, old_time, new_time):
        selected = self.selected()
        if not selected:
            return
        properties = selected[0]['effect'] if selected[1] else selected[0]
        frames = deepcopy(properties.get('keyframes', []))
        if not math.isfinite(new_time) or not math.isfinite(old_time) or not 0 <= new_time <= (self.video.duration if self.video else new_time):
            raise ValueError('기록 시각이 영상 길이 밖입니다.')
        if any(abs(frame['time'] - new_time) < .001 and abs(frame['time'] - old_time) >= .001 for frame in frames):
            raise ValueError('같은 시각의 기록점이 이미 있습니다.')
        for frame in frames:
            if abs(frame['time'] - old_time) < .001:
                frame['time'] = new_time
        self.update_selected(keyframes=sorted(frames, key=lambda frame: frame['time']))

    def resize_selected(self, rect, time=None):
        if len(rect) != 4 or any(not math.isfinite(v) for v in rect) or any(v < 0 for v in rect[2:]):
            raise ValueError('크기와 위치는 유한한 좌표와 음수가 아닌 크기를 사용하세요.')
        if time is not None and (not math.isfinite(time) or time < 0):
            raise ValueError('편집 시각을 확인하세요.')
        selected = self.selected()
        if not selected:
            return
        anchor = positioned(selected[0], selected[1], time)
        anchor_points = shape_points(anchor)[1] if selected[1] else anchor['points']
        anchor_rect = bounds(anchor_points)
        selected_ids = self._selected_ids_with_groups()
        self._checkpoint()
        for item, region in self.items():
            target = item['effect'] if region else item
            if self.item_id(item, region) not in selected_ids or target.get('locked', False):
                continue
            points = shape_points(item)[1] if region else item['points']
            old = bounds(points)
            shown = rect_at(old, target.get('keyframes', []), time)
            moved_origin = map_point(shown[:2], anchor_rect, rect)
            moved_size = [shown[i + 2] * rect[i + 2] / anchor_rect[i + 2]
                          if anchor_rect[i + 2] else shown[i + 2] for i in range(2)]
            item_rect = moved_origin + moved_size
            frames = target.get('keyframes', [])
            start = target.get('timeRange', [0, 0])[0]
            if time is not None and self.record_motion and (frames or time - start >= .001):
                frames = target.setdefault('keyframes', [])
                if not frames and time > target.get('timeRange', [0, 0])[0] + .001:
                    frames.append({'time': target.get('timeRange', [0, 0])[0], 'rect': [old[:2], old[2:]]})
                target['keyframes'] = sorted([f for f in frames if abs(f['time'] - time) >= .001]
                                             + [{'time': time, 'rect': [item_rect[:2], item_rect[2:]]}], key=lambda f: f['time'])
                continue
            # Recording off shifts the complete recorded path while preserving relative offsets.
            delta = [item_rect[i] - shown[i] for i in range(4)]
            dimensions = self.page.point_size or (self.page.image.width(), self.page.image.height())
            def shifted(r):
                return [r[0] + delta[0], r[1] + delta[1]] + [
                    0 if r[i + 2] == 0 else max(1 / dimensions[i], r[i + 2] + delta[i + 2])
                    for i in range(2)]
            new_base = shifted(old) if frames else item_rect
            moved = [map_point(p, old, new_base) for p in points]
            if region:
                kind, shape = next(iter(item['shape'].items()))
                if kind == 'polygon':
                    shape['points'] = moved
                else:
                    shape['origin'], shape['size'] = new_base[:2], new_base[2:]
            else:
                item['points'] = moved
            for hole in target.get('erasures', []):
                hole['points'] = [map_point(p, old, new_base) for p in hole['points']]
            for frame in target.get('keyframes', []):
                r = frame['rect'][0] + frame['rect'][1]
                moved_frame = shifted(r)
                frame['rect'] = [moved_frame[:2], moved_frame[2:]]

    def move_selected(self, dx, dy, time=None):
        """Translate without applying resize minimums or recomputing extents.

        A one-pixel or subpixel item remains the same size, including every
        recorded frame and erasure. Actual resize keeps its separate minimum
        policy. Both mouse and keyboard moves use this single undo transaction.
        """
        if not math.isfinite(dx) or not math.isfinite(dy):
            raise ValueError('이동은 유한한 좌표를 사용하세요.')
        if time is not None and (not math.isfinite(time) or time < 0):
            raise ValueError('편집 시각을 확인하세요.')
        if not self.selected() or not (dx or dy):
            return
        selected_ids = self._selected_ids_with_groups()
        moving = [(item, region) for item, region in self.items()
                  if self.item_id(item, region) in selected_ids
                  and not (item['effect'] if region else item).get('locked', False)]
        if not moving:
            return
        self._checkpoint()
        def translated(point):
            return [point[0] + dx, point[1] + dy]
        for item, region in moving:
            target = item['effect'] if region else item
            if region:
                kind, shape = next(iter(item['shape'].items()))
                old = (bounds(shape['points']) if kind == 'polygon' else
                       list(shape['origin']) + list(shape['size']))
            else:
                old = bounds(item['points'])
            frames = target.get('keyframes', [])
            start = target.get('timeRange', [0, 0])[0]
            if time is not None and self.record_motion and (frames or time - start >= .001):
                shown = rect_at(old, frames, time)
                if not frames and time > start + .001:
                    frames = [{'time': start, 'rect': [old[:2], old[2:]]}]
                target['keyframes'] = sorted([f for f in frames if abs(f['time'] - time) >= .001]
                    + [{'time': time, 'rect': [translated(shown[:2]), shown[2:]]}], key=lambda f: f['time'])
                continue
            if region:
                if kind == 'polygon':
                    shape['points'] = [translated(point) for point in shape['points']]
                else:
                    shape['origin'] = translated(shape['origin'])
            else:
                item['points'] = [translated(point) for point in item['points']]
            for hole in target.get('erasures', []):
                hole['points'] = [translated(point) for point in hole['points']]
            for frame in frames:
                frame['rect'][0] = translated(frame['rect'][0])

    def reorder_selected(self, offset):
        self._available()
        reordered = {}
        for key, region in [('regions', True), ('drawings', False)]:
            items = list(self.page.state[key])
            selected = [i for i in items if self.item_id(i, region) in self.selection_ids
                        and not (i['effect'] if region else i).get('locked', False)]
            selected_ids = {self.item_id(item, region) for item in selected}
            # Move a selected block across unselected neighbors, never across
            # itself. This preserves relative order even at either boundary.
            for _ in range(min(abs(offset), len(items))):
                indices = range(len(items) - 2, -1, -1) if offset > 0 else range(1, len(items))
                changed = False
                for index in indices:
                    neighbor = index + (1 if offset > 0 else -1)
                    if (self.item_id(items[index], region) in selected_ids
                            and self.item_id(items[neighbor], region) not in selected_ids):
                        items[index], items[neighbor] = items[neighbor], items[index]
                        changed = True
                if not changed:
                    break
            if items != self.page.state[key]:
                reordered[key] = items
        if reordered:
            self._checkpoint()
            self.page.state.update(reordered)

    def duplicate_selected(self, offset=None):
        self._available()
        selected = self._selected_ids_with_groups()
        if not selected:
            return
        dimensions = self.page.point_size or (self.page.image.width(), self.page.image.height())
        dx, dy = offset or (12 / dimensions[0], -12 / dimensions[1])
        groups, copies, new_ids = {}, {'regions': [], 'drawings': []}, set()
        for original, region in self.items():
            if self.item_id(original, region) not in selected:
                continue
            item = deepcopy(original)
            identifier = str(uuid.uuid4()).upper()
            new_ids.add(identifier)
            properties = item['effect'] if region else item
            if region:
                kind, shape = next(iter(item['shape'].items()))
                shape['id'] = identifier
                if kind == 'polygon':
                    shape['points'] = [[x + dx, y + dy] for x, y in shape['points']]
                else:
                    shape['origin'] = [shape['origin'][0] + dx, shape['origin'][1] + dy]
            else:
                item['id'] = identifier
                item['points'] = [[x + dx, y + dy] for x, y in item['points']]
            if properties.get('groupID'):
                old = properties['groupID']
                properties['groupID'] = groups.setdefault(old, str(uuid.uuid4()).upper())
            if properties.get('name'):
                properties['name'] = bounded_name_with_suffix(properties['name'], ' 사본')
            for hole in properties.get('erasures', []):
                hole['points'] = [[x + dx, y + dy] for x, y in hole['points']]
            for frame in properties.get('keyframes', []):
                frame['rect'][0] = [frame['rect'][0][0] + dx, frame['rect'][0][1] + dy]
            copies['regions' if region else 'drawings'].append(item)
        self._checkpoint()
        for key in copies:
            self.page.state[key].extend(copies[key])
        self.selection_ids = new_ids

    @staticmethod
    def _read_project(path, *, allow_legacy_pdf=False, cancel=None):
        check_cancel(cancel)
        project_path = Path(path).absolute()
        if project_path.stat().st_size > MAX_V2_BYTES:
            raise ValueError('프로젝트 파일 크기 한도를 초과했습니다.')
        with project_path.open('rb') as source:
            chunks, total = [], 0
            while total <= MAX_V2_BYTES:
                check_cancel(cancel)
                chunk = source.read(min(1024 * 1024, MAX_V2_BYTES + 1 - total))
                if not chunk:
                    break
                chunks.append(chunk)
                total += len(chunk)
            payload = b''.join(chunks)
        check_cancel(cancel)
        project = decode_project(payload)
        reviews = validate_host_reviews(project)
        if allow_legacy_pdf:
            reviews = tuple(reason for reason in reviews if not re.fullmatch(
                r'\$\.pages\[[0-9]+\]: legacy edited PDF requires host crop/rotation geometry check before render/export',
                reason))
        if reviews:
            raise ValueError('프로젝트 호환 검토가 필요해 기존 편집을 적용하지 않았습니다:\n'
                             + '\n'.join(reviews))
        return project

    def import_project_items(self, path, page_index=0, cancel=None):
        self._available()
        project = self._read_project(path, cancel=cancel)
        tree = project.to_dict()
        entry = tree if project.version in (1, 3) else tree['pages'][page_index]
        if self.video and project.version == 1:
            from .video_project_compatibility import require_legacy_video_timing_compatible
            require_legacy_video_timing_compatible(entry, getattr(self.video, 'origin', None))
        elif self.video and project.version == 3:
            # Explicit import targets the operating source, not the old SHA.
            # Its edits remain asset numbers; target clock must be observed.
            self.video.verified_asset_binding(cancel)
        groups, additions = {}, {'regions': [], 'drawings': []}
        for key, region in [('regions', True), ('drawings', False)]:
            for original in entry[key]:
                check_cancel(cancel)
                item = deepcopy(original)
                identifier = str(uuid.uuid4()).upper()
                if region:
                    next(iter(item['shape'].values()))['id'] = identifier
                else:
                    item['id'] = identifier
                properties = item['effect'] if region else item
                if properties.get('groupID'):
                    old = properties['groupID']
                    properties['groupID'] = groups.setdefault(old, str(uuid.uuid4()).upper())
                interval = properties.get('timeRange', [0, 0])
                if self.video and interval != [0, 0] and interval[1] > self.video.duration:
                    properties['timeRange'] = [min(interval[0], self.video.duration), self.video.duration]
                additions[key].append(item)
        if not any(additions.values()):
            return
        validate_source_identities(self.pages)
        check_cancel(cancel)
        self._checkpoint()
        self.selection_ids.clear()
        for key, region in [('regions', True), ('drawings', False)]:
            self.page.state[key].extend(additions[key])
            self.selection_ids.update(self.item_id(item, region) for item in additions[key])

    @_owned_asset_transaction
    def apply_project_template(self, path, media_paths, page_index=0, cancel=None):
        if self.busy:
            raise ValueError('진행 중인 작업이 끝난 뒤 템플릿을 여세요.')
        project = self._read_project(path, cancel=cancel)
        tree = project.to_dict()
        entry = tree if project.version in (1, 3) else tree['pages'][page_index]
        # Explicit template use applies normalized edits to intentionally different
        # media. Load into a temporary workspace so failure retains current edits.
        candidate = Workspace()
        candidate.load(media_paths, cancel=cancel)
        if candidate.video and project.version == 1:
            from .video_project_compatibility import require_legacy_video_timing_compatible
            require_legacy_video_timing_compatible(entry, getattr(candidate.video, 'origin', None))
        elif candidate.video and project.version == 3:
            candidate.video.verified_asset_binding(cancel)
        for page in candidate.pages:
            check_cancel(cancel)
            page.state = {key: deepcopy(entry[key]) for key in ('regions', 'drawings')}
            if candidate.video:
                for item, region in candidate.items():
                    properties = item['effect'] if region else item
                    interval = properties.get('timeRange', [0, 0])
                    if interval != [0, 0] and interval[1] > candidate.video.duration:
                        properties['timeRange'] = [min(interval[0], candidate.video.duration), candidate.video.duration]
        check_cancel(cancel)
        validate_source_identities(candidate.pages)
        self._replace(candidate.pages, candidate.title, candidate.video)
        self.dirty = True

    def group_selected(self, ids=None):
        self._checkpoint()
        ids = set(ids) if ids is not None else self.selection_ids
        group = str(uuid.uuid4()).upper()
        for item, region in self.items():
            if self.item_id(item, region) in ids:
                (item['effect'] if region else item)['groupID'] = group

    def ungroup_selected(self):
        self.update_selected(groupID=None)

    def copy_all(self):
        self._available()
        source = deepcopy(self.page.state)
        original_index = self.index
        for index, page in enumerate(self.pages):
            if index == original_index:
                continue
            self.index = index
            self._checkpoint()
            page.state = deepcopy(source)
        self.index = original_index

    def save_project(self, path, cancel=None):
        self._available()
        check_cancel(cancel)
        validate_output_path(path, platform='windows')
        destination = Path(path).absolute()
        from .media import validate_sources
        validate_sources(self.pages, cancel)
        binding=None
        if self.video and getattr(self.video,'asset_session',None) is not None:
            binding=self.video.verified_asset_binding(cancel)
            if (Path(self.video.path) != self.page.source or
                    binding.source_sha256 != self.page.source_sha256):
                raise ValueError('현재 페이지와 영상 프로젝트 원본 바인딩이 다릅니다.')
        elif self.video:
            from .video_project_compatibility import require_legacy_video_timing_compatible
            require_legacy_video_timing_compatible(self.page.state, getattr(self.video, 'origin', None))
        tree = deepcopy(self._project_tree) if self._project_tree else {}
        def reference(page):
            return page.source.name if page.source.parent == destination.parent else str(page.source)
        if binding is not None:
            from . import __version__
            tree.update(version=3, mediaKind='video', mediaPath=reference(self.page),
                sourceSHA256=binding.source_sha256,
                producer={'name':'BlurAction','platform':'windows','version':__version__},
                timeline=binding.timeline, **deepcopy(self.page.state))
        elif self.video or (tree.get('version') == 1 and len(self.pages) == 1):
            tree.update(version=1, mediaPath=reference(self.page), **deepcopy(self.page.state))
            # Optional extension is lossless in portable readers; legacy Mac ignores it.
            tree['sourceSHA256'] = self.page.source_sha256
        else:
            old_pages = tree.get('pages', [])
            output = []
            for index, page in enumerate(self.pages):
                check_cancel(cancel)
                entry = deepcopy(old_pages[index]) if index < len(old_pages) else {}
                entry.update(mediaPath=reference(page), sourceSHA256=page.source_sha256, **deepcopy(page.state))
                if page.pdf_index is not None:
                    entry.update(pdfPageIndex=page.pdf_index, pdfGeometryVersion=1)
                else:
                    entry.pop('pdfPageIndex', None)
                    entry.pop('pdfGeometryVersion', None)
                output.append(entry)
            tree.update(version=2, title=self.title[:255], currentIndex=self.index, pages=output)
        payload = dump_project(PortableProject(tree))
        reviews=validate_host_reviews(PortableProject(tree))
        if reviews:
            raise ValueError('프로젝트 호환 검토가 필요합니다:\n'+'\n'.join(reviews))
        validate_sources(self.pages, cancel)
        if binding is not None:
            if self.video.verified_asset_binding(cancel) != binding:
                raise ValueError('저장 중 영상 원본 또는 시간축이 변경되었습니다.')
        check_cancel(cancel)
        def before_publication():
            # Closing/flushing the private payload can take time. Keep the
            # borrowed operating session and reject changed sources before
            # the first exclusive creation of the public destination.
            validate_sources(self.pages,cancel)
            if binding is not None and self.video.verified_asset_binding(cancel)!=binding:
                raise ValueError('저장 직전 영상 원본 또는 시간축이 변경되었습니다.')
            check_cancel(cancel)
        save_bytes_new(destination,payload,cancel=cancel,prepublish=before_publication)
        self._project_tree = tree
        self.dirty = False

    @_owned_asset_transaction
    def load_project(self, path, relinks=None, acknowledged_unverified=None, cancel=None):
        if self.busy:
            raise ValueError('진행 중인 작업이 끝난 뒤 프로젝트를 여세요.')
        check_cancel(cancel)
        project_path = Path(path).absolute()
        project = self._read_project(project_path, allow_legacy_pdf=True, cancel=cancel)
        tree = project.to_dict()
        entries = [tree] if project.version in (1, 3) else tree['pages']
        relinks = relinks or {}
        native = 'windows' if os.name == 'nt' else 'macos'
        resolved, missing, unverified = [], [], []
        for entry in entries:
            check_cancel(cancel)
            old = entry['mediaPath']
            resolution = resolve_reference(old, str(project_path), native)
            source = Path(relinks[old]).absolute() if old in relinks else (Path(resolution.path) if resolution.path else None)
            if source is None or not source.is_file():
                missing.append(old)
            else:
                expected = entry.get('sourceSHA256')
                if old in relinks and not expected and old not in (acknowledged_unverified or set()):
                    unverified.append(old)
                resolved.append(source)
        if missing:
            raise MissingSources(list(dict.fromkeys(missing)))
        if unverified:
            raise UnverifiedSources(list(dict.fromkeys(unverified)))
        # Bound the complete mixed workspace before hashing any source. Video
        # hashes stream within the captured size; still documents retain the
        # existing per-file and whole-input limits.
        unique_sizes, limits = {}, {}
        for source in resolved:
            check_cancel(cancel)
            size = source.stat().st_size
            video_source = project.version == 3 or source.suffix.lower() in {'.mp4', '.mov', '.m4v', '.avi', '.mkv', '.webm'}
            limit = max(1, size) if video_source else (512 if source.suffix.lower() == '.pdf' else 128) * 1024 ** 2
            if size > limit:
                raise ValueError('원본 파일이 읽기 용량 한도를 넘습니다.')
            if not video_source:
                unique_sizes[source.resolve()] = size
            limits[source] = limit
        if sum(unique_sizes.values()) > 1024 ** 3:
            raise ValueError('전체 입력은 1GB 이하로 선택하세요.')
        checked = {}
        for entry, source in zip(entries, resolved):
            check_cancel(cancel)
            expected = entry.get('sourceSHA256')
            if expected:
                if source not in checked:
                    checked[source] = fingerprint(source, max_bytes=limits[source], cancel=cancel)
                if checked[source] != expected:
                    raise ValueError('재연결 원본의 지문이 다릅니다. 기존 편집을 자동 적용하지 않습니다.')
        decoded, legacy_geometry = {}, {}
        pages = []
        video = None
        for entry, source in zip(entries, resolved):
            check_cancel(cancel)
            is_video = project.version == 3 or source.suffix.lower() in {'.mp4', '.mov', '.m4v', '.avi', '.mkv', '.webm'}
            is_pdf = project.version == 2 and entry.get('pdfPageIndex') is not None
            if project.version == 2 and ((is_video) or (is_pdf != (source.suffix.lower() == '.pdf'))):
                raise ValueError('페이지 프로젝트의 미디어 종류가 원래 저장 정보와 다릅니다.')
            if project.version == 1 and source.suffix.lower() == '.pdf':
                raise ValueError('단일 프로젝트의 PDF는 페이지 형식으로 다시 열어 주세요.')
            if source not in decoded:
                if is_video:
                    from .video import VideoSource
                    if project.version == 3:
                        video = VideoSource(source, cancel=cancel, require_asset_presentation=True)
                        from shared.video_timeline import verify_asset_descriptor
                        binding=video.verified_asset_binding(cancel)
                        verify_asset_descriptor(tree,source_sha256=binding.source_sha256,
                                                observed_timeline=binding.timeline)
                    else:
                        video = VideoSource(source, cancel=cancel)
                        from .video_project_compatibility import require_legacy_video_timing_compatible
                        require_legacy_video_timing_compatible(entry, getattr(video, 'origin', None))
                    decoded[source] = [video.page()]
                else:
                    decoded[source] = load_pages([source], cancel=cancel) if cancel is not None else load_pages([source])
            index = int(entry['pdfPageIndex']) if entry.get('pdfPageIndex') is not None else 0
            if index >= len(decoded[source]):
                raise ValueError('프로젝트의 PDF 페이지가 원본에 없습니다.')
            base = decoded[source][index]
            if entry.get('sourceSHA256') and base.source_sha256 != entry['sourceSHA256']:
                raise ValueError('원본이 프로젝트를 여는 동안 변경되었습니다. 기존 편집을 적용하지 않았습니다.')
            if (is_pdf and entry.get('pdfGeometryVersion') is None
                    and (entry['regions'] or entry['drawings'])):
                if source not in legacy_geometry:
                    from .pdf_geometry import inspect_pdf_geometry, PDFGeometryError
                    try:
                        legacy_geometry[source] = inspect_pdf_geometry(
                            source, [page.point_size for page in decoded[source]],
                            expected_identity=base.source_identity, expected_sha256=base.source_sha256, cancel=cancel)
                    except PDFGeometryError as error:
                        raise ValueError('프로젝트 호환 검토가 필요해 기존 편집을 적용하지 않았습니다:\n' + str(error)) from error
                if legacy_geometry[source][index].legacy_edits_need_review:
                    raise ValueError('프로젝트 호환 검토: 이전 PDF의 crop·회전으로 좌표가 달라졌습니다. 기존 편집을 자동 적용하지 않습니다.')
            from .media import Page
            page = Page(base.source, base.source_sha256, base._image, base.pdf_index, base.point_size,
                        {'regions': deepcopy(entry['regions']), 'drawings': deepcopy(entry['drawings'])},
                        source_identity=base.source_identity)
            pages.append(page)
        selected_index = int(tree.get('currentIndex', 0))
        _ = pages[selected_index].image
        from .media import validate_sources
        validate_sources(pages, cancel)
        if video is not None and project.version == 3:
            final_binding=video.verified_asset_binding(cancel)
            verify_asset_descriptor(tree,source_sha256=final_binding.source_sha256,
                                    observed_timeline=final_binding.timeline)
        check_cancel(cancel)
        self._replace(pages, tree.get('title', project_path.stem[:255]), video)
        self.index = selected_index
        self._project_tree = tree
        # Every provisional legacy review above was resolved against the exact
        # source baseline before committing. Other review types never pass here.
        self.review_required = []
        return self.review_required
