#!/usr/bin/env bash
# Refinement re-checks on the spec after T2, panic exit code, coarse JobSP Fail / JobCP Spawn tightening.
cd "$(dirname "$0")/.."
export MIX_INCLUDE_WIP=all
set -x
python3 scripts/gen_ref.py JobSP F C --sites 1 --launch 1 --faults abort,abortCmdError,rpcTimeout,storeError,launchError,deployError --run --timeout 1500 --workers 12 &
python3 scripts/gen_ref.py JobCP F C --sites 1 --launch 2 --faults abort,admissionError,archiveError,cjCrash,deployError,launchError,outcomeReportFail,outcomeTimeout,resExpiry,rpcTimeout,storeError --run --timeout 1500 --workers 12 &
python3 scripts/gen_ref.py WfSJ F C --sites 1 --faults taskTimeout --run --timeout 1200 --workers 8 &
wait
python3 scripts/gen_ref.py JobSP F C --sites 1 --launch 1 --faults abort,abortCmdError,rpcTimeout,storeError --negative --run --timeout 300 --workers 4
python3 scripts/gen_ref.py JobCP F C --sites 1 --launch 1 --faults launchError --negative --run --timeout 300 --workers 4
echo REF2_DONE
