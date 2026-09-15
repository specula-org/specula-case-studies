#!/usr/bin/env bash
set -euo pipefail
HARNESS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
EXPERIMENT=/home/ubuntu/nvflare-job-lifecycle-20260914
export TMPDIR="$EXPERIMENT/scratch/tmp"
export TLC_STATE_DIR="$EXPERIMENT/scratch/tlc"
export PYTHONPATH="$EXPERIMENT/source"
export PATH="$EXPERIMENT/venv/bin:$PATH"
mkdir -p "$HARNESS_DIR/logs" "$HARNESS_DIR/../traces" "$TMPDIR" "$TLC_STATE_DIR"
bash "$HARNESS_DIR/apply.sh"
timeout 60 python -m compileall -q "$HARNESS_DIR/src" "$EXPERIMENT/source/nvflare/_lifecycle_probe.py" "$EXPERIMENT/source/nvflare/_lifecycle_workload.py"
RUN_RC=0
for SCENARIO in competition delayed_start admission_exception abort_completion; do
    printf 'Running %s\n' "$SCENARIO"
    if timeout --kill-after=15s 360 python -m pytest -q -s "$HARNESS_DIR/src/lifecycle_test.py::test_lifecycle[$SCENARIO]" > "$HARNESS_DIR/logs/$SCENARIO.pytest.log" 2>&1; then
        printf '%s: pytest PASS\n' "$SCENARIO"
    else
        TEST_RC=$?
        printf '%s: pytest failed (exit %s); see %s\n' "$SCENARIO" "$TEST_RC" "$HARNESS_DIR/logs/$SCENARIO.pytest.log"
        if [ "$TEST_RC" = 124 ]; then
            printf '%s: outer timeout; investigate a possible deadlock, no automatic retry\n' "$SCENARIO" >> "$HARNESS_DIR/logs/timeouts.txt"
        fi
        RUN_RC=1
    fi
done
python "$HARNESS_DIR/src/normalize.py" || RUN_RC=1
timeout 520 "$EXPERIMENT/specula/.venv/bin/python" "$HARNESS_DIR/src/validate.py" || RUN_RC=1
python "$HARNESS_DIR/src/audit.py" || RUN_RC=1
wc -l "$HARNESS_DIR"/../traces/*.ndjson
exit "$RUN_RC"
