"""Backport Flutter's OverlayPortal semantics fixes to the pinned Windows SDK."""
from pathlib import Path
import subprocess

from version import ROOT


ENGINE = 'cf636b1dfb818dd6a3ff16e390e93b1a036969c8'
PATCH = ROOT / 'scripts/patches/flutter-3.47.8-semantics.patch'
SIBLINGS_PATCH = ROOT / 'scripts/patches/flutter-3.47.8-semantics-siblings.patch'
PATCHES = (PATCH, SIBLINGS_PATCH)


def _apply_patch(sdk, patch):
    command = ['git', '-C', str(sdk), 'apply']
    patched = subprocess.run(
        [*command, '--reverse', '--check', str(patch)], capture_output=True,
    )
    if patched.returncode:
        subprocess.run([*command, '--check', str(patch)], check=True)
        subprocess.run([*command, str(patch)], check=True)


def prepare_windows_flutter(flutter):
    sdk = Path(flutter).resolve().parent.parent
    engine = sdk / 'bin/internal/engine.version'
    if not engine.is_file() or engine.read_text().strip() != ENGINE:
        raise SystemExit('Windows requires Flutter 3.47.8 with the pinned semantics backport.')
    patches = (PATCH,) if PATCH != ROOT / 'scripts/patches/flutter-3.47.8-semantics.patch' else PATCHES
    for patch in patches:
        _apply_patch(sdk, patch)
    print('Verified Flutter OverlayPortal semantics backports (flutter/flutter#193372, #190431, #190344).')
    return sdk
