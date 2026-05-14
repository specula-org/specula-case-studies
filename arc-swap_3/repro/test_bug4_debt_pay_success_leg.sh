#!/usr/bin/env bash
# Reproduces Bug 4 (issue #204): downgrading Debt::pay's success leg from
# AcqRel back to Release breaks transitivity between the two legs and is the
# pre-cccf354 state.
#
# This is the bug variant whose miri reproduction is HARD on x86: the bug was
# originally identified through formal C++ memory model analysis (#200), not a
# miri run. On x86, miri's TSO-leaning weak-memory emulation tends to be too
# strong to expose the lost transitivity edge between the two CAS legs. We
# document this honestly: the script attempts the run with multi-seed sweeping
# and reports whatever miri produces.
#
# Strategy:
#   * Save src/debt/mod.rs.
#   * Revert the success leg of Debt::pay's compare_exchange (line 77) from
#     AcqRel back to Release.
#   * Run tests/dynamic_threads.rs under miri with --many-seeds=0..32.
#   * Restore src/debt/mod.rs.

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
new = '.compare_exchange(ptr as usize, Self::NONE, Release, Acquire)  // BUG REPRO #204'
if old not in text:
    sys.exit("could not find target line in debt/mod.rs")
p.write_text(text.replace(old, new))
PY

cd "$ROOT"
echo "===== diff applied ====="
grep -n "compare_exchange(ptr as usize" src/debt/mod.rs

echo
echo "===== miri run (--many-seeds=0..32) ====="
LOG=$(mktemp)
MIRIFLAGS="-Zmiri-disable-isolation -Zmiri-many-seeds=0..32" \
    timeout 600 cargo +nightly miri test --test dynamic_threads 2>&1 | tee "$LOG" | tail -40
if grep -q 'error: Undefined Behavior' "$LOG"; then status=1; else status=0; fi
rm -f "$LOG"
echo
echo "exit code: $status"
echo "(non-zero exit + 'error: Undefined Behavior' in output ⇒ bug reproduced)"
echo "(zero exit ⇒ miri did not catch the bug under x86 weak-memory emulation;"
echo " the historical fix in cccf354 still stands by formal proof in #200)"
exit $status
