#!/usr/bin/env bash
set -euo pipefail

REPO="/home/ubuntu/Specula/runs/slatedb-dist-compaction-20260721-213543/slatedb-dist-compaction/.specula-output/confirmation/CR-2/worktree"

run_level() {
  local label="$1"
  shift
  echo "== ${label} =="
  echo "+ $*"
  timeout 10m "$@"
  echo
}

cd "$REPO"
export CARGO_TERM_COLOR=never

run_level \
  "Level 0 - normal coordinator and worker commit path" \
  env RUST_TEST_THREADS=1 cargo test -p slatedb test_should_persist_compactions_on_start_and_finish -- --nocapture

run_level \
  "Level 1 - timing/interleaving around manifest writes" \
  env RUST_TEST_THREADS=1 cargo test -p slatedb test_should_write_manifest_safely -- --nocapture

run_level \
  "Level 2 - injected crash window after manifest before .compactions" \
  env RUST_TEST_THREADS=1 cargo test -p slatedb test_recovery_after_manifest_commit_preserves_output_and_gc_safety -- --nocapture

echo "RESULT: the crash-window state stayed recovery-safe; restart retained the manifest output, marked the retained compaction Failed, and GC kept the live SST."
