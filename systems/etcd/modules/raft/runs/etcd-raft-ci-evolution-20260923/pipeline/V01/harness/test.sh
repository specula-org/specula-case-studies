#!/usr/bin/env bash
set -euo pipefail
harness_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source_dir="$(cd -- "$harness_dir/../../source" && pwd)"
run_dir="$(cd -- "$source_dir/../.." && pwd)"
export TMPDIR="$run_dir/tmp/harness-generation"
export GOTMPDIR="$TMPDIR/go-tmp" GOCACHE="$run_dir/tmp/go-build-cache" GOMODCACHE="$run_dir/tmp/go-module-cache"
export GOFLAGS=-mod=readonly GOTOOLCHAIN=local GOTELEMETRY=off GOMAXPROCS=8
label="$(date -u +%Y%m%d-%H%M%S)-$$"
export SPECULA_TRACE_DIR="$harness_dir/logs/race-traces/$label"
export SPECULA_HARNESS_TMP="$TMPDIR/race-$label"
mkdir -p "$SPECULA_TRACE_DIR" "$SPECULA_HARNESS_TMP" "$GOTMPDIR"
cd -- "$source_dir"
timeout 10m go test -p 8 -count=1 ./... > "$harness_dir/logs/upstream-tests-$label.log" 2>&1
timeout 10m go test -p 8 -race -tags specula -run '^TestSpecula' -count=1 -timeout 8m . > "$harness_dir/logs/race-tests-$label.log" 2>&1
printf 'Upstream and harness race checks passed; logs use label %s\n' "$label"
