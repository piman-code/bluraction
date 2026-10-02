"""Runner contracts only; native Windows tree tests run only on that host.

No Qt/codec imports, installs, OS input, or personal files. A missing Windows
host explicitly skips the two Job Object observations, never simulates a pass.
"""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('verify_windows', Path(__file__).resolve().parents[2] / 'scripts/verify_windows.py')
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


def complete(family='test_video', count=3, skips=(), **changes):
    row = dict(family=family, collected=count, testsRun=count, failures=0, errors=0,
               expectedFailures=0, unexpectedSuccesses=0, skips=list(skips))
    row.update(changes)
    end = 'OK' if not skips else f'OK (skipped={len(skips)})'
    return f'Ran {count} tests in 0.01s\n\n{end}\n' + runner.PREFIX + json.dumps(row) + '\n'


class WindowsRunnerContracts(unittest.TestCase):
    def test_source_inputs_include_nested_authored_pdf_and_manual_fixtures(self):
        inputs = runner.source_inputs()
        fixture_root = runner.ROOT / 'shared/fixtures'
        expected = {str(p.relative_to(runner.ROOT)) for p in fixture_root.rglob('*') if p.is_file()}
        self.assertTrue(expected <= set(inputs))
        self.assertIn('shared/fixtures/pdf-geometry/generated/inset-r270.pdf', inputs)
        self.assertIn('shared/fixtures/manual-os/synthetic-three-pages.pdf', inputs)
        with patch.object(Path, 'is_symlink', return_value=True):
            with self.assertRaises(ValueError): runner.source_inputs()

    def test_dynamic_inventory_and_command_each_import_only_one_family(self):
        expected = sorted(p.stem for p in runner.TESTS.glob('test_*.py'))
        self.assertEqual(runner.families(), expected)
        self.assertIn('test_ui', expected); self.assertIn('test_video', expected)
        for family in expected:
            argv = runner.command(family)
            self.assertEqual(argv[-2:], ['Tests.WindowsAppTests.' + family, family])
            self.assertNotIn('discover', argv)
        self.assertEqual(runner.command('test_heif_codec', True)[-2],
                         'Tests.WindowsAppTests.test_heif_codec.ActualHeifCodecTests')

    def test_empty_invalid_and_symlink_inventory_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaises(ValueError): runner.families(root)
            (root/'test_invalid-name.py').write_text('')
            with self.assertRaises(ValueError): runner.families(root)
            (root/'test_invalid-name.py').unlink()
            (root/'test_ok.py').write_text('')
            self.assertEqual(runner.families(root), ['test_ok'])
            # No host symlink permission is needed to test inventory rejection.
            with patch.object(Path, 'is_symlink', return_value=True):
                with self.assertRaises(ValueError): runner.families(root)

    def test_positive_single_summary_and_json_are_both_required(self):
        output = complete()
        self.assertEqual(runner.completed_result(output, 'test_video', 0)['status'], 'pass')
        for bad in ('', 'Ran 3 tests in .01s\nOK\n', runner.PREFIX + '{}\n', output+output,
                    output.replace('Ran 3', 'Ran 2'), output.replace('OK', 'FAILED (errors=1)'),
                    complete(count=0), complete(collected=2), complete(family='test_ui')):
            self.assertEqual(runner.completed_result(bad, 'test_video', 0)['status'], 'failed-or-incomplete')

    def test_exit_timeout_errors_and_expected_failure_cannot_look_complete(self):
        for exit_code in (1, None, -9):
            self.assertEqual(runner.completed_result(complete(), 'test_video', exit_code)['status'], 'failed-or-incomplete')
        for field in ('errors', 'failures', 'expectedFailures', 'unexpectedSuccesses'):
            self.assertEqual(runner.completed_result(complete(**{field: 1}), 'test_video', 0)['status'], 'failed-or-incomplete')
        for value in (True, 3.0, -1, '3'):
            self.assertEqual(runner.completed_result(complete(testsRun=value), 'test_video', 0)['status'], 'failed-or-incomplete')

    def test_required_backend_and_encoder_skips_are_failure_with_reason_preserved(self):
        skip = dict(testID='Tests.WindowsAppTests.test_video.VideoTests.test_export',
                    reason='Native encoder export proof missing: actual open failed')
        result = runner.completed_result(complete(skips=[skip]), 'test_video', 0)
        self.assertEqual(result['status'], 'failed-or-incomplete'); self.assertEqual(result['skips'], [skip])
        for family in runner.BACKENDS:
            skip = dict(testID=f'Tests.WindowsAppTests.{family}.ActualBackend.test_missing', reason='dependency missing')
            self.assertEqual(runner.completed_result(complete(family, skips=[skip]), family, 0,
                             backend_only=True)['status'], 'failed-or-incomplete')
        # Class-level skip may return exit0, but reports zero actual tests.
        skip = dict(testID='setUpClass (Tests.WindowsAppTests.test_video.VideoTests)', reason='missing av')
        self.assertEqual(runner.completed_result(complete(count=0, collected=8, skips=[skip]),
                         'test_video', 0)['status'], 'failed-or-incomplete')

    def test_host_symlink_skip_requires_exact_test_and_reason_and_is_not_backend_pass(self):
        name = 'test_asset_timeline.AssetTimelineTests.test_parent_symlink_retarget_and_missing_path_are_generic_read_failures'
        skip = dict(testID='Tests.WindowsAppTests.'+name, reason=runner.SYMLINK_SKIPS[name])
        output = complete('test_asset_timeline', skips=[skip])
        row = runner.completed_result(output, 'test_asset_timeline', 0)
        self.assertEqual(row['status'], 'pass-with-host-skips'); self.assertEqual(row['skips'], [skip])
        self.assertEqual(runner.completed_result(output, 'test_asset_timeline', 0, backend_only=True)['status'], 'failed-or-incomplete')
        for change in ({'testID': skip['testID']+'Unknown'}, {'reason': 'missing Qt'}, {'reason': skip['reason']+' extra'}):
            wrong = dict(skip, **change)
            self.assertEqual(runner.completed_result(complete('test_asset_timeline', skips=[wrong]),
                             'test_asset_timeline', 0)['status'], 'failed-or-incomplete')
        self.assertEqual(runner.completed_result(output.replace('skipped=1', 'skipped=2'),
                         'test_asset_timeline', 0)['status'], 'failed-or-incomplete')

    def test_historical_portable_skip_is_not_allowlisted_in_windows_families(self):
        skip = dict(testID='Tests.PortableProjectTests.test_portable_project.PortableProjectTests.test_existing_controlled_mac_v2_json_fixtures_load_without_source_reads',
                    reason='Local controlled Mac QA JSON fixtures are not present on this checkout')
        row = runner.completed_result(complete('test_ui', skips=[skip]), 'test_ui', 0)
        self.assertEqual(row['status'], 'failed-or-incomplete'); self.assertEqual(row['skips'], [skip])

    def test_main_records_logs_hashes_and_stops_on_incomplete_without_global_environment_change(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory)/'fresh'
            original_env = dict(os.environ)
            called = []
            def child(argv, log, timeout):
                called.append(argv[-1]); log.write(complete(argv[-1])); log.flush()
                return 0, False
            with patch.object(runner, 'families', return_value=['test_video', 'test_ui']), \
                 patch.object(runner, 'source_inputs', return_value={'source.py': 'sha'}), \
                 patch.object(runner, 'run_command', side_effect=child):
                self.assertEqual(runner.main(['--output', str(destination)]), 0)
            report = json.loads((destination/'report.json').read_text())
            self.assertEqual(called, ['test_video', 'test_ui'])
            self.assertTrue(report['fullInventoryRequested']); self.assertTrue(report['inputsUnchanged'])
            self.assertEqual(report['testCount'], 6)
            for row in report['families']:
                self.assertEqual(row['logSHA256'], runner.sha(Path(row['log'])))
            self.assertEqual(dict(os.environ), original_env)
            with self.assertRaises(FileExistsError):
                runner.main(['--output', str(destination)])
            failed = Path(directory)/'incomplete'
            def incomplete(argv, log, timeout): log.write('partial'); return 0, False
            with patch.object(runner, 'families', return_value=['test_video', 'test_ui']), \
                 patch.object(runner, 'source_inputs', return_value={}), \
                 patch.object(runner, 'run_command', side_effect=incomplete):
                self.assertEqual(runner.main(['--output', str(failed)]), 1)
            report = json.loads((failed/'report.json').read_text())
            self.assertEqual(len(report['families']), 1); self.assertEqual(report['testCount'], 0)

    def test_timeout_flag_blocks_pass_even_if_child_exit_and_summary_look_successful(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory)/'timed-out'
            def child(argv, log, timeout):
                log.write(complete(argv[-1])); log.flush(); return 0, True
            with patch.object(runner, 'families', return_value=['test_video']), \
                 patch.object(runner, 'source_inputs', return_value={}), \
                 patch.object(runner, 'run_command', side_effect=child):
                self.assertEqual(runner.main(['--output', str(target)]), 1)
            row = json.loads((target/'report.json').read_text())['families'][0]
            self.assertTrue(row['timedOut']); self.assertEqual(row['status'], 'failed-or-incomplete')

    def test_source_change_or_tree_setup_error_cannot_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            def child(argv, log, timeout): log.write(complete(argv[-1])); log.flush(); return 0, False
            with patch.object(runner, 'families', return_value=['test_video']), \
                 patch.object(runner, 'source_inputs', side_effect=[{'x': 'before'}, {'x': 'after'}]), \
                 patch.object(runner, 'run_command', side_effect=child):
                target = Path(directory)/'changed'
                self.assertEqual(runner.main(['--output', str(target)]), 1)
                self.assertFalse(json.loads((target/'report.json').read_text())['inputsUnchanged'])
            with patch.object(runner, 'families', return_value=['test_video']), \
                 patch.object(runner, 'source_inputs', return_value={}), \
                 patch.object(runner, 'run_command', side_effect=OSError('private job assignment failed')):
                target = Path(directory)/'job-failure'
                self.assertEqual(runner.main(['--output', str(target)]), 1)
                report = json.loads((target/'report.json').read_text())
                self.assertIn('private job assignment failed', report['families'][0]['runnerError'])

    def test_selection_unknown_duplicates_and_nonfinite_deadline_fail_before_output(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)/'never'
            for args in (['--family', 'unknown'], ['--family', 'test_ui', '--family', 'test_ui'],
                         ['--timeout', 'nan'], ['--timeout', '0'], ['--timeout', '901'],
                         ['--required-backends-only', '--family', 'test_ui']):
                with self.assertRaises(SystemExit): runner.main(args+['--output', str(output)])
                self.assertFalse(output.exists())


@unittest.skipUnless(sys.platform == 'win32', 'Actual private Windows Job Object proof requires Windows')
class WindowsOwnedProcessTests(unittest.TestCase):
    def test_job_assignment_precedes_test_entry_and_global_environment_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory)/'entry'
            source = 'import sys\nassert sys.stdin.buffer.read(1)==b"G"\nfrom pathlib import Path\nPath(sys.argv[1]).write_text("entered")'
            original = runner.WindowsJob
            observed = []
            class ObservedJob(original):
                def assign(self, child):
                    self_test.assertFalse(marker.exists(), 'Test entry must remain gated before job assignment')
                    observed.append(child.pid)
                    super().assign(child)
            self_test = self
            before = dict(os.environ)
            with patch.object(runner, 'WindowsJob', ObservedJob), (Path(directory)/'child.log').open('w') as log:
                self.assertEqual(runner.run_command([sys.executable, '-c', source, str(marker)], log, 5), (0, False))
            self.assertEqual(len(observed), 1); self.assertEqual(marker.read_text(), 'entered')
            self.assertEqual(dict(os.environ), before)

    def test_timeout_stops_actual_owned_grandchild_before_log_hash_and_no_more_writes(self):
        with tempfile.TemporaryDirectory() as directory:
            heartbeat = Path(directory)/'heartbeat'
            leaf = 'import time,sys\np=open(sys.argv[1],"a",buffering=1)\nwhile True:\n p.write("tick\\n");time.sleep(.01)'
            parent = ('import sys\nassert sys.stdin.buffer.read(1)==b"G"\nimport subprocess,time\n'
                      'subprocess.Popen([sys.executable,"-c",sys.argv[1],sys.argv[2]])\ntime.sleep(30)')
            with (Path(directory)/'process.log').open('w') as log:
                exit_code, timed_out = runner.run_command([sys.executable, '-c', parent, leaf, str(heartbeat)], log, 3)
            self.assertTrue(timed_out); self.assertIsNone(exit_code)
            self.assertTrue(heartbeat.exists(), 'Actual grandchild must have entered before deadline')
            before = heartbeat.read_bytes(); self.assertGreater(len(before), 0)
            time.sleep(.1)
            self.assertEqual(heartbeat.read_bytes(), before, 'Closed private job must stop descendants')


if __name__ == '__main__':
    unittest.main()
