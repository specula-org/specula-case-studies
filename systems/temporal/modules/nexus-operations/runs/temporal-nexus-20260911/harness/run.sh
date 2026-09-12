#!/usr/bin/env bash
set -euo pipefail
harness_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source_dir=${TEMPORAL_SOURCE:-/home/ubuntu/temporal-investigation-20260909/parallel-20260911/source-nexus}
mkdir -p "$harness_dir/evidence" "$harness_dir/../traces"
export GOMAXPROCS=${GOMAXPROCS:-4}
bash "$harness_dir/apply.sh"
cd "$source_dir"
printf 'Building the instrumented Temporal functional tests.\n'
timeout 1800 go test -tags test_dep -p 4 -c -o "$harness_dir/evidence/nexus-tests" ./tests > "$harness_dir/evidence/build.log" 2>&1
timeout 180 go test -tags test_dep -p 4 ./service/history/hsm/nexusoperations/... -count=1 -json > "$harness_dir/evidence/unit-tests.jsonl" 2>&1
cd "$source_dir/tests"
printf 'Running existing Nexus workflow and API controls.\n'
timeout 180 "$harness_dir/evidence/nexus-tests" -test.run '^TestNexusWorkflowTestSuiteHSM$/(TestNexusOperationSyncCompletion|TestNexusOperationAsyncCompletionBeforeStart|TestNexusOperationCancelBeforeStarted_CancelationEventuallyDelivered|TestNexusOperationScheduleToCloseTimeout|TestNexusOperationScheduleToStartTimeout|TestNexusOperationStartToCloseTimeout)$' -test.parallel 1 -test.timeout 150s -test.v -persistenceType=sql -persistenceDriver=sqlite > "$harness_dir/evidence/existing-workflow-controls.log" 2>&1
timeout 180 "$harness_dir/evidence/nexus-tests" -test.run '^TestNexusApiTestSuiteWithTemporalFailures$/(TestNexusStartOperation_Outcomes|TestNexusCancelOperation_Outcomes)$' -test.parallel 1 -test.timeout 150s -test.v -persistenceType=sql -persistenceDriver=sqlite > "$harness_dir/evidence/existing-api-controls.log" 2>&1
python3 "$harness_dir/collect.py"
python3 "$harness_dir/audit.py"
set +e
python3 "$harness_dir/validate.py"
validation_status=$?
set -e
python3 "$harness_dir/report.py"
exit "$validation_status"
