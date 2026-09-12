#!/usr/bin/env bash
set -euo pipefail
harness_dir="$(cd "$(dirname "$0")" && pwd)"
source_dir="${SOURCE_DIR:-/home/ubuntu/temporal-investigation-20260909/parallel-20260910/source-matching}"
trace_dir="${SPECULA_TRACE_DIR:-$(dirname "$harness_dir")/traces}"
export SPECULA_HARNESS="$harness_dir" SPECULA_TRACE_DIR="$trace_dir"
mkdir -p "$harness_dir/build" "$harness_dir/logs" "$trace_dir"
exec 9>"$harness_dir/.run.lock"
flock -n 9 || { echo "Another harness run is active." >&2; exit 1; }
bash "$harness_dir/apply.sh" "$source_dir"
run_id="$(date -u +%Y%m%dT%H%M%S)-$$"
export SPECULA_RUN_ID="$run_id"
python3 "$harness_dir/provenance.py" "$source_dir" "$trace_dir" "$run_id"
cd "$source_dir"
timeout 900 go test -p 4 -tags test_dep -c -o "$harness_dir/build/matching.test" ./service/matching > "$harness_dir/logs/build.log" 2>&1
TEMPORAL_TEST_TIMEOUT=13m timeout 900 "$harness_dir/build/matching.test" -test.run '^TestSpeculaMatching' -test.count=1 -test.timeout=14m > "$harness_dir/logs/scenarios.log" 2>&1
python3 "$harness_dir/verify.py" "$trace_dir"
