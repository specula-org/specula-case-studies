#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SHA="cc69461d902560bb5f4407a506f32cd154ede79d"
RUN_TMP="$(mktemp -d "${TMPDIR:-/tmp}/slatedb-byom-followup.XXXXXX")"

cleanup() {
  chmod -R u+w "$RUN_TMP" 2>/dev/null || true
  rm -rf "$RUN_TMP"
}
trap cleanup EXIT

if [[ -n "${SOURCE_REPO:-}" ]]; then
  SOURCE_REPO="$(cd "$SOURCE_REPO" && pwd)"
else
  SOURCE_REPO="$RUN_TMP/source"
  git clone --quiet --filter=blob:none https://github.com/slatedb/slatedb.git "$SOURCE_REPO"
  git -C "$SOURCE_REPO" checkout --quiet --detach "$TARGET_SHA"
fi

actual_sha="$(git -C "$SOURCE_REPO" rev-parse HEAD)"
if [[ "$actual_sha" != "$TARGET_SHA" ]]; then
  echo "Expected SlateDB $TARGET_SHA, got $actual_sha" >&2
  exit 1
fi
if [[ -n "$(git -C "$SOURCE_REPO" status --short --untracked-files=no)" ]]; then
  echo "SOURCE_REPO has tracked changes; use a clean checkout" >&2
  exit 1
fi

mkdir -p "$RUN_TMP/tmp"
export SOURCE_REPO
export TMPDIR="$RUN_TMP/tmp"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$RUN_TMP/cargo-target}"

timeout 10m "$SCRIPT_DIR/test_bugMC-1_external_compaction_conflict.sh"
timeout 15m "$SCRIPT_DIR/test_bugCR-6_custom_scheduler_l0_order.sh"

echo "SlateDB BYOM follow-up reproductions passed"
