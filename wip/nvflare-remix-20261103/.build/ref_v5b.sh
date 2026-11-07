#!/usr/bin/env bash
# v5 refinement re-check: CommSJ under cseTasks (duplicate ClientTask on resend,
# monitor death); resends come from a CJ relaunch (cjCrash, launch 2).
cd "$(dirname "$0")/.."
export MIX_INCLUDE_WIP=all
set -x
python3 scripts/gen_ref.py CommSJ F C --sites 2 --launch 2 --faults cjCrash --profile cseTasks --run --timeout 1500 --workers 24 --tag v5b
python3 scripts/gen_ref.py CommSJ F C --sites 2 --launch 1 --faults taskTimeout --profile cseTasks --negative --run --timeout 300 --workers 4 --tag v5bn
echo REF_V5B_DONE
