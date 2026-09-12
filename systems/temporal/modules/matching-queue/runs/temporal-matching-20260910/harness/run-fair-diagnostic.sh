#!/usr/bin/env bash
set -euo pipefail
harness_dir="$(cd "$(dirname "$0")" && pwd)"
source_dir="${SOURCE_DIR:-/home/ubuntu/temporal-investigation-20260909/parallel-20260910/source-matching}"
evidence_dir="${SPECULA_FAIR_OUTPUT:-$(dirname "$harness_dir")/spec/output/fair-diagnostic-$(date -u +%Y%m%dT%H%M%S)}"
mkdir -p "$evidence_dir"
bash "$harness_dir/apply.sh" "$source_dir"
cd "$source_dir"
timeout 900 go test -p 4 -tags test_dep -c -o "$evidence_dir/matching.test" ./service/matching > "$evidence_dir/build.log" 2>&1
SPECULA_FAIR_EVIDENCE="$evidence_dir/reproduction.json" timeout 180 "$evidence_dir/matching.test" -test.run '^TestSpeculaFairLateCompletionSQLite$' -test.count=1 -test.timeout=120s > "$evidence_dir/reproduction.log" 2>&1
SPECULA_FAIR_CONTROL=1 SPECULA_FAIR_EVIDENCE="$evidence_dir/control.json" timeout 180 "$evidence_dir/matching.test" -test.run '^TestSpeculaFairLateCompletionSQLite$' -test.count=1 -test.timeout=120s > "$evidence_dir/control.log" 2>&1
