#!/usr/bin/env bash
set -euo pipefail
HARNESS_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
OUTPUT_DIR=$(cd -- "$HARNESS_DIR/.." && pwd)
SOURCE_DIR=${SOURCE_DIR:-/home/ubuntu/temporal-investigation-20260909/parallel-20260910/source-activity}
RUN_DIR=$(mktemp -d "$HARNESS_DIR/evidence/run-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
export SOURCE_DIR
export SPECULA_TRACE_ROOT="$RUN_DIR"
export HARNESS_TEST_PATTERN=${HARNESS_TEST_PATTERN:-'^TestSpeculaActivityTrace$'}
export GOMAXPROCS=${HARNESS_GOMAXPROCS:-16}
export GOTOOLCHAIN=${GOTOOLCHAIN:-go1.27.0}
export TMPDIR="$RUN_DIR/tmp" GOTMPDIR="$RUN_DIR/go-tmp"
mkdir -p "$TMPDIR" "$GOTMPDIR" "$RUN_DIR/traces" "$OUTPUT_DIR/traces"
printf '%s\n' "$RUN_DIR" > "$HARNESS_DIR/evidence/latest-run.txt"
bash "$HARNESS_DIR/apply.sh"
export SPECULA_PATCH_SHA256
SPECULA_PATCH_SHA256=$(sha256sum "$HARNESS_DIR/patches/instrumentation.patch" | cut -d ' ' -f 1)
cd "$SOURCE_DIR"
printf 'Building real Temporal functional tests; evidence: %s\n' "$RUN_DIR"
if timeout 900 go test -c -tags test_dep -o "$RUN_DIR/temporal-tests" ./tests > "$RUN_DIR/build.log" 2>&1; then
    printf 'Build passed.\n'
else
    rc=$?
    printf 'Build failed (exit %s); see %s/build.log\n' "$rc" "$RUN_DIR"
    exit "$rc"
fi
export SPECULA_BINARY_SHA256
SPECULA_BINARY_SHA256=$(sha256sum "$RUN_DIR/temporal-tests" | cut -d ' ' -f 1)
python3 "$HARNESS_DIR/provenance.py" "$RUN_DIR"
if timeout 600 "$RUN_DIR/temporal-tests" -test.run "$HARNESS_TEST_PATTERN" -test.v -test.timeout 540s -persistenceType=sql -persistenceDriver=sqlite > "$RUN_DIR/tests.log" 2>&1; then
    rg '^--- PASS:|^    --- PASS:' "$RUN_DIR/tests.log"
else
    rc=$?
    printf 'Scenario run failed (exit %s); see %s/tests.log. A timeout requires investigation before retry.\n' "$rc" "$RUN_DIR"
    exit "$rc"
fi
python3 "$HARNESS_DIR/collect.py" --evidence "$RUN_DIR" --traces "$RUN_DIR/traces"
python3 "$HARNESS_DIR/audit_key_allocation.py" "$RUN_DIR"
python3 "$HARNESS_DIR/check_contract.py" "$RUN_DIR"
cp "$RUN_DIR/traces/"*.ndjson "$OUTPUT_DIR/traces/"
set +e
python3 "$HARNESS_DIR/validate.py" --evidence "$RUN_DIR" --traces "$RUN_DIR/traces"
rc=$?
set -e
printf 'Collection and validation evidence: %s\n' "$RUN_DIR"
if [ "$rc" -ne 0 ]; then
    printf 'INCOMPLETE: one or more complete trace replays failed. See the current validation logs.\n'
fi
exit "$rc"
