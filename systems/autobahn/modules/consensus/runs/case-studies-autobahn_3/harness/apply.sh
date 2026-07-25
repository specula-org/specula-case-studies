#!/usr/bin/env bash
# Apply (or verify) TLA+ trace instrumentation into the autobahn-artifact.
#
# Strategy: the harness files (tla_trace.rs trace module + trace_test.rs test
# scenarios) live in harness/src/ as a canonical copy.  The instrumentation
# patches to core.rs / lib.rs are already committed in the artifact tree
# (commit cb2a415 + bf897ef).  This script:
#   1) Copies harness/src/tla_trace.rs and trace_test.rs into the artifact
#      tree, so any local edits to those files are picked up.
#   2) Verifies that lib.rs and core.rs already carry the in-tree wiring
#      (`pub mod tla_trace;` in lib.rs and `tla_trace::...` calls in core.rs).
#
# Run from .specula-output/ as `bash harness/apply.sh`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARTIFACT="${ROOT_DIR}/../artifact/autobahn-artifact"

if [[ ! -d "${ARTIFACT}" ]]; then
    echo "ERROR: artifact not found at ${ARTIFACT}" >&2
    exit 1
fi

echo "[apply] Artifact:    ${ARTIFACT}"
echo "[apply] Harness src: ${SCRIPT_DIR}/src"

# 1) Drop the canonical harness sources into the artifact.
install -m 0644 "${SCRIPT_DIR}/src/tla_trace.rs" \
    "${ARTIFACT}/primary/src/tla_trace.rs"
install -m 0644 "${SCRIPT_DIR}/src/trace_test.rs" \
    "${ARTIFACT}/primary/src/tests/trace_test.rs"
echo "[apply] Copied tla_trace.rs and trace_test.rs"

# 2) Verify the existing wiring.  These edits are committed in the artifact
#    and we do not re-apply them here — but we fail loudly if they are gone.
if ! grep -q '^pub mod tla_trace;' "${ARTIFACT}/primary/src/lib.rs"; then
    echo "ERROR: primary/src/lib.rs is missing 'pub mod tla_trace;'" >&2
    echo "       Add the line to enable trace emission." >&2
    exit 1
fi
echo "[apply] lib.rs declares 'pub mod tla_trace;'"

if ! grep -q 'use crate::tla_trace;' "${ARTIFACT}/primary/src/core.rs"; then
    echo "ERROR: primary/src/core.rs is missing 'use crate::tla_trace;'" >&2
    exit 1
fi
if ! grep -q 'tla_trace::emit_send_prepare' "${ARTIFACT}/primary/src/core.rs"; then
    echo "ERROR: primary/src/core.rs has no emit_send_prepare call" >&2
    exit 1
fi
if ! grep -q '#\[path = "tests/trace_test.rs"\]' "${ARTIFACT}/primary/src/core.rs"; then
    echo "ERROR: primary/src/core.rs is missing the test_test.rs module attr" >&2
    exit 1
fi
echo "[apply] core.rs has the expected emit calls and test wiring"

# 3) Sanity check Cargo dependencies.  The instrumentation relies on
#    serde_json (already a primary dep) and serial_test for the
#    #[serial] tests.  Both are in primary/Cargo.toml since cb2a415.
for dep in serde_json serial_test; do
    if ! grep -q "^${dep} *=" "${ARTIFACT}/primary/Cargo.toml"; then
        echo "ERROR: primary/Cargo.toml missing ${dep} dependency" >&2
        exit 1
    fi
done
echo "[apply] primary/Cargo.toml has serde_json + serial_test"

echo "[apply] OK — instrumentation in place"
