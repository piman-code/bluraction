"""Authored runner outcomes; these fixtures never claim native execution."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from scripts import verify_windows_bundle as subject


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
