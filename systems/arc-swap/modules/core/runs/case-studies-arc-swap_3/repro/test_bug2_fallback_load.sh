#!/usr/bin/env bash
# Reproduces Bug 2 (issue #198): downgrading the fallback path's
# storage.load from SeqCst to Acquire reintroduces the cross-variable
# UAF that commit d5dd00c fixed.
#
# Strategy:
#   * Save src/strategy/hybrid.rs.
#   * Revert the fallback storage.load (line 83) from SeqCst to Acquire.
#   * Run upstream tests/fallback_uaf.rs (the regression test the maintainer
#     added for #198) under miri with seed=39 — this is the seed that
#     originally triggered the Miri report.
#   * Restore src/strategy/hybrid.rs.
#
# Expected (post-revert): miri reports Undefined Behavior — data race between
#   a retag write on one thread (Arc drop) and a retag read on another thread
#   (Arc::clone inside Protected::into_inner).
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
old = '        let candidate = storage.load(SeqCst);'
new = '        let candidate = storage.load(Acquire); // BUG REPRO #198'
if old not in text:
    sys.exit("could not find target line in hybrid.rs")
p.write_text(text.replace(old, new))
PY

cd "$ROOT"
echo "===== diff applied ====="
grep -n "let candidate = storage.load" src/strategy/hybrid.rs

echo
echo "===== miri run (seed=39) ====="
LOG=$(mktemp)
MIRIFLAGS="-Zmiri-disable-isolation -Zmiri-seed=39" \
    timeout 300 cargo +nightly miri test \
        --features internal-test-strategies --test fallback_uaf 2>&1 | tee "$LOG" | tail -40
if grep -q 'error: Undefined Behavior' "$LOG"; then status=1; else status=0; fi
rm -f "$LOG"
echo
echo "exit code: $status"
echo "(non-zero exit + 'error: Undefined Behavior' in output ⇒ bug reproduced)"
exit $status
