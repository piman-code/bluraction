"""Mandatory native-dependency source smoke; not a frozen executable verdict."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]


class CandidateSourceSmokeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.output = self.root / 'output'

    def test_real_source_smoke_in_fresh_process(self):
        code = ('from platforms.windows.bluraction.candidate_smoke import run; '
                'import sys; sys.exit(run(sys.argv[1], _allow_source=True))')
        result = subprocess.run([sys.executable, '-c', code, str(self.output)], cwd=REPO,
            capture_output=True, text=True, timeout=90, env=dict(os.environ, QT_QPA_PLATFORM='offscreen'))
        report = json.loads((self.output / 'report.json').read_text())
        self.assertEqual(result.returncode, 0, (report, result.stderr[-1500:]))
        self.assertEqual(report['status'], 'pass')
        self.assertFalse(report['frozenExecutionVerified'])
        self.assertEqual(report['checks']['documents']['pages'], 3)
        self.assertTrue(report['checks']['production-decoder']['productionWorkerHandshake'])
        self.assertTrue(report['checks']['production-decoder']['ownedChildClosed'])
        self.assertFalse(report['installerVerified'])
        self.assertTrue(all(row['bytes'] > 0 for row in report['files']))


if __name__ == '__main__':
    unittest.main()
