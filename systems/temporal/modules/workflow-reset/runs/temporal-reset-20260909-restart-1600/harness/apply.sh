#!/usr/bin/env bash
set -euo pipefail
harness_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source_dir=${SOURCE_RESET:-/home/ubuntu/temporal-investigation-20260909/restart-20260909-1600/source-reset}
expected=0c010ce5fe8c0180aa7573c72fe8fc87c6df7025
[[ $(git -C "$source_dir" rev-parse HEAD) == "$expected" ]] || { echo 'Unexpected Temporal revision' >&2; exit 1; }
patch_file="$harness_dir/patches/instrumentation.patch"
if git -C "$source_dir" apply --reverse --check "$patch_file" 2>/dev/null; then
 echo 'Instrumentation patch already applied'
else
 git -C "$source_dir" apply --check "$patch_file"
 git -C "$source_dir" apply "$patch_file"
fi
python3 "$harness_dir/src/copy_sources.py" "$harness_dir" "$source_dir"
python3 - "$harness_dir/../spec/Trace.tla" <<'PY'
import sys
from pathlib import Path
p=Path(sys.argv[1]);s=p.read_text()
if 'e.tag = "temporal-reset"' in s:
 p.write_text(s.replace('e.tag = "temporal-reset"','e.tag = "trace"'))
else:
 assert 'e.tag = "trace"' in s, 'Unrecognized trace parser'
PY
