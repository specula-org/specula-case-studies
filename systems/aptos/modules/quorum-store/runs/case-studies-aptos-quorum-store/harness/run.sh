#!/usr/bin/env bash
# run.sh -- One-command harness pipeline:
#   1. Apply trace instrumentation to artifact source.
#   2. Build the consensus crate's tests.
#   3. Run the trace scenarios, each writing its own NDJSON file.
#   4. Print a summary of trace line counts per file.

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_DIR="$(cd "${HARNESS_DIR}/../../artifact/aptos-core" && pwd)"
TRACES_DIR="$(cd "${HARNESS_DIR}/.." && pwd)/traces"

# Step 1: instrument.
bash "${HARNESS_DIR}/apply.sh"

# Step 2: ensure traces dir exists and is empty for a clean run.
mkdir -p "${TRACES_DIR}"
rm -f "${TRACES_DIR}"/*.ndjson

# Step 3: build + run scenarios. Single-threaded so the global trace state
# does not interleave between scenarios.
cd "${ARTIFACT_DIR}"

echo "[run.sh] building aptos-consensus tests..."
# Cap build at 20 min; concurrent rustc can hang on huge Aptos workspaces.
timeout 1500 cargo test \
  -p aptos-consensus \
  --no-run \
  --tests \
  -- 2>&1 | tail -40

echo "[run.sh] running trace scenarios..."
APTOS_QS_TLA_TRACE_DIR="${TRACES_DIR}" \
  timeout 600 cargo test \
  -p aptos-consensus \
  quorum_store::tests::tla_trace_scenario_test \
  -- --test-threads=1 --nocapture 2>&1 | tail -120

# Step 4: report.
echo ""
echo "[run.sh] trace files:"
shopt -s nullglob
files=("${TRACES_DIR}"/*.ndjson)
if [[ ${#files[@]} -eq 0 ]]; then
  echo "  (none -- check cargo output above for failures)"
  exit 2
fi
for f in "${files[@]}"; do
  printf "  %-50s %s lines\n" "$(basename "$f")" "$(wc -l < "$f")"
done

echo ""
echo "[run.sh] event coverage per file:"
for f in "${files[@]}"; do
  echo "  $(basename "$f"):"
  python3 -c "
import json, sys
from collections import Counter
counts = Counter()
with open(sys.argv[1]) as fh:
    for line in fh:
        try:
            o = json.loads(line)
        except Exception:
            continue
        if o.get('tag') == 'trace':
            counts[o['event']['name']] += 1
for k, v in sorted(counts.items()):
    print(f'    {k}: {v}')
" "$f"
done
