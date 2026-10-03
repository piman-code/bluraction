"""Separate mandatory Windows stage; no optional/skipped native test inventory."""
from __future__ import annotations

import argparse
from copy import deepcopy
import json
import os
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from contract import (EDITED_NAME, HASHES, KINDS, ROOT, fixture_bytes, owned,
                      packet, read, require, sha, tree, write_new)


def image_bytes(image):
    from PySide6.QtGui import QImage
    held = image.convertToFormat(QImage.Format.Format_RGBA8888)
    view = held.constBits()
    return b''.join(bytes(view[y * held.bytesPerLine():y * held.bytesPerLine() + held.width() * 4])
                    for y in range(held.height()))


def check_edits(state):
    require(len(state['regions']) == 3 and len(state['drawings']) == 6, 'Rich edit inventory was lost')
    require([next(iter(r['shape'])) for r in state['regions']] == ['rectangle', 'ellipse', 'polygon'], 'Region ordering changed')
    require([d['kind'] for d in state['drawings']] == ['rectangle', 'ellipse', 'line', 'freehand', 'arrow', 'text'], 'Drawing ordering changed')
    for item in [r['effect'] for r in state['regions']] + state['drawings']:
        require([k['time'] for k in item['keyframes']] == [2, 1, 1], 'Motion ordering or duplicate keyframes changed')
        require(item['erasures'][0].get('from') is None and item['erasures'][1]['from'] == .625, 'Temporal erasures changed')
        require(item['groupID'] == '00000000-0000-0000-0000-000000000777', 'Grouping changed')
    require(state['regions'][2]['effect']['timeRange'] == [4, 6] and
            state['drawings'][5]['timeRange'] == [4, 6], 'Ordinary project load clipped original periods')
    for region in state['regions']:
        require('color' in region['effect'] and region['effect']['color'] is None, 'Explicit default-color null was lost')
    require(all(key in state['drawings'][0] and state['drawings'][0][key] is None
                for key in ('fontName', 'textBackground')), 'Explicit drawing nulls were lost')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--input', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    require(sys.platform == 'win32', 'This required stage needs a real Windows host')
    require(os.environ.get('BLURACTION_V3_ROUNDTRIP_OWNED_CHILD') == '1', 'Use the bounded owned stage driver')
    source, output = owned(args.input), owned(args.output, empty=True)
    incoming = packet(source, 'mac-emit')
    fixtures = fixture_bytes()
    before = {p.name: sha(read(p)) for p in source.iterdir()}
    # Native imports only after host, ownership, complete packet and source whitelist checks.
    sys.path.insert(0, str(ROOT))
    from PySide6.QtWidgets import QApplication
    from platforms.windows.bluraction.editor import Workspace
    from platforms.windows.bluraction import __version__, renderer
    from shared.portable_project import load_project
    app = QApplication.instance() or QApplication([])

    class RequiredWindowsRoundTrip(unittest.TestCase):
        def test_actual_load_edit_undo_redo_save(self):
            rows, observations = [], []
            for kind, digest, row in zip(KINDS, HASHES, incoming['cases']):
                original = read(source / (kind + '.mac.bluraction'), 20 * 1024 * 1024)
                mac = load_project(original).to_dict()
                self.assertEqual(mac['mediaPath'], kind + '.mov')
                self.assertEqual((mac['version'], mac['mediaKind'], mac['sourceSHA256']), (3, 'video', digest))
                self.assertEqual(mac['producer']['platform'], 'macos')
                state = {key: deepcopy(mac[key]) for key in ('regions', 'drawings')}
                check_edits(state)
                media = output / (kind + '.mov')
                self.assertEqual(read(source / media.name), fixtures[kind])
                write_new(media, fixtures[kind])
                write_new(output / (kind + '.mac.bluraction'), original)
                workspace = Workspace()
                try:
                    workspace.load_project(source / (kind + '.mac.bluraction'), relinks={mac['mediaPath']: media})
                    self.assertEqual(workspace.page.state, state)
                    binding = workspace.video.verified_asset_binding()
                    self.assertEqual(binding.timeline, mac['timeline'], 'Actual independently inspected descriptor must match Mac source binding')
                    self.assertEqual(binding.source_sha256, digest)
                    frame = workspace.video.frame_at_timed(workspace.video.first_frame_time)
                    self.assertEqual(frame.presence, 'content')
                    self.assertFalse(frame.image.isNull())
                    original_pixels = image_bytes(frame.image)
                    flattened = renderer.render(frame.image, workspace.page.state, time=float(frame.time))
                    rendered_pixels = image_bytes(flattened)
                    self.assertNotEqual(rendered_pixels, original_pixels, 'Visible effects/drawings must actually reach the renderer')
                    self.assertEqual(image_bytes(frame.image), original_pixels, 'Rendering must preserve source pixels')
                    observations.append({'kind': kind, 'actualFrameTime': {'value': str(frame.time.numerator), 'timescale': frame.time.denominator},
                                         'presence': frame.presence, 'width': frame.image.width(), 'height': frame.image.height(),
                                         'originalPixelSHA256': sha(original_pixels), 'renderedPixelSHA256': sha(rendered_pixels)})
                    workspace.selectionID = state['drawings'][0]['id']
                    workspace.update_selected(name=EDITED_NAME)
                    expected = deepcopy(state); expected['drawings'][0]['name'] = EDITED_NAME
                    self.assertEqual(workspace.page.state, expected)
                    self.assertTrue(workspace.can_undo)
                    workspace.undo(); self.assertEqual(workspace.page.state, state)
                    workspace.redo(); self.assertEqual(workspace.page.state, expected)
                    destination = output / (kind + '.windows.bluraction')
                    workspace.save_project(destination)
                    saved_bytes = read(destination, 20 * 1024 * 1024)
                    saved = load_project(saved_bytes).to_dict()
                    self.assertEqual(saved['producer'], {'name': 'BlurAction', 'platform': 'windows', 'version': __version__})
                    self.assertEqual(saved['timeline'], mac['timeline'])
                    self.assertEqual(saved['sourceSHA256'], digest)
                    self.assertEqual(saved['mediaPath'], media.name)
                    self.assertEqual({key: saved[key] for key in state}, expected)
                    check_edits(saved)
                    self.assertEqual(read(media), fixtures[kind])
                    rows.append(dict(kind=kind, sourceSHA256=digest, macProjectSHA256=row['macProjectSHA256'], windowsProjectSHA256=sha(saved_bytes)))
                finally:
                    session = getattr(workspace.video, 'asset_session', None)
                    if session is not None:
                        folder = Path(session._directory.name) if session._directory else None
                        session.close()
                        self.assertIsNone(session._process)
                        if folder is not None: self.assertFalse(folder.exists())
            self.assertEqual({p.name: sha(read(p)) for p in source.iterdir()}, before)
            self.assertEqual(fixture_bytes(), fixtures)
            write_new(output / 'observations.json', json.dumps({'host': 'windows', 'scope': 'actual v3 owned decode/render/save; no display-device/export parity claim', 'cases': observations}, ensure_ascii=False, sort_keys=True).encode('utf-8'))
            write_new(output / 'packet.json', json.dumps(dict(schemaVersion=1, stage='windows-edit', host='windows', status='completed', cases=rows), ensure_ascii=False, sort_keys=True).encode('utf-8'))
            packet(output, 'windows-edit')

    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(RequiredWindowsRoundTrip))
    require(result.testsRun == 1 and not result.skipped and result.wasSuccessful(), 'Required native Windows stage failed or did not complete')
    # Retain app until all native render/session teardown is complete.
    del app


if __name__ == '__main__':
    main()
