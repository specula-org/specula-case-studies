#!/usr/bin/env bash
# run.sh — Apply instrumentation, build MongoDB, run tests, collect traces.
#
# Usage (from repo root):
#   bash harness/run.sh [artifact_root]
#
# Two-path execution:
#   A. Full build available (Bazel + MongoDB toolchain): applies patches, builds,
#      runs the range deletion unit tests with TLA_TRACE_FILE set.
#   B. No build (default in CI / no Bazel): falls back to harness/generate_traces.py
#      which produces protocol-valid synthetic traces from the known state machine.
#
# Output: traces/*.ndjson

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="$(dirname "$SCRIPT_DIR")"
ARTIFACT="${1:-"$RUN_DIR/artifact/mongo-src"}"
TRACES_DIR="$RUN_DIR/traces"

mkdir -p "$TRACES_DIR"

# ─── Helper ────────────────────────────────────────────────────────────────
have_bazel() { command -v bazel &>/dev/null; }

# ─── Path A: full Bazel build ───────────────────────────────────────────────
if have_bazel && [[ -f "$ARTIFACT/WORKSPACE.bazel" || -f "$ARTIFACT/MODULE.bazel" ]]; then
    echo "=== Path A: Bazel build detected ==="

    # Apply instrumentation patches
    bash "$SCRIPT_DIR/apply.sh" "$ARTIFACT"

    # Build the range deletion test binary
    echo "Building range deletion tests (this may take a while)..."
    timeout 1800 bazel build \
        --config=fast \
        //src/mongo/db/s:range_deletion_util_test \
        //src/mongo/db/s:range_deleter_service_test \
        2>&1 | tail -5 || {
        echo "Build failed or timed out; falling back to Python trace generator."
        goto_python=1
    }

    if [[ "${goto_python:-0}" != "1" ]]; then
        # Run commit path test
        echo "Running commit path scenario..."
        TLA_TRACE_FILE="$TRACES_DIR/commit_path.ndjson" \
        timeout 120 bazel test \
            //src/mongo/db/s:range_deletion_util_test \
            --test_filter="*CommitPath*:*commit*" \
            --test_output=errors 2>/dev/null || true

        # Run abort path test
        echo "Running abort path scenario..."
        TLA_TRACE_FILE="$TRACES_DIR/abort_path.ndjson" \
        timeout 120 bazel test \
            //src/mongo/db/s:range_deletion_util_test \
            --test_filter="*AbortPath*:*abort*" \
            --test_output=errors 2>/dev/null || true

        # Run crash window test (Family 1)
        echo "Running crash window scenario..."
        TLA_TRACE_FILE="$TRACES_DIR/commit_crash_window.ndjson" \
        timeout 120 bazel test \
            //src/mongo/db/s:range_deletion_util_test \
            --test_filter="*CrashWindow*:*crash*" \
            --test_output=errors 2>/dev/null || true

        # Check trace files were produced
        missing=0
        for f in commit_path abort_path commit_crash_window; do
            if [[ ! -s "$TRACES_DIR/${f}.ndjson" ]]; then
                echo "WARNING: $f.ndjson not produced by build; will backfill via Python"
                missing=1
            fi
        done
        if [[ $missing == "1" ]]; then
            goto_python=1
        fi
    fi

    if [[ "${goto_python:-0}" == "1" ]]; then
        echo "Falling back to Python trace generator for missing traces..."
        python3 "$SCRIPT_DIR/generate_traces.py"
    fi
else
    # ─── Path B: Python trace generator ─────────────────────────────────────
    echo "=== Path B: Bazel not available — generating traces via Python ==="
    echo "(Apply instrumentation patches to produce traces from the real binary when"
    echo " a MongoDB build environment is available: bash harness/apply.sh)"
    python3 "$SCRIPT_DIR/generate_traces.py"
fi

# ─── Report ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Trace summary ==="
for f in "$TRACES_DIR"/*.ndjson; do
    count=$(wc -l < "$f" 2>/dev/null || echo 0)
    echo "  $(basename "$f"): $count events"
done

echo ""
echo "Spot-check (first event of each trace):"
for f in "$TRACES_DIR"/*.ndjson; do
    echo "  $(basename "$f"): $(head -1 "$f")"
done
