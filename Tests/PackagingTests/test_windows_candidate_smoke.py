"""Isolated source/dispatch checks; never frozen Windows execution evidence."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from platforms.windows.bluraction import candidate_smoke as subject

REPO = Path(__file__).resolve().parents[2]


class CandidateSmokeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.output = self.root / 'output'

    def test_cli_rejects_nonfrozen_host_with_truthful_report(self):
        self.assertEqual(subject.main(['--output', str(self.output)]), 1)
        report = json.loads((self.output / 'report.json').read_text())
        self.assertEqual(report['host'], sys.platform)
        self.assertEqual(report['actualWindows'], sys.platform == 'win32')
        self.assertFalse(report['frozenExecutionVerified'])
        self.assertEqual(report['status'], 'fail')
        self.assertEqual(report['failure']['stage'], 'runtime')
        self.assertFalse(report['redistributionApproved'])

    def test_existing_output_is_never_reused(self):
        self.output.mkdir()
        marker = self.output / 'report.json'
        marker.write_text('preserve')
        self.assertEqual(subject.main(['--output', str(self.output)]), 2)
        self.assertEqual(marker.read_text(), 'preserve')

    def test_sensitive_exception_text_not_recorded(self):
        with patch.object(subject, '_dependencies', side_effect=ValueError('SECRET personal-file-path')):
            self.assertEqual(subject.run(self.output, _allow_source=True), 1)
        text = (self.output / 'report.json').read_text()
        self.assertNotIn('SECRET', text)
        self.assertNotIn('personal-file-path', text)
        self.assertLess(len(text), 65536)

    def test_launcher_dispatches_smoke_after_freeze_before_gui(self):
        code = '''
import builtins,json,multiprocessing,runpy,sys,types
events=[]
multiprocessing.freeze_support=lambda: events.append('freeze')
module=types.ModuleType('platforms.windows.bluraction.candidate_smoke')
def main(args):
    events.append(args)
    return 19
module.main=main
sys.modules[module.__name__]=module
old=builtins.__import__
def guard(name,*args,**kwargs):
    if name=='platforms.windows.bluraction.__main__' or name.startswith('PySide6'):
        raise AssertionError('GUI imported')
    return old(name,*args,**kwargs)
builtins.__import__=guard
launcher=sys.argv[1]
sys.argv=['BlurAction.exe','--candidate-smoke','--output','fresh-dir']
try:
    runpy.run_path(launcher,run_name='__main__')
except SystemExit as error:
    events.append(error.code)
print(json.dumps(events))
'''
        result = subprocess.run([sys.executable, '-c', code, str(REPO / 'platforms/windows/launcher.py')],
            capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), ['freeze', ['--output', 'fresh-dir'], 19])


if __name__ == '__main__':
    unittest.main()
