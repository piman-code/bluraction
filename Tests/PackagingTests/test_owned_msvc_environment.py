"""Controlled environment/Job contract checks, not native MSVC evidence.

Injected process/Job objects never execute CMD or a compiler on this host.
Actual Windows CMD+VsDevCmd+installed tool execution remains mandatory CI.
"""
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('test_msvc_environment_capture',
    ROOT / 'build-recipes/windows-owned-ffmpeg/capture_msvc_environment.py')
capture = importlib.util.module_from_spec(spec); spec.loader.exec_module(capture)


def selected_environment():
    return dict(PATH=r'C:\Installed VS\VC\bin;C:\Windows\System32', INCLUDE=r'C:\Installed VS\include',
        LIB=r'C:\Installed VS\lib', LIBPATH=r'C:\Installed VS\libpath',
        VCToolsInstallDir='C:\\Installed VS\\VC\\Tools\\MSVC\\14.0\\', VCToolsVersion='14.0',
        VCINSTALLDIR='C:\\Installed VS\\VC\\', WindowsSdkDir='C:\\Installed SDK\\',
        WindowsSDKVersion='10.0\\', VSCMD_ARG_HOST_ARCH='x64', VSCMD_ARG_TGT_ARCH='x64', VSCMD_VER='17.0')


class OwnedMSVCEnvironmentTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='owned-msvc-contract-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        (self.root / 'owned.json').write_text('{}'); (self.root / 'reports').mkdir()
        tools = self.root / 'Installed VS (x64)'; tools.mkdir()
        self.devcmd = tools / 'VsDevCmd.bat'; self.devcmd.write_bytes(b'controlled existing DevCmd')
        self.comspec = tools / 'cmd.exe'; self.comspec.write_bytes(b'controlled existing CMD')
        self.python = tools / 'python.exe'; self.python.write_bytes(b'controlled existing Python')
        self.events = []; self.calls = []

    def run_capture(self, *, exit_code=0, emit=True, timed_out=False, mutate=None, drain_error=None):
        events = self.events; calls = self.calls; owner = self
        class Job:
            drains = 0
            def assign(self, child): events.append('assigned')
            def terminate(self): events.append('terminated')
            def drain(self):
                self.drains += 1
                events.append('drained')
                if drain_error and self.drains > 1: raise drain_error
            def close(self): events.append('closed')
        class Child:
            def __init__(self): self.stdin = io.BytesIO(); self.code = None; self.waits = 0
            def wait(self, timeout):
                self.waits += 1
                if timed_out and self.waits == 1: raise subprocess.TimeoutExpired('controlled', timeout)
                self.code = -9 if timed_out else exit_code
                events.append('waited')
                return self.code
            def poll(self): return self.code
            def kill(self): self.code = -9; events.append('killed')
        def process(argv, **kwargs):
            calls.append((argv, kwargs)); events.append('started')
            kwargs['stdout'].write(b'controlled VsDevCmd stdout\n')
            kwargs['stderr'].write(b'""C:\\Program is not recognized\n' if exit_code else b'')
            if emit:
                capture.write_json_new(Path(kwargs['env']['BLURACTION_MSVC_ENVIRONMENT']),
                                       capture.environment_document(selected_environment()))
            if mutate: mutate()
            return Child()
        with patch.object(capture, 'IS_WINDOWS', True), patch.object(capture.sys, 'executable', str(self.python)):
            return capture.capture(self.root, self.devcmd, self.comspec, process_factory=process, job_factory=Job)

    def report(self):
        return json.loads((self.root / 'reports/msvc-environment-capture.json').read_text())

    def test_fixed_wrapper_calls_batch_returns_on_failure_and_avoids_outer_path_quotes(self):
        lines = capture.WRAPPER.splitlines()
        self.assertEqual(lines[0], '@echo off')
        self.assertEqual(lines[1], 'setlocal DisableDelayedExpansion')
        self.assertEqual(lines[2], 'call "%BLURACTION_MSVC_DEVCMD%" -no_logo -arch=x64 -host_arch=x64')
        self.assertEqual(lines[3], 'if not "%errorlevel%"=="0" exit /b %errorlevel%')
        self.assertIn(' emit --output ', lines[4]); self.assertEqual(lines[5], 'exit /b %errorlevel%')
        self.assertNotIn('&& set', capture.WRAPPER)

    def test_spaced_parenthesis_paths_travel_in_environment_and_only_fixed_basename_in_cmd(self):
        report = self.run_capture()
        argv, kwargs = self.calls[0]
        self.assertEqual(argv[-6:], [str(self.comspec), '/d', '/s', '/v:off', '/c', 'msvc-environment.cmd'])
        self.assertEqual(kwargs['env']['BLURACTION_MSVC_DEVCMD'], str(self.devcmd))
        self.assertNotIn(str(self.devcmd), argv)
        self.assertEqual(self.events[:2], ['started', 'assigned'])
        self.assertTrue(report['privateTreeDrained']); self.assertFalse(report['compilerExecuted'])
        self.assertEqual(report['exitCode'], 0)
        for name in ('stdout.txt', 'stderr.txt'):
            self.assertEqual(report[name]['sha256'], hashlib.sha256((self.root/'msvc-environment'/name).read_bytes()).hexdigest())

    def test_nonzero_cmd_exit_preserves_actual_stdout_stderr_and_never_adopts_environment(self):
        with self.assertRaisesRegex(ValueError, 'VsDevCmd failed'): self.run_capture(exit_code=1, emit=False)
        report = self.report()
        self.assertEqual(report['exitCode'], 1); self.assertEqual(report['status'], 'failed-or-incomplete')
        self.assertTrue(report['privateTreeDrained']); self.assertNotIn('environmentSHA256', report)
        self.assertIn(b'""C:\\Program', (self.root/'msvc-environment/stderr.txt').read_bytes())

    def test_timeout_terminates_owned_job_and_reaps_before_recording_hashes(self):
        with self.assertRaises(ValueError): self.run_capture(timed_out=True, emit=False)
        report = self.report(); self.assertTrue(report['timedOut']); self.assertEqual(report['exitCode'], -9)
        self.assertLess(self.events.index('terminated'), self.events.index('drained'))
        self.assertTrue(report['privateTreeDrained']); self.assertNotIn('environmentSHA256', report)

    def test_success_exit_without_environment_document_is_not_accepted(self):
        with self.assertRaises(FileNotFoundError): self.run_capture(emit=False)
        self.assertEqual(self.report()['status'], 'failed-or-incomplete')

    def test_inherited_prompt_fields_are_removed_and_parent_environment_preserved(self):
        injected = {name: 'inherited-stale' for name in capture.REQUIRED_NAMES + capture.ARCHITECTURE_NAMES}
        with patch.dict(os.environ, injected):
            before = dict(os.environ); self.run_capture(); self.assertEqual(dict(os.environ), before)
        native_env = self.calls[0][1]['env']
        for name in capture.REQUIRED_NAMES + capture.ARCHITECTURE_NAMES:
            if name != 'PATH': self.assertNotIn(name, native_env)

    def test_environment_export_is_allowlisted_and_cannot_include_secrets(self):
        environment = selected_environment() | {'UNRELATED_SECRET': 'private sentinel'}
        document = capture.environment_document(environment)
        encoded = json.dumps(document)
        self.assertNotIn('UNRELATED_SECRET', encoded); self.assertNotIn('private sentinel', encoded)
        self.assertEqual(set(document['environment']), set(capture.ENVIRONMENT_NAMES))

    def test_missing_sdk_and_wrong_or_unknown_host_target_are_rejected(self):
        for name, value in (('WindowsSdkDir', ''), ('LIB', None), ('VSCMD_ARG_TGT_ARCH', 'arm64'),
                            ('VSCMD_ARG_HOST_ARCH', None), ('VSCMD_VER', True)):
            with self.subTest(name=name), self.assertRaises(ValueError):
                capture.environment_document(selected_environment() | {name: value})

    def test_relative_installed_roots_are_not_guessed(self):
        for value in ('C:relative', 'relative', ''):
            with self.subTest(value=value), self.assertRaises(ValueError):
                capture.environment_document(selected_environment() | {'VCToolsInstallDir': value})

    def test_ambiguous_call_expansion_characters_rejected_without_execution(self):
        for value in ('C:\\%PATH%\\VsDevCmd.bat', 'C:\\!value!\\VsDevCmd.bat', 'C:\\x".bat', 'C:\\x\n.bat'):
            with self.subTest(value=value), self.assertRaises(ValueError): capture.validate_control_path(value)
        self.assertEqual(capture.validate_control_path(r'C:\Installed VS (x64)\VsDevCmd.bat'), r'C:\Installed VS (x64)\VsDevCmd.bat')

    def test_installed_input_change_after_launch_rejects_capture(self):
        with self.assertRaisesRegex(ValueError, 'inputs changed'):
            self.run_capture(mutate=lambda: self.devcmd.write_bytes(b'changed installed script'))
        self.assertEqual(self.report()['status'], 'failed-or-incomplete')

    def test_cleanup_failure_keeps_native_failure_primary_and_marks_tree_unconfirmed(self):
        cleanup = OSError('controlled drain failure')
        with self.assertRaisesRegex(ValueError, 'VsDevCmd failed') as observed:
            self.run_capture(exit_code=1, emit=False, drain_error=cleanup)
        self.assertIsNot(observed.exception.__cause__, observed.exception)
        self.assertTrue(any('drain' in note for note in observed.exception.__notes__))
        self.assertFalse(self.report()['privateTreeDrained'])
        self.assertNotIn('environmentSHA256', self.report())
        self.assertIn('closed', self.events)

    def test_existing_attempt_capture_folder_cannot_be_overwritten(self):
        folder = self.root/'msvc-environment'; folder.mkdir(); (folder/'keep').write_bytes(b'original')
        with self.assertRaises(FileExistsError): self.run_capture()
        self.assertEqual((folder/'keep').read_bytes(), b'original'); self.assertFalse(self.calls)

    def test_recipe_keeps_full_build_then_adopts_only_verified_selected_tools_and_restores_environment(self):
        script = (ROOT/'build-recipes/windows-owned-ffmpeg/BuildOwnedCandidate.ps1').read_text()
        self.assertLess(script.index("OwnedCommand 'stock-ffmpeg-build'"), script.index("OwnedCommand 'msvc-environment'"))
        self.assertLess(script.index("OwnedCommand 'msvc-environment'"), script.index("'import-libs'"))
        self.assertIn('$Capture.environmentSHA256', script)
        self.assertIn("'bin/Hostx64/x64'", script)
        self.assertIn("$EnvNames -notcontains $Property.Name", script)
        self.assertNotIn('$EnvironmentRows', script)
        self.assertIn("SetEnvironmentVariable($Name,$BeforeEnv[$Name],'Process')", script)
