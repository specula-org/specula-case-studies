#!/bin/bash
# Apply instrumentation to SONiC warm reboot source code.
#
# Two modes:
#   1. Python protocol driver (default) — no source modification needed
#   2. C++ source patches — for real SONiC build environments
#
# Usage:
#   cd .specula-output && bash harness/apply.sh [--cpp]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS_SRC="$SCRIPT_DIR/src"
PATCHES_DIR="$SCRIPT_DIR/patches"

# Artifact directories
SWSS_DIR="$(cd "$SCRIPT_DIR/../../artifact/sonic-swss" 2>/dev/null && pwd || true)"
SAIREDIS_DIR="$(cd "$SCRIPT_DIR/../../artifact/sonic-sairedis" 2>/dev/null && pwd || true)"

apply_cpp_patches() {
    echo "=== Applying C++ instrumentation patches ==="

    if [ -z "$SWSS_DIR" ] || [ ! -d "$SWSS_DIR" ]; then
        echo "ERROR: sonic-swss artifact not found at expected path"
        echo "Expected: $SCRIPT_DIR/../../artifact/sonic-swss"
        exit 1
    fi

    if [ -z "$SAIREDIS_DIR" ] || [ ! -d "$SAIREDIS_DIR" ]; then
        echo "ERROR: sonic-sairedis artifact not found at expected path"
        echo "Expected: $SCRIPT_DIR/../../artifact/sonic-sairedis"
        exit 1
    fi

    # Copy trace header to both repos
    echo "Copying tla_trace.h to sonic-swss and sonic-sairedis..."
    cp "$HARNESS_SRC/tla_trace.h" "$SWSS_DIR/orchagent/"
    cp "$HARNESS_SRC/tla_trace.h" "$SWSS_DIR/warmrestart/"
    cp "$HARNESS_SRC/tla_trace.h" "$SWSS_DIR/neighsyncd/"
    cp "$HARNESS_SRC/tla_trace.h" "$SAIREDIS_DIR/syncd/"

    # Apply git patch (best-effort; line numbers may drift)
    echo "Applying instrumentation patch..."
    if [ -f "$PATCHES_DIR/instrumentation.patch" ]; then
        # Try applying to sonic-swss
        cd "$SWSS_DIR"
        if git apply --check "$PATCHES_DIR/instrumentation.patch" 2>/dev/null; then
            git apply "$PATCHES_DIR/instrumentation.patch"
            echo "  sonic-swss: patch applied successfully"
        else
            echo "  sonic-swss: patch does not apply cleanly (line numbers may have drifted)"
            echo "  See harness/INSTRUMENTATION.md for manual instrumentation guide"
        fi

        # Try applying to sonic-sairedis
        cd "$SAIREDIS_DIR"
        if git apply --check "$PATCHES_DIR/instrumentation.patch" 2>/dev/null; then
            git apply "$PATCHES_DIR/instrumentation.patch"
            echo "  sonic-sairedis: patch applied successfully"
        else
            echo "  sonic-sairedis: patch does not apply cleanly"
            echo "  See harness/INSTRUMENTATION.md for manual instrumentation guide"
        fi
    fi

    echo "=== C++ patches applied ==="
    echo "To revert: cd artifact/sonic-swss && git checkout -- ."
    echo "           cd artifact/sonic-sairedis && git checkout -- ."
}

apply_python_driver() {
    echo "=== Python protocol driver — no source modification needed ==="
    echo "The Python driver exercises the warm reboot protocol using the"
    echo "exact state machine logic from the C++ source code."
    echo ""
    echo "Source files referenced:"
    echo "  orchdaemon.cpp:1012-1245  — freeze + restore protocol"
    echo "  warmRestartAssist.cpp     — cache reconciliation"
    echo "  Syncd.cpp:4591-4924       — INIT_VIEW / APPLY_VIEW"
    echo "  neighsyncd.cpp:42-86      — timer reconciliation"
}

if [ "${1:-}" = "--cpp" ]; then
    apply_cpp_patches
else
    apply_python_driver
fi
