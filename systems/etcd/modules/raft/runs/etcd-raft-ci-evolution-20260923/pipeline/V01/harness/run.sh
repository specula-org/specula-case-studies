#!/usr/bin/env bash
set -euo pipefail
harness_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
output_dir="$(cd -- "$harness_dir/.." && pwd)"
source_dir="$(cd -- "$harness_dir/../../source" && pwd)"
run_dir="$(cd -- "$source_dir/../.." && pwd)"
export SPECULA_TRACE_DIR="$output_dir/traces"
export SPECULA_HARNESS_TMP="$run_dir/tmp/harness-generation"
export TMPDIR="$SPECULA_HARNESS_TMP"
export GOTMPDIR="$SPECULA_HARNESS_TMP/go-tmp"
export GOCACHE="$run_dir/tmp/go-build-cache"
export GOMODCACHE="$run_dir/tmp/go-module-cache"
export GOTOOLCHAIN=local
export GOFLAGS=-mod=readonly
export GOTELEMETRY=off
export PYTHONDONTWRITEBYTECODE=1
mkdir -p "$SPECULA_TRACE_DIR" "$GOTMPDIR" "$GOCACHE" "$GOMODCACHE" "$harness_dir/logs"
run_label="$(date -u +%Y%m%d-%H%M%S)-$$"
archive="$harness_dir/logs/trace-batches/$run_label"
mkdir -p "$archive"
for trace in "$SPECULA_TRACE_DIR"/*.ndjson "$SPECULA_TRACE_DIR"/*.coverage.json; do
    [[ ! -f "$trace" ]] || cp -- "$trace" "$archive/"
done
bash "$harness_dir/apply.sh"
cd -- "$source_dir"
timeout 5m go build -tags specula ./... > "$harness_dir/logs/build-$run_label.log" 2>&1
timeout 10m go test -tags specula -run '^TestSpecula' -count=1 -timeout 8m -v . > "$harness_dir/logs/scenarios-$run_label.log" 2>&1
python3 "$output_dir/spec/trace_codec.py" "$SPECULA_TRACE_DIR"/*.ndjson
python3 "$harness_dir/audit.py"
wc -l "$SPECULA_TRACE_DIR"/*.ndjson
printf 'Build and scenario logs: %s/logs\n' "$harness_dir"
