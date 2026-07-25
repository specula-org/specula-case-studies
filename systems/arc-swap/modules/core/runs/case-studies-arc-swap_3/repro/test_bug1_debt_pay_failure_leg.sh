#!/usr/bin/env bash
# Reproduces Bug 1 (PR #195): downgrading Debt::pay's failure leg from
# Acquire to Relaxed reintroduces a use-after-free between a reader's
# guard and the writer's pay_all path.
#
# Prerequisite: rustup nightly with miri (`rustup +nightly component add miri`).
#
# Strategy:
#   * Save src/debt/mod.rs.
#   * Revert the failure leg of Debt::pay's compare_exchange (line 77) from
#     Acquire back to Relaxed (the pre-PR-#195 state).
#   * Compile & run tests/dynamic_threads.rs under miri with seed 4
#     (found by --many-seeds=0..32 sweep).
#   * Restore src/debt/mod.rs.
#
# Expected (post-revert): miri should report Undefined Behavior — data race
#   between an Arc deref on one thread and Arc::drop_slow on another thread.
# Expected (current code): test passes cleanly.

set -u
cd "$(dirname "$0")"
ROOT="$(cd ../../artifact/arc-swap && pwd)"
SRC="$ROOT/src/debt/mod.rs"
BACKUP="$(mktemp)"
cp "$SRC" "$BACKUP"
trap 'cp "$BACKUP" "$SRC"; rm -f "$BACKUP"' EXIT

python3 - "$SRC" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
text = p.read_text()
old = '.compare_exchange(ptr as usize, Self::NONE, AcqRel, Acquire)'
new = '.compare_exchange(ptr as usize, Self::NONE, AcqRel, Relaxed)  // BUG REPRO PR#195'
if old not in text:
    sys.exit("could not find target line in debt/mod.rs")
p.write_text(text.replace(old, new))
PY

cd "$ROOT"
echo "===== diff applied ====="
grep -n "compare_exchange(ptr as usize" src/debt/mod.rs

echo
echo "===== miri run (seed=4) ====="
LOG=$(mktemp)
MIRIFLAGS="-Zmiri-disable-isolation -Zmiri-seed=4" \
    timeout 300 cargo +nightly miri test --test dynamic_threads 2>&1 | tee "$LOG" | tail -40
if grep -q 'Undefined Behavior' "$LOG"; then
  status=1
else
  status=0
fi
rm -f "$LOG"
echo
echo "exit code: $status"
echo "(non-zero exit + 'error: Undefined Behavior' in output ⇒ bug reproduced)"
exit $status
