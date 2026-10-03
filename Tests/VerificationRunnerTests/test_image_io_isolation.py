"""Controlled runner regressions; these never call ImageIO or crash the host.

Actual native 51 observations and Mac14 crash survival are root execution gates.
"""
import json
import io
from pathlib import Path
import signal
import sys
import tempfile
import unittest
from unittest.mock import patch

from scripts import diagnose_image_io as diagnostic


class ImageIOIsolationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='imageio-isolation-unit-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()

    def runner(self, behavior=None, seen=None):
        def observed(command, stdout, stderr, timeout):
            index = int(command[command.index('--attempt-index') + 1])
            descriptor = diagnostic.descriptor(index)
            source = Path(command[command.index('--input-rgba') + 1])
            output = Path(command[command.index('--output-parent') + 1])
            if seen is not None: seen.append(index)
            digest = diagnostic.sha(source)
            ready = dict(diagnosticStage='source-ready', attemptIndex=index,
                         width=descriptor['width'], height=descriptor['height'],
                         authoredRGBA8SHA256=digest, inputFileSHA256=digest)
            stdout.write_text('', encoding='utf-8')
            stderr.write_text(json.dumps(ready) + '\n', encoding='utf-8')
            partial = output / 'owned-partial.heic'; partial.write_bytes(b'controlled partial; never decode')
            choice = behavior(index, source, stdout, stderr, output) if behavior else 'success'
            if choice == 'crash':
                with stderr.open('a') as stream: stream.write(json.dumps(dict(diagnosticStage='software-heif-write')) + '\ncontrolled crash text\n')
                return -int(signal.SIGSEGV), False
            if choice == 'timeout': return -int(signal.SIGKILL), True
            if choice == 'missing-report': return 0, False
            succeeded = choice != 'encode-failure'
            native = dict(schemaVersion=2, attemptIndex=index, attemptCount=1,
                          width=descriptor['width'], height=descriptor['height'],
                          cleanupSucceeded=True, sourcesPreserved=True,
                          sources=[dict(authoredRGBA8SHA256=digest, sourcePreserved=True)],
                          results=[dict(variant=descriptor['variant'], type=descriptor['type'], succeeded=succeeded)],
                          failedAttemptCount=0 if succeeded else 1)
            stdout.write_text(json.dumps(native), encoding='utf-8')
            return (0 if succeeded else 3), False
        return observed

    def test_crash_is_failure_observation_with_all_51_continued_and_external_sources_preserved(self):
        seen = []
        def behavior(index, *args):
            return 'crash' if index in (16, 33, 50) else 'success'
        rows = diagnostic.observe_all('never executed', self.root, 2, self.runner(behavior, seen))
        self.assertEqual(seen, list(range(51)))
        self.assertEqual(diagnostic.verdict(rows), 3)
        self.assertEqual(sum(r['succeeded'] for r in rows), 48)
        self.assertEqual([r['attemptIndex'] for r in rows if r['status'] == 'native-process-crash-observed'], [16, 33, 50])
        for row in rows:
            attempt = self.root / ('attempt-%02d' % row['attemptIndex'])
            self.assertTrue(row['cleanupSucceeded']); self.assertTrue(row['sourcePreserved'])
            self.assertFalse((attempt / 'native-output').exists())
            self.assertEqual(diagnostic.sha(attempt / 'input.rgba'), row['sourceSHA256'])
            self.assertTrue((attempt / 'native.stderr').exists())
            if row['status'] == 'native-process-crash-observed':
                self.assertFalse(row['succeeded']); self.assertIsNone(row['nativeMemoryPreservationVerified'])
                self.assertEqual(row['crashSignal'], int(signal.SIGSEGV))
                self.assertEqual(row['lastCheckpoint']['diagnosticStage'], 'software-heif-write')

    def test_timeout_missing_report_and_missing_source_checkpoint_are_incomplete_not_format_failures(self):
        def behavior(index, source, stdout, stderr, output):
            if index == 0: return 'timeout'
            if index == 1: return 'missing-report'
            if index == 2:
                stderr.write_text('controlled text without source checkpoint\n', encoding='utf-8')
                return 'crash'
            return 'success'
        rows = diagnostic.observe_all('never executed', self.root, 2, self.runner(behavior))
        self.assertEqual(len(rows), 51)
        self.assertEqual([r['status'] for r in rows[:3]], ['incomplete'] * 3)
        self.assertEqual(diagnostic.verdict(rows), 1)
        self.assertTrue(all(r['cleanupSucceeded'] for r in rows))
        self.assertTrue(all(r['sourcePreserved'] for r in rows))
        self.assertEqual(rows[-1]['status'], 'encode-readable')

    def test_changed_input_rejects_even_positive_native_report_and_still_cleans_owned_output(self):
        def behavior(index, source, *args):
            source.write_bytes(b'changed authored witness')
            return 'success'
        row = diagnostic.observe_attempt('never executed', self.root, 0, 2, self.runner(behavior))
        self.assertEqual(row['status'], 'incomplete')
        self.assertFalse(row['sourcePreserved'])
        self.assertTrue(row['cleanupSucceeded'])
        self.assertFalse((self.root / 'attempt-00/native-output').exists())
        self.assertEqual((self.root / 'attempt-00/input.rgba').read_bytes(), b'changed authored witness')

    def test_cleanup_failure_is_incomplete_and_keeps_owner_output_and_input(self):
        with patch.object(diagnostic, 'cleanup_output', side_effect=OSError('controlled owner cleanup failure')):
            row = diagnostic.observe_attempt('never executed', self.root, 0, 2, self.runner())
        self.assertEqual(row['status'], 'incomplete')
        self.assertFalse(row['cleanupSucceeded']); self.assertTrue(row['sourcePreserved'])
        self.assertIn('OSError', row['cleanupError'])
        self.assertTrue((self.root / 'attempt-00/native-output/owned-partial.heic').exists())
        self.assertEqual(diagnostic.sha(self.root / 'attempt-00/input.rgba'), row['sourceSHA256'])

    def test_success_and_native_false_are_distinct_and_exact_inventory_is_required(self):
        all_success = [dict(attemptIndex=i, status='encode-readable', succeeded=True,
                            sourcePreserved=True, cleanupSucceeded=True) for i in range(51)]
        self.assertEqual(diagnostic.verdict(all_success), 0)
        row = diagnostic.observe_attempt('never executed', self.root, 0, 2,
            self.runner(lambda *_: 'encode-failure'))
        self.assertEqual(row['status'], 'encode-failure-observed')
        self.assertFalse(row['succeeded']); self.assertTrue(row['nativeMemoryPreservationVerified'])
        all_success[0] = row
        self.assertEqual(diagnostic.verdict(all_success), 3)
        self.assertEqual(diagnostic.verdict(all_success[:-1]), 1)
        all_success[-1]['attemptIndex'] = 49
        self.assertEqual(diagnostic.verdict(all_success), 1)

    def test_supervisor_signal_unwinds_owned_attempt_and_retains_incomplete_artifact(self):
        original_handler = signal.getsignal(signal.SIGTERM)
        cause = KeyboardInterrupt('controlled same supervisor cancellation')
        captured = []
        def cancel(command, stdout, stderr, timeout):
            source = Path(command[command.index('--input-rgba') + 1])
            output = Path(command[command.index('--output-parent') + 1])
            captured.append((diagnostic.identity(source), diagnostic.sha(source)))
            stdout.write_text('', encoding='utf-8')
            stderr.write_text('controlled cancellation checkpoint\n', encoding='utf-8')
            (output / 'private-partial.heic').write_bytes(b'controlled partial')
            raise cause
        with self.assertRaises(KeyboardInterrupt) as observed:
            diagnostic.observe_attempt('never executed', self.root, 0, 2, cancel)
        self.assertIs(observed.exception, cause)
        attempt = self.root / 'attempt-00'
        report = json.loads((attempt / 'observation.json').read_text())
        self.assertEqual(report['status'], 'incomplete')
        self.assertIn('KeyboardInterrupt', report['error'])
        self.assertTrue(report['sourcePreserved']); self.assertTrue(report['cleanupSucceeded'])
        self.assertEqual((diagnostic.identity(attempt / 'input.rgba'), diagnostic.sha(attempt / 'input.rgba')), captured[0])
        self.assertFalse((attempt / 'native-output').exists())
        self.assertEqual(signal.getsignal(signal.SIGTERM), original_handler)
        with self.assertRaisesRegex(KeyboardInterrupt, 'Supervisor cancelled'):
            diagnostic.supervisor_cancelled(signal.SIGTERM, None)
        # The CLI must also retain a top-level incomplete report after a
        # supervisor interruption, instead of losing every artifact in unwind.
        main_root = self.root / 'controlled-main'; (main_root / 'scripts').mkdir(parents=True)
        swift = main_root / 'scripts/diagnose_image_io.swift'; swift.write_bytes(b'controlled source; never compiled')
        python = main_root / 'scripts/diagnose_image_io.py'; python.write_bytes(b'controlled source; never executed')
        def compile_only(command, stdout, stderr, timeout):
            Path(command[-1]).write_bytes(b'controlled native placeholder; never executed')
            stdout.write_text('', encoding='utf-8'); stderr.write_text('', encoding='utf-8')
            return 0, False
        with patch.object(diagnostic, 'ROOT', main_root), patch.object(diagnostic, '__file__', str(python)), \
             patch.object(diagnostic, 'run', side_effect=compile_only), \
             patch.object(diagnostic, 'observe_all', side_effect=cause), \
             patch.object(sys, 'argv', ['controlled-diagnostic', '--timeout', '2']), \
             patch.object(sys, 'platform', 'darwin'), patch.object(sys, 'stdout', io.StringIO()):
            self.assertEqual(diagnostic.main(), 1)
        reports = list((main_root / '.build').glob('image-io-diagnostic-*/execution.json'))
        self.assertEqual(len(reports), 1)
        top = json.loads(reports[0].read_text())
        self.assertEqual(top['status'], 'incomplete')
        self.assertIn('KeyboardInterrupt', top['error'])
        self.assertTrue(top['inputsUnchanged']); self.assertIsNone(top['nativeExit'])
        self.assertIsNot(cause.__cause__, cause)
        self.assertEqual(signal.getsignal(signal.SIGTERM), original_handler)
