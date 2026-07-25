#!/usr/bin/env bash
# Specula harness one-shot driver for Algorand BA*.
#
# Steps:
#   1. Apply instrumentation (apply.sh).
#   2. Make sure the libsodium fork is built (one-time, cached).
#   3. Run the trace scenarios via `go test`. Each scenario writes an
#      NDJSON file into .specula-output/traces/<scenario>.ndjson.
#   4. Print line counts and event-type histograms for each trace file.
#
# Reproducible with: `bash harness/run.sh` from .specula-output/.

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "$0")" && pwd)"
# harness/ lives under .specula-output/, and the artifact is at the case root.
CASE_DIR="$(cd "$HARNESS_DIR/../.." && pwd)"
OUT_DIR="$(cd "$HARNESS_DIR/.." && pwd)"
ARTIFACT_DIR="$CASE_DIR/artifact/go-algorand"
TRACE_DIR="$OUT_DIR/traces"
mkdir -p "$TRACE_DIR"

export PATH="/usr/local/go/bin:$PATH"
if ! command -v go >/dev/null 2>&1; then
  echo "run.sh: 'go' not on PATH" >&2
  exit 1
fi

echo "[run] step 1: apply instrumentation"
bash "$HARNESS_DIR/apply.sh"

echo "[run] step 2: ensure libsodium fork is built"
cd "$ARTIFACT_DIR"
if [ ! -f "crypto/libs/$(./scripts/ostype.sh)/$(./scripts/archtype.sh)/lib/libsodium.a" ]; then
  echo "[run] building libsodium-fork (first run only)..."
  make libsodium >/dev/null
fi

echo "[run] step 3: run trace scenarios under go test"
# Run scenarios sequentially so trace files don't collide. The trace module
# itself is mutex-protected, but Simulate uses a shared in-tree sqlite db
# filename which we want to keep one test at a time.
export SPECULA_TRACE_DIR="$TRACE_DIR"

# Run each scenario in its own go-test invocation. -count=1 disables the
# test cache so we always regenerate.
SCENARIOS=(
  TestTrace_NormalAgreement
  TestTrace_LargerCommittee
  TestTrace_ShortRun
  TestTrace_DiverseSeeds
)

for s in "${SCENARIOS[@]}"; do
  echo "[run]   $s ..."
  timeout 240 go test -count=1 -timeout 200s -run "^${s}$" ./agreement/agreementtest/ \
      || { echo "[run] scenario $s failed"; exit 1; }
done

echo "[run] step 4: trace summary"
cd "$OUT_DIR"
for f in "$TRACE_DIR"/*.ndjson; do
  if [ ! -f "$f" ]; then continue; fi
  lines=$(wc -l < "$f")
  echo "[trace] $f : $lines lines"
  python3 -c "
import json, sys
from collections import Counter
c = Counter()
with open('$f') as fh:
    for line in fh:
        try:
            ev = json.loads(line)['event']['name']
            c[ev] += 1
        except Exception:
            pass
for n, v in c.most_common():
    print(f'  {n}: {v}')
"
done

echo "[run] done. Traces in $TRACE_DIR"
