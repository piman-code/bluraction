"""Qt host validation for the portable loader's native grapheme reviews.

No media is read and no project field is changed. The caller must still refuse
render/export when validate_host_reviews returns any unresolved reasons.
Unknown-field and legacy-PDF reviews are never cleared by text validation.

Qt's Grapheme finder follows UAX #29; QString positions are UTF-16 code units,
not Python code-point indices. Only the installed Qt Unicode implementation is
claimed here, not equivalence with every future Swift Unicode version.
Official API: https://doc.qt.io/qt-6/qtextboundaryfinder.html
UTF-16 representation: https://doc.qt.io/qt-6/qstring.html
"""
from __future__ import annotations

import re

from PySide6.QtCore import QTextBoundaryFinder

from shared.portable_project import PortableProject, ProjectError, validate_project


_GRAPHEME_REVIEW = re.compile(r'^(\$(?:\.[A-Za-z][A-Za-z0-9_]*|\[[0-9]+\])*)'
                              r': native grapheme-count limit ([1-9][0-9]*) requires validation$')


def _require_text(value):
    if not isinstance(value, str):
        raise TypeError('Grapheme validation requires a string')
    # Do not let a binding replace an unpaired surrogate with another character.
    if any(0xD800 <= ord(character) <= 0xDFFF for character in value):
        raise ValueError('문자열에 올바르지 않은 Unicode surrogate가 있습니다.')


def _finder(text):
    _require_text(text)
    finder = QTextBoundaryFinder(QTextBoundaryFinder.BoundaryType.Grapheme, text)
    if not finder.isValid():
        raise ValueError('Qt에서 문자열의 grapheme 경계를 확인할 수 없습니다.')
    finder.toStart()
    return finder


def grapheme_count(text: str, stop_after: int | None = None) -> int:
    """Count actual Qt clusters; optional cutoff returns at most limit + 1.

    A cutoff bounds Python/Qt boundary crossings when refusing an oversized
    field; callers must not describe that early result as an exact full count.
    """
    _require_text(text)
    if stop_after is not None and (type(stop_after) is not int or stop_after < 0):
        raise ValueError('Grapheme cutoff must be a nonnegative integer')
    if not text:
        return 0
    finder, count = _finder(text), 0
    while finder.toNextBoundary() != -1:
        count += 1
        if stop_after is not None and count > stop_after:
            break
    return count


def _known_text_fields(tree):
    """Known Swift String.count paths/limits, not evaluation of JSONPath text."""
    if tree['version'] in (1, 3):
        pages = [('$', tree)]
    else:
        yield '$.title', tree['title'], 255
        pages = [(f'$.pages[{index}]', page) for index, page in enumerate(tree['pages'])]
    for path, page in pages:
        yield path + '.mediaPath', page['mediaPath'], 4096
        for index, region in enumerate(page['regions']):
            value = region['effect'].get('name')
            if value is not None:
                yield f'{path}.regions[{index}].effect.name', value, 200
        for index, drawing in enumerate(page['drawings']):
            for field, limit in (('name', 200), ('fontName', 200), ('text', 1000)):
                value = drawing.get(field)
                if value is not None:
                    yield f'{path}.drawings[{index}].{field}', value, limit


def validate_host_reviews(project: PortableProject) -> tuple[str, ...]:
    """Validate known text reviews and return every unresolved reason in order.

    Over-limit text raises ProjectError containing its actual data path and
    limit. Successful validation does not mutate required_reviews or the tree.
    The adapter should use the returned tuple as its remaining approval gate.
    """
    if not isinstance(project, PortableProject):
        raise TypeError('Host validation requires an already validated PortableProject')
    tree = project.to_dict()
    # Revalidate the tree so removing/changing the public review tuple cannot
    # bypass an unknown field or a native text review. Preserve extra future
    # host reasons instead of assuming every review came from this version.
    reasons = list(project.required_reviews)
    if not all(isinstance(reason, str) for reason in reasons):
        raise ProjectError('Host review reasons must be strings')
    for reason in validate_project(tree):
        if reason not in reasons:
            reasons.append(reason)
    fields = {path: (value, limit) for path, value, limit in _known_text_fields(tree)}
    unresolved = []
    for reason in reasons:
        match = _GRAPHEME_REVIEW.fullmatch(reason)
        if match is None:
            unresolved.append(reason)
            continue
        path, recorded_limit = match.group(1), match.group(2)
        if path not in fields or recorded_limit != str(fields[path][1]):
            unresolved.append(reason)
            continue
        value, maximum = fields[path]
        try:
            actual = grapheme_count(value, stop_after=maximum)
        except (TypeError, ValueError) as error:
            raise ProjectError(f'{path}: native grapheme validation failed: {error}') from error
        if actual > maximum:
            raise ProjectError(f'{path}: native grapheme-count limit {maximum} exceeded (at least {actual} clusters)')
    return tuple(unresolved)


def _prefix_clusters(text, count):
    if count == 0 or not text:
        return ''
    finder, end_utf16 = _finder(text), 0
    for _ in range(count):
        position = finder.toNextBoundary()
        if position == -1:
            return text
        end_utf16 = position
    # QString boundary positions refer to UTF-16 code units. Indexing a Python
    # str with this value would split/overshoot astral emoji sequences.
    return text.encode('utf-16-le')[:end_utf16 * 2].decode('utf-16-le')


def bounded_name_with_suffix(name: str, suffix: str, maxclusters: int = 200) -> str:
    """Reserve complete suffix clusters and cut only at Qt grapheme boundaries.

    This is a text-limit helper, not filesystem sanitization or a byte-budget
    helper. Media's existing safe_stem remains responsible for such rules.
    Unicode spelling is preserved; there is no normalization or case change.
    """
    _require_text(name)
    _require_text(suffix)
    if type(maxclusters) is not int or maxclusters < 0:
        raise ValueError('Maximum clusters must be a nonnegative integer')
    suffix_count = grapheme_count(suffix, stop_after=maxclusters)
    if suffix_count > maxclusters:
        raise ValueError('접미사를 보존할 수 있는 grapheme 길이 한도가 부족합니다.')
    if grapheme_count(name + suffix, stop_after=maxclusters) <= maxclusters:
        return name + suffix
    result = _prefix_clusters(name, maxclusters - suffix_count) + suffix
    if grapheme_count(result, stop_after=maxclusters) > maxclusters:
        raise ValueError('접미사 결합 후 grapheme 길이 한도를 넘습니다.')
    return result
