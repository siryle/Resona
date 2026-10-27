#!/usr/bin/env python3
"""Produce reproducible Linux server archives from VERSION.json."""
import gzip
import hashlib
import io
import os
import subprocess
import tarfile
from version import ROOT, stem

os.chdir(ROOT)
dist = ROOT / "dist"
dist.mkdir(exist_ok=True)
go = os.environ.get("GO", "go")
for arch in ("amd64", "arm64"):
    binary = ROOT / ".build" / f"server-{arch}"
    binary.parent.mkdir(exist_ok=True)
    subprocess.run([go, "build", "-trimpath", "-buildvcs=false", "-ldflags=-s -w",
                    "-o", str(binary), "./cmd/resona"], env=dict(os.environ, CGO_ENABLED="0", GOOS="linux", GOARCH=arch), check=True)
    out = dist / f"Resona-server-{stem()}-linux-{arch}.tar.gz"
    buffer = io.BytesIO()
    with gzip.GzipFile(fileobj=buffer, mode="wb", mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode="w") as archive:
            for name, path, mode in [("resona", binary, 0o755), ("VERSION.json", ROOT / "VERSION.json", 0o644),
                                     ("LICENSE", ROOT / "LICENSE", 0o644), ("THIRD_PARTY.md", ROOT / "THIRD_PARTY.md", 0o644),
                                     ("SQLITE-LICENSES.txt", ROOT / "docs/licenses/sqlite.txt", 0o644)]:
                data = path.read_bytes()
                info = tarfile.TarInfo(name)
                info.size, info.mode, info.mtime = len(data), mode, 0
                archive.addfile(info, io.BytesIO(data))
    out.write_bytes(buffer.getvalue())
    out.with_suffix(out.suffix + ".sha256").write_text(f"{hashlib.sha256(out.read_bytes()).hexdigest()}  {out.name}\n")
    print(out.relative_to(ROOT))
