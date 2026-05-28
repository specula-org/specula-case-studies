#!/usr/bin/env bash
# CR-1: catchup/service.go:819-840 fork-detection branch is log-only.
#
# Level 0 (black-box static): the comment at service.go:819 promises
#   "if the cert we fetched is valid but for the wrong block, panic as loudly as possible"
# But the branch body only constructs a string, prints it to stdout, and calls
# logging.Base().Error(...). No panic(), no os.Exit, no break, no return. The
# enclosing `for s.ledger.LastRound() < cert.Round { ... }` loop continues and
# the node will keep retrying — silently with respect to halt/alert semantics.
#
# This is structurally observable without a running cluster: inspect the source
# region and assert that no panic / break / return exists in the branch.

set -euo pipefail
export PATH=/usr/local/go/bin:$PATH

REPO="/home/ubuntu/Specula/case-studies/algorand/artifact/go-algorand"
SVC="$REPO/catchup/service.go"

echo "[1/3] confirming the comment promises a panic"
PROMISED_PANIC=$(awk '/As a failsafe.*panic as loudly as possible/{print NR": "$0}' "$SVC")
if [[ -z "$PROMISED_PANIC" ]]; then
  echo "FAIL: comment 'panic as loudly as possible' not found — has the file changed?"
  exit 1
fi
echo "  $PROMISED_PANIC"

echo
echo "[2/3] extracting the fork-detection branch body"
# Get the lines from FORK DETECTED block opening through the closing brace
BRANCH=$(awk '
  /As a failsafe, if the cert we fetched is valid but for the wrong block/{capture=1}
  capture {print; lines++}
  capture && /^\t\t}$/ {if (lines > 3) {capture=0}}
' "$SVC")
echo "----- branch body -----"
echo "$BRANCH"
echo "-----------------------"

echo
echo "[3/3] asserting branch does NOT actually panic, return, or break the loop"
NO_PANIC=$(echo "$BRANCH" | grep -c "panic(" || true)
NO_RETURN=$(echo "$BRANCH" | grep -c "return$\|return " || true)
NO_BREAK=$(echo "$BRANCH" | grep -c "break$" || true)
NO_OSEXIT=$(echo "$BRANCH" | grep -c "os\.Exit" || true)

echo "  panic( calls in branch:       $NO_PANIC"
echo "  return statements in branch:  $NO_RETURN"
echo "  break statements in branch:   $NO_BREAK"
echo "  os.Exit calls in branch:      $NO_OSEXIT"

if [[ "$NO_PANIC" == "0" && "$NO_RETURN" == "0" && "$NO_BREAK" == "0" && "$NO_OSEXIT" == "0" ]]; then
  echo
  echo "CR-1 CONFIRMED: branch body only logs (logging.Base().Error + fmt.Println)."
  echo "The 'panic as loudly as possible' comment is contradicted by the code: the"
  echo "node continues looping in fetchRound, repeatedly attempting peers, with no"
  echo "halt, no panic, no exit, no operator alert beyond a logged Error line."
  echo
  echo "Consequence in production: an attacker who can present a fake-but-validly"
  echo "signed cert+block for a different fork will trigger this branch once per"
  echo "request; the node never halts and never escalates."
  exit 0
else
  echo "REPRO FAILED: branch contains a halt/exit primitive — bug already fixed."
  exit 1
fi
