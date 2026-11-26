import importlib.util
import io
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location('test_audio_routes_mod', Path(__file__).with_name('test-audio-routes.py'))
audio_routes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audio_routes)


class AudioRouteLaunchTests(unittest.TestCase):
    def test_passes_on_first_attempt(self):
        calls = []

        def fake_run(command, **kwargs):
            calls.append((list(command), kwargs))
            return subprocess.CompletedProcess(command, 0, stdout='PASS: iOS music routing, ok\n')

        with patch.object(audio_routes.subprocess, 'run', side_effect=fake_run), \
             patch('sys.stdout', new_callable=io.StringIO) as out:
            audio_routes.launch_and_verify('SIM-UDID', 'app.resona.audio-route-tests')

        self.assertEqual(len(calls), 1)
        self.assertIn('PASS: iOS music routing, ok', out.getvalue())

    def test_retries_once_after_cold_launch_timeout(self):
        calls = []

        def fake_run(command, **kwargs):
            calls.append(list(command))
            if len(calls) == 1:
                raise subprocess.TimeoutExpired(command, 240, output=b'')
            if len(calls) == 2:
                return subprocess.CompletedProcess(command, 0)
            return subprocess.CompletedProcess(command, 0, stdout='PASS: iOS music routing, ok\n')

        with patch.object(audio_routes.subprocess, 'run', side_effect=fake_run), \
             patch('sys.stdout', new_callable=io.StringIO):
            audio_routes.launch_and_verify('SIM-UDID', 'app.resona.audio-route-tests')

        self.assertEqual(len(calls), 3)
        self.assertEqual(calls[1][:3], ['xcrun', 'simctl', 'terminate'])

    def test_fails_after_exhausting_timeout_retries(self):
        calls = []

        def fake_run(command, **kwargs):
            calls.append(list(command))
            if command[:3] == ['xcrun', 'simctl', 'launch']:
                raise subprocess.TimeoutExpired(command, 240, output=b'partial')
            return subprocess.CompletedProcess(command, 0)

        with patch.object(audio_routes.subprocess, 'run', side_effect=fake_run), \
             patch('sys.stdout', new_callable=io.StringIO) as out:
            with self.assertRaises(SystemExit) as ctx:
                audio_routes.launch_and_verify('SIM-UDID', 'app.resona.audio-route-tests')

        self.assertIn('timed out', str(ctx.exception))
        self.assertIn('partial', out.getvalue())
        self.assertEqual(len(calls), 4)

    def test_does_not_retry_explicit_test_failure(self):
        calls = []

        def fake_run(command, **kwargs):
            calls.append(list(command))
            return subprocess.CompletedProcess(command, 1, stdout='FAIL: Playback did not start\n')

        with patch.object(audio_routes.subprocess, 'run', side_effect=fake_run), \
             patch('sys.stdout', new_callable=io.StringIO):
            with self.assertRaises(SystemExit) as ctx:
                audio_routes.launch_and_verify('SIM-UDID', 'app.resona.audio-route-tests')

        self.assertIn('did not complete successfully', str(ctx.exception))
        self.assertEqual(len(calls), 1)

    def test_retries_silent_cold_launch_crash_without_fail_marker(self):
        calls = []

        def fake_run(command, **kwargs):
            calls.append(list(command))
            if len(calls) == 1:
                return subprocess.CompletedProcess(command, 1, stdout='')
            if len(calls) == 2:
                return subprocess.CompletedProcess(command, 0)
            return subprocess.CompletedProcess(command, 0, stdout='PASS: iOS music routing, ok\n')

        with patch.object(audio_routes.subprocess, 'run', side_effect=fake_run), \
             patch('sys.stdout', new_callable=io.StringIO):
            audio_routes.launch_and_verify('SIM-UDID', 'app.resona.audio-route-tests')

        self.assertEqual(len(calls), 3)
        self.assertEqual(calls[1][:3], ['xcrun', 'simctl', 'terminate'])


if __name__ == '__main__':
    unittest.main()
