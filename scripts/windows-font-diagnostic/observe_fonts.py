"""Unexecuted QA: actual Qt font observations; no windows, fonts installed or OS input."""
from __future__ import annotations
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import sys

parser = argparse.ArgumentParser()
parser.add_argument('--repository', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--platform', choices=('offscreen', 'windows'), required=True)
args = parser.parse_args()
if sys.platform != 'win32':
    raise SystemExit('Actual Windows required; do not substitute host results')
repo = args.repository.resolve()
output = args.output.absolute()
output.relative_to(repo / '.build')
if output.exists() or output.parent.resolve() != output.parent:
    raise SystemExit('New plain owned output required')
paths = [Path(__file__).resolve(), repo / 'platforms/windows/bluraction/renderer.py',
         repo / 'platforms/windows/bluraction/ui.py', repo / 'Tests/WindowsAppTests/test_ui.py']
before = {str(p.relative_to(repo)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
# Only the new child process changes its QPA choice. The application below never
# creates/shows a QWidget, starts an event loop or sends any input event.
os.environ['QT_QPA_PLATFORM'] = args.platform
sys.path.insert(0, str(repo))
row = {'status': 'incomplete', 'actualWindows': True, 'OSInput': False,
       'windowShown': False, 'installedFonts': False, 'requestedPlatform': args.platform,
       'sourceBefore': before, 'fullGoalComplete': False, 'fontDefectClosed': False,
       'families': [], 'systemFonts': [], 'genericRequests': []}
code = 1
app = None

def checkpoint(stage):
    print(json.dumps({'stage': stage, 'platform': args.platform}), file=sys.stderr, flush=True)

try:
    checkpoint('before-qt-import')
    import PySide6
    from PySide6.QtCore import qVersion
    from PySide6.QtGui import QFont, QFontDatabase, QFontInfo, QFontMetricsF, QRawFont
    from PySide6.QtWidgets import QApplication
    checkpoint('before-application')
    app = QApplication(['owned-font-observer'])
    row.update(PySide6Version=PySide6.__version__, QtVersion=qVersion(),
               actualPlatform=app.platformName(),
               customFontDirectoryConfigured=bool(os.environ.get('QT_QPA_FONTDIR')))
    if app.platformName() != args.platform:
        raise ValueError('Requested and actual QPA platform differ')
    from platforms.windows.bluraction.renderer import text_font
    from platforms.windows.bluraction.ui import font_available
    observations = [0]
    samples = ('i', 'W', 'iiii', 'WWWW', '0123456789', '가', '한', '힣', '한글 iW')

    def observe(font):
        observations[0] += 1
        if observations[0] > 8192:
            raise ValueError('Font observation resource bound reached; no truncated PASS')
        info, metrics = QFontInfo(font), QFontMetricsF(font)
        advances = {s: float(metrics.horizontalAdvance(s)) for s in samples}
        if any(not math.isfinite(v) or v < 0 for v in advances.values()):
            raise ValueError('Nonfinite or negative native font advance')
        raw = QRawFont.fromFont(font)
        result = dict(requestedFamily=font.family(), requestedStyle=font.styleName(),
            requestedFixedPitch=font.fixedPitch(), requestedStyleHint=int(font.styleHint().value),
            requestedPointSize=float(font.pointSizeF()), requestedPixelSize=font.pixelSize(),
            resolvedFamily=info.family(), resolvedStyle=info.styleName(),
            resolvedFixedPitch=info.fixedPitch(), exactMatch=info.exactMatch(),
            resolvedPointSize=float(info.pointSizeF()), resolvedPixelSize=info.pixelSize(),
            advances=advances, asciiAdvancesNonzero=advances['iiii'] > 0 and advances['WWWW'] > 0,
            asciiFourAdvanceExactlyEqual=advances['iiii'] == advances['WWWW'],
            inFont={s: bool(metrics.inFontUcs4(ord(s))) for s in ('i', 'W', '가', '한', '힣')},
            rawFontValid=raw.isValid())
        if raw.isValid():
            result.update(rawFamily=raw.familyName(), rawStyle=raw.styleName(),
                rawGlyphIndexes={s: list(raw.glyphIndexesForString(s)) for s in ('i', 'W', '가', '한', '힣')})
        return result

    checkpoint('database-census')
    families = sorted(QFontDatabase.families(), key=str.casefold)
    if len(families) > 4096 or any(len(f) > 256 for f in families):
        raise ValueError('Family census resource bound reached')
    row['familyCount'] = len(families)
    row['applicationFont'] = observe(app.font())
    for name in ('GeneralFont', 'FixedFont', 'TitleFont', 'SmallestReadableFont'):
        kind = getattr(QFontDatabase.SystemFont, name)
        row['systemFonts'].append({'kind': name, 'font': observe(QFontDatabase.systemFont(kind))})
    for name in ('Sans Serif', 'Serif', 'Monospace', 'System', 'BlurAction-Synthetic-Unavailable-Font-51E86A'):
        row['genericRequests'].append({'request': name, 'productAvailable': font_available(name),
                                      'productResolved': observe(text_font(name))})
    for index, family in enumerate(families):
        styles = list(QFontDatabase.styles(family))
        if len(styles) > 64 or any(len(s) > 256 for s in styles):
            raise ValueError('Style census resource bound reached')
        entry = {'family': family, 'databaseFixedPitch': QFontDatabase.isFixedPitch(family),
                 'styles': styles, 'defaultRequest': observe(QFont(family)), 'fixedStyleRequests': []}
        for style in styles:
            if QFontDatabase.isFixedPitch(family, style):
                entry['fixedStyleRequests'].append({'style': style,
                    'font': observe(QFontDatabase.font(family, style, 12))})
        row['families'].append(entry)
        if index % 50 == 0: checkpoint('family-' + str(index))
    row['observationCount'] = observations[0]
    # Observe real candidate outcomes; do not declare the product fixed or
    # manufacture a font by setting fixedPitch=True on a proportional face.
    candidates = []
    for family in row['families']:
        for font in [family['defaultRequest']] + [s['font'] for s in family['fixedStyleRequests']]:
            if (font['resolvedFixedPitch'] and font['asciiAdvancesNonzero'] and
                    font['asciiFourAdvanceExactlyEqual'] and font['inFont']['i'] and font['inFont']['W']):
                candidates.append({'family': family['family'], 'requestedStyle': font['requestedStyle'],
                                   'resolvedFamily': font['resolvedFamily'], 'resolvedStyle': font['resolvedStyle']})
    row['observedFixedCandidates'] = candidates
    row['status'] = 'observations-complete-not-product-pass'
    code = 0
except BaseException as error:
    row.update(errorType=type(error).__name__, error=str(error))
finally:
    after = {str(p.relative_to(repo)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
    row.update(sourceAfter=after, sourcesPreserved=before == after)
    if before != after:
        row['status'] = 'source-changed-incomplete'; code = 1
    with output.open('x', encoding='utf-8') as stream:
        json.dump(row, stream, ensure_ascii=False, sort_keys=True, indent=2, allow_nan=False)
        stream.write('\n')
    checkpoint('observation-report-written')
    if app is not None: app.quit()
raise SystemExit(code)
