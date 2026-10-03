"""Layer lock and no-op history regressions using owned synthetic media."""
import unittest
from copy import deepcopy
from . import test_ui as ui_checks


class LayerOrderLockTests(unittest.TestCase):
    setUp = ui_checks.WindowTests.setUp
    tearDown = ui_checks.WindowTests.tearDown
    spin_until = ui_checks.WindowTests.spin_until

    def populate(self, region=False):
        add = self.workspace.add_cover if region else self.workspace.add_drawing
        for x in (0, .2, .4):
            add('rectangle', [[x, 0], [x + .2, .2]])
        key = 'regions' if region else 'drawings'
        self.workspace.selectionID = self.workspace.item_id(self.workspace.page.state[key][0], region)
        return key

    def snapshot(self):
        return deepcopy((self.workspace.page.state, self.workspace._undo, self.workspace._redo, self.workspace.dirty))

    def test_locked_layers_do_not_reorder_or_create_history(self):
        for region in (False, True):
            with self.subTest(region=region):
                self.workspace.load([self.source])
                self.populate(region)
                self.workspace.update_selected(locked=True)
                self.workspace.dirty = False
                before = self.snapshot()
                self.workspace.reorder_selected(1)
                self.assertEqual(self.snapshot(), before)
                self.window.refresh()
                for name in ('front', 'back', 'to_front', 'to_back'):
                    self.assertFalse(self.window.actions[name].isEnabled())

    def test_unlocked_can_cross_locked_and_undo(self):
        key = self.populate()
        items = self.workspace.page.state[key]
        items[1]['locked'] = True
        original_ids = [i['id'] for i in items]
        self.workspace.reorder_selected(1)
        self.assertEqual([i['id'] for i in self.workspace.page.state[key]], [original_ids[1], original_ids[0], original_ids[2]])
        self.workspace.undo()
        self.assertEqual([i['id'] for i in self.workspace.page.state[key]], original_ids)

    def test_boundary_and_empty_selection_leave_history_unchanged(self):
        self.populate()
        self.workspace.dirty = False
        before = self.snapshot()
        self.workspace.reorder_selected(-1)
        self.assertEqual(self.snapshot(), before)
        self.workspace.selection_ids.clear()
        self.workspace.reorder_selected(1)
        self.assertEqual(self.snapshot(), before)

    def test_selected_block_at_boundary_is_noop(self):
        key = self.populate()
        items = self.workspace.page.state[key]
        self.workspace.selection_ids = {i['id'] for i in items[1:]}
        self.workspace.dirty = False
        before = self.snapshot()
        self.workspace.reorder_selected(1)
        self.assertEqual(self.snapshot(), before)

    def test_front_back_preserve_selected_relative_order(self):
        for offset, chosen, expected in ((3, (0, 1), (2, 0, 1)), (-3, (1, 2), (1, 2, 0))):
            with self.subTest(offset=offset):
                self.workspace.load([self.source])
                key = self.populate()
                ids = [i['id'] for i in self.workspace.page.state[key]]
                self.workspace.selection_ids = {ids[i] for i in chosen}
                self.workspace.reorder_selected(offset)
                self.assertEqual([i['id'] for i in self.workspace.page.state[key]], [ids[i] for i in expected])

    def test_separated_selection_moves_one_step_without_reversing(self):
        key = self.populate()
        for x in (.6, .8):
            self.workspace.add_drawing('rectangle', [[x, 0], [x + .1, .2]])
        ids = [i['id'] for i in self.workspace.page.state[key]]
        self.workspace.selection_ids = {ids[0], ids[2]}
        self.workspace.reorder_selected(1)
        self.assertEqual([i['id'] for i in self.workspace.page.state[key]], [ids[i] for i in (1, 0, 3, 2, 4)])
        self.workspace.undo()
        self.assertEqual([i['id'] for i in self.workspace.page.state[key]], ids)
