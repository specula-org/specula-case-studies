#!/usr/bin/env bash
set -u -o pipefail

WORKTREE="/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-reset-20260909-restart-1600/temporal-reset/.specula-output/confirmation/MC-1/worktree"
BIN="/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-reset-20260909-restart-1600/temporal-reset/.specula-output/harness/build/reset-trace.test"
OUT_ROOT="/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-reset-20260909-restart-1600/temporal-reset/.specula-output/confirmation/MC-1/repro-logs/script-$(date -u +%Y%m%dT%H%M%SZ)"

fail() {
  echo "REPRO_RESULT FAIL: $*" >&2
  exit 1
}

extract_field() {
  local line="$1"
  local name="$2"
  sed -n "s/.*${name}=\\([^ ]*\\).*/\\1/p" <<<"$line"
}

run_case() {
  local mode="$1"
  local age="$2"
  local log="$OUT_ROOT/${mode}-${age}.log"
  local raw="$OUT_ROOT/${mode}-${age}.raw.jsonl"

  rm -f "$log" "$raw"
  echo "COMMAND: timeout 10m env RESET_SCANNER_MODE=$mode RESET_SCANNER_AGE=$age RESET_SCANNER_OUTPUT=$OUT_ROOT $BIN -test.run '^TestWorkflowResetTestSuite/TestValidationScannerAge$' -test.v -test.count=1"

  (
    cd "$WORKTREE" || exit 2
    timeout 10m env \
      RESET_SCANNER_MODE="$mode" \
      RESET_SCANNER_AGE="$age" \
      RESET_SCANNER_OUTPUT="$OUT_ROOT" \
      "$BIN" -test.run '^TestWorkflowResetTestSuite/TestValidationScannerAge$' -test.v -test.count=1
  ) >"$log" 2>&1
  local rc=$?

  echo "CASE mode=$mode age=$age go_test_rc=$rc log=$log"
  [[ "$rc" -ne 124 ]] || fail "$mode/$age timed out"

  local obs
  obs="$(grep 'SCANNER_OBSERVATION' "$log" | tail -1 || true)"
  [[ -n "$obs" ]] || fail "$mode/$age missing SCANNER_OBSERVATION"
  echo "$obs"

  grep 'SCANNER_EXPECTED_ASSERTIONS' "$log" | tail -1 || true
  grep 'SCANNER_RECOVERY' "$log" | tail -1 || true
  grep 'SCANNER_WORKER_COMPLETE' "$log" | tail -1 || true

  local eligible next events expected history_error
  eligible="$(extract_field "$obs" "eligible")"
  next="$(extract_field "$obs" "persistedNext")"
  events="$(extract_field "$obs" "historyEvents")"
  history_error="$(sed -n 's/.*historyError=//p' <<<"$obs")"
  [[ "$next" =~ ^[0-9]+$ ]] || fail "$mode/$age could not parse persistedNext from: $obs"
  [[ "$events" =~ ^[0-9]+$ ]] || fail "$mode/$age could not parse historyEvents from: $obs"
  expected=$((next - 1))

  if [[ "$age" == "0" ]]; then
    [[ "$eligible" == "true" ]] || fail "$mode/$age expected scanner eligibility"
    [[ "$events" -lt "$expected" ]] || fail "$mode/$age expected truncated history, got $events of $expected"
    echo "EVIDENCE: short age deleted/invalidated history for acknowledged $mode run: historyEvents=$events expected=$expected historyError=$history_error"
  else
    [[ "$eligible" == "false" ]] || fail "$mode/$age expected scanner skip"
    [[ "$events" -eq "$expected" ]] || fail "$mode/$age expected complete history, got $events of $expected"
    [[ "$history_error" == "<nil>" ]] || fail "$mode/$age expected no history read error, got $history_error"
    echo "CONTROL: default age preserved acknowledged $mode run history: historyEvents=$events expected=$expected"
  fi
}

mkdir -p "$OUT_ROOT"
[[ -x "$BIN" ]] || fail "missing executable test binary: $BIN"

run_case start 0
run_case reset 0
run_case start 60d
run_case reset 60d

echo "REPRO_RESULT PASS: MC-1 scanner-age sensitivity reproduced with public Start/Reset handlers and controlled by 60-day minimum age"
