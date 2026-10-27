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
        actual = windows_product_version(exe)
        if actual != f'{v["version"]}+{v["build"]}':
            raise SystemExit(f'Windows version mismatch: {actual}')
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
        print('\n'.join(log.read_text(encoding='utf-8', errors='replace').splitlines()[-30:]))
    return completed.returncode


def verify_windows_upgrade(installer, source, v):
    """Exercise a previous registered installation, repair, downgrade and uninstall."""
    import winreg
    import tempfile

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
