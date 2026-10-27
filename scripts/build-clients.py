#!/usr/bin/env python3
"""Build Flutter clients from VERSION.json, then package and checksum them."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import zipfile
from version import ROOT, stem, version

CLIENT = ROOT / 'clients/resona'


def output_name(target, preview=False):
    if target == 'android':
        return f'Resona-Android-{stem()}{"-preview" if preview else ""}.apk'
    return f'Resona-Windows-{stem()}-x64.zip'


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
        actual = subprocess.check_output([
            'powershell', '-NoProfile', '-Command',
            f"(Get-Item -LiteralPath '{str(exe).replace(chr(39), chr(39)*2)}').VersionInfo.ProductVersion"
        ], text=True).strip()
        if actual != f'{v["version"]}+{v["build"]}':
            raise SystemExit(f'Windows version mismatch: {actual}')
        with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as archive:
            for path in sorted(bundle.rglob('*')):
                if path.is_file():
                    archive.write(path, Path('Resona') / path.relative_to(bundle))
            for name in ('LICENSE', 'THIRD_PARTY.md'):
                archive.write(ROOT / name, 'Resona/' + name)
            archive.writestr('Resona/VERSION.json', json.dumps(v, indent=2) + '\n')
    checksum = hashlib.sha256(out.read_bytes()).hexdigest()
    out.with_suffix(out.suffix + '.sha256').write_text(f'{checksum}  {out.name}\n')
    print(out.name, checksum)


if __name__ == '__main__':
    main()
