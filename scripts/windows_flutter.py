"""Backport Flutter's OverlayPortal semantics fix to the pinned Windows SDK."""
from pathlib import Path
import subprocess

from version import ROOT


ENGINE = 'cf636b1dfb818dd6a3ff16e390e93b1a036969c8'
PATCH = ROOT / 'scripts/patches/flutter-3.47.8-semantics.patch'


def prepare_windows_flutter(flutter):
    sdk = Path(flutter).resolve().parent.parent
    engine = sdk / 'bin/internal/engine.version'
    if not engine.is_file() or engine.read_text().strip() != ENGINE:
        raise SystemExit('Windows requires Flutter 3.47.8 with the pinned semantics backport.')
    command = ['git', '-C', str(sdk), 'apply']
    patched = subprocess.run(
        [*command, '--reverse', '--check', str(PATCH)], capture_output=True,
    )
    if patched.returncode:
        subprocess.run([*command, '--check', str(PATCH)], check=True)
        subprocess.run([*command, str(PATCH)], check=True)
    print('Verified Flutter OverlayPortal semantics backport (flutter/flutter#193372).')
    return sdk
