#!/usr/bin/env bash
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="$(cd "$HARNESS_DIR/.." && pwd)"
SOURCE_DIR="$OUTPUT_DIR/../source"
GOFMT_BIN="${GOFMT_BIN:-/usr/local/go/bin/gofmt}"

mkdir -p "$SOURCE_DIR/internal/speculatrace"
cp "$HARNESS_DIR/src/speculatrace/trace.go" "$SOURCE_DIR/internal/speculatrace/trace.go"
cp "$HARNESS_DIR/src/trace_scenarios_test.go" "$SOURCE_DIR/controllers/trace_scenarios_test.go"

if [[ -s "$HARNESS_DIR/patches/instrumentation.patch" ]]; then
  if git -C "$SOURCE_DIR" apply --check "$HARNESS_DIR/patches/instrumentation.patch" 2>/dev/null; then
    git -C "$SOURCE_DIR" apply "$HARNESS_DIR/patches/instrumentation.patch"
  elif git -C "$SOURCE_DIR" apply --reverse --check "$HARNESS_DIR/patches/instrumentation.patch" 2>/dev/null; then
    echo "Instrumentation patch already applied."
  else
    echo "Instrumentation patch does not apply cleanly; refusing to alter unrelated source changes." >&2
    exit 1
  fi
fi

"$GOFMT_BIN" -w \
  "$SOURCE_DIR/internal/speculatrace/trace.go" \
  "$SOURCE_DIR/controllers/trace_scenarios_test.go" \
  "$SOURCE_DIR/controllers/solr_pod_lifecycle_util.go" \
  "$SOURCE_DIR/controllers/solrbackup_controller.go" \
  "$SOURCE_DIR/controllers/util/backup_util.go" \
  "$SOURCE_DIR/controllers/util/solr_scale_util.go" \
  "$SOURCE_DIR/controllers/util/solr_security_util.go" \
  "$SOURCE_DIR/controllers/util/solr_update_util.go" \
  "$SOURCE_DIR/controllers/util/solr_util.go"
echo "Applied Solr Operator trace harness to $SOURCE_DIR"
