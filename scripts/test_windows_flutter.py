from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import windows_flutter


class WindowsFlutterTests(unittest.TestCase):
    def test_backport_applies_once_and_refuses_an_unknown_engine(self):
        with tempfile.TemporaryDirectory() as directory:
            sdk = Path(directory)
            (sdk / 'bin/internal').mkdir(parents=True)
            engine = sdk / 'bin/internal/engine.version'
            engine.write_text(windows_flutter.ENGINE + '\n')
            source = sdk / 'semantics.dart'
            source.write_text('original\n')
            backport = sdk / 'fix.patch'
            backport.write_text(
                '--- a/semantics.dart\n+++ b/semantics.dart\n'
                '@@ -1 +1 @@\n-original\n+fixed\n',
            )
            subprocess.run(['git', 'init', '-q', str(sdk)], check=True)
            flutter = sdk / 'bin/flutter.bat'
            with patch.object(windows_flutter, 'PATCH', backport):
                windows_flutter.prepare_windows_flutter(flutter)
                windows_flutter.prepare_windows_flutter(flutter)
                self.assertEqual(source.read_text(), 'fixed\n')
                engine.write_text('another-engine\n')
                with self.assertRaisesRegex(SystemExit, 'pinned semantics'):
                    windows_flutter.prepare_windows_flutter(flutter)
                self.assertEqual(source.read_text(), 'fixed\n')

    def test_conflicting_sdk_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            sdk = Path(directory)
            (sdk / 'bin/internal').mkdir(parents=True)
            (sdk / 'bin/internal/engine.version').write_text(windows_flutter.ENGINE)
            (sdk / 'semantics.dart').write_text('local changes\n')
            backport = sdk / 'fix.patch'
            backport.write_text(
                '--- a/semantics.dart\n+++ b/semantics.dart\n'
                '@@ -1 +1 @@\n-original\n+fixed\n',
            )
            subprocess.run(['git', 'init', '-q', str(sdk)], check=True)
            with patch.object(windows_flutter, 'PATCH', backport):
                with self.assertRaises(subprocess.CalledProcessError):
                    windows_flutter.prepare_windows_flutter(sdk / 'bin/flutter.bat')
            self.assertEqual((sdk / 'semantics.dart').read_text(), 'local changes\n')


if __name__ == '__main__':
    unittest.main()
