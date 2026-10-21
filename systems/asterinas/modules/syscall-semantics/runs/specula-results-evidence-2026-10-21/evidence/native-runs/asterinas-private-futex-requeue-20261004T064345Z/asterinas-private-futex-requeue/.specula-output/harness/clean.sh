#!/usr/bin/env bash
set -euo pipefail
h=$(cd -- "$(dirname -- "$0")" && pwd)
s=$(cd "$h/../../source" && pwd)
git -C "$s" apply --reverse --check "$h/patches/instrumentation.patch"
# Check generated files before changing either tracked or untracked files.
python3 - "$h" "$s" <<'PY'
import json,pathlib,subprocess,sys
h,s=map(pathlib.Path,sys.argv[1:])
owned=[('trace.rs','ostd/src/specula_trace.rs'),('probes.rs','kernel/core/src/specula_probes.rs'),('scenarios.c','test/initramfs/src/regression/process/specula_futex/scenarios.c'),('Makefile','test/initramfs/src/regression/process/specula_futex/Makefile')]
build=json.loads((h/'logs/instrumentation-identity.json').read_text())['build_id']
for src,dst in owned:
    expected=(h/'src'/src).read_text()
    if src=='probes.rs':expected=expected.replace('HARNESS_BUILD_ID',build)
    if (s/dst).read_text()!=expected:raise SystemExit(f'Preserved locally modified generated file: {dst}')
subprocess.run(['git','-C',str(s),'apply','--reverse',str(h/'patches/instrumentation.patch')],check=True)
for _,dst in owned:(s/dst).unlink()
PY
