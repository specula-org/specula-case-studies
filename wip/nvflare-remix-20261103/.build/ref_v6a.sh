#!/usr/bin/env bash
# v6 refinement: JobSP with admin delete (deleteJob) and scheduler-loop death.
cd "$(dirname "$0")/.."
export MIX_INCLUDE_WIP=all
set -x
python3 scripts/gen_ref.py JobSP F C --sites 1 --launch 1 --faults deleteJob,rpcTimeout,storeError,deployError,abort --run --timeout 1500 --workers 16 --tag v6a &
python3 scripts/gen_ref.py JobSP F C --sites 2 --launch 1 --faults deleteJob,rpcTimeout --profile nonStrictStart --run --timeout 1500 --workers 16 --tag v6b &
wait
python3 scripts/gen_ref.py JobSP F C --sites 1 --launch 1 --faults deleteJob --negative --run --timeout 300 --workers 4 --tag v6an
echo REF_V6A_DONE
