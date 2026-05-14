#!/bin/bash
# Reproduction runner for Specula-found Mysticeti consensus bugs.
#
# Usage:  ./run_repro.sh        (runs both reproductions, restores lib.rs)
#         ./run_repro.sh bug1   (runs just Bug 1)
#         ./run_repro.sh bug2   (runs just Bug 2)
#
# Both reproductions are Rust tests that link into the consensus-core
# crate via a temporary #[path] mod statement in lib.rs. The lib.rs is
# restored on exit (even on Ctrl-C) via trap.

set -uo pipefail

REPRO_DIR="$(cd "$(dirname "$0")" && pwd)"
SUI_REPO="$REPRO_DIR/../../artifact/sui"
LIB_RS="$SUI_REPO/consensus/core/src/lib.rs"
BACKUP="$REPRO_DIR/.lib.rs.bak"

cleanup() {
    if [ -f "$BACKUP" ]; then
        mv "$BACKUP" "$LIB_RS"
        echo "[run_repro] restored $LIB_RS"
    fi
}
trap cleanup EXIT INT TERM

cp "$LIB_RS" "$BACKUP"

cat >> "$LIB_RS" <<'EOF'

// SPECULA reproduction tests — temporary insertion by run_repro.sh.
#[cfg(test)]
#[path = "../../../../../.specula-output/repro/test_bug1_find_supported_block.rs"]
mod repro_bug1_find_supported_block;

#[cfg(test)]
#[path = "../../../../../.specula-output/repro/test_bug2_force_propose.rs"]
mod repro_bug2_force_propose;
EOF

which=${1:-both}
filter=""
case "$which" in
    bug1) filter="repro_bug1" ;;
    bug2) filter="repro_bug2" ;;
    both) filter="repro_bug" ;;
    *) echo "usage: $0 [bug1|bug2|both]" >&2; exit 2 ;;
esac

cd "$SUI_REPO"
echo "[run_repro] running: cargo test -p consensus-core --lib $filter -- --nocapture"
timeout 600 cargo test -p consensus-core --lib "$filter" -- --nocapture
