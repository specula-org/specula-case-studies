#!/usr/bin/env bash
set -u -o pipefail

WORKTREE="/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-matching-20260910/temporal-matching/.specula-output/confirmation/CR-5/worktree"
OUTDIR="/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-matching-20260910/temporal-matching/.specula-output/confirmation/CR-5/repro-output"
TEST_RE='^TestSpeculaFairLateCompletionSQLite$'

mkdir -p "$OUTDIR"
cd "$WORKTREE" || exit 2

echo "CR-5 fairness eviction during unlocked replacement"
echo "worktree=$WORKTREE"
echo "revision=$(git rev-parse HEAD)"
echo "dirty_entries=$(git status --short | wc -l | tr -d ' ')"
echo "test=./service/matching $TEST_RE"

if [[ ! -f service/matching/specula_fair_diagnostic_test.go ]]; then
  echo "missing diagnostic test: service/matching/specula_fair_diagnostic_test.go"
  exit 2
fi

run_case() {
  local label="$1"
  local control="$2"
  local evidence="$OUTDIR/${label}.json"
  local log="$OUTDIR/${label}.go-test.log"

  rm -f "$evidence" "$log"
  echo
  echo "== $label =="
  echo "evidence=$evidence"
  if [[ "$control" == "1" ]]; then
    echo "mode=Level 0 / no dangerous window control"
    export SPECULA_FAIR_CONTROL=1
  else
    echo "mode=Level 1 / timing-assisted unlocked replacement window"
    unset SPECULA_FAIR_CONTROL
  fi
  export SPECULA_FAIR_EVIDENCE="$evidence"

  set +e
  timeout 5m go test ./service/matching -run "$TEST_RE" -count=1 -timeout 2m -v | tee "$log"
  local status=${PIPESTATUS[0]}
  set -e
  echo "go_test_exit=$status"
  if [[ "$status" != "0" ]]; then
    exit "$status"
  fi

  python3 - "$label" "$control" "$evidence" <<'PY'
import json
import sys

label, control_s, path = sys.argv[1:]
control = control_s == "1"
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

def lev(v):
    return f"<{v['pass']},{v['id']}>"

def less(a, b):
    return (a["pass"], a["id"]) < (b["pass"], b["id"])

store_b = [r for r in data["storeRows"] if r["work"] == "B"]
replay_b = [r for r in data["restartRead"] if r["work"] == "B"]
ack_crosses_b = not less(data["durableAck"], data["BLevel"])
summary = [
    f"{label}: reproduced={data['reproduced']}",
    f"{label}: controlWindowClosed={data['controlWindowClosed']}",
    f"{label}: durableAck={lev(data['durableAck'])}",
    f"{label}: BLevel={lev(data['BLevel'])}",
    f"{label}: ackCrossesB={ack_crosses_b}",
    f"{label}: BRowsInStore={len(store_b)}",
    f"{label}: BReturnedByRestartRead={bool(replay_b)}",
    f"{label}: accepted={','.join(data['accepted'])}",
    f"{label}: historyAccepted={','.join(data['historyAccepted'])}",
]
print("\n".join(summary))

if control:
    assert data["controlWindowClosed"] is True
    assert data["reproduced"] is False
    assert len(store_b) == 1
    assert bool(replay_b) is True
    assert ack_crosses_b is False
else:
    assert data["controlWindowClosed"] is False
    assert data["reproduced"] is True
    assert len(store_b) == 1
    assert bool(replay_b) is False
    assert ack_crosses_b is True
PY
}

run_case "level0_control" "1"
run_case "level1_candidate" "0"

echo
echo "CR-5 reproduction summary: Level 0 control did not cross B; Level 1 timing-assisted run crossed B and restart-style fair read skipped B while B remained in SQLite."
