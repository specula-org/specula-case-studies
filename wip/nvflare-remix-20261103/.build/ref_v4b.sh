#!/usr/bin/env bash
# Refinement re-checks after the outcomeSeen port (JobSP, JobCP changed).
cd "$(dirname "$0")/.."
export MIX_INCLUDE_WIP=all
set -x
python3 scripts/gen_ref.py JobSP F C --sites 1 --launch 1 --faults abort,abortCmdError,rpcTimeout,storeError,outcomeReportFail --run --timeout 1500 --workers 12 --tag v4b &
python3 scripts/gen_ref.py JobCP F C --sites 1 --launch 2 --faults admissionError,cjCrash,launchError,outcomeReportFail,outcomeTimeout,rpcTimeout --run --timeout 1500 --workers 12 --tag v4b &
wait
python3 scripts/gen_ref.py JobSP F C --sites 1 --launch 1 --faults abort,rpcTimeout --negative --run --timeout 300 --workers 4 --tag v4bn
python3 scripts/gen_ref.py JobCP F C --sites 1 --launch 1 --faults launchError --negative --run --timeout 300 --workers 4 --tag v4bn
echo REF_V4B_DONE
