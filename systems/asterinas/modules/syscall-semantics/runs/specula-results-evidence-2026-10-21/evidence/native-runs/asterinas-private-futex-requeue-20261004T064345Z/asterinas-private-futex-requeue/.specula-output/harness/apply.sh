#!/usr/bin/env bash
set -euo pipefail
h=$(cd -- "$(dirname -- "$0")" && pwd)
s=$(cd "$h/../../source" && pwd)
[[ $(git -C "$s" rev-parse HEAD) == 0c60537098f4c2949ad2d382aaf499de72263d76 ]]
if git -C "$s" apply --reverse --check "$h/patches/instrumentation.patch" 2>/dev/null; then
    :
else
    git -C "$s" apply --check "$h/patches/instrumentation.patch"
    git -C "$s" apply "$h/patches/instrumentation.patch"
fi
cp "$h/src/trace.rs" "$s/ostd/src/specula_trace.rs"
python3 "$h/identity.py" "$h" "$s"
mkdir -p "$s/test/initramfs/src/regression/process/specula_futex"
cp "$h/src/scenarios.c" "$h/src/Makefile" "$s/test/initramfs/src/regression/process/specula_futex/"
