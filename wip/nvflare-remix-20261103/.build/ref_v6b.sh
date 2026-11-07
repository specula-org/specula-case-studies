#!/usr/bin/env bash
# v6 refinement: JobSP with SP crash-restart, JobCP with CP crash-restart.
cd "$(dirname "$0")/.."
export MIX_INCLUDE_WIP=all
set -x
python3 scripts/gen_ref.py JobSP F C --sites 1 --launch 1 --faults spCrash,rpcTimeout,abort,storeError --run --timeout 1500 --workers 16 --tag v6c &
python3 scripts/gen_ref.py JobCP F C --sites 1 --launch 2 --faults cpCrash,cjCrash,rpcTimeout,launchError --run --timeout 1500 --workers 16 --tag v6c &
python3 scripts/gen_ref.py JobCP F C --sites 1 --launch 2 --faults cpCrash,rpcTimeout,outcomeReportFail --profile otherJob --run --timeout 1500 --workers 16 --tag v6d &
wait
python3 scripts/gen_ref.py JobSP F C --sites 1 --launch 1 --faults spCrash,rpcTimeout --negative --run --timeout 300 --workers 4 --tag v6cn
python3 scripts/gen_ref.py JobCP F C --sites 1 --launch 1 --faults cpCrash,rpcTimeout --negative --run --timeout 300 --workers 4 --tag v6cn
echo REF_V6B_DONE
