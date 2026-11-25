import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location('build_clients', Path(__file__).with_name('build-clients.py'))
build_clients = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build_clients)


class InstallerTests(unittest.TestCase):
    def test_expected_installer_failure_logs_work_on_a_windows_console(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / 'downgrade.log'
            message = '已安装更高版本的 Resona。'
            log.write_text(message + '\n', encoding='utf-8-sig')
            output = io.BytesIO()
            console = io.TextIOWrapper(output, encoding='cp1252')
            with patch.object(build_clients.subprocess, 'run',
                              return_value=subprocess.CompletedProcess([], 1)), patch('sys.stdout', console):
                self.assertEqual(build_clients.run_installer(Path('setup.exe'), log), 1)
            console.flush()
            expected = message.encode('cp1252', errors='backslashreplace').decode('cp1252')
            self.assertEqual(output.getvalue().decode('cp1252').strip(), expected)


class FlutterTestRunnerTests(unittest.TestCase):
    def _run_with_outcomes(self, outcomes, *, test_args=(), windows=True, retries=2, files=()):
        calls = []
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for rel in files:
                target = root / rel
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text('void main() {}\n', encoding='utf-8')

            def fake_run(command, cwd=None, check=False):
                calls.append((list(command), cwd, check))
                returncode, events = outcomes[len(calls) - 1]
                for arg in command:
                    if arg.startswith('--file-reporter=json:'):
                        report = Path(arg.split(':', 1)[1])
                        lines = [event if isinstance(event, str) else json.dumps(event) for event in events]
                        report.write_text('\n'.join(lines) + ('\n' if lines else ''), encoding='utf-8')
                if check and returncode != 0:
                    raise subprocess.CalledProcessError(returncode, command)
                return subprocess.CompletedProcess(command, returncode)

            with patch.object(build_clients.subprocess, 'run', side_effect=fake_run), \
                 patch('sys.stdout', new_callable=io.StringIO):
                build_clients.run_flutter_test('flutter', test_args, cwd=root, windows=windows, retries=retries)
        return calls

    def test_retries_only_crashed_test_file_on_silent_windows_tester_crash(self):
        crash_events = [
            {'type': 'suite', 'suite': {'id': 0, 'path': 'test/android_audio_test.dart'}},
            {'type': 'testStart', 'test': {'id': 1, 'suiteID': 0}},
            {'type': 'testDone', 'testID': 1, 'result': 'error', 'skipped': False},
            {'type': 'done', 'success': False},
        ]
        calls = self._run_with_outcomes(
            [(1, crash_events), (0, [])],
            files=['test/android_audio_test.dart'],
        )
        self.assertEqual(len(calls), 2)
        self.assertIn('--concurrency=1', calls[0][0])
        self.assertTrue(any(arg.startswith('--file-reporter=json:') for arg in calls[0][0]))
        self.assertEqual(calls[1][0][-1], 'test/android_audio_test.dart')

    def test_retries_explicit_harness_crash_markers(self):
        for marker in (
            'Connection closed before test suite loaded',
            'flutter_tester process exited with code=-1073741819',
        ):
            with self.subTest(marker=marker):
                events = [
                    {'type': 'suite', 'suite': {'id': 0, 'path': 'test/api_cache_test.dart'}},
                    {'type': 'testStart', 'test': {'id': 1, 'suiteID': 0}},
                    {'type': 'error', 'testID': 1, 'error': marker},
                    {'type': 'testDone', 'testID': 1, 'result': 'error', 'skipped': False},
                    {'type': 'done', 'success': False},
                ]
                calls = self._run_with_outcomes(
                    [(1, events), (0, [])],
                    files=['test/api_cache_test.dart'],
                )
                self.assertEqual(len(calls), 2)
                self.assertEqual(calls[1][0][-1], 'test/api_cache_test.dart')

    def test_retries_full_suite_when_report_is_incomplete_or_truncated(self):
        incomplete = [
            {'type': 'suite', 'suite': {'id': 0, 'path': 'test/android_audio_test.dart'}},
            {'type': 'testStart', 'test': {'id': 1, 'suiteID': 0}},
            '{"type": "testDone",',
        ]
        calls = self._run_with_outcomes(
            [(1, incomplete), (0, [])],
            files=['test/android_audio_test.dart'],
        )
        self.assertEqual(len(calls), 2)
        self.assertNotIn('test/android_audio_test.dart', calls[1][0])

    def test_does_not_retry_real_dart_test_failure(self):
        real_failure = [
            {'type': 'suite', 'suite': {'id': 0, 'path': 'test/offline_test.dart'}},
            {'type': 'testStart', 'test': {'id': 1, 'suiteID': 0}},
            {'type': 'error', 'testID': 1, 'error': 'Expected: <true>\n  Actual: <false>'},
            {'type': 'testDone', 'testID': 1, 'result': 'failure', 'skipped': False},
            {'type': 'done', 'success': False},
        ]
        with self.assertRaises(subprocess.CalledProcessError) as ctx:
            self._run_with_outcomes(
                [(1, real_failure)],
                files=['test/offline_test.dart'],
            )
        self.assertEqual(ctx.exception.returncode, 1)

    def test_does_not_retry_mixed_crash_and_real_error(self):
        mixed = [
            {'type': 'suite', 'suite': {'id': 0, 'path': 'test/a_test.dart'}},
            {'type': 'suite', 'suite': {'id': 1, 'path': 'test/b_test.dart'}},
            {'type': 'testStart', 'test': {'id': 1, 'suiteID': 0}},
            {'type': 'testDone', 'testID': 1, 'result': 'error', 'skipped': False},
            {'type': 'testStart', 'test': {'id': 2, 'suiteID': 1}},
            {'type': 'error', 'testID': 2, 'error': 'Bad state: boom'},
            {'type': 'testDone', 'testID': 2, 'result': 'error', 'skipped': False},
            {'type': 'done', 'success': False},
        ]
        calls_count = 0
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)

            def fake_run(command, cwd=None, check=False):
                nonlocal calls_count
                calls_count += 1
                for arg in command:
                    if arg.startswith('--file-reporter=json:'):
                        Path(arg.split(':', 1)[1]).write_text(
                            '\n'.join(json.dumps(e) for e in mixed) + '\n', encoding='utf-8',
                        )
                return subprocess.CompletedProcess(command, 1)

            with patch.object(build_clients.subprocess, 'run', side_effect=fake_run):
                with self.assertRaises(subprocess.CalledProcessError):
                    build_clients.run_flutter_test('flutter', cwd=root, windows=True)
        self.assertEqual(calls_count, 1)

    def test_raises_after_exhausting_retries(self):
        crash = [
            {'type': 'suite', 'suite': {'id': 0, 'path': 'test/android_audio_test.dart'}},
            {'type': 'testStart', 'test': {'id': 1, 'suiteID': 0}},
            {'type': 'testDone', 'testID': 1, 'result': 'error', 'skipped': False},
            {'type': 'done', 'success': False},
        ]
        with self.assertRaises(subprocess.CalledProcessError):
            self._run_with_outcomes(
                [(1, crash), (1, crash), (1, crash)],
                files=['test/android_audio_test.dart'],
                retries=2,
            )

    def test_preserves_explicit_test_args_on_retry(self):
        crash = [
            {'type': 'suite', 'suite': {'id': 0, 'path': 'test/widgets/semantics_test.dart'}},
            {'type': 'testStart', 'test': {'id': 1, 'suiteID': 0}},
            {'type': 'testDone', 'testID': 1, 'result': 'error', 'skipped': False},
            {'type': 'done', 'success': False},
        ]
        explicit_args = ['--plain-name', 'some test', 'test/widgets/semantics_test.dart']
        calls = self._run_with_outcomes(
            [(1, crash), (0, [])],
            test_args=explicit_args,
            files=['test/widgets/semantics_test.dart'],
        )
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[0][0][-3:], explicit_args)
        self.assertEqual(calls[1][0][-3:], explicit_args)

    def test_non_windows_runs_without_concurrency_or_retry(self):
        calls = self._run_with_outcomes([(0, [])], test_args=['test/offline_test.dart'], windows=False)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][0], ['flutter', 'test', '--reporter=expanded', 'test/offline_test.dart'])
        self.assertTrue(calls[0][2])
        with self.assertRaises(subprocess.CalledProcessError):
            self._run_with_outcomes([(1, [])], test_args=['test/offline_test.dart'], windows=False)


if __name__ == '__main__':
    unittest.main()
