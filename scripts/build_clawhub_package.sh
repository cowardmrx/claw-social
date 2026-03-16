#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
IGNORE_FILE="${CLAWHUB_IGNORE_FILE:-$ROOT_DIR/.clawhubignore}"
OUTPUT_DIR="${1:-$ROOT_DIR/dist}"

mkdir -p "$OUTPUT_DIR"

TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
PACKAGE_BASENAME="${CLAWHUB_PACKAGE_NAME:-$(basename "$ROOT_DIR")-clawhub-$TIMESTAMP.zip}"
PACKAGE_PATH="$OUTPUT_DIR/$PACKAGE_BASENAME"

python3 - "$ROOT_DIR" "$IGNORE_FILE" "$PACKAGE_PATH" <<'PY'
import fnmatch
import os
import stat
import sys
import zipfile
from pathlib import Path, PurePosixPath

root_dir = Path(sys.argv[1]).resolve()
ignore_file = Path(sys.argv[2]).resolve()
package_path = Path(sys.argv[3]).resolve()


def load_patterns(path: Path) -> list[str]:
    if not path.exists():
        return []
    patterns = []
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        patterns.append(line.replace("\\", "/"))
    return patterns


def matches_pattern(rel_path: str, pattern: str, is_dir: bool) -> bool:
    rel = PurePosixPath(rel_path)
    normalized = pattern.rstrip("/")

    if pattern.endswith("/"):
        return is_dir and (
            fnmatch.fnmatch(rel_path, normalized)
            or rel_path == normalized
            or rel_path.startswith(normalized + "/")
        )

    return fnmatch.fnmatch(rel_path, pattern) or rel_path == normalized


patterns = load_patterns(ignore_file)
included_files: list[Path] = []

for current_root, dir_names, file_names in os.walk(root_dir):
    current_path = Path(current_root)
    rel_dir = current_path.relative_to(root_dir).as_posix()
    if rel_dir == ".":
        rel_dir = ""

    kept_dirs = []
    for name in dir_names:
        rel_path = f"{rel_dir}/{name}" if rel_dir else name
        if any(matches_pattern(rel_path, pattern, True) for pattern in patterns):
            continue
        kept_dirs.append(name)
    dir_names[:] = kept_dirs

    for name in file_names:
        rel_path = f"{rel_dir}/{name}" if rel_dir else name
        if any(matches_pattern(rel_path, pattern, False) for pattern in patterns):
            continue
        path = root_dir / rel_path
        if path.resolve() == package_path:
            continue
        included_files.append(path)

package_path.parent.mkdir(parents=True, exist_ok=True)

with zipfile.ZipFile(package_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
    for path in sorted(included_files):
        rel_path = path.relative_to(root_dir).as_posix()
        info = zipfile.ZipInfo.from_file(path, arcname=rel_path)
        mode = stat.S_IMODE(path.stat().st_mode)
        info.external_attr = (mode & 0xFFFF) << 16
        with path.open("rb") as src:
            zf.writestr(info, src.read(), compress_type=zipfile.ZIP_DEFLATED)

print(f"Created package: {package_path}")
print(f"Included files: {len(included_files)}")
print(f"Ignore file: {ignore_file}")
PY
