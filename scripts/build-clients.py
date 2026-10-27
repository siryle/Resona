#!/usr/bin/env python3
"""Build Flutter clients from VERSION.json, then package and checksum them."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
from version import ROOT, stem, version

CLIENT = ROOT / 'clients/resona'


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
    run('test')
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
        expected = f'{v["version"]}+{v["build"]}'
        if windows_product_version(exe) != expected:
            raise SystemExit(f'Windows version mismatch: {windows_product_version(exe)}')
        stage = ROOT / '.build' / 'windows-stage'
        if stage.exists():
            shutil.rmtree(stage)
        shutil.copytree(bundle, stage)
        for name in ('LICENSE', 'THIRD_PARTY.md'):
            shutil.copy2(ROOT / name, stage / name)
        (stage / 'VERSION.json').write_text(json.dumps(v, indent=2) + '\n', encoding='utf-8')
        quad = f'{v["version"]}.{v["build"]}'
        subprocess.run([
            inno_compiler(),
            f'/DAppVersion={quad}',
            f'/DBuildNumber={v["build"]}',
            f'/DSourceDir={stage}',
            f'/DOutputDir={out.parent}',
            f'/DOutputBase={out.stem}',
            str(CLIENT / 'windows' / 'installer.iss'),
        ], check=True)
        if windows_product_version(out) != quad:
            raise SystemExit(f'Windows installer version mismatch: {windows_product_version(out)}')
        verify_windows_upgrade(out, exe, expected, v['build'])
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
    raise SystemExit('Inno Setup 6 (ISCC.exe) is required to build the Windows installer.')


def run_installer(installer, directory, log):
    return subprocess.run([
        str(installer), '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART',
        f'/DIR={directory}', f'/LOG={log}',
    ], check=False).returncode


def installer_failure(action, code, log):
    details = ''
    if log.is_file():
        details = '\n' + '\n'.join(log.read_text(encoding='utf-8', errors='replace').splitlines()[-40:])
    raise SystemExit(f'{action} failed with exit code {code}{details}')


def uninstall_registration():
    for view in ('64', '32'):
        completed = subprocess.run([
            'reg', 'query', r'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
            '/f', 'Resona', '/d', '/s', '/reg:' + view,
        ], text=True, capture_output=True)
        for line in completed.stdout.splitlines():
            key = line.strip()
            if key.startswith('HKEY_') and 'Uninstall' in key:
                return key, view
    raise SystemExit('Windows installer did not register an uninstall entry')


def verify_windows_upgrade(installer, source_exe, expected, build):
    root = Path(os.environ.get('TEMP', '.')) / f'resona-setup-{build}'
    app = root / 'app'
    shutil.rmtree(root, ignore_errors=True)
    app.mkdir(parents=True)
    code = run_installer(installer, app, root / 'install.log')
    if code != 0:
        installer_failure('Windows installation', code, root / 'install.log')
    installed = app / 'Resona.exe'
    if windows_product_version(installed) != expected:
        raise SystemExit('Installed Resona.exe version mismatch')
    if json.loads((app / 'VERSION.json').read_text(encoding='utf-8')) != version():
        raise SystemExit('Installed VERSION.json mismatch')
    marker = app / 'kept-by-upgrade.txt'
    marker.write_text('keep', encoding='utf-8')
    installed.write_bytes(b'not-the-app')
    code = run_installer(installer, app, root / 'upgrade.log')
    if code != 0:
        installer_failure('Windows upgrade', code, root / 'upgrade.log')
    if marker.read_text(encoding='utf-8') != 'keep' or not installed.read_bytes().startswith(b'MZ'):
        raise SystemExit('Upgrade did not replace the old program while preserving unrelated files')
    if installed.read_bytes() != source_exe.read_bytes():
        raise SystemExit('Upgrade installed different program bytes')
    key, view = uninstall_registration()
    subprocess.run(['reg', 'add', key, '/v', 'DisplayVersion', '/d', f'9.9.9.{int(build) + 1}', '/f', '/reg:' + view], check=True)
    code = run_installer(installer, app, root / 'downgrade.log')
    if code == 0:
        raise SystemExit('An older installer replaced a newer installation')
    subprocess.run([str(app / 'unins000.exe'), '/VERYSILENT', '/NORESTART'], check=True)
    if installed.exists():
        raise SystemExit('Uninstall left Resona.exe behind')

if __name__ == '__main__':
    main()
