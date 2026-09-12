#!/usr/bin/env bash
set -euo pipefail
harness_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source_dir=${SOURCE_RESET:-/home/ubuntu/temporal-investigation-20260909/restart-20260909-1600/source-reset}
python3 - "$harness_dir" "$source_dir" <<'PY'
import sys
from pathlib import Path
harness,source=map(Path,sys.argv[1:])
files={'trace.go':'common/resettrace/trace.go','sql_observer.go':'common/persistence/sql/reset_trace.go','mutable_observer.go':'service/history/workflow/reset_trace.go','history_observer.go':'service/history/historybuilder/reset_trace.go','scenarios_test.go':'tests/reset_trace_test.go'}
for src,dst in files.items():
 p=source/dst
 assert p.read_bytes()==(harness/'src'/src).read_bytes(),f'Refusing to remove modified file: {p}'
PY
git -C "$source_dir" apply --reverse --check "$harness_dir/patches/instrumentation.patch"
git -C "$source_dir" apply --reverse "$harness_dir/patches/instrumentation.patch"
rm -- "$source_dir/common/resettrace/trace.go" "$source_dir/common/persistence/sql/reset_trace.go" "$source_dir/service/history/workflow/reset_trace.go" "$source_dir/service/history/historybuilder/reset_trace.go" "$source_dir/tests/reset_trace_test.go"
