#!/usr/bin/env bash
# CommSJ refinement after the coarse Reject fix (one receipt per submission).
cd "$(dirname "$0")/.."
export MIX_INCLUDE_WIP=all
set -x
python3 scripts/gen_ref.py CommSJ F C --sites 1 --launch 2 --attempt 2 --faults cjCrash,taskTimeout --run --timeout 1200 --workers 12 --tag v4d
python3 scripts/gen_ref.py CommSJ F C --sites 1 --faults taskTimeout --negative --run --timeout 300 --workers 4 --tag v4dn
echo REF_V4D_DONE
