"""Exercise the real launcher with injected dispatch/GUI boundaries, not a frozen EXE."""
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest


LAUNCHER = Path(__file__).resolve().parents[2] / 'platforms/windows/launcher.py'
PROBE = r'''
import builtins
import json
import multiprocessing
import runpy
import sys
import types

launcher, scenario = sys.argv[1:3]
sys.argv = ['launcher', '한글 project.bluraction', '--literal-argument']
events = []
def freeze_support():
    events.append(['freeze', sys.argv[1:]])
    if scenario == 'child':
        raise SystemExit(0)
multiprocessing.freeze_support = freeze_support
gui = types.ModuleType('platforms.windows.bluraction.__main__')
def main():
    events.append(['main', sys.argv[1:]])
    return 23
gui.main = main
original_import = builtins.__import__
def observed_import(name, *args, **kwargs):
    if name == 'platforms.windows.bluraction.__main__':
        events.append(['gui-import'])
        return gui
    if name.startswith('PySide6'):
        raise AssertionError('real GUI must not be imported by this probe')
    return original_import(name, *args, **kwargs)
builtins.__import__ = observed_import
code = 0
try:
    runpy.run_path(launcher, run_name='launcher_import_probe' if scenario == 'import' else '__main__')
except SystemExit as exc:
    code = exc.code
finally:
    # ASCII JSON transports Korean arguments losslessly even when Windows
    # redirects stdout using a legacy code page. Assertions decode it below.
    print(json.dumps(events, ensure_ascii=True))
sys.exit(code)
'''


class WindowsLauncherTests(unittest.TestCase):
    def probe(self, scenario, encoding=None):
        environment = dict(os.environ)
        if encoding:
            environment['PYTHONIOENCODING'] = encoding
        result = subprocess.run(
            [sys.executable, '-c', PROBE, str(LAUNCHER), scenario],
            text=True, capture_output=True, timeout=15, env=environment,
        )
        self.assertEqual(result.stderr, '')
        return result.returncode, json.loads(result.stdout)

    def test_child_dispatch_exits_before_gui_import(self):
        code, events = self.probe('child')
        self.assertEqual(events, [['freeze', ['한글 project.bluraction', '--literal-argument']]])
        self.assertEqual(code, 0)

    def test_normal_entry_preserves_arguments_and_application_exit_status(self):
        code, events = self.probe('normal')
        arguments = ['한글 project.bluraction', '--literal-argument']
        self.assertEqual(events, [['freeze', arguments], ['gui-import'], ['main', arguments]])
        self.assertEqual(code, 23)

    def test_import_has_no_gui_or_dispatch_side_effects(self):
        code, events = self.probe('import')
        self.assertEqual(events, [])
        self.assertEqual(code, 0)

    def test_korean_arguments_survive_legacy_stdout_encoding(self):
        code, events = self.probe('normal', encoding='cp1252')
        self.assertEqual(code, 23)
        self.assertEqual(events[-1], ['main', ['한글 project.bluraction', '--literal-argument']])


if __name__ == '__main__':
    unittest.main()
