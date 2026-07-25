#!/usr/bin/env bash
# apply.sh — apply round-4 trace harness instrumentation to the arc-swap artifact.
#
# This script is idempotent: it can be re-run safely.  It:
#   1. Copies the round-4 tla_trace.rs trace module into the artifact.
#   2. Copies the round-4 test scenarios into the artifact's tests/ directory.
#   3. Patches src/debt/list.rs to add the new
#      emit_reader_fallback_discard_node() call after self.node.take().
#
# The artifact already contains the round-3 instrumentation (emit calls inside
# strategy/hybrid.rs, debt/{mod,list,helping,fast}.rs, lib.rs).  Round 4 only
# adds ONE new in-source emit (the F5 split point) plus updates to the trace
# module and test scenarios.

set -euo pipefail

# Resolve harness/ directory absolute path (the directory this script lives in).
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve artifact directory.  Defaults to the symlinked artifact in the case
# study layout: case-studies/arc-swap_4/artifact/arc-swap.
ARTIFACT="${ARC_SWAP_ARTIFACT:-${HARNESS_DIR}/../../artifact/arc-swap}"
if [ ! -d "${ARTIFACT}" ]; then
    echo "error: artifact directory not found: ${ARTIFACT}" >&2
    echo "       set ARC_SWAP_ARTIFACT to override" >&2
    exit 1
fi
ARTIFACT="$(cd "${ARTIFACT}" && pwd)"

echo "[apply] harness:  ${HARNESS_DIR}"
echo "[apply] artifact: ${ARTIFACT}"

# 1) Copy trace module.
mkdir -p "${ARTIFACT}/src"
cp "${HARNESS_DIR}/src/tla_trace.rs" "${ARTIFACT}/src/tla_trace.rs"
echo "[apply] copied tla_trace.rs into ${ARTIFACT}/src/"

# Make sure lib.rs declares `pub mod tla_trace;` (the artifact already has this
# from round 3, but we check defensively).
if ! grep -q "^pub mod tla_trace;" "${ARTIFACT}/src/lib.rs"; then
    # Insert after the first `pub mod cache;` (round 3 inserted it after access/cache).
    sed -i '/^pub mod cache;/a pub mod tla_trace;' "${ARTIFACT}/src/lib.rs"
    echo "[apply] added 'pub mod tla_trace;' to lib.rs"
else
    echo "[apply] lib.rs already declares pub mod tla_trace"
fi

# 2) Copy test scenarios.
mkdir -p "${ARTIFACT}/tests"
cp "${HARNESS_DIR}/src/tla_trace_scenarios.rs" "${ARTIFACT}/tests/tla_trace_scenarios.rs"
echo "[apply] copied tla_trace_scenarios.rs into ${ARTIFACT}/tests/"

# 3) Patch list.rs to add the round-4 emit_reader_fallback_discard_node().
LIST_RS="${ARTIFACT}/src/debt/list.rs"
if [ ! -f "${LIST_RS}" ]; then
    echo "error: cannot find ${LIST_RS}" >&2
    exit 1
fi

if grep -q "emit_reader_fallback_discard_node" "${LIST_RS}"; then
    echo "[apply] list.rs already has emit_reader_fallback_discard_node()"
else
    # Insert the emit call directly after self.node.take() inside new_helping.
    # The match is unique (single occurrence in the file).
    LIST_RS="${LIST_RS}" python3 - <<'PYEOF'
import os
p = os.environ["LIST_RS"]
src = open(p).read()
needle = "            self.node.take();\n"
add    = "            self.node.take();\n            crate::tla_trace::emit_reader_fallback_discard_node();\n"
if src.count(needle) != 1:
    raise SystemExit("expected exactly 1 occurrence of self.node.take(), found " + str(src.count(needle)))
src = src.replace(needle, add, 1)
open(p, "w").write(src)
print("[apply] inserted emit_reader_fallback_discard_node() after self.node.take()")
PYEOF
fi

echo "[apply] OK"
