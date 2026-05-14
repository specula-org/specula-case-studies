#!/usr/bin/env bash
# Reproduces Bug 5 (issue #164 family): downgrading LIST_HEAD.load from
# SeqCst to Acquire reintroduces the stale-snapshot UAF in writer's pay_all
# scan, the canonical "stale snapshot" pattern the brief identified.
#
# Strategy:
#   * Save src/debt/list.rs.
#   * Revert LIST_HEAD.load (line 102) from SeqCst to Acquire (pre-d849a2d).
#   * Run tests/dynamic_threads.rs (designed to spawn fresh threads while a
#     writer runs, forcing new nodes to be prepended mid-pay_all) under miri.
#   * Restore src/debt/list.rs.
#
# Expected (post-revert): miri reports Undefined Behavior at most seeds —
#   data race between rcu's read and Arc::drop_slow.
# Expected (current code): test passes cleanly.

set -u
cd "$(dirname "$0")"
ROOT="$(cd ../../artifact/arc-swap && pwd)"
SRC="$ROOT/src/debt/list.rs"
BACKUP="$(mktemp)"
cp "$SRC" "$BACKUP"
trap 'cp "$BACKUP" "$SRC"; rm -f "$BACKUP"' EXIT

python3 - "$SRC" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
text = p.read_text()
old = 'let mut current = unsafe { LIST_HEAD.load(SeqCst).as_ref() };'
new = 'let mut current = unsafe { LIST_HEAD.load(Acquire).as_ref() }; // BUG REPRO #164'
if old not in text:
    sys.exit("could not find target line in debt/list.rs")
p.write_text(text.replace(old, new))
PY

cd "$ROOT"
echo "===== diff applied ====="
grep -n "LIST_HEAD.load" src/debt/list.rs

echo
echo "===== miri run (seed=1) ====="
LOG=$(mktemp)
MIRIFLAGS="-Zmiri-disable-isolation -Zmiri-seed=1" \
    timeout 300 cargo +nightly miri test --test dynamic_threads 2>&1 | tee "$LOG" | tail -40
if grep -q 'error: Undefined Behavior' "$LOG"; then status=1; else status=0; fi
rm -f "$LOG"
echo
echo "exit code: $status"
echo "(non-zero exit + 'error: Undefined Behavior' in output ⇒ bug reproduced)"
exit $status
