"""Temporary shift guard for legacy v1 video projects without timeline policy.

This is not a decoder, a source/native origin policy, or full compatibility proof.
Call only for video state after normal project/source validation, before applying
legacy state or creating an output. Never shift/rewrite saved times to pass it.
Actual timeline support and source-frame/Qt/PyAV verification remain required.
"""
from fractions import Fraction


class VideoTimelineReview(ValueError):
    """Keep current edits/output intact until legacy video timing is reviewed."""


def _temporal_fields(item):
    reasons = []
    if 'timeRange' in item and item['timeRange'] != [0, 0]:
        reasons.append('시간 범위')
    if item.get('keyframes'):
        reasons.append('이동 기록점')
    if any(stroke.get('from') is not None for stroke in item.get('erasures') or []):
        # The schema/renderer treat omitted or null cutoff as all-time. Other
        # malformed cutoff values remain a separate normal validation error.
        reasons.append('시간 지우개')
    return reasons


def require_legacy_video_timing_compatible(state, source_origin):
    """Reject temporal edits unless this narrow shift guard knows exact zero.

    Always-on [0,0] effects/drawings without motion or temporal erasures pass
    regardless of origin. Any nonzero, unknown or non-Fraction origin with
    temporal fields requires review. Hidden/disabled/locked edits are included:
    they remain saved edits that may later become visible. Nothing is mutated.
    Passing exact Fraction(0) proves only absence of this origin-shift risk;
    it does not establish frame identity, precision or cross-platform parity.
    """
    reasons = set()
    for region in state.get('regions', []):
        reasons.update(_temporal_fields(region['effect']))
    for drawing in state.get('drawings', []):
        reasons.update(_temporal_fields(drawing))
    if not reasons or (type(source_origin) is Fraction and source_origin == 0):
        return
    fields = '·'.join(reason for reason in ('시간 범위', '이동 기록점', '시간 지우개') if reason in reasons)
    raise VideoTimelineReview(
        f'이전 영상 프로젝트의 시간축 호환 검토가 필요합니다 ({fields}). '
        '원본의 시간 원점이 정확한 0초로 확인되지 않아 저장된 시간 편집을 '
        '자동 적용하거나 저장하지 않았습니다. 기간·기록점·지우개 시각은 변경하지 않습니다.'
    )
