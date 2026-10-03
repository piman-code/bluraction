"""Authored runner outcomes; these fixtures never claim native execution."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from scripts import verify_windows_bundle as subject


class WrapperEnvironmentTests(unittest.TestCase):
    """Execute real wrapper code in a subprocess; the app launch is intercepted."""
    def probe(self, environment, gate='G'):
        driver = r'''
import io,json,os,subprocess,sys,types
wrapper,gate,environment=sys.argv[1:]
calls=[]
def child(argv,**kwargs):
    calls.append(dict(argv=argv,cwd=kwargs['cwd'],env=kwargs['env'],
                      stdinClosed=kwargs['stdin']==subprocess.DEVNULL))
    return types.SimpleNamespace(returncode=17)
subprocess.run=child
sys.stdin=types.SimpleNamespace(buffer=io.BytesIO(gate.encode('ascii')))
sys.argv=['wrapper','authored-app','authored-output','empty-working-directory']
result={}
os.environ.clear()
os.environ.update(json.loads(environment))
try:
    exec(compile(wrapper,'<actual-wrapper>','exec'), {'__name__':'__main__'})
except SystemExit as error:
    result['exit']=error.code
except Exception as error:
    result['errorType']=type(error).__name__
result['calls']=calls
print(json.dumps(result))
'''
        # Preserve the host environment while starting Python. Apply the
        # authored environment only inside the already-running probe process.
        result = subprocess.run([sys.executable, '-c', driver, subject.WRAPPER, gate,
                                 json.dumps(environment)],
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_uppercase_windows_environment_reaches_child_without_dev_paths(self):
        root = os.path.abspath('authored-windows-root')
        result = self.probe({'SYSTEMROOT': root, 'PATH': 'unwanted-development-path',
                             'PYTHONPATH': 'private-code', 'QT_PLUGIN_PATH': 'private-plugins',
                             'PYSIDE_TEST': 'private-setting', 'VIRTUAL_ENV': 'private-venv'})
        self.assertEqual(result.get('exit'), 17, result)
        self.assertEqual(len(result['calls']), 1)
        call = result['calls'][0]
        self.assertEqual(call['argv'], ['authored-app', '--candidate-smoke', '--output', 'authored-output'])
        self.assertEqual(call['cwd'], 'empty-working-directory')
        self.assertTrue(call['stdinClosed'])
        self.assertEqual(call['env']['PATH'], os.pathsep.join((os.path.join(root, 'System32'), root)))
        for key in ('PYTHONPATH', 'QT_PLUGIN_PATH', 'PYSIDE_TEST', 'VIRTUAL_ENV'):
            self.assertNotIn(key, call['env'])

    def test_mixed_case_environment_is_normalized(self):
        result = self.probe({'SystemRoot': os.path.abspath('authored-windows-root'),
                             'Path': 'private-tools', 'PythonPath': 'private-code'})
        self.assertEqual(result.get('exit'), 17, result)
        self.assertNotIn('Path', result['calls'][0]['env'])
        self.assertNotIn('PythonPath', result['calls'][0]['env'])

    def test_missing_root_fails_before_child(self):
        result = self.probe({'PATH': 'unwanted-development-path'})
        self.assertEqual(result['errorType'], 'ValueError')
        self.assertEqual(result['calls'], [])

    def test_gate_precedes_environment_handling_and_child(self):
        result = self.probe({}, gate='X')
        self.assertEqual(result['exit'], 2)
        self.assertEqual(result['calls'], [])


class BundleRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.bundle = self.root / 'bundle'
        self.bundle.mkdir()
        (self.bundle / 'BlurAction.exe').write_bytes(b'authored fixture')
        self.output = self.root / 'result'
        self.smoke = dict(status='pass', actualWindows=True, frozenExecutionVerified=True,
                          installerVerified=False, userAcceptanceVerified=False,
                          redistributionApproved=False)
        self.smoke['checks'] = {
            'documents': dict(pages=3, projectStateRoundtrip=True,
                              outputPixelsChecked=True, originalsUnchanged=True),
            'production-decoder': dict(productionWorkerHandshake=True,
                                      decodedFrame=True, ownedChildClosed=True)}
        self.code, self.timeout = 0, False
        self.drift = False

    def execute(self, argv, log, timeout):
        self.assertEqual(timeout, 180)
        self.assertEqual(argv[1:3], ['-c', subject.WRAPPER])
        self.assertEqual(list(Path(argv[-1]).iterdir()), [])
        destination = Path(argv[-2])
        destination.mkdir()
        (destination / 'report.json').write_text(json.dumps(self.smoke))
        log.write('authored child outcome\n')
        if self.drift:
            (self.bundle / 'BlurAction.exe').write_bytes(b'changed')
        return self.code, self.timeout

    def run_fixture(self):
        with patch.object(subject.sys, 'platform', 'win32'), \
             patch.object(subject.files, 'require_amd64'), \
             patch.object(subject, 'run_command', side_effect=self.execute):
            return subject.verify(self.bundle, self.output)

    def test_positive_exit_and_report_are_both_required(self):
        result = self.run_fixture()
        self.assertEqual(result['status'], 'frozen-smoke-pass')
        self.assertTrue(result['bundleUnchanged'])
        self.assertFalse(result['installerVerified'])

    def test_timeout_cannot_pass_despite_success_report(self):
        self.timeout = True
        with self.assertRaisesRegex(ValueError, 'positively complete'):
            self.run_fixture()
        self.assertEqual(json.loads((self.output / 'execution.json').read_text())['status'],
                         'failed-or-incomplete')

    def test_unfrozen_report_cannot_pass_with_zero_exit(self):
        self.smoke['frozenExecutionVerified'] = False
        with self.assertRaises(ValueError):
            self.run_fixture()

    def test_native_failure_cannot_pass_with_success_report(self):
        self.code = 1
        with self.assertRaises(ValueError):
            self.run_fixture()

    def test_launch_failure_is_not_hidden_by_missing_smoke_report(self):
        def fail_before_app(argv, log, timeout):
            log.write('authored launch failure\n')
            return 1, False
        with patch.object(self, 'execute', side_effect=fail_before_app):
            with self.assertRaisesRegex(ValueError, 'positively complete'):
                self.run_fixture()
        report = json.loads((self.output / 'execution.json').read_text())
        self.assertEqual(report['failure'], {'stage': 'process-execution', 'type': 'ValueError'})
        self.assertEqual(report['exit'], 1)
        self.assertTrue(report['bundleUnchanged'])
        self.assertIn('logSHA256', report)

    def test_zero_exit_without_smoke_report_is_still_failure(self):
        with patch.object(self, 'execute', return_value=(0, False)):
            with self.assertRaises(FileNotFoundError):
                self.run_fixture()
        report = json.loads((self.output / 'execution.json').read_text())
        self.assertEqual(report['status'], 'failed-or-incomplete')
        self.assertEqual(report['failure']['stage'], 'smoke-report-read')

    def test_exception_message_is_not_copied_into_report(self):
        with patch.object(self, 'execute', side_effect=OSError('private-path-secret-value')):
            with self.assertRaises(OSError):
                self.run_fixture()
        text = (self.output / 'execution.json').read_text()
        self.assertNotIn('private-path-secret-value', text)
        self.assertEqual(json.loads(text)['failure']['type'], 'OSError')

    def test_missing_decoder_completion_cannot_pass(self):
        del self.smoke['checks']['production-decoder']['ownedChildClosed']
        with self.assertRaises(ValueError):
            self.run_fixture()

    def test_bundle_drift_invalidates_success(self):
        self.drift = True
        with self.assertRaisesRegex(ValueError, 'incomplete'):
            self.run_fixture()
        self.assertFalse(json.loads((self.output / 'execution.json').read_text())['bundleUnchanged'])

    def test_existing_output_is_preserved(self):
        self.output.mkdir()
        (self.output / 'keep').write_text('existing')
        with self.assertRaises(FileExistsError):
            self.run_fixture()
        self.assertEqual((self.output / 'keep').read_text(), 'existing')

    def test_other_host_creates_nothing(self):
        with patch.object(subject.sys, 'platform', 'darwin'):
            with self.assertRaisesRegex(ValueError, 'Actual Windows'):
                subject.verify(self.bundle, self.output)
        self.assertFalse(self.output.exists())

    def test_output_must_not_contain_or_be_inside_bundle(self):
        self.output = self.bundle / 'result'
        with self.assertRaisesRegex(ValueError, 'separate'):
            self.run_fixture()
        self.assertFalse(self.output.exists())


if __name__ == '__main__':
    unittest.main()
