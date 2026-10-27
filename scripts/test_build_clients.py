import importlib.util
import io
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
            log.write_text('Downgrade was prevented.\n', encoding='utf-8-sig')
            output = io.BytesIO()
            console = io.TextIOWrapper(output, encoding='cp1252')
            with patch.object(build_clients.subprocess, 'run',
                              return_value=subprocess.CompletedProcess([], 1)), patch('sys.stdout', console):
                self.assertEqual(build_clients.run_installer(Path('setup.exe'), log), 1)
            console.flush()
            self.assertEqual(output.getvalue().decode('cp1252').strip(), 'Downgrade was prevented.')


if __name__ == '__main__':
    unittest.main()
