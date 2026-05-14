#!/usr/bin/env bash
# One-command trace collection for the CCC regalloc / liveness spec.
#
#   1. Apply instrumentation (idempotent).
#   2. Build the ccc crate in release mode.
#   3. Run all `tla_trace_scenarios::*` tests with TLA_TRACE_DIR pointing at
#      .specula-output/traces/.
#   4. Print a summary of trace files and line counts.
#
# Invoked from the case-study root as:
#     bash .specula-output/harness/run.sh
# or from anywhere via absolute paths.

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$(cd "$HARNESS_DIR/.." && pwd)"
ARTIFACT_DIR="${ARTIFACT_DIR:-$HARNESS_DIR/../../../ccc/artifact/claudes-c-compiler}"
TRACES_DIR="$OUT_DIR/traces"

mkdir -p "$TRACES_DIR"
rm -f "$TRACES_DIR"/*.ndjson

echo "==> Step 1: apply instrumentation"
bash "$HARNESS_DIR/apply.sh"

echo "==> Step 2: build ccc (release)"
cd "$ARTIFACT_DIR"
cargo build --lib --release

echo "==> Step 3: run trace scenarios"
TLA_TRACE_DIR="$TRACES_DIR" \
    cargo test --lib --release \
        backend::tla_trace_scenarios:: \
        -- --test-threads=1 --nocapture

echo "==> Step 4: trace summary"
if compgen -G "$TRACES_DIR/*.ndjson" > /dev/null; then
    for f in "$TRACES_DIR"/*.ndjson; do
        lines=$(wc -l < "$f")
        printf "  %-40s %6d lines\n" "$(basename "$f")" "$lines"
    done
else
    echo "  NO TRACES PRODUCED"
    exit 1
fi

echo "==> Done. Traces in $TRACES_DIR/"
