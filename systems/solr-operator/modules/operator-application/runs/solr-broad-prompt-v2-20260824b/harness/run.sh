#!/usr/bin/env bash
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="$(cd "$HARNESS_DIR/.." && pwd)"
SOURCE_DIR="$OUTPUT_DIR/../source"
TRACE_DIR="$OUTPUT_DIR/traces"
GO_BIN="${GO_BIN:-/usr/local/go/bin/go}"

export TRACE_DIR
mkdir -p "$TRACE_DIR"
find "$TRACE_DIR" -maxdepth 1 -type f -name '*.ndjson' -delete

bash "$HARNESS_DIR/apply.sh"

cd "$SOURCE_DIR"
timeout 300 "$GO_BIN" test ./internal/speculatrace -count=1
timeout 900 "$GO_BIN" test ./controllers -run '^TestTrace' -count=1 -v

echo "Trace files:"
found=0
for trace in "$TRACE_DIR"/*.ndjson; do
  [[ -e "$trace" ]] || continue
  found=1
  lines="$(wc -l < "$trace")"
  printf '%s %s lines\n' "$(basename "$trace")" "$lines"
done
if [[ "$found" -eq 0 ]]; then
  echo "No trace files were generated." >&2
  exit 1
fi
