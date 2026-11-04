#!/usr/bin/env python3
"""Build the WinUI 3 Windows client from VERSION.json, then package it."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

from version import ROOT, stem, version

CLIENT = ROOT / "clients/windows"


def find_msbuild():
    vswhere = Path(
        r"C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe"
    )
    if vswhere.is_file():
        result = subprocess.check_output(
            [
                str(vswhere),
                "-latest",
                "-products",
                "*",
                "-requires",
                "Microsoft.Component.MSBuild",
                "-find",
                r"MSBuild\**\Bin\MSBuild.exe",
            ],
            text=True,
        ).strip()
        if result:
            return Path(result.splitlines()[0])
    found = shutil.which("msbuild")
    if found:
        return Path(found)
    raise SystemExit(
        "Visual Studio 2022 Build Tools with the WinUI build tools component "
        "(Microsoft.VisualStudio.ComponentGroup.UWP.BuildTools) is required."
    )


def prepare_dotnet():
    local = ROOT / ".tools/dotnet"
    if (local / "dotnet.exe").is_file():
        env = os.environ.copy()
        env["DOTNET_ROOT"] = str(local)
        env["PATH"] = str(local) + os.pathsep + env.get("PATH", "")
        return env
    return os.environ.copy()


def find_iscc():
    candidates = [
        os.environ.get("ISCC", ""),
        r"C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
        r"C:\Program Files\Inno Setup 6\ISCC.exe",
    ]
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return Path(candidate)
    found = shutil.which("ISCC")
    if found:
        return Path(found)
    raise SystemExit("Inno Setup 6.7.1 or newer is required to build the Windows installer.")


def main():
    v = version()
    stem_value = stem()
    env = prepare_dotnet()
    msbuild = find_msbuild()

    output = ROOT / "dist" / f"Resona-Windows-{stem_value}-x64.exe"
    if output.exists():
        raise SystemExit(f"{output.name} already exists; verify and reuse it, or bump VERSION.json.")

    stage = ROOT / ".build/windows-stage"
    shutil.rmtree(stage, ignore_errors=True)

    version_quad = f"{v['version']}.{v['build']}"
    command = [
        str(msbuild),
        str(CLIENT / "Resona.Windows.csproj"),
        "/restore",
        "/t:Build",
        "/p:Configuration=Release",
        "/p:Platform=x64",
        "/p:RuntimeIdentifier=win-x64",
        "/p:SelfContained=true",
        f"/p:Version={v['version']}",
        f"/p:AssemblyVersion={version_quad}",
        f"/p:FileVersion={version_quad}",
        f"/p:InformationalVersion={v['version']}+{v['build']}",
        "/v:minimal",
    ]
    subprocess.run(command, cwd=ROOT, env=env, check=True)

    bundle = (
        CLIENT
        / "bin/x64/Release/net8.0-windows10.0.19041.0/win-x64"
    )
    shutil.copytree(bundle, stage)

    for name in ("LICENSE", "THIRD_PARTY.md"):
        shutil.copy2(ROOT / name, stage / name)
    (stage / "VERSION.json").write_text(json.dumps(v, indent=2) + "\n", encoding="utf-8")

    exe = stage / "Resona.exe"
    if not exe.is_file():
        raise SystemExit("Publish did not produce Resona.exe.")

    with exe.open("rb") as binary:
        binary.seek(0x3C)
        offset = int.from_bytes(binary.read(4), "little")
        binary.seek(offset)
        if binary.read(6) != b"PE\0\0\x64\x86":
            raise SystemExit("Windows application must be x64.")

    for name in ("coreclr.dll", "hostfxr.dll"):
        if not (stage / name).is_file():
            raise SystemExit(f"Self-contained publish is missing {name}.")

    output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            str(find_iscc()),
            f"/DAppVersion={version_quad}",
            f"/DSourceDir={stage}",
            f"/DOutputDir={output.parent}",
            f"/DOutputBase={output.stem}",
            str(CLIENT / "installer.iss"),
        ],
        check=True,
    )

    checksum = hashlib.sha256(output.read_bytes()).hexdigest()
    output.with_suffix(output.suffix + ".sha256").write_text(
        f"{checksum}  {output.name}\n", encoding="utf-8"
    )
    print(output.name, checksum)


if __name__ == "__main__":
    main()
