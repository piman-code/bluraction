"""Mandatory, exact asset presentation metadata for video project v3.

This is a data boundary, not a decoder clock policy. A host must independently
inspect the fingerprinted source and compare its asset descriptor before applying
edits. Producer/platform information never establishes a legacy video's clock.
Native/PyAV/Qt timestamps and private PTS indices are deliberately not persisted.
"""
from __future__ import annotations

from fractions import Fraction
import re

INT64_MAX = (1 << 63) - 1
INT64_MIN = -(1 << 63)
MAX_TRACKS = 17
MAX_SEGMENTS = 4096


class VideoTimelineError(ValueError):
    pass


def _object(value, fields, path):
    if type(value) is not dict or set(value) != set(fields):
        raise VideoTimelineError(path + ': missing or unsupported fields')


def _integer(value, low, high, path):
    if type(value) is not int or not low <= value <= high:
        raise VideoTimelineError(path + ': invalid integer')


def rational(value, path='rational'):
    """Read reduced decimal Int64 strings without JSON float precision loss."""
    _object(value, ('numerator', 'denominator'), path)
    numbers = []
    for field in ('numerator', 'denominator'):
        text = value[field]
        if type(text) is not str or len(text) > 20 or re.fullmatch(r'0|-?[1-9][0-9]*', text) is None:
            raise VideoTimelineError(path + '.' + field + ': expected canonical decimal string')
        number = int(text)
        if not INT64_MIN <= number <= INT64_MAX:
            raise VideoTimelineError(path + '.' + field + ': outside Int64')
        numbers.append(number)
    if numbers[1] <= 0:
        raise VideoTimelineError(path + ': denominator must be positive')
    result = Fraction(*numbers)
    if (result.numerator, result.denominator) != tuple(numbers):
        raise VideoTimelineError(path + ': fraction must be reduced')
    return result


def encode_rational(value):
    if type(value) is not Fraction:
        raise VideoTimelineError('exact Fraction required')
    result = {'numerator': str(value.numerator), 'denominator': str(value.denominator)}
    rational(result)
    return result


def validate_timeline(value):
    _object(value, ('version', 'basis', 'assetDuration', 'tracks'), 'timeline')
    _integer(value['version'], 1, 1, 'timeline.version')
    if value['basis'] != 'asset-presentation':
        raise VideoTimelineError('timeline: unknown time basis')
    duration = rational(value['assetDuration'], 'timeline.assetDuration')
    if duration <= 0:
        raise VideoTimelineError('timeline: nonpositive asset duration')
    tracks = value['tracks']
    if type(tracks) is not list or not 1 <= len(tracks) <= MAX_TRACKS:
        raise VideoTimelineError('timeline: invalid track count')
    identities = set()
    previous_id = 0
    videos = 0
    for track in tracks:
        _object(track, ('id', 'kind', 'mediaTimescale', 'segments'), 'timeline.track')
        _integer(track['id'], 1, INT64_MAX, 'timeline.track.id')
        _integer(track['mediaTimescale'], 1, INT64_MAX, 'timeline.track.mediaTimescale')
        if track['id'] in identities:
            raise VideoTimelineError('timeline: duplicate track ID')
        if track['id'] <= previous_id:
            raise VideoTimelineError('timeline: tracks must be ordered by container track ID')
        identities.add(track['id'])
        previous_id = track['id']
        if track['kind'] not in ('video', 'audio'):
            raise VideoTimelineError('timeline: unsupported track kind')
        videos += track['kind'] == 'video'
        segments = track['segments']
        if type(segments) is not list or not 1 <= len(segments) <= MAX_SEGMENTS:
            raise VideoTimelineError('timeline: invalid segment count')
        end = Fraction(0)
        content = False
        for segment in segments:
            _object(segment, ('assetStart', 'assetDuration', 'mediaStart', 'rate'), 'timeline.segment')
            start = rational(segment['assetStart'], 'timeline.segment.assetStart')
            length = rational(segment['assetDuration'], 'timeline.segment.assetDuration')
            rate = rational(segment['rate'], 'timeline.segment.rate')
            if start != end or length <= 0 or rate <= 0:
                raise VideoTimelineError('timeline: unordered/gapped/invalid segment; encode gaps explicitly')
            end = start + length
            if end > duration:
                raise VideoTimelineError('timeline: segment exceeds asset duration')
            if segment['mediaStart'] is None:
                if rate != 1:
                    raise VideoTimelineError('timeline: empty segment rate must be one')
            else:
                media = rational(segment['mediaStart'], 'timeline.segment.mediaStart')
                if media < 0:
                    raise VideoTimelineError('timeline: negative content media start')
                content = True
        if not content:
            raise VideoTimelineError('timeline: track has no content')
    if videos != 1:
        raise VideoTimelineError('timeline: exactly one video track required')


def validate_video_metadata(project):
    """Validate mandatory v3 envelope fields; edits are validated separately."""
    if type(project) is not dict or project.get('mediaKind') != 'video':
        raise VideoTimelineError('v3: video media kind required')
    _integer(project.get('version'), 3, 3, 'project.version')
    digest = project.get('sourceSHA256')
    if type(digest) is not str or re.fullmatch(r'[0-9a-f]{64}', digest) is None:
        raise VideoTimelineError('v3: source SHA-256 required')
    producer = project.get('producer')
    _object(producer, ('name', 'platform', 'version'), 'producer')
    if producer['name'] != 'BlurAction' or producer['platform'] not in ('macos', 'windows'):
        raise VideoTimelineError('producer: unsupported identity')
    version = producer['version']
    if type(version) is not str or not 1 <= len(version) <= 64 or re.fullmatch(r'[0-9A-Za-z.+_-]+', version) is None:
        raise VideoTimelineError('producer: invalid app version')
    validate_timeline(project.get('timeline'))


def verify_asset_descriptor(project, *, source_sha256, observed_timeline):
    """Require the independently inspected source, never a saved origin guess.

    Caller guards source identity before and after native inspection. Exact
    descriptor equality is intentionally strict; a host must investigate native
    policy differences instead of rewriting periods/keyframes/eraser start times.
    """
    validate_video_metadata(project)
    validate_timeline(observed_timeline)
    if project['sourceSHA256'] != source_sha256 or project['timeline'] != observed_timeline:
        raise VideoTimelineError('video source fingerprint or asset timeline changed')
