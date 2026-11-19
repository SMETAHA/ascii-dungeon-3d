#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
out="$root/ascii-dungeon-3d-v19.love"

python3 - "$root" "$out" <<'PY'
from pathlib import Path
import sys
from zipfile import ZIP_DEFLATED, ZipFile

root = Path(sys.argv[1])
output = Path(sys.argv[2])
excluded_dirs = {".git", ".github", "screenshots"}

with ZipFile(output, "w", compression=ZIP_DEFLATED, compresslevel=9) as archive:
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root)
        if path.is_dir() or any(part in excluded_dirs for part in relative.parts):
            continue
        if path == output or path.name in {"settings.cfg", "records.cfg"} or path.suffix == ".love":
            continue
        archive.write(path, relative.as_posix())

print(f"Built {output.name}")
PY
