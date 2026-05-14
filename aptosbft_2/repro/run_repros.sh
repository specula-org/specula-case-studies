#!/usr/bin/env bash
#
# Top-level runner for the aptosbft_2 bug reproductions.
# Executes the Rust reproduction tests in safety-rules and the storage-backend
# precondition check, capturing all output to test_output.txt.

set -euo pipefail

REPRO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APTOS_CORE="${REPRO_DIR}/../../artifact/aptos-core"

OUT="${REPRO_DIR}/test_output.txt"
: > "${OUT}"

log() {
    echo "$@" | tee -a "${OUT}"
}

log "############################################################"
log "# aptosbft_2 bug reproductions"
log "# $(date -u +%FT%TZ)"
log "############################################################"

log
log "==> Step 1: Rust reproduction tests (cargo test)"
log
cd "${APTOS_CORE}"
# Use a generous timeout — the safety-rules build can take a few minutes from
# scratch. Reproduction tests themselves are millisecond-fast.
timeout 600 cargo test -p aptos-safety-rules --lib repro_bugs -- --nocapture 2>&1 | tee -a "${OUT}"

log
log "==> Step 2: OnDiskStorage durability precondition (no-fsync)"
log
bash "${REPRO_DIR}/test_bug1_on_disk_storage_no_fsync.sh" 2>&1 | tee -a "${OUT}"

log
log "############################################################"
log "# Done. Combined output captured to ${OUT}"
log "############################################################"
