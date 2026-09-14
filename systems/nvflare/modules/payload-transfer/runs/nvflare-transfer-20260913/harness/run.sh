#!/usr/bin/env bash
set -euo pipefail
HARNESS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUTPUT_DIR=$(cd "$HARNESS_DIR/.." && pwd)
export NVFLARE_SOURCE=${NVFLARE_SOURCE:-/home/ubuntu/nvflare-runs-20260913/source-transfer}
export NVFLARE_PYTHON=${NVFLARE_PYTHON:-/home/ubuntu/nvflare-runs-20260913/venv-transfer/bin/python}
export SPECULA_ROOT=${SPECULA_ROOT:-/home/ubuntu/nvflare-runs-20260913/specula}
export SPECULA_WORK_DIR="$OUTPUT_DIR"
export TMPDIR=/home/ubuntu/nvflare-runs-20260913/scratch/transfer/tmp
export TLC_STATE_DIR=/home/ubuntu/nvflare-runs-20260913/scratch/transfer/tlc
export JAVA_TOOL_OPTIONS="-Djava.io.tmpdir=$TMPDIR"
export SPECULA_TLC_MEMORY_LIMIT=128G
export SPECULA_TLC_WORKER_LIMIT=40
export PYTHONDONTWRITEBYTECODE=1
export PYTHONHASHSEED=0
TLC_PYTHON="$SPECULA_ROOT/tools/tlc_tools/.venv/bin/python"
mkdir -p "$TMPDIR" "$TLC_STATE_DIR" "$HARNESS_DIR/logs" "$HARNESS_DIR/build"
bash "$HARNESS_DIR/apply.sh"
timeout 120 "$NVFLARE_PYTHON" "$HARNESS_DIR/src/build.py"
echo 'Running real Cell transfer scenarios (one fresh pytest process each)'
timeout 900 "$NVFLARE_PYTHON" "$HARNESS_DIR/src/run_tests.py"
(
    cd "$NVFLARE_SOURCE"
    timeout 120 "$NVFLARE_PYTHON" -m pytest \
        "$HARNESS_DIR/src/test_profiles.py" \
        tests/unit_test/fuel/f3/streaming/receiver_confirm_test.py::TestProducerSide::test_legacy_receiver_finalizes_at_serve \
        tests/unit_test/fuel/f3/streaming/receiver_confirm_test.py::TestProducerSide::test_kill_switch_off_restores_legacy_semantics \
        tests/unit_test/fuel/f3/streaming/receiver_confirm_test.py::TestReceiverSide::test_no_confirm_toward_legacy_producer \
        tests/unit_test/fuel/f3/streaming/receiver_confirm_test.py::TestReceiverSide::test_kill_switch_off_receiver_is_fully_legacy \
        tests/unit_test/fuel/f3/streaming/receiver_budget_test.py::TestQuorumSurface \
        tests/unit_test/fuel/f3/streaming/transfer_outcome_test.py::TestComputeTransferOutcome::test_unknown_receiver_count_cannot_complete \
        -q --tb=short > "$HARNESS_DIR/logs/profiles.log" 2>&1
)
cat "$HARNESS_DIR/logs/profiles.log"
"$NVFLARE_PYTHON" "$HARNESS_DIR/src/normalize.py"
echo 'Validating all traces with unchanged Trace.tla and Trace.cfg (2G heap, 1G direct, 1 worker)'
timeout 900 "$TLC_PYTHON" "$HARNESS_DIR/src/validate.py"
timeout 180 "$TLC_PYTHON" "$HARNESS_DIR/src/negative_controls.py"
"$NVFLARE_PYTHON" "$HARNESS_DIR/src/audit.py"
wc -l "$OUTPUT_DIR"/traces/*.ndjson
