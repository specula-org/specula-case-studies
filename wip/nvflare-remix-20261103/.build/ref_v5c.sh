#!/usr/bin/env bash
# v5 refinement re-checks after the smoke-run fixes: JobSP_C Terminate
# (no-kill branch only for an unregistered or dead SJ), JobCP_F START reply
# decoupled from the restart pc (replyDue), JobSP startDropped port.
cd "$(dirname "$0")/.."
export MIX_INCLUDE_WIP=all
set -x
python3 scripts/gen_ref.py JobSP F C --sites 1 --launch 1 --faults abort,abortCmdError,rpcTimeout,storeError,outcomeReportFail,sjCrash,slowAdminStop --run --timeout 1500 --workers 16 --tag v5d &
python3 scripts/gen_ref.py JobCP F C --sites 1 --launch 2 --faults cjCrash,launchError,rpcTimeout,outcomeReportFail,admissionError --profile otherJob --run --timeout 1500 --workers 16 --tag v5d &
python3 scripts/gen_ref.py JobSP F C --sites 2 --launch 1 --faults rpcTimeout,storeError,sjCrash --profile nonStrictStart --run --timeout 1500 --workers 16 --tag v5e &
wait
python3 scripts/gen_ref.py JobSP F C --sites 1 --launch 1 --faults abort,rpcTimeout --negative --run --timeout 300 --workers 4 --tag v5dn
python3 scripts/gen_ref.py JobCP F C --sites 1 --launch 1 --faults launchError --negative --run --timeout 300 --workers 4 --tag v5dn
echo REF_V5C_DONE
