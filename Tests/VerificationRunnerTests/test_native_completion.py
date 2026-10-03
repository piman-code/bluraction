"""Completion evidence regression: native process once exited0 without summary."""
import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest

spec = importlib.util.spec_from_file_location('verify_mac', Path(__file__).resolve().parents[2] / 'scripts/verify_mac.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class NativeCompletionTests(unittest.TestCase):
    def test_exit_zero_with_only_partial_suite_is_incomplete(self):
        self.assertIsNone(module.completed_count('Suite DemoTests passed after 1 second.', 'DemoTests', 0))

    def test_empty_wrong_suite_and_multiple_summaries_are_incomplete(self):
        output = 'Suite DemoTests passed after 1 second.\nTest run with 2 tests in 1 suite passed after 1 second.'
        self.assertEqual(module.completed_count(output, 'DemoTests', 0), 2)
        self.assertIsNone(module.completed_count(output, 'OtherTests', 0))
        self.assertIsNone(module.completed_count(output.replace('2 tests', '0 tests'), 'DemoTests', 0))
        self.assertIsNone(module.completed_count(output + output, 'DemoTests', 0))

    def test_failed_or_timed_out_child_never_passes_even_with_summary(self):
        output = 'Suite DemoTests passed after 1 second.\nTest run with 1 test in 1 suite passed after 1 second.'
        self.assertIsNone(module.completed_count(output, 'DemoTests', 1))
        self.assertIsNone(module.completed_count(output, 'DemoTests', None))

    def test_swift_testing_102_summary_requires_one_started_and_completed_suite(self):
        output = ('◇ Suite DemoTests started.\n'
                  '✔ Suite DemoTests passed after 1 second.\n'
                  '✔ Test run with 3 tests passed after 1 second.')
        self.assertEqual(module.completed_count(output, 'DemoTests', 0), 3)
        self.assertIsNone(module.completed_count(output, 'OtherTests', 0))
        self.assertIsNone(module.completed_count(output.replace('3 tests', '0 tests'), 'DemoTests', 0))
        self.assertIsNone(module.completed_count(output.replace('◇ Suite DemoTests started.\n', ''), 'DemoTests', 0))
        self.assertIsNone(module.completed_count(output + '\n◇ Suite OtherTests started.', 'DemoTests', 0))
        self.assertIsNone(module.completed_count(output + '\n✔ Suite OtherTests passed after 1 second.', 'DemoTests', 0))
        self.assertIsNone(module.completed_count(output + output, 'DemoTests', 0))
        self.assertIsNone(module.completed_count(output, 'DemoTests', 1))

    def test_mixed_old_new_and_multiple_suite_summaries_cannot_pass(self):
        output = 'Suite DemoTests passed after 1 second.\nTest run with 2 tests in 1 suite passed after 1 second.'
        self.assertIsNone(module.completed_count(output + '\nTest run with 2 tests passed after 1 second.', 'DemoTests', 0))
        self.assertIsNone(module.completed_count(output.replace('1 suite', '2 suites'), 'DemoTests', 0))
        self.assertIsNone(module.completed_count(output + '\nSuite OtherTests passed after 1 second.', 'DemoTests', 0))

    def test_all_existing_sources_have_unique_suite_inventory(self):
        names = module.native_suites()
        self.assertEqual(len(names), len(set(names)))
        self.assertIn('PortableProjectCompatibilityTests', names)
        self.assertIn('PageWorkspaceTests', names)

    @unittest.skipUnless(hasattr(os, 'killpg'), 'Native Mac runner requires Unix process groups')
    def test_timeout_stops_grandchild_writes_before_log_digest(self):
        with tempfile.TemporaryDirectory() as folder:
            heartbeat = Path(folder) / 'heartbeat'
            # Actual parent and child: timeout must stop the descendant even
            # though only the parent is the direct Popen target.
            leaf = 'import time,sys\np=open(sys.argv[1],"a",buffering=1)\nwhile True:\n p.write("tick\\n");time.sleep(.01)'
            parent = ('import subprocess,sys,time\n'
                      'subprocess.Popen([sys.executable,"-c",sys.argv[1],sys.argv[2]])\n'
                      'time.sleep(30)')
            with (Path(folder) / 'process.log').open('w') as log:
                exit_code, timed_out = module.run_native_command(
                    [sys.executable, '-c', parent, leaf, str(heartbeat)], log, .5)
            self.assertTrue(timed_out)
            self.assertIsNone(exit_code)
            self.assertTrue(heartbeat.exists(), 'Grandchild must actually have started')
            before = heartbeat.read_bytes()
            self.assertGreater(len(before), 0)
            time.sleep(.1)
            self.assertEqual(heartbeat.read_bytes(), before, 'Timed-out child must not keep writing')


if __name__ == '__main__':
    unittest.main()
