#!/usr/bin/env bash
# Reproduces Bug 3 (issue #76): downgrading the fast path's confirm-load
# from SeqCst to Acquire reintroduces a use-after-free in the reader.
#
# Strategy:
#   * Save src/strategy/hybrid.rs.
#   * Revert the fast confirm-load (line 52) from SeqCst to Acquire.
#   * Run tests/uaf_stress.rs (added by this case study) under miri.
#   * Restore src/strategy/hybrid.rs.
#
# Expected (post-revert): miri reports Undefined Behavior at every seed —
#   data race between a guard deref and Arc::drop_slow.
# Expected (current code): test passes cleanly.

set -u
cd "$(dirname "$0")"
ROOT="$(cd ../../artifact/arc-swap && pwd)"
SRC="$ROOT/src/strategy/hybrid.rs"
BACKUP="$(mktemp)"
cp "$SRC" "$BACKUP"
trap 'cp "$BACKUP" "$SRC"; rm -f "$BACKUP"' EXIT

python3 - "$SRC" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
text = p.read_text()
old = '        let confirm = storage.load(SeqCst);'
new = '        let confirm = storage.load(Acquire); // BUG REPRO #76'
if old not in text:
    sys.exit("could not find target line in hybrid.rs")
p.write_text(text.replace(old, new))
PY

cd "$ROOT"
echo "===== diff applied ====="
grep -n "let confirm = storage.load" src/strategy/hybrid.rs

echo
echo "===== miri run (seed=39) ====="
LOG=$(mktemp)
MIRIFLAGS="-Zmiri-disable-isolation -Zmiri-seed=39" \
    timeout 300 cargo +nightly miri test --test uaf_stress 2>&1 | tee "$LOG" | tail -40
if grep -q 'error: Undefined Behavior' "$LOG"; then status=1; else status=0; fi
rm -f "$LOG"
echo
echo "exit code: $status"
echo "(non-zero exit + 'error: Undefined Behavior' in output ⇒ bug reproduced)"
exit $status
