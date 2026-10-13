"""Prepare and commit automatic edits as a single undoable transaction."""
from copy import deepcopy
import math
import uuid

from .auto_find import MAX_FINDS
from .renderer import active, bounds, positioned, shape_points


def prepared_regions(detections, state, time, duration, *, style, radius, feather, color):
    if len(detections) > MAX_FINDS:
        raise ValueError('찾은 영역은 최대 512개입니다.')
    if style not in ('blur','mosaic','solid') or not all(math.isfinite(v) and 0 <= v <= 500 for v in (radius,feather)):
        raise ValueError('가리기 설정을 확인하세요.')
    regions = []
    for detection in detections:
        x, y, w, h = detection.rect
        if not all(math.isfinite(v) for v in (x,y,w,h)) or min(w,h) <= 0 or min(x,y) < 0 or x+w > 1.000001 or y+h > 1.000001:
            raise ValueError('찾은 영역의 좌표를 확인하세요.')
        duplicate = False
        for existing in state['regions']:
            effect = existing['effect']
            if not effect.get('enabled',True) or not active(effect.get('timeRange',[0,0]), time) or effect.get('erasures'):
                continue
            existing_style = effect.get('style', 'blur')
            if ((existing_style in ('blur', 'mosaic') and effect.get('blurRadius', 25) <= 0)
                    or (existing_style == 'solid' and effect.get('color', {}).get('alpha', 1) <= 0)):
                continue
            shown = positioned(existing,True,time)
            shape, points = shape_points(shown)
            a,b,c,d = bounds(points)
            # Only a complete un-erased rectangle proves full coverage. A
            # touching ellipse/freehand/partial rectangle must not hide a find.
            if shape == 'rectangle' and a <= x and b <= y and a+c >= x+w and b+d >= y+h:
                duplicate = True
                break
        if duplicate:
            continue
        identifier = str(uuid.uuid4()).upper()
        kind = 'ellipse' if detection.kind == 'faces' else 'rectangle'
        regions.append({'shape':{kind:{'id':identifier,'origin':[x,y],'size':[w,h]}},
                        'effect':{'blurRadius':radius,'featherRadius':feather,'enabled':True,
                                  'style':style,'color':deepcopy(color),'locked':False,
                                  'name':'찾은 얼굴' if kind=='ellipse' else '찾은 글자',
                                  'timeRange':[time,duration] if duration is not None else [0,0],
                                  'keyframes':[],'erasures':[]}})
    return regions


def apply_tracks_to_items(items, results):
    by_id = {result.item_id:result for result in results if not result.skipped}
    for item, region in items:
        identifier = next(iter(item['shape'].values()))['id'] if region else item['id']
        if identifier in by_id:
            result = by_id[identifier]
            target = item['effect'] if region else item
            target['keyframes'] = deepcopy(result.keyframes)
            target['timeRange'] = list(result.time_range)


def commit_find(workspace, regions):
    workspace._available()
    if not regions:
        return set()
    regions = deepcopy(regions)
    workspace._checkpoint()
    workspace.page.state['regions'].extend(regions)
    identifiers = {next(iter(region['shape'].values()))['id'] for region in regions}
    workspace.selection_ids = identifiers
    return identifiers


def commit_tracking(workspace, results):
    workspace._available()
    applicable = {r.item_id for r in results if not r.skipped}
    items = [(item,region) for item,region in workspace.items()
             if workspace.item_id(item,region) in applicable
             and not (item['effect'] if region else item).get('locked',False)]
    if items:
        workspace._checkpoint()
        apply_tracks_to_items(items, results)
