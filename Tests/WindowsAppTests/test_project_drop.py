"""Owned Qt controller checks; no Explorer or OS input automation."""
import unittest
from copy import deepcopy
from unittest.mock import Mock, patch
from PySide6.QtCore import QMimeData, QUrl
from . import test_ui as ui_checks


class ProjectDropTests(unittest.TestCase):
    setUp = ui_checks.WindowTests.setUp
    tearDown = ui_checks.WindowTests.tearDown
    spin_until = ui_checks.WindowTests.spin_until
    wait_for_operation = ui_checks.WindowTests.wait_for_operation

    def event(self, paths):
        mime = QMimeData()
        mime.setUrls([QUrl.fromLocalFile(str(p)) for p in paths])
        event = Mock()
        event.mimeData.return_value = mime
        return event

    def test_single_project_drop_reopens_saved_edits(self):
        self.workspace.add_cover('rectangle', [[0, 0], [.5, .5]], 'solid', 25, 0)
        expected = deepcopy(self.workspace.page.state)
        project = self.source.parent / '저장.BLURACTION'
        self.workspace.save_project(project)
        self.workspace.load([self.source])
        self.window.dropEvent(self.event([project]))
        self.wait_for_operation()
        self.assertEqual(self.workspace.page.state, expected)
        self.assertEqual(self.window._project_path, project)

    def test_project_drop_cancel_keeps_unsaved_edits(self):
        self.workspace.add_drawing('line', [[0, 0], [1, 1]])
        before = deepcopy(self.workspace.page.state)
        with patch.object(self.window, '_prepare_project') as prepare:
            self.window.dropEvent(self.event([self.source.parent / 'work.bluraction']))
        prepare.assert_not_called()
        self.assertEqual(self.workspace.page.state, before)
        self.assertTrue(self.workspace.dirty)
        self.question.assert_called_once()

    def test_mixed_or_multiple_projects_rejected_before_discard(self):
        self.workspace.add_drawing('line', [[0, 0], [1, 1]])
        before = deepcopy(self.workspace.page.state)
        project = self.source.parent / 'work.bluraction'
        for paths in ([project, self.source], [project, project.with_name('other.bluraction')]):
            with self.subTest(paths=paths), patch.object(self.window, 'show_error') as error:
                event = self.event(paths)
                self.window.dropEvent(event)
                error.assert_called_once()
                event.ignore.assert_called_once()
                self.assertFalse(self.workspace.busy)
                self.assertEqual(self.workspace.page.state, before)
        self.question.assert_not_called()

    def test_busy_project_drop_is_ignored(self):
        self.workspace.busy = True
        try:
            with patch.object(self.window, 'open_project') as open_project:
                event = self.event([self.source.parent / 'work.bluraction'])
                self.window.dropEvent(event)
                event.ignore.assert_called_once()
                open_project.assert_not_called()
        finally:
            self.workspace.busy = False
