#!/usr/bin/env bash
set -uo pipefail
SPEC_RUN_DIR=$(cd -- "$(dirname -- "$0")/.." && pwd)
export TMPDIR="$SPEC_RUN_DIR/output/tmp"
export TLC_STATE_DIR="$SPEC_RUN_DIR/output/tmp"
export JAVA_TOOL_OPTIONS="-Djava.io.tmpdir=$SPEC_RUN_DIR/output/tmp"
cd "$SPEC_RUN_DIR"
/home/ubuntu/Specula/scripts/infra/start_background.sh -s MC.tla -c MC.cfg -o output/MC_round1b.out -w 64 -m 48G -M 96G -t 30 -j output/MC_round1b.counterexample.json
start_rc=$?
if [ "$start_rc" -ne 0 ]; then exit "$start_rc"; fi
/home/ubuntu/Specula/scripts/infra/wait_for_pid.sh --pid-file output/MC_round1b.out.pid --timeout 35m --log output/MC_round1b.out
