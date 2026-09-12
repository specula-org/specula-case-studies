#!/usr/bin/env bash
set -euo pipefail
harness_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
output_dir=$(cd -- "$harness_dir/.." && pwd)
source_dir=${SOURCE_RESET:-/home/ubuntu/temporal-investigation-20260909/restart-20260909-1600/source-reset}
export SOURCE_RESET="$source_dir"
export GOMAXPROCS=${GOMAXPROCS:-8}
export RESET_TRACE_SQLITE_FILE=1
export TMPDIR="$harness_dir/build/tmp"
export GOTMPDIR="$TMPDIR"
export RESET_TRACE_RAW_DIR="$harness_dir/evidence/raw"
mkdir -p "$RESET_TRACE_RAW_DIR" "$output_dir/traces" "$harness_dir/build" "$TMPDIR"
bash "$harness_dir/apply.sh"
(
 cd "$source_dir"
 timeout 900 go test -tags test_dep -p 8 -c ./tests -o "$harness_dir/build/reset-trace.test"
) > "$harness_dir/evidence/build.log" 2>&1
python3 "$harness_dir/src/manifest.py" "$harness_dir" "$source_dir"
scenarios=(same-replay response-loss missing-rejected missing-commit-lost can-chain competing-start base-rejected base-commit-lost)
for scenario in "${scenarios[@]}"; do
 export RESET_TRACE_SCENARIO="$scenario"
 (
  cd "$source_dir"
  timeout 180 "$harness_dir/build/reset-trace.test" -test.run '^TestWorkflowResetTestSuite$/^TestTraceReset$' -test.v -test.timeout 150s -test.parallel 1 -persistenceType=sql -persistenceDriver=sqlite
 ) > "$harness_dir/evidence/$scenario.test.log" 2>&1
 python3 "$harness_dir/src/normalize.py" "$RESET_TRACE_RAW_DIR/$scenario.jsonl" "$output_dir/traces/$scenario.ndjson"
done
wc -l "$output_dir"/traces/*.ndjson
validation_status=0
python3 "$harness_dir/src/validate.py" "$output_dir" || validation_status=$?
python3 "$harness_dir/src/summarize.py" "$harness_dir"
exit "$validation_status"
