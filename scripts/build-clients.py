#!/usr/bin/env python3
"""Build Flutter clients from VERSION.json, then package and checksum them."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from version import ROOT, stem, version
from windows_flutter import prepare_windows_flutter
from windows_accessibility import run_accessibility_smoke

CLIENT = ROOT / 'clients/resona'
WINDOWS_FLUTTER_TEST_RETRIES = 2
FLUTTER_TESTER_CRASH_MARKERS = (
    'connection closed before test suite loaded',
    'unable to connect to flutter_tester process',
    'shell subprocess crashed',
    'exited with code=-1073741819',
    '0xc0000005',
    'did not complete',
)


def parse_flutter_tester_crash(report_path):
    """Return crashed suite paths for a pure flutter_tester.exe crash, or None."""
    if not report_path.is_file():
        return None
    suites = {}
    test_suites = {}
    failed_tests = []
    saw_suite = False
    saw_done = False
    truncated = False
    has_non_crash_error = False
    with report_path.open('r', encoding='utf-8', errors='replace') as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except ValueError:
                truncated = True
                break
            if not isinstance(event, dict):
                continue
            event_type = event.get('type')
            if event_type == 'suite':
                saw_suite = True
                suite = event.get('suite') or {}
                if 'id' in suite:
                    suites[suite['id']] = suite.get('path')
            elif event_type == 'testStart':
                test = event.get('test') or {}
                if 'id' in test:
                    test_suites[test['id']] = test.get('suiteID')
            elif event_type == 'error':
                message = str(event.get('error') or '').lower()
                if not any(marker in message for marker in FLUTTER_TESTER_CRASH_MARKERS):
                    has_non_crash_error = True
            elif event_type == 'testDone':
                if not event.get('skipped') and event.get('result') != 'success':
                    failed_tests.append(event.get('testID'))
            elif event_type == 'done':
                saw_done = True
    if has_non_crash_error:
        return None
    if not failed_tests:
        return [] if saw_suite and (not saw_done or truncated) else None
    if not saw_done or truncated:
        return []
    paths = []
    seen = set()
    for test_id in failed_tests:
        path = suites.get(test_suites.get(test_id))
        if not isinstance(path, str) or not path:
            return []
        if path not in seen:
            seen.add(path)
            paths.append(path)
    return paths


def run_flutter_test(flutter, test_args=(), *, cwd, windows=False, retries=WINDOWS_FLUTTER_TEST_RETRIES):
    """Run flutter test sequentially on Windows and retry native tester crashes."""
    if not windows:
        subprocess.run([flutter, 'test', '--reporter=expanded', *test_args], cwd=cwd, check=True)
        return
    current_args = list(test_args)
    for attempt in range(retries + 1):
        with tempfile.TemporaryDirectory(prefix='resona-flutter-test-') as directory:
            report = Path(directory) / 'report.json'
            command = [
                flutter, 'test', '--reporter=expanded', '--concurrency=1',
                f'--file-reporter=json:{report}', *current_args,
            ]
            completed = subprocess.run(command, cwd=cwd)
            if completed.returncode == 0:
                return
            crashed = parse_flutter_tester_crash(report)
        if crashed is None or attempt >= retries:
            raise subprocess.CalledProcessError(completed.returncode, command)
        if not current_args and crashed and all((Path(cwd) / path).is_file() for path in crashed):
            current_args = crashed
        target = ' '.join(current_args) if current_args else 'all tests'
        print(
            f'Retrying Windows flutter test ({attempt + 1}/{retries}) '
            f'after flutter_tester.exe crash (flutter/flutter#196440): {target}',
            flush=True,
        )


def output_name(target, preview=False):
    if target == 'android':
        return f'Resona-Android-{stem()}{"-preview" if preview else ""}.apk'
    return f'Resona-Windows-{stem()}-x64.exe'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('target', choices=['android', 'windows'])
    args = parser.parse_args()
    v = version()
    flutter = shutil.which('flutter')
    if not flutter:
        raise SystemExit('Flutter is required on PATH (see clients/resona/README.md).')
    signing = [os.environ.get(key, '') for key in (
        'RESONA_ANDROID_KEYSTORE', 'RESONA_ANDROID_STORE_PASSWORD',
        'RESONA_ANDROID_KEY_ALIAS', 'RESONA_ANDROID_KEY_PASSWORD')]
    if args.target == 'android' and any(signing) and not all(signing):
        raise SystemExit('Supply all four Android signing variables, or none for a preview build.')
    preview = args.target == 'android' and not all(signing)
    out = ROOT / 'dist' / output_name(args.target, preview)
    if out.exists():
        raise SystemExit(f'{out.name} already exists; verify and reuse it, or bump VERSION.json.')

    if args.target == 'windows':
        sdk = prepare_windows_flutter(flutter)
        run_flutter_test(
            flutter, ['test/semantics/semantics_update_test.dart'],
            cwd=sdk / 'packages/flutter', windows=True,
        )
        run_flutter_test(
            flutter,
            ['--plain-name', 'sibling traversal parents are not merged into a single node',
             'test/widgets/semantics_test.dart'],
            cwd=sdk / 'packages/flutter', windows=True,
        )
        run_flutter_test(
            flutter,
            ['--plain-name', 'toggling an overlay child does not leave a parentless attached semantics node',
             'test/widgets/overlay_portal_test.dart'],
            cwd=sdk / 'packages/flutter', windows=True,
        )

    def run(*args):
        subprocess.run([flutter, *args], cwd=CLIENT, check=True)

    if args.target == 'android':
        legal = CLIENT / 'android/app/src/main/assets'
        legal.mkdir(exist_ok=True)
        for name in ('LICENSE', 'THIRD_PARTY.md'):
            shutil.copy2(ROOT / name, legal / name)
        (legal / 'VERSION.json').write_text(json.dumps(v, indent=2) + '\n')
    run('pub', 'get', '--enforce-lockfile')
    run('analyze', '--fatal-infos')
    run_flutter_test(flutter, cwd=CLIENT, windows=args.target == 'windows')
    if args.target == 'windows':
        run('build', 'windows', '--release',
            '--target=test/windows_accessibility_smoke.dart',
            f'--build-name={v["version"]}', f'--build-number={v["build"]}')
        run_accessibility_smoke(
            CLIENT / 'build/windows/x64/runner/Release/Resona.exe', CLIENT,
        )
    command = ['build', 'apk' if args.target == 'android' else 'windows', '--release',
               f'--build-name={v["version"]}', f'--build-number={v["build"]}']
    run(*command)
    out.parent.mkdir(exist_ok=True)
    if args.target == 'android':
        sdk = os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT')
        if not sdk:
            raise SystemExit('ANDROID_HOME is required to verify the built APK version.')
        analyzer = Path(sdk) / 'cmdline-tools/latest/bin' / ('apkanalyzer.bat' if os.name == 'nt' else 'apkanalyzer')
        apk = CLIENT / 'build/app/outputs/flutter-apk/app-release.apk'
        for field, expected in [('version-name', v['version']), ('version-code', str(v['build']))]:
            actual = subprocess.check_output([str(analyzer), 'manifest', field, str(apk)], text=True).strip()
            if actual != expected:
                raise SystemExit(f'APK {field} mismatch: {actual} != {expected}')
        shutil.copy2(apk, out)
        if preview:
            print('PREVIEW: APK uses a development certificate; configure signing secrets for updateable releases.')
    else:
        bundle = CLIENT / 'build/windows/x64/runner/Release'
        exe = bundle / 'Resona.exe'
        actual = windows_product_version(exe)
        if actual != f'{v["version"]}+{v["build"]}':
            raise SystemExit(f'Windows version mismatch: {actual}')
        build = CLIENT / 'build/windows/x64'
        cmake = next(line.split('=', 1)[1] for line in
                     (build / 'CMakeCache.txt').read_text().splitlines()
                     if line.startswith('CMAKE_COMMAND:INTERNAL='))
        subprocess.run([cmake, '--build', str(build),
                        '--config', 'Release', '--target', 'resona_desktop_tests'], check=True)
        subprocess.run([str(build / 'tests/Release/resona_desktop_tests.exe')],
                       env={**os.environ, 'PATH': str(bundle) + os.pathsep + os.environ.get('PATH', '')},
                       check=True)
        with exe.open('rb') as binary:
            binary.seek(0x3C)
            offset = int.from_bytes(binary.read(4), 'little')
            binary.seek(offset)
            if binary.read(6) != b'PE\0\0\x64\x86':
                raise SystemExit('Windows application must be x64')
        for name in ('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll'):
            if not (bundle / name).is_file():
                raise SystemExit(f'Missing Windows runtime: {name}')
        stage = ROOT / '.build/windows-stage'
        shutil.rmtree(stage, ignore_errors=True)
        shutil.copytree(bundle, stage)
        for name in ('LICENSE', 'THIRD_PARTY.md'):
            shutil.copy2(ROOT / name, stage / name)
        (stage / 'VERSION.json').write_text(json.dumps(v, indent=2) + '\n', encoding='utf-8')
        quad = f'{v["version"]}.{v["build"]}'
        compile_installer(stage, out, quad)
        if windows_product_version(out) != quad:
            raise SystemExit('Windows installer version mismatch')
        verify_windows_upgrade(out, stage, v)
    checksum = hashlib.sha256(out.read_bytes()).hexdigest()
    out.with_suffix(out.suffix + '.sha256').write_text(f'{checksum}  {out.name}\n')
    print(out.name, checksum)


def windows_product_version(path):
    quoted = str(path).replace("'", "''")
    return subprocess.check_output([
        'powershell', '-NoProfile', '-Command',
        f"(Get-Item -LiteralPath '{quoted}').VersionInfo.ProductVersion",
    ], text=True).strip()


def inno_compiler():
    candidates = [os.environ.get('ISCC', ''),
                  r'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
                  r'C:\Program Files\Inno Setup 6\ISCC.exe']
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return candidate
    found = shutil.which('ISCC')
    if found:
        return found
    raise SystemExit('Inno Setup 6.7.1 or newer is required to build the Windows installer.')


def compile_installer(source, output, app_version):
    subprocess.run([
        inno_compiler(), f'/DAppVersion={app_version}', f'/DSourceDir={source}',
        f'/DOutputDir={output.parent}', f'/DOutputBase={output.stem}',
        str(CLIENT / 'windows/installer.iss'),
    ], check=True)


def run_installer(installer, log, directory=None):
    command = [str(installer), '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', f'/LOG={log}']
    if directory is not None:
        command.append(f'/DIR={directory}')
    completed = subprocess.run(command, timeout=180)
    if completed.returncode and log.is_file():
        text = '\n'.join(log.read_text(encoding='utf-8-sig', errors='replace').splitlines()[-30:])
        encoding = sys.stdout.encoding or 'utf-8'
        print(text.encode(encoding, errors='backslashreplace').decode(encoding))
    return completed.returncode


def verify_windows_upgrade(installer, source, v):
    """Exercise a previous registered installation, repair, downgrade and uninstall."""
    import winreg

    key = r'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{8F3A1C2E-6B47-4D91-9E5A-2C7B0A4D6F18}_is1'
    # These integration checks install software; run them only on disposable CI runners.
    if os.environ.get('GITHUB_ACTIONS') != 'true':
        print('Windows install/upgrade checks run on the disposable GitHub Actions runner.')
        return
    with tempfile.TemporaryDirectory(prefix='resona-upgrade-') as directory:
        root = Path(directory)
        old = root / 'old'
        old.mkdir()
        (old / 'Resona.exe').write_bytes(b'previous application fixture')
        (old / 'VERSION.json').write_text('{"version":"0.0.0","build":1}\n')
        previous = root / 'previous.exe'
        compile_installer(old, previous, '0.0.0.1')
        app = root / 'installed'
        try:
            if run_installer(previous, root / 'install.log', app) != 0:
                raise SystemExit('Previous Windows installation failed')
            marker = app / 'kept-by-upgrade.txt'
            marker.write_text('preserved', encoding='utf-8')
            # Omit /DIR: the new installer must discover the existing custom path.
            if run_installer(installer, root / 'upgrade.log') != 0:
                raise SystemExit('Windows upgrade failed')
            for path in source.rglob('*'):
                if path.is_file() and path.suffix.lower() != '.pdb':
                    if (app / path.relative_to(source)).read_bytes() != path.read_bytes():
                        raise SystemExit(f'Upgrade installed different bytes: {path.name}')
            if marker.read_text(encoding='utf-8') != 'preserved':
                raise SystemExit('Upgrade removed unrelated user files')
            if windows_product_version(app / 'Resona.exe') != f'{v["version"]}+{v["build"]}':
                raise SystemExit('Upgraded application version mismatch')
            with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, key, 0, winreg.KEY_READ | winreg.KEY_WOW64_64KEY) as entry:
                if winreg.QueryValueEx(entry, 'DisplayVersion')[0] != f'{v["version"]}.{v["build"]}':
                    raise SystemExit('Upgrade did not update the uninstall registration')
            if run_installer(previous, root / 'downgrade.log') == 0:
                raise SystemExit('Older installer replaced a newer installation')
            if (app / 'Resona.exe').read_bytes() != (source / 'Resona.exe').read_bytes():
                raise SystemExit('Rejected downgrade changed application files')
            if run_installer(installer, root / 'repair.log') != 0:
                raise SystemExit('Same-version Windows repair failed')
        finally:
            uninstaller = app / 'unins000.exe'
            if uninstaller.is_file():
                subprocess.run([str(uninstaller), '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART'],
                               check=True, timeout=180)
        if (app / 'Resona.exe').exists() or not marker.exists():
            raise SystemExit('Uninstall did not remove the app while preserving unrelated files')
        try:
            with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, key, 0, winreg.KEY_READ | winreg.KEY_WOW64_64KEY):
                raise SystemExit('Uninstall left its registration behind')
        except FileNotFoundError:
            pass
        print('Verified Windows install, upgrade discovery, repair, downgrade protection and uninstall.')


if __name__ == '__main__':
    main()
