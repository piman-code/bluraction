"""Deadline/linkage orchestration contracts, not native roundtrip completion."""
import importlib.util
from contextlib import redirect_stdout
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('roundtrip_stage', ROOT / 'scripts/video-project-roundtrip/run_stage.py')
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)


def binaries(scratch):
    parent = scratch / 'arm64-apple-macosx/debug'
    executable = parent / 'BlurActionPackageTests.xctest/Contents/MacOS/BlurActionPackageTests'
    executable.parent.mkdir(parents=True)
    executable.write_bytes(b'synthetic test executable')
    executable.chmod(0o700)
    app = parent / 'BlurAction'
    app.write_bytes(b'synthetic app executable')
    app.chmod(0o700)
    return executable


class RoundtripStageContractTests(unittest.TestCase):
    def drive(self, root, *, host='darwin', build_result=(0, False), mutate_binary=False, change_source=False,
              build_summary=True, stage_result=(0, False)):
        build = root / '.build'; build.mkdir()
        incoming = build / 'incoming'; incoming.mkdir()
        (incoming / 'source').write_bytes(b'preserved')
        output = build / 'attempt'
        calls = []
        def child(argv, log, deadline):
            calls.append((argv, deadline))
            if '--build-only' in argv:
                if build_result == (0, False):
                    binaries(Path(argv[argv.index('--scratch-path') + 1]))
                    log.write('Build complete! (176.37s)\n' if build_summary else 'Linking BlurAction\n')
                else:
                    log.write('Building failed or incomplete\n')
                return build_result
            if host == 'win32':
                log.write('Ran 1 test in 0.2s\nOK\n')
            else:
                log.write(f'◇ Suite {stage.SUITE} started.\n✔ Suite {stage.SUITE} passed after 1s.\n'
                          '✔ Test run with 1 test passed after 1s.\n')
                if mutate_binary:
                    (output / 'swift-build/arm64-apple-macosx/debug/BlurAction').write_bytes(b'changed')
            return stage_result
        arguments = ['run_stage.py', '--stage', 'windows-edit' if host == 'win32' else 'mac-emit', '--output', str(output)]
        if host == 'win32': arguments += ['--input', str(incoming)]
        before = {'source.swift': 'a' * 64}
        snapshots = [before, {'source.swift': 'b' * 64}, {'source.swift': 'b' * 64}] if change_source else None
        with patch.object(stage, 'ROOT', root), patch.object(stage.sys, 'platform', host), \
             patch.object(stage.sys, 'argv', arguments), patch.object(stage, 'run_command', side_effect=child), \
             patch.object(stage, 'inputs', return_value=before, side_effect=snapshots), \
             patch.object(stage, 'fixture_bytes'), patch.object(stage, 'packet', return_value={'synthetic': True}), \
             patch.object(stage, 'owned', return_value=incoming), redirect_stdout(io.StringIO()):
            try:
                stage.main()
            except ValueError as error:
                failure = str(error)
            else:
                failure = None
        return json.loads((output / 'report.json').read_text()), calls, failure

    def test_mac_build_and_test_use_separate_deadlines_and_one_fresh_binary(self):
        with tempfile.TemporaryDirectory() as folder:
            report, calls, error = self.drive(Path(folder))
            self.assertIsNone(error)
            self.assertEqual([d for _, d in calls], [600, 180])
            self.assertIn('--build-only', calls[0][0])
            self.assertNotIn('--filter', calls[0][0])
            self.assertIn('--skip-build', calls[1][0])
            self.assertEqual(calls[0][0][-1], calls[1][0][calls[1][0].index('--scratch-path') + 1])
            self.assertTrue(report['buildSourceInputsPreserved'])
            self.assertTrue(report['buildBinaryInputsPreserved'])
            self.assertEqual(report['buildBinaryInputs'], report['finalBinaryInputs'])
            self.assertEqual(report['status'], 'completed')
            self.assertEqual([p['phase'] for p in report['phases']], ['mac-build', 'native-stage'])
            self.assertTrue(all(p['processTreeCleanupCompleted'] and len(p['logSHA256']) == 64 and
                                p['elapsedSeconds'] >= 0 and p['startedAt'] <= p['finishedAt'] for p in report['phases']))

    def test_failed_or_timed_out_build_never_runs_suite_and_keeps_report(self):
        for result in ((1, False), (None, True)):
            with self.subTest(result=result), tempfile.TemporaryDirectory() as folder:
                report, calls, error = self.drive(Path(folder), build_result=result)
                self.assertIsNotNone(error)
                self.assertEqual(len(calls), 1)
                self.assertEqual(report['status'], 'failed-or-incomplete')
                self.assertEqual(report['phases'][0]['exit'], result[0])
                self.assertEqual(report['phases'][0]['timedOut'], result[1])
                self.assertTrue(report['sourceInputsPreserved'])
                self.assertTrue((Path(folder) / '.build/attempt/build.log').is_file())
                self.assertFalse((Path(folder) / '.build/attempt/stage.log').exists())

    def test_source_change_during_build_rejects_stale_binary_before_suite(self):
        with tempfile.TemporaryDirectory() as folder:
            report, calls, error = self.drive(Path(folder), change_source=True)
            self.assertIn('changed during native build', error)
            self.assertEqual(len(calls), 1)
            self.assertFalse(report['sourceInputsPreserved'])

    def test_exit_zero_build_without_completion_cannot_run_suite(self):
        with tempfile.TemporaryDirectory() as folder:
            report, calls, error = self.drive(Path(folder), build_summary=False)
            self.assertIn('Missing positive native test build completion', error)
            self.assertEqual(len(calls), 1)
            self.assertEqual(report['status'], 'failed-or-incomplete')

    def test_failed_or_timed_out_stage_cannot_pass_a_positive_summary(self):
        for result in ((1, False), (None, True)):
            with self.subTest(result=result), tempfile.TemporaryDirectory() as folder:
                report, calls, error = self.drive(Path(folder), stage_result=result)
                self.assertIsNotNone(error)
                self.assertEqual(len(calls), 2)
                self.assertEqual(report['status'], 'failed-or-incomplete')
                self.assertEqual(report['exit'], result[0])
                self.assertEqual(report['timedOut'], result[1])
                self.assertTrue(report['buildBinaryInputsPreserved'])

    def test_binary_change_after_positive_suite_summary_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            report, calls, error = self.drive(Path(folder), mutate_binary=True)
            self.assertIsNotNone(error)
            self.assertEqual(len(calls), 2)
            self.assertFalse(report['buildBinaryInputsPreserved'])
            self.assertEqual(report['status'], 'failed-or-incomplete')

    def test_windows_keeps_single_180_second_job_without_swift_build(self):
        with tempfile.TemporaryDirectory() as folder:
            report, calls, error = self.drive(Path(folder), host='win32')
            self.assertIsNone(error)
            self.assertEqual(len(calls), 1)
            self.assertEqual(calls[0][1], 180)
            self.assertNotIn('--build-only', calls[0][0])
            self.assertNotIn('--skip-build', calls[0][0])
            self.assertNotIn('buildBinaryInputs', report)
            self.assertEqual(report['phases'][0]['phase'], 'native-stage')

    def test_binary_inventory_rejects_missing_ambiguous_and_escaping_inputs(self):
        with tempfile.TemporaryDirectory() as folder:
            scratch = Path(folder) / 'scratch'; scratch.mkdir()
            with self.assertRaises(ValueError): stage.mac_binary_inputs(scratch)
            executable = binaries(scratch)
            self.assertEqual(len(stage.mac_binary_inputs(scratch)), 2)
            (scratch / 'other/BlurActionPackageTests.xctest').mkdir(parents=True)
            with self.assertRaises(ValueError): stage.mac_binary_inputs(scratch)
        with tempfile.TemporaryDirectory() as folder:
            scratch = Path(folder) / 'scratch'; scratch.mkdir()
            binaries(scratch)
            outside = Path(folder) / 'outside'; outside.write_bytes(b'outside')
            link = scratch / 'arm64-apple-macosx/debug/BlurActionPackageTests.xctest/link'
            link.symlink_to(outside)
            with self.assertRaises(ValueError): stage.mac_binary_inputs(scratch)

    def test_current_apple_test_product_keeps_whole_bundle_and_app_linkage(self):
        # Observed by root in a fresh actual Mac build: Apple's build system
        # uses the test target name, unlike SwiftPM's legacy package runner.
        with tempfile.TemporaryDirectory() as folder:
            scratch = Path(folder) / 'scratch'
            parent = scratch / 'out/Products/Debug'
            bundle = parent / 'BlurActionTests.xctest'
            executable = bundle / 'Contents/MacOS/BlurActionTests'
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b'controlled current test executable'); executable.chmod(0o700)
            (bundle / 'Contents/Info.plist').write_bytes(b'controlled bundle metadata')
            app = parent / 'BlurAction'; app.write_bytes(b'controlled app'); app.chmod(0o700)
            observed = stage.mac_binary_inputs(scratch)
            self.assertEqual(len(observed), 3)
            self.assertIn(executable.relative_to(scratch).as_posix(), observed)
            before = observed[executable.relative_to(scratch).as_posix()]['SHA256']
            executable.write_bytes(b'changed current test executable')
            self.assertNotEqual(stage.mac_binary_inputs(scratch)[executable.relative_to(scratch).as_posix()]['SHA256'], before)
            bundle.rename(parent / 'UnrelatedTests.xctest')
            with self.assertRaisesRegex(ValueError, 'Unknown native test product'):
                stage.mac_binary_inputs(scratch)

    def test_cleanup_error_retains_phase_failure_and_log_hash(self):
        with tempfile.TemporaryDirectory() as folder:
            report = {'phases': []}
            def failure(argv, stream, timeout):
                stream.write('preserved failure\n')
                raise TimeoutError('Private descendants did not terminate')
            with patch.object(stage, 'run_command', side_effect=failure), self.assertRaises(TimeoutError):
                stage.run_phase('mac-build', ['synthetic'], 600, Path(folder) / 'build.log', report)
            row = report['phases'][0]
            self.assertFalse(row['processTreeCleanupCompleted'])
            self.assertIn('descendants', row['error'])
            self.assertEqual(len(row['logSHA256']), 64)

    @unittest.skipUnless(hasattr(os, 'killpg'), 'Actual private Unix process-tree check')
    def test_phase_timeout_reaps_grandchild_before_hashing_log(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            heartbeat = folder / 'heartbeat'
            leaf = 'import sys,time\np=open(sys.argv[1],"a",buffering=1)\nwhile True:\n p.write("tick\\n");time.sleep(.01)'
            parent = 'import sys,time,subprocess\nsubprocess.Popen([sys.executable,"-c",sys.argv[1],sys.argv[2]])\ntime.sleep(30)'
            report = {'phases': []}
            code, timed_out = stage.run_phase('native-stage', [sys.executable, '-c', parent, leaf, str(heartbeat)],
                                             .6, folder / 'stage.log', report)
            self.assertIsNone(code)
            self.assertTrue(timed_out)
            self.assertTrue(report['phases'][0]['processTreeCleanupCompleted'])
            before = heartbeat.read_bytes()
            self.assertGreater(len(before), 0)
            time.sleep(.1)
            self.assertEqual(heartbeat.read_bytes(), before)

    @unittest.skipUnless(os.name == 'posix', 'Bash wrapper contract')
    def test_wrapper_build_only_and_skip_build_keep_identical_plugin_flags(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder); tools = folder / 'bin'; tools.mkdir()
            developer = folder / 'developer'; plugin = developer / 'usr/lib/swift/host/plugins/testing/libTestingMacros.dylib'
            plugin.parent.mkdir(parents=True); plugin.write_bytes(b'fixture')
            swift = tools / 'swift'
            swift.write_text('#!/usr/bin/env python3\nimport os,sys,json\nopen(os.environ["ARGS_LOG"],"a").write(json.dumps(sys.argv[1:])+"\\n")\n')
            swift.chmod(0o700)
            select = tools / 'xcode-select'; select.write_text('#!/bin/bash\nprintf "%s\\n" "$FIXTURE_DEVELOPER"\n'); select.chmod(0o700)
            log = folder / 'args.log'
            env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'], ARGS_LOG=str(log), FIXTURE_DEVELOPER=str(developer))
            subprocess.run(['bash', str(ROOT / 'scripts/test.sh'), '--build-only', '--scratch-path', str(folder / 'fresh')], env=env, check=True)
            subprocess.run(['bash', str(ROOT / 'scripts/test.sh'), '--scratch-path', str(folder / 'fresh'), '--skip-build', '--filter', stage.SUITE], env=env, check=True)
            build, test = [json.loads(line) for line in log.read_text().splitlines()]
            self.assertEqual(build[:2], ['build', '--build-tests'])
            self.assertEqual(test[0], 'test')
            self.assertIn('--skip-build', test)
            for argv in (build, test):
                self.assertIn('--disable-sandbox', argv)
                self.assertEqual(argv[argv.index('-load-plugin-library') + 2], str(plugin))
            self.assertEqual(build[2:build.index('--scratch-path')], test[1:test.index('--scratch-path')])


if __name__ == '__main__':
    unittest.main()
