#!/usr/bin/env bash
# v5 refinement re-checks: JobSP (nonStrictStart, completion-thread KeyError),
# JobCP (otherJob env write).
cd "$(dirname "$0")/.."
export MIX_INCLUDE_WIP=all
set -x
python3 scripts/gen_ref.py JobSP F C --sites 2 --launch 1 --faults rpcTimeout,storeError,sjCrash --profile nonStrictStart --run --timeout 1500 --workers 16 --tag v5b &
python3 scripts/gen_ref.py JobSP F C --sites 1 --launch 1 --faults abort,abortCmdError,rpcTimeout,storeError,outcomeReportFail,sjCrash --run --timeout 1500 --workers 16 --tag v5c &
python3 scripts/gen_ref.py JobCP F C --sites 1 --launch 2 --faults cjCrash,launchError,rpcTimeout,outcomeReportFail --profile otherJob --run --timeout 1500 --workers 16 --tag v5b &
wait
python3 scripts/gen_ref.py JobSP F C --sites 1 --launch 1 --faults abort,rpcTimeout --profile nonStrictStart --negative --run --timeout 300 --workers 4 --tag v5bn
python3 scripts/gen_ref.py JobCP F C --sites 1 --launch 1 --faults launchError --profile otherJob --negative --run --timeout 300 --workers 4 --tag v5bn
echo REF_V5A_DONE
