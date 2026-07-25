#!/usr/bin/env bash
# run.sh — end-to-end: apply instrumentation, build the evidence package,
# run the trace scenarios, and report event counts in the collected traces.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPECULA_OUT="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT_DIR="${ARTIFACT_DIR:-/home/ubuntu/Specula/case-studies/cometbft/artifact/cometbft}"
TRACE_DIR="${TRACE_DIR:-$SPECULA_OUT/traces}"

export PATH="/usr/local/go/bin:$PATH"

echo "[run] step 1: apply instrumentation"
bash "$SCRIPT_DIR/apply.sh"

echo "[run] step 2: ensure trace dir exists and is clean"
mkdir -p "$TRACE_DIR"
rm -f "$TRACE_DIR"/*.ndjson

echo "[run] step 3: build the evidence package"
(
  cd "$ARTIFACT_DIR"
  timeout 240 go build ./evidence/...
)

echo "[run] step 4: run the Specula trace scenarios"
(
  cd "$ARTIFACT_DIR"
  TLA_TRACE_DIR="$TRACE_DIR" timeout 240 \
    go test -count=1 -run "TestTLATrace" ./evidence/
)

echo "[run] step 5: report"
echo
echo "trace files:"
ls -la "$TRACE_DIR"
echo
echo "line counts:"
wc -l "$TRACE_DIR"/*.ndjson 2>/dev/null || true
echo
echo "event coverage:"
grep -ho '"name":"[^"]*"' "$TRACE_DIR"/*.ndjson 2>/dev/null \
  | sort | uniq -c \
  | awk '{printf "  %4d  %s\n", $1, $2}'

echo
echo "[run] done."
