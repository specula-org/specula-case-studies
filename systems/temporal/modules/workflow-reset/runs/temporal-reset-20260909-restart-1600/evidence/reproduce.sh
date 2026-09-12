#!/usr/bin/env bash
set -eu

SOURCE_ROOT=${SOURCE_ROOT:-/home/ubuntu/temporal-investigation-20260909/restart-20260909-1600/source-reset}
EVIDENCE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPRO_DIR=$(mktemp -d "$EVIDENCE_DIR/reproduction-XXXXXX")
mkdir -p "$REPRO_DIR/build-tmp"
cd "$SOURCE_ROOT"
test "$(git rev-parse HEAD)" = 0c010ce5fe8c0180aa7573c72fe8fc87c6df7025
export GOTMPDIR="$REPRO_DIR/build-tmp" GOMAXPROCS=16 CGO_ENABLED=0 TEMPORAL_TEST_LOG_LEVEL=error
go test -c -p 8 -tags test_dep -o "$REPRO_DIR/temporal-reset.test" ./tests > "$REPRO_DIR/build.log" 2>&1

run_case() {
    case_name=$1
    case_pattern=$2
    set +e
    "$REPRO_DIR/temporal-reset.test" -test.v -test.parallel 8 -test.timeout 8m -persistenceType=sql -persistenceDriver=sqlite -test.run "$case_pattern" > "$REPRO_DIR/$case_name.log" 2>&1
    case_status=$?
    set -e
    printf '%s\t%s\n' "$case_name" "$case_status" >> "$REPRO_DIR/status.tsv"
}

run_case baseline '^TestHistoryNodeCleanupSuite$|^TestResetWorkflowTestSuite/Test(ResetWorkflow|BufferedSignal)|^TestWorkflowResetTestSuite/Test(SameBase|DifferentBase|NoBase|RepeatedResets)'
run_case identity '^TestWorkflowResetTestSuite/TestAnalysis(ExactResetReplay|ResetStartIDCollision|SeparateResetControl)$'
run_case recovery '^TestWorkflowResetTestSuite/TestAnalysisMissingCurrentRecovery$'
run_case history '^Test(ResetWorkflowTestSuite|WorkflowResetTestSuite)/(TestAnalysisCANUpdateIDReuse|TestAnalysisDeleteBasePreservesReset)$'

python3 - "$REPRO_DIR" <<'PY'
import json
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
statuses = dict(line.split('\t') for line in (root / 'status.tsv').read_text().splitlines())
expected = {'baseline': (27, 0, 0), 'identity': (2, 6, 1), 'recovery': (2, 0, 0), 'history': (6, 0, 0)}
results = {}
for name, (want_pass, want_fail, want_exit) in expected.items():
    entries = re.findall(r'^\s*--- (PASS|FAIL): (\S+) \(', (root / f'{name}.log').read_text(), re.M)
    leaves = [(status, case) for status, case in entries if not any(other.startswith(case + '/') for _, other in entries)]
    passed = sum(status == 'PASS' for status, _ in leaves)
    failed = sum(status == 'FAIL' for status, _ in leaves)
    assert (passed, failed, int(statuses[name])) == (want_pass, want_fail, want_exit), (name, leaves, statuses[name])
    if name == 'identity':
        assert all(case.startswith('TestWorkflowResetTestSuite/TestAnalysisExactResetReplay/') for status, case in leaves if status == 'FAIL')
    results[name] = {'passed': passed, 'failed': failed, 'exit_code': int(statuses[name]), 'cases': leaves}
(root / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
print(f'Recorded expected pinned-source observations in {root}')
print('Identity failures demonstrate the request replay defect; passing rejection assertions are observations, not a formal proof.')
PY
