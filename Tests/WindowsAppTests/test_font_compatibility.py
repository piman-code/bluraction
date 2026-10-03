"""글꼴 선택·저장·실제 Qt 렌더링 계약. Mac/offscreen 검사는 Windows 실행 증거가 아니다.

원본은 이 검사에서 작성한 PNG뿐이다. 자체 Qt 객체의 함수·신호만 사용하며
제품의 새 helper를 import하지 않는다. 실행과 native 환경 관찰은 Root가 담당한다.
"""
import os
os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')

from copy import deepcopy
import hashlib
import json
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch
import uuid

from PySide6.QtCore import QPointF, Qt
from PySide6.QtGui import QColor, QFont, QFontDatabase, QFontInfo, QFontMetricsF, QImage, QPainter, QPen
from PySide6.QtWidgets import QApplication, QMessageBox

from platforms.windows.bluraction.editor import Workspace
from platforms.windows.bluraction.media import export_image
from platforms.windows.bluraction import renderer
from platforms.windows.bluraction.ui import BlurActionWindow, font_available


APP = QApplication.instance() or QApplication([])
if not isinstance(APP, QApplication):
    raise RuntimeError('이 검사는 실제 QApplication을 사용하는 별도 프로세스로 실행해야 합니다.')

ALIASES = ('System', 'Sans Serif', 'sans-serif', 'Monospace', 'Serif', 'Cursive', 'Fantasy')
MISSING = object()


def rgba(image):
    """padding을 제외한 모든 RGBA byte를 보존한다."""
    image = image.convertToFormat(QImage.Format.Format_RGBA8888)
    raw = bytes(image.constBits())
    stride = image.bytesPerLine()
    return b''.join(raw[row * stride:row * stride + image.width() * 4] for row in range(image.height()))


def native_reference_font(alias, bold):
    """기대 font는 제품 resolver가 아닌 Qt의 native API와 실제 font DB에서 취득한다."""
    key = (alias or 'Sans Serif').lower()
    if key == 'system':
        font = QFontDatabase.systemFont(QFontDatabase.SystemFont.GeneralFont)
    elif key == 'monospace':
        font = QFontDatabase.systemFont(QFontDatabase.SystemFont.FixedFont)
        if not QFontInfo(font).fixedPitch():
            candidates = [QFont(family) for family in sorted(QFontDatabase.families(), key=str.casefold)
                          if QFontDatabase.isFixedPitch(family) and QFontInfo(QFont(family)).fixedPitch()]
            if not candidates:
                raise AssertionError('실제 고정폭 native family가 없습니다. 요청 flag만으로 통과할 수 없습니다.')
            font = candidates[0]
    else:
        font = QFont(alias or 'Sans Serif')
        font.setStyleHint({'sans serif': QFont.StyleHint.SansSerif, 'sans-serif': QFont.StyleHint.SansSerif,
                           'serif': QFont.StyleHint.Serif, 'cursive': QFont.StyleHint.Cursive,
                           'fantasy': QFont.StyleHint.Fantasy}[key])
    font.setBold(bold)
    font.setPixelSize(100)
    return font


def native_reference_raster(font):
    """독립 작성한 160×100 투명 원본에 black 글자와 고정 상자를 직접 그린다.

    제품 annotation/render/font 함수를 호출하지 않는다. 검은 투명 glyph는
    linear-light 합성 구현을 복제하지 않고 glyph·alpha·색·위치의 전체 RGBA를 비교한다.
    """
    image = QImage(160, 100, QImage.Format.Format_RGBA8888_Premultiplied)
    image.fill(Qt.GlobalColor.transparent)
    painter = QPainter(image)
    try:
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        painter.setPen(QPen(QColor(0, 0, 0, 255), .006 * (160 * 100) ** .5,
                            Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap, Qt.PenJoinStyle.RoundJoin))
        painter.setFont(font)
        metrics = QFontMetricsF(font)
        advance = metrics.horizontalAdvance('Wi 17')
        if not advance > 0:
            raise AssertionError('독립 native glyph advance가 양수가 아닙니다.')
        # normalized corners (.1,.2),(.9,.8): pixel box (16,20), width128, height60.
        sy = 48 / 100
        baseline = 80 - metrics.descent() * sy - (60 - 48 * 1.2) / 2
        painter.translate(16, baseline)
        painter.scale(128 / advance, sy)
        painter.drawText(QPointF(0, 0), 'Wi 17')
    finally:
        painter.end()
    return image


class FontCompatibilityTests(unittest.TestCase):
    """23개 focused 검사. subTest 행렬도 raw 로그에 조건을 남긴다."""

    def setUp(self):
        for method, response in [('warning', QMessageBox.StandardButton.Ok),
                                 ('question', QMessageBox.StandardButton.No),
                                 ('information', QMessageBox.StandardButton.Ok)]:
            guard = patch('platforms.windows.bluraction.ui.QMessageBox.' + method, return_value=response)
            guard.start()
            self.addCleanup(guard.stop)
        self.temp = tempfile.TemporaryDirectory(prefix='bluraction-font-contract-')
        self.directory = Path(self.temp.name)
        self.source = self.directory / '직접 작성한 원본.png'
        image = QImage(160, 100, QImage.Format.Format_RGBA8888)
        image.fill(QColor('white'))
        self.assertTrue(image.save(str(self.source)))
        self.original = self.source.read_bytes()
        self.source_sha = hashlib.sha256(self.original).hexdigest()
        self.workspace = Workspace()
        self.workspace.load([self.source])
        self.window = BlurActionWindow(self.workspace)
        self.wait_preview()

    def tearDown(self):
        self.assertFalse(self.workspace.busy, '완료되지 않은 작업을 감춘 채 원본을 삭제하지 않습니다.')
        self.workspace.dirty = False
        self.window.close()
        self.wait_queue()
        self.assertEqual(self.source.read_bytes(), self.original)
        self.assertEqual(hashlib.sha256(self.source.read_bytes()).hexdigest(), self.source_sha)
        self.temp.cleanup()

    def wait_queue(self):
        deadline = time.monotonic() + 5
        while self.window.canvas.preview_queue.busy and time.monotonic() < deadline:
            APP.processEvents()
            time.sleep(.005)
        self.assertFalse(self.window.canvas.preview_queue.busy, '합성 preview worker가 종료되지 않았습니다.')

    def wait_preview(self):
        self.wait_queue()
        APP.processEvents()
        self.assertFalse(self.window.canvas.preview_pending, '글꼴 preview가 실패하거나 미완료 상태입니다.')
        self.assertIsNotNone(self.window.canvas._preview)

    def named_family(self):
        default = QApplication.font().family()
        names = [name for name in QFontDatabase.families()
                 if name != default and name.lower() not in {name.lower() for name in ALIASES}]
        self.assertTrue(names, '기본값·별칭 밖의 실제 설치 named family가 필요합니다.')
        return sorted(names)[0]

    def raw_cases(self):
        return [('필드 없음', MISSING), ('명시 null', None), ('빈 문자열', ''),
                ('설치 named', self.named_family()), ('혼합 대소문자 별칭', 'sErIf')]

    def reset_text(self, name=MISSING, bold=False):
        self.wait_queue()
        self.workspace.load([self.source])
        identity = self.workspace.add_drawing('text', [[.1, .2], [.9, .8]],
            color={'red': 0, 'green': 0, 'blue': 0, 'alpha': 1}, text='Wi 17', font=None, bold=True)
        item = self.workspace.selected()[0]
        if name is MISSING:
            item.pop('fontName', None)
        else:
            item['fontName'] = name
        if bold is MISSING:
            item.pop('bold', None)
        else:
            item['bold'] = bold
        self.window.refresh()
        self.wait_preview()
        return identity

    def item(self, identity):
        return next(item for item in self.workspace.page.state['drawings'] if item['id'] == identity)

    def field(self, item, key):
        return key in item, deepcopy(item.get(key))

    def activate_font(self, name):
        index = self.window.font.findText(name)
        self.assertGreaterEqual(index, 0, '현재 목록에서 실제 선택할 수 있어야 합니다: ' + name)
        self.window.font.setCurrentIndex(index)
        # 같은 index를 재선택해도 사용자의 명시 선택은 activated로 전달된다.
        self.window.font.activated.emit(index)
        self.assertEqual(self.window.font.currentText(), name)

    def snapshot(self):
        return (deepcopy(self.workspace.page.state), deepcopy(self.workspace._undo),
                deepcopy(self.workspace._redo), self.workspace.dirty)

    def save_and_reopen(self, identity):
        project = self.directory / (str(uuid.uuid4()) + '.bluraction')
        self.workspace.save_project(project)
        tree = json.loads(project.read_text(encoding='utf-8'))
        entry = tree['pages'][0]
        self.assertEqual(entry['sourceSHA256'], self.source_sha)
        stored = next(item for item in entry['drawings'] if item['id'] == identity)
        reopened = Workspace()
        reopened.load_project(project)
        reopened_item = next(item for item in reopened.page.state['drawings'] if item['id'] == identity)
        self.assertEqual(reopened_item, stored)
        self.assertEqual(self.source.read_bytes(), self.original)
        return stored

    def undo_redo(self, identity, before, after):
        self.workspace.undo()
        self.assertEqual(self.item(identity), before)
        self.workspace.selectionID = identity
        self.window.refresh()
        self.wait_preview()
        self.workspace.redo()
        self.assertEqual(self.item(identity), after)
        self.workspace.selectionID = identity
        self.window.refresh()
        self.wait_preview()

    def test_01_named_default_and_seven_explicit_picker_choices(self):
        self.assertEqual(self.window.font.currentText(), QApplication.font().family())
        for alias in ALIASES:
            with self.subTest(alias=alias):
                self.activate_font(alias)
        self.assertEqual(self.workspace.page.state['drawings'], [])

    def test_02_seven_aliases_create_save_and_reopen_without_canonical_rewrite(self):
        for alias in ALIASES:
            with self.subTest(alias=alias):
                self.workspace.load([self.source]); self.window.refresh(); self.wait_preview()
                self.activate_font(alias)
                self.window.text.setPlainText('Wi 17')
                self.window.create_item('text', [[.1, .2], [.9, .8]])
                self.wait_preview()
                item = self.workspace.selected()[0]
                self.assertEqual(item['fontName'], alias)
                self.assertEqual(self.save_and_reopen(item['id'])['fontName'], alias)

    def test_03_text_only_apply_preserves_raw_font_presence_and_value(self):
        for label, name in self.raw_cases():
            with self.subTest(raw=label):
                identity = self.reset_text(name)
                before = deepcopy(self.item(identity))
                self.window.text.setPlainText('바뀐 글자')
                self.window.text_apply.click(); self.wait_preview()
                after = deepcopy(self.item(identity))
                self.assertEqual(after['text'], '바뀐 글자')
                self.assertEqual(self.field(after, 'fontName'), self.field(before, 'fontName'))
                self.assertEqual(self.field(self.save_and_reopen(identity), 'fontName'), self.field(before, 'fontName'))
                self.undo_redo(identity, before, after)

    def test_04_bold_only_apply_preserves_raw_font_presence_and_value(self):
        for label, name in self.raw_cases():
            with self.subTest(raw=label):
                identity = self.reset_text(name, bold=False)
                before = deepcopy(self.item(identity))
                self.window.bold.setChecked(True)
                self.window.text_apply.click(); self.wait_preview()
                after = deepcopy(self.item(identity))
                self.assertIs(after['bold'], True)
                self.assertEqual(after['text'], before['text'])
                self.assertEqual(self.field(after, 'fontName'), self.field(before, 'fontName'))
                self.undo_redo(identity, before, after)

    def test_05_explicit_other_font_apply_and_undo_preserve_prior_raw_state(self):
        for label, name in self.raw_cases():
            with self.subTest(raw=label):
                identity = self.reset_text(name)
                before = deepcopy(self.item(identity))
                self.activate_font('Monospace')
                self.assertEqual(self.item(identity), before, '미적용 선택은 모델 편집이 아닙니다.')
                self.window.text_apply.click(); self.wait_preview()
                after = deepcopy(self.item(identity))
                self.assertEqual(after['fontName'], 'Monospace')
                self.assertEqual(self.save_and_reopen(identity)['fontName'], 'Monospace')
                self.undo_redo(identity, before, after)

    def test_06_same_display_named_default_activation_explicitly_replaces_null(self):
        identity = self.reset_text(None)
        before = deepcopy(self.item(identity))
        default = QApplication.font().family()
        self.assertEqual(self.window.font.currentText(), default)
        self.activate_font(default)
        self.assertEqual(self.item(identity), before)
        self.window.text_apply.click(); self.wait_preview()
        after = deepcopy(self.item(identity))
        self.assertEqual(after['fontName'], default)
        self.undo_redo(identity, before, after)

    def test_07_unrelated_refresh_preserves_unapplied_text_font_and_bold(self):
        identity = self.reset_text(self.named_family(), bold=False)
        before = deepcopy(self.item(identity))
        self.window.text.setPlainText('아직 적용하지 않은 줄\n둘째 줄')
        self.activate_font('Serif')
        self.window.bold.setChecked(True)
        self.window.refresh(); self.wait_preview()
        self.assertEqual(self.window.text.toPlainText(), '아직 적용하지 않은 줄\n둘째 줄')
        self.assertEqual(self.window.font.currentText(), 'Serif')
        self.assertTrue(self.window.bold.isChecked())
        self.assertEqual(self.item(identity), before)

    def test_08_unchanged_apply_has_no_history_or_raw_field_mutation(self):
        for label, name in self.raw_cases():
            with self.subTest(raw=label):
                self.reset_text(name, bold=True)
                before = self.snapshot()
                self.window.text_apply.click(); self.wait_preview()
                self.assertEqual(self.snapshot(), before, 'no-op Apply는 undo를 추가하거나 null을 named로 바꾸면 안 됩니다.')

    def test_09_locked_text_apply_cannot_mutate_or_checkpoint(self):
        identity = self.reset_text(self.named_family())
        self.workspace.update_selected(locked=True)
        self.window.refresh(); self.wait_preview()
        before = self.snapshot()
        self.window.text.setPlainText('잠긴 글자 변경 시도')
        self.window.bold.setChecked(True)
        self.window.text_apply.click(); self.wait_preview()
        self.assertEqual(self.snapshot(), before)
        self.assertTrue(self.item(identity)['locked'])

    def test_10_busy_text_apply_is_disabled_and_preserves_history(self):
        self.reset_text(self.named_family())
        before = self.snapshot()
        self.workspace.busy = True
        try:
            self.window.refresh(); self.wait_queue()
            self.assertFalse(self.window.text_apply.isEnabled())
            self.window.text.setPlainText('작업 중 변경 시도')
            self.window.text_apply.click()
            self.assertEqual(self.snapshot(), before)
        finally:
            self.workspace.busy = False
            self.window.refresh(); self.wait_preview()

    def test_11_mixed_selection_changes_only_unlocked_text_and_keeps_unrelated_fields(self):
        identity = self.reset_text(self.named_family())
        main = self.item(identity)
        main['textBackground'] = {'red': .13, 'green': .27, 'blue': .41, 'alpha': .63}
        locked = self.workspace.add_drawing('text', [[.2, .1], [.8, .7]], text='잠긴 글자', font='System')
        self.item(locked)['locked'] = True
        line = self.workspace.add_drawing('line', [[.1, .1], [.9, .9]], font=self.named_family())
        cover = self.workspace.add_cover('rectangle', [[.1, .1], [.2, .2]])
        self.workspace.selectionID = identity
        self.window.refresh(); self.wait_preview()
        self.workspace.selection_ids = {identity, locked, line, cover}
        self.window.refresh(); self.wait_preview()
        before = deepcopy(self.workspace.page.state)
        self.window.text.setPlainText('선택한 글자만 수정')
        self.window.text_apply.click(); self.wait_preview()
        expected = deepcopy(before)
        target = next(item for item in expected['drawings'] if item['id'] == identity)
        target['text'] = '선택한 글자만 수정'
        self.assertEqual(self.workspace.page.state, expected)
        self.workspace.undo(); self.assertEqual(self.workspace.page.state, before)
        self.workspace.redo(); self.assertEqual(self.workspace.page.state, expected)

    def test_12_ascii_alias_and_unicode_near_names_have_distinct_interpretation(self):
        for name, hint in [('sErIf', QFont.StyleHint.Serif), ('CURSIVE', QFont.StyleHint.Cursive),
                           ('FANTASY', QFont.StyleHint.Fantasy), ('sans-SERIF', QFont.StyleHint.SansSerif)]:
            with self.subTest(alias=name):
                self.assertEqual(renderer.text_font(name).styleHint(), hint)
        for name in ['ſerif', 'ſystem', 'monoſpace', ' System ', 'Monospace-extra']:
            with self.subTest(named=name):
                expected = QFont(name)
                actual = renderer.text_font(name)
                # 공백 등의 정규화는 Qt 자체 named-font 계약과 비교한다.
                # 사용자 원문 보존은 아래 실제 프로젝트 JSON에서 따로 검증한다.
                self.assertEqual(actual.family(), expected.family())
                self.assertEqual(actual.styleHint(), expected.styleHint())
                # long-s는 실제 generic 이름의 DB entry와 충돌한다. 공백·접미는
                # 조작한 가짜 named cache 대신 실제 설치 DB를 사용한다.
                cache = ({name.casefold()} if 'ſ' in name else
                         {family.casefold() for family in QFontDatabase.families()})
                self.assertEqual(font_available(name, cache), QFontInfo(expected).exactMatch(),
                                 'named cache에서 casefold만으로 가용성을 보증하면 안 됩니다.')
                if 'ſ' not in name:
                    self.assertEqual(font_available(name), QFontInfo(expected).exactMatch())
                identity = self.reset_text(name)
                self.assertEqual(self.save_and_reopen(identity)['fontName'], name)

    def test_13_generic_named_cache_cannot_bypass_actual_fixed_pitch_check(self):
        family = next((name for name in QFontDatabase.families() if not QFontInfo(QFont(name)).fixedPitch()), None)
        self.assertIsNotNone(family, '고정폭이 아닌 실제 native 대조군이 필요합니다.')
        proportional = QFont(family)
        self.assertFalse(QFontInfo(proportional).fixedPitch())
        with patch('platforms.windows.bluraction.ui.renderer.text_font', return_value=proportional):
            self.assertFalse(font_available('Monospace', {'monospace'}),
                             'generic 이름이 named cache에 있어도 실제 proportional 얼굴을 허용하면 안 됩니다.')
        fixed = renderer.text_font('Monospace')
        self.assertTrue(QFontInfo(fixed).fixedPitch())
        metrics = QFontMetricsF(fixed)
        narrow, wide = metrics.horizontalAdvance('iiii'), metrics.horizontalAdvance('WWWW')
        self.assertGreater(narrow, 0); self.assertGreater(wide, 0)
        self.assertAlmostEqual(narrow, wide, places=4)

    def test_14_seven_aliases_and_weights_match_independent_complete_native_rgba(self):
        transparent = QImage(160, 100, QImage.Format.Format_RGBA8888)
        transparent.fill(QColor(0, 0, 0, 0))
        for alias in ALIASES:
            for bold in (False, True):
                with self.subTest(alias=alias, bold=bold):
                    identity = self.reset_text(alias, bold=bold)
                    item = deepcopy(self.item(identity))
                    expected_font = native_reference_font(alias, bold)
                    expected = native_reference_raster(expected_font)
                    actual = renderer.render(transparent, {'regions': [], 'drawings': [item]})
                    actual_bytes, expected_bytes = rgba(actual), rgba(expected)
                    self.assertEqual(len(actual_bytes), 160 * 100 * 4)
                    self.assertTrue(actual_bytes == expected_bytes,
                        f'독립 전체 RGBA 불일치: {alias}/{bold}, 실제 {hashlib.sha256(actual_bytes).hexdigest()}, '
                        f'기대 {hashlib.sha256(expected_bytes).hexdigest()}')
                    self.assertNotEqual(actual_bytes, rgba(transparent), '빈 raster의 일치로 통과하지 않습니다.')

    def test_15_preview_png_export_and_reopened_project_keep_complete_rgba_and_source(self):
        for alias in ALIASES:
            with self.subTest(alias=alias):
                identity = self.reset_text(alias, bold=True)
                preview = rgba(self.window.canvas._preview)
                self.assertNotEqual(preview, rgba(self.workspace.page.image), '실제 글자 출력이 비어 있습니다.')
                output = self.directory / (str(uuid.uuid4()) + '.png')
                export_image(self.workspace.page, output)
                self.assertEqual(rgba(QImage(str(output))), preview)
                output_sha = hashlib.sha256(output.read_bytes()).hexdigest()
                with self.assertRaises((ValueError, FileExistsError)):
                    export_image(self.workspace.page, output)
                self.assertEqual(hashlib.sha256(output.read_bytes()).hexdigest(), output_sha)
                stored = self.save_and_reopen(identity)
                reopened = renderer.render(self.workspace.page.image, {'regions': [], 'drawings': [stored]})
                self.assertEqual(rgba(reopened), preview)
                self.assertEqual(self.source.read_bytes(), self.original)

    def test_16_nullable_bold_uses_legacy_true_rendering_and_preserves_raw_value(self):
        transparent = QImage(160, 100, QImage.Format.Format_RGBA8888)
        transparent.fill(QColor(0, 0, 0, 0))
        expected = rgba(native_reference_raster(native_reference_font('System', True)))
        for label, value in [('필드 없음', MISSING), ('명시 null', None), ('명시 true', True)]:
            with self.subTest(bold=label):
                identity = self.reset_text('System', bold=value)
                before = deepcopy(self.item(identity))
                self.assertTrue(self.window.bold.isChecked(), '이전 Mac 프로젝트 absent/null bold는 true입니다.')
                actual = rgba(renderer.render(transparent, {'regions': [], 'drawings': [before]}))
                self.assertTrue(actual == expected,
                    f'nullable bold native 전체 RGBA: 실제 {hashlib.sha256(actual).hexdigest()}, 기대 {hashlib.sha256(expected).hexdigest()}')
                self.assertNotEqual(actual, rgba(transparent))
                self.window.text.setPlainText('글자만 명시 수정')
                self.window.text_apply.click(); self.wait_preview()
                after = deepcopy(self.item(identity))
                self.assertEqual(self.field(after, 'bold'), self.field(before, 'bold'))
                self.assertEqual(self.field(self.save_and_reopen(identity), 'bold'), self.field(before, 'bold'))
                self.undo_redo(identity, before, after)

    def test_17_selection_growth_and_shrink_reset_previous_context_draft(self):
        identity = self.reset_text(self.named_family(), bold=False)
        other = self.workspace.add_drawing('text', [[.2, .1], [.8, .7]],
                                            text='둘째 글자', font='System', bold=True)
        self.workspace.selectionID = identity
        self.window.refresh(); self.wait_preview()
        before = self.snapshot()
        self.window.text.setPlainText('이전 단일 선택의 초안')
        self.activate_font('Fantasy')
        self.window.bold.setChecked(True)
        self.workspace.selection_ids = {identity, other}
        self.window.refresh(); self.wait_preview()
        representative = self.workspace.selected()[0]
        self.assertEqual(self.window.text.toPlainText(), representative['text'])
        self.assertEqual(self.window.font.currentText(), representative['fontName'])
        self.assertEqual(self.window.bold.isChecked(), representative['bold'])
        self.assertEqual(self.snapshot(), before)
        self.window.text.setPlainText('이전 다중 선택의 초안')
        self.activate_font('Cursive')
        self.window.bold.setChecked(True)
        self.workspace.selection_ids = {identity}
        self.window.refresh(); self.wait_preview()
        self.assertEqual(self.window.text.toPlainText(), self.item(identity)['text'])
        self.assertEqual(self.window.font.currentText(), self.item(identity)['fontName'])
        self.assertFalse(self.window.bold.isChecked())
        self.assertEqual(self.snapshot(), before)
        self.window.text_apply.click(); self.wait_preview()
        self.assertEqual(self.snapshot(), before, '이전 집합의 draft는 no-op 적용으로 전달되면 안 됩니다.')

    def test_18_new_page_identity_resets_draft_even_when_ids_and_raw_values_match(self):
        identity = self.reset_text(self.named_family(), bold=False)
        original_page = self.workspace.page
        state = deepcopy(original_page.state)
        self.window.text.setPlainText('이전 페이지의 미적용 초안')
        self.activate_font('Serif')
        self.window.bold.setChecked(True)
        self.workspace.load([self.source])
        self.assertIsNot(self.workspace.page, original_page)
        self.workspace.page.state = state
        self.workspace.selectionID = identity
        before = self.snapshot()
        self.window.refresh(); self.wait_preview()
        self.assertEqual(self.window.text.toPlainText(), self.item(identity)['text'])
        self.assertEqual(self.window.font.currentText(), self.item(identity)['fontName'])
        self.assertFalse(self.window.bold.isChecked())
        self.window.text_apply.click(); self.wait_preview()
        self.assertEqual(self.snapshot(), before)

    def test_19_nullable_text_is_preserved_when_only_font_or_bold_is_applied(self):
        for label, value in [('필드 없음', MISSING), ('명시 null', None), ('빈 문자열', '')]:
            for changed in ('font', 'bold'):
                with self.subTest(text=label, changed=changed):
                    identity = self.reset_text('System', bold=False)
                    item = self.item(identity)
                    if value is MISSING:
                        item.pop('text', None)
                    else:
                        item['text'] = value
                    self.window.refresh(); self.wait_preview()
                    self.assertEqual(self.window.text.toPlainText(), '')
                    before = deepcopy(item)
                    if changed == 'font':
                        self.activate_font('Serif')
                    else:
                        self.window.bold.setChecked(True)
                    self.window.text_apply.click(); self.wait_preview()
                    after = deepcopy(self.item(identity))
                    self.assertEqual(self.field(after, 'text'), self.field(before, 'text'))
                    expected = deepcopy(before)
                    expected['fontName' if changed == 'font' else 'bold'] = 'Serif' if changed == 'font' else True
                    self.assertEqual(after, expected)
                    self.assertEqual(self.field(self.save_and_reopen(identity), 'text'), self.field(before, 'text'))
                    self.undo_redo(identity, before, after)

    def test_20_same_named_font_activation_does_not_add_undo(self):
        default = QApplication.font().family()
        self.reset_text(default, bold=True)
        before = self.snapshot()
        self.activate_font(default)
        self.window.text_apply.click(); self.wait_preview()
        self.assertEqual(self.snapshot(), before, '이미 같은 named 값의 명시 선택은 no-op입니다.')

    def test_21_changed_then_returned_display_is_still_explicit_raw_edit(self):
        identity = self.reset_text('System', bold=None)
        item = self.item(identity)
        item.pop('text', None)
        self.window.refresh(); self.wait_preview()
        before = deepcopy(item)
        self.window.text.setPlainText('입력 후 지울 글자')
        self.window.text.setPlainText('')
        self.window.bold.setChecked(False)
        self.window.bold.setChecked(True)
        self.window.text_apply.click(); self.wait_preview()
        after = deepcopy(self.item(identity))
        expected = deepcopy(before)
        expected['text'] = ''
        expected['bold'] = True
        self.assertEqual(after, expected, 'display가 처음과 같아도 실제 편집한 raw 필드만 명시 값으로 변경합니다.')
        self.undo_redo(identity, before, after)

    def test_22_other_selected_text_raw_changes_reset_draft_without_apply_or_undo(self):
        for changed in ('text', 'fontName', 'bold', 'locked'):
            with self.subTest(other_field=changed):
                identity = self.reset_text(self.named_family(), bold=False)
                other = self.workspace.add_drawing('text', [[.2, .1], [.8, .7]],
                                                    text='둘째 글자', font='System', bold=True)
                self.workspace.selection_ids = {identity, other}
                self.window.refresh(); self.wait_preview()
                representative = self.workspace.selected()[0]
                target_id = ({identity, other} - {representative['id']}).pop()
                self.window.text.setPlainText('이전 다중 선택의 미적용 초안')
                self.activate_font('Cursive')
                self.window.bold.setChecked(not representative['bold'])
                target = self.item(target_id)
                target[changed] = {'text': '다른 항목의 새 원문', 'fontName': 'Fantasy',
                                   'bold': not target['bold'], 'locked': True}[changed]
                before = self.snapshot()
                self.window.refresh(); self.wait_preview()
                self.assertEqual(self.window.text.toPlainText(), representative['text'])
                self.assertEqual(self.window.font.currentText(), representative['fontName'])
                self.assertEqual(self.window.bold.isChecked(), representative['bold'])
                self.assertEqual(self.snapshot(), before)
                self.window.text_apply.click(); self.wait_preview()
                self.assertEqual(self.snapshot(), before, '다른 선택 항목의 변경 뒤 이전 draft는 적용·undo로 넘어가면 안 됩니다.')

    def test_23_stale_selection_context_apply_is_rejected_without_history(self):
        for expanded in (False, True):
            with self.subTest(expanded=expanded):
                identity = self.reset_text(self.named_family(), bold=False)
                other = self.workspace.add_drawing('text', [[.2, .1], [.8, .7]],
                                                    text='둘째 글자', font='System', bold=True)
                self.workspace.selectionID = identity
                self.window.refresh(); self.wait_preview()
                self.window.text.setPlainText('이전 선택에만 작성한 초안')
                self.activate_font('Fantasy')
                self.window.bold.setChecked(True)
                before = self.snapshot()
                self.workspace.selection_ids = {identity, other} if expanded else {other}
                # refresh를 의도적으로 하지 않아 이전 inspector token 전송을 재현한다.
                self.window.text_apply.click(); self.wait_preview()
                self.assertEqual(self.snapshot(), before, '선택 집합이 달라진 stale Apply는 모델이나 history를 바꾸면 안 됩니다.')


if __name__ == '__main__':
    unittest.main(verbosity=2)
