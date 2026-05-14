#!/bin/bash
# apply.sh — install trace instrumentation into the artifact tree.
#
# The artifact already ships the trace module (`src/tla_trace.rs`), the
# `tla-trace` cargo feature, and the `#[cfg(feature = "tla-trace")]` emit
# calls in `src/base.rs`. This script copies the canonical harness sources
# from `.specula-output/harness/src/` into the artifact, overwriting any
# stale copies. It is idempotent.
#
# Usage:  bash harness/apply.sh           # run from .specula-output/
#         bash apply.sh                    # or run from harness/

set -euo pipefail

# Locate the harness directory regardless of CWD
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_ROOT="$(cd "$SCRIPT_DIR/../../artifact/crossbeam/crossbeam-skiplist" && pwd)"

echo "Applying instrumentation to: $ARTIFACT_ROOT"

# 1. Install the trace module (overwrite OK; idempotent).
cp "$SCRIPT_DIR/src/tla_trace.rs" "$ARTIFACT_ROOT/src/tla_trace.rs"

# 2. Install the test scenarios.
cp "$SCRIPT_DIR/src/tla_scenarios.rs" "$ARTIFACT_ROOT/tests/tla_scenarios.rs"

# 3. Verify Cargo.toml has the tla-trace feature wired.
if ! grep -q '^tla-trace' "$ARTIFACT_ROOT/Cargo.toml"; then
    echo "ERROR: Cargo.toml is missing the 'tla-trace' feature. Add:"
    echo '    tla-trace = ["std"]'
    exit 1
fi

# 4. Verify lib.rs declares the module.
if ! grep -q 'pub mod tla_trace' "$ARTIFACT_ROOT/src/lib.rs"; then
    echo "ERROR: src/lib.rs is missing the tla_trace module declaration."
    exit 1
fi

# 5. Verify base.rs has the trace-feature instrumentation.
INSTR_COUNT=$(grep -c 'cfg(feature = "tla-trace")' "$ARTIFACT_ROOT/src/base.rs" || true)
if [ "$INSTR_COUNT" -lt 20 ]; then
    echo "ERROR: src/base.rs has only $INSTR_COUNT cfg(feature = \"tla-trace\") attrs."
    echo "Expected ~30+ — instrumentation is missing or partial."
    exit 1
fi

echo "OK: instrumentation in place ($INSTR_COUNT trace cfg sites in base.rs)."
