#!/usr/bin/env bash
# CR-8/CR-9/CR-10: Static TODO findings.
#
# Level 0 (source-only): verify each TODO exists in the artifact and is not
# yet resolved. These are code-quality / documentation findings, not behavior
# bugs. There is nothing to "trigger." Escalation ladder is not applicable.

set -euo pipefail

REPO="/home/ubuntu/Specula/case-studies/algorand/artifact/go-algorand"

echo "==== CR-8: BlockValidator.Validate TODO ===="
grep -n "There should probably be a second Round argument here" "$REPO/agreement/abstractions.go" \
  || { echo "FAIL: TODO not found"; exit 1; }

echo
echo "==== CR-9: redundant Hash() call TODO ===="
grep -n "remove the following Hash" "$REPO/agreement/proposal.go" \
  || { echo "FAIL: TODO not found"; exit 1; }

echo
echo "==== CR-10: PR #5286 TODO file content ===="
TODOFILE="$REPO/agreement/TODO"
if [[ ! -f "$TODOFILE" ]]; then
  echo "agreement/TODO file ABSENT (matches the modeling brief's claim that the TODO file was deleted)."
else
  echo "agreement/TODO file PRESENT in v4.7.0-stable artifact:"
  cat "$TODOFILE"
  echo
  echo "NOTE: the modeling brief claimed the TODO file was deleted in PR #5286,"
  echo "but it is still present in the v4.7.0-stable artifact. The two items remain"
  echo "documented but un-actioned. The maintainer comment in PR #5286 acknowledged"
  echo "not understanding the items well enough to file follow-up issues."
fi

echo
echo "==== ALL three findings are STATIC (no runtime trigger). ===="
