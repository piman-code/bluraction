"""Shared playback policy for observed or omitted sample aspect ratios.

Raw frame inventories keep missing SAR missing. Display prefers the frame,
then codec, then FFmpeg's stream ratio (which can include container geometry).
Only wholly unspecified geometry uses square pixels, matching ffplay's
calculate_display_rect fallback. This is a compatibility policy, not evidence
that the source explicitly declared 1:1. Never infer a 16:9/4:3 ratio from size.

https://github.com/FFmpeg/FFmpeg/blob/n8.0/fftools/ffplay.c
"""
from fractions import Fraction


class DisplayGeometryError(ValueError):
    pass


def resolve_display_sar(frame_sar=None, codec_sar=None, stream_sar=None):
    """Return one exact positive ratio; reject malformed metadata, not absence."""
    from .frame_inventory import _exact_fraction
    for value in (frame_sar, codec_sar, stream_sar):
        if value is None:
            continue
        try:
            exact = _exact_fraction(value, '영상 픽셀 비율')
        except ValueError as error:
            raise DisplayGeometryError('영상의 픽셀 비율 정보를 읽을 수 없습니다.') from error
        if exact < 0:
            raise DisplayGeometryError('영상의 픽셀 비율 정보가 잘못되었습니다.')
        if exact > 0:
            return exact
    return Fraction(1)
