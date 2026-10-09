"""Atomic, multi-target CSRT paths on source presentation timestamps.

Forward cursors and reverse timestamp queries share the original source's
identity/asset checks. No average-FPS clock or unbounded reverse frame cache.
"""
from copy import deepcopy
from dataclasses import dataclass
import math

from .media import check_cancel
from .renderer import bounds, positioned, shape_points
from .video import VideoError, _bgr, _csrt


@dataclass
class TrackResult:
    item_id: str
    keyframes: list
    time_range: list
    lost: bool = False
    skipped: bool = False


def _reverse_frames(source, initial, lower, cancel):
    current = initial
    for _ in range(100_000):
        check_cancel(cancel)
        stamp = float(current.interval_start if current.interval_start is not None else current.time)
        if stamp <= lower:
            return
        previous = source.frame_at_timed(max(lower, stamp-1e-7), cancel=cancel)
        if float(previous.time) >= float(current.time):
            raise VideoError('이 영상의 이전 실제 프레임 시각을 확인할 수 없습니다.')
        yield previous
        current = previous
    raise VideoError('뒤로 추적하는 프레임 수가 100,000개를 넘습니다.')


def smooth_frames(frames, region):
    result = deepcopy(frames)
    for index, target in enumerate(result):
        window = frames[max(0, index-2):index+3]
        centers = [(f['rect'][0][0]+f['rect'][1][0]/2,
                    f['rect'][0][1]+f['rect'][1][1]/2) for f in window]
        cx = sum(c[0] for c in centers)/len(centers)
        cy = sum(c[1] for c in centers)/len(centers)
        (x, y), (w, h) = frames[index]['rect']
        if region:
            # Keep the current raw box contained while damping its center.
            w = min(1., w+2*abs(cx-x-w/2))
            h = min(1., h+2*abs(cy-y-h/2))
        target['rect'] = [[max(0., min(1-w, cx-w/2)), max(0., min(1-h, cy-h/2))], [w, h]]
    return result


def track_many(source, targets, start, *, direction='both', smoothing=True,
               reacquire_faces=True, cancel=None, progress=None):
    """Return independent paths without mutating any editor item.

    Cancel discards the whole task. Lost targets retain a bounded partial path
    and a visible warning; coverage is not extended beyond verified frames.
    """
    if direction not in ('forward', 'backward', 'both') or not math.isfinite(start) or not 0 <= start < source.duration:
        raise VideoError('추적 방향과 시작 시각을 확인하세요.')
    if not targets or len(targets) > 512:
        raise VideoError('자동 추적은 한 번에 1~512개 항목을 선택하세요.')
    source.validate(cancel)
    check_cancel(cancel)
    from .auto_find import configure_cv
    configure_cv()
    initial = source.frame_at_timed(start, cancel=cancel)
    if initial.presence != 'content' or initial.image.isNull():
        raise VideoError('현재 시각에 추적할 영상 프레임이 없습니다.')
    width, height = initial.image.width(), initial.image.height()
    start = float(initial.time)
    results = []
    total_samples = 0
    for batch_offset in range(0, len(targets), 32):
        batch = []
        for item, region in targets[batch_offset:batch_offset+32]:
            check_cancel(cancel)
            item = deepcopy(item)
            properties = item['effect'] if region else item
            item_id = next(iter(item['shape'].values()))['id'] if region else item['id']
            shown = positioned(item, region, start)
            x, y, w, h = bounds(shape_points(shown)[1] if region else shown['points'])
            unavailable = (properties.get('locked') or not properties.get('enabled', True)
                           or properties.get('hidden') or min(w, h) < .01 or min(w*width, h*height) < 2
                           or x < 0 or y < 0 or x+w > 1.000001 or y+h > 1.000001)
            interval = properties.get('timeRange', [0, 0])
            upper = source.duration if interval == [0, 0] else min(source.duration, interval[1])
            unavailable = unavailable or upper < start or (interval != [0, 0] and interval[0] > start)
            result = TrackResult(item_id, [], list(interval), skipped=bool(unavailable))
            results.append(result)
            if unavailable:
                continue
            result.keyframes = [{'time': start, 'rect': [[x, y], [w, h]]}]
            batch.append({'item': item, 'region': region, 'properties': properties, 'initial': (x,y,w,h),
                          'result': result, 'upper': upper})
        if not batch:
            continue
        for backward in ([False, True] if direction == 'both' else [direction == 'backward']):
            initial_bgr = _bgr(initial.image)
            for target in batch:
                x, y, w, h = target['initial']
                roi = (max(0, math.floor(x*width)), max(0, math.floor((1-y-h)*height)),
                       min(width-math.floor(x*width), math.ceil(w*width)),
                       min(height-max(0, math.floor((1-y-h)*height)), math.ceil(h*height)))
                _, target['tracker'] = _csrt()
                target['active'] = target['tracker'].init(initial_bgr, roi) is not False
                target['center'] = (roi[0]+roi[2]/2, roi[1]+roi[3]/2)
                target['last_box'] = roi
                target['last_time'] = start
                target['waiting'] = False
                target['face'] = bool(target['region'] and target['properties'].get('name', '').startswith('찾은 얼굴'))
                if not target['active']:
                    target['result'].lost = True
            upper = max((t['upper'] for t in batch), default=start)
            cursor = (_reverse_frames(source, initial, 0., cancel) if backward
                      else source.iter_frames(start, upper, cancel))
            previous_stamp = start
            previous_boundary = initial.interval_start if backward else initial.interval_end
            try:
                for timed in cursor:
                    check_cancel(cancel)
                    stamp = float(timed.time)
                    if stamp == start or (timed.source_index is not None and timed.source_index == initial.source_index):
                        continue
                    if (backward and stamp >= previous_stamp) or (not backward and stamp <= previous_stamp):
                        raise VideoError('실제 영상 프레임의 시각 순서가 올바르지 않습니다.')
                    gap = (previous_boundary is not None and
                           (float(timed.interval_end or stamp) < float(previous_boundary)-1e-7 if backward
                            else stamp > float(previous_boundary)+1e-7))
                    if gap or timed.presence != 'content' or timed.image.size() != initial.image.size():
                        for target in batch:
                            if target['active']:
                                target['result'].lost = True
                                target['active'] = False
                        break
                    previous_stamp = stamp
                    previous_boundary = timed.interval_start if backward else timed.interval_end
                    bgr = _bgr(timed.image)
                    recovery = None
                    claimed_recoveries = set()
                    for target in batch:
                        if not target['active'] or (not backward and stamp > target['upper']):
                            continue
                        success, box = target['tracker'].update(bgr)
                        valid = (success and all(math.isfinite(float(v)) for v in box)
                                 and min(box[2:]) >= 2 and min(box[:2]) >= 0
                                 and box[0]+box[2] <= width and box[1]+box[3] <= height)
                        if not valid and reacquire_faces and target['face'] and abs(stamp-target['last_time']) <= 1.5:
                            from .auto_find import detect
                            if recovery is None:
                                recovery = detect(timed.image, 'faces', cancel)
                            candidates = []
                            lx, ly, lw, lh = target['last_box']
                            for face_index, found in enumerate(recovery):
                                if face_index in claimed_recoveries:
                                    continue
                                fx, fy, fw, fh = found.rect
                                candidate = (round(fx*width), round((1-fy-fh)*height), round(fw*width), round(fh*height))
                                distance = math.hypot(candidate[0]+candidate[2]/2-lx-lw/2,
                                                      candidate[1]+candidate[3]/2-ly-lh/2)
                                if distance < max(lw,lh)*1.5 and .5 < candidate[2]/lw < 2 and .5 < candidate[3]/lh < 2:
                                    candidates.append((distance, face_index, candidate))
                            candidates.sort()
                            # Ambiguous neighboring faces are not silently assigned.
                            if candidates and (len(candidates)==1 or candidates[1][0]-candidates[0][0] > max(lw,lh)*.3):
                                claimed_recoveries.add(candidates[0][1])
                                box = candidates[0][2]
                                _, target['tracker'] = _csrt()
                                valid = target['tracker'].init(bgr, box) is not False
                        if not valid:
                            if reacquire_faces and target['face'] and abs(stamp-target['last_time']) <= 1.5:
                                target['waiting'] = True
                                continue
                            target['result'].lost = True
                            target['active'] = False
                            continue
                        left, top, bw, bh = box
                        x, y, w, h = target['initial']
                        if target['region']:
                            rect = [[left/width, 1-(top+bh)/height], [bw/width, bh/height]]
                        else:
                            cx, cy = target['center']
                            nx, ny = x+(left+bw/2-cx)/width, y-(top+bh/2-cy)/height
                            if nx < 0 or ny < 0 or nx+w > 1 or ny+h > 1:
                                target['result'].lost = True
                                target['active'] = False
                                continue
                            rect = [[nx, ny], [w, h]]
                        target['result'].keyframes.append({'time': stamp, 'rect': rect})
                        target['last_box'], target['last_time'] = box, stamp
                        target['waiting'] = False
                        total_samples += 1
                        if total_samples > 200_000:
                            raise VideoError('추적 결과가 200,000개 기록을 넘습니다. 구간을 나눠 추적하세요.')
                    if progress:
                        portion = ((start-stamp)/max(start,1e-7) if backward
                                   else (stamp-start)/max(upper-start,1e-7))
                        direction_count = 2 if direction == 'both' else 1
                        completed = 1 if direction == 'both' and backward else 0
                        progress(min(.99, (batch_offset+len(batch)*(completed+portion)/direction_count)/len(targets)))
                    if not any(t['active'] and (backward or stamp < t['upper']) for t in batch):
                        break
            finally:
                close = getattr(cursor, 'close', None)
                if close is not None:
                    close()
            for target in batch:
                if target.get('waiting'):
                    target['result'].lost = True
                if target['active'] and previous_boundary is not None:
                    if ((backward and float(previous_boundary) > 1e-7)
                            or (not backward and float(previous_boundary) < target['upper']-1e-7)):
                        target['result'].lost = True
        for target in batch:
            result = target['result']
            result.keyframes.sort(key=lambda f: f['time'])
            lo, hi = result.keyframes[0]['time'], result.keyframes[-1]['time']
            if smoothing:
                result.keyframes = smooth_frames(result.keyframes, target['region'])
            if result.lost:
                # [0,0] means the entire video in the portable project format.
                # An immediately lost target must never accidentally use it.
                verified_end = float(initial.interval_end) if initial.interval_end is not None else math.nextafter(start, source.duration)
                result.time_range = [lo, max(hi, min(source.duration, verified_end))]
            else:
                result.time_range = [lo if direction in ('both','backward') else
                                     (0. if target['properties'].get('timeRange') == [0,0] else target['properties']['timeRange'][0]),
                                     target['upper']]
            retained = [f for f in target['properties'].get('keyframes', []) if f['time'] < lo or f['time'] > hi]
            result.keyframes = sorted(deepcopy(retained)+result.keyframes, key=lambda f: f['time'])
            if len(result.keyframes) > 100_000:
                raise VideoError('항목별 위치 기록은 최대 100,000개입니다.')
    source.validate(cancel)
    check_cancel(cancel)
    if progress:
        progress(1.)
    return results
