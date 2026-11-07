#!/usr/bin/env bash
# WfSJ refinement after moving the per-round port reset to the schedule step.
cd "$(dirname "$0")/.."
export MIX_INCLUDE_WIP=all
set -x
python3 scripts/gen_ref.py WfSJ F C --sites 1 --faults taskTimeout --attempt 2 --run --timeout 1500 --workers 12 --tag v4c
python3 scripts/gen_ref.py WfSJ F C --sites 1 --faults taskTimeout --negative --run --timeout 300 --workers 4 --tag v4cn
echo REF_V4C_DONE
