#!/usr/bin/env bash
# CR-7: none.fresherThan(none) == true — reflexivity asymmetric with documentation.
#
# Level: 0 (black-box: call the exported behavior via in-package test).
# Goal: demonstrate the reflexive-true result for two `none` events.
#
# The function comment claims a "partial ordering". A strict partial order is
# irreflexive. None.fresherThan(None) returning true breaks the doc but is
# intentionally used so the empty-cache replacement path works in voteTrackerRound.

set -euo pipefail
export PATH=/usr/local/go/bin:$PATH

REPO="/home/ubuntu/Specula/case-studies/algorand/artifact/go-algorand"
TEST_SRC="$REPO/agreement/repro_bug_cr7_test.go"

cleanup() { rm -f "$TEST_SRC"; }
trap cleanup EXIT

cat > "$TEST_SRC" <<'EOF'
package agreement

import "testing"

func TestReproBugCR7FresherThanReflexivity(t *testing.T) {
	a := thresholdEvent{T: none}
	b := thresholdEvent{T: none}
	if !a.fresherThan(b) {
		t.Fatalf("CR-7: expected none.fresherThan(none) == true (per code), got false")
	}
	// also verify with explicit assertion: a strict partial-order would say
	// a == a is NOT fresher than itself; the code returns true. Document the
	// asymmetry between the "partial ordering" comment in events.go:732 and
	// the actual implementation at events.go:745-748.
	t.Logf("BUG: none.fresherThan(none) returned %v (events.go:745-748)", a.fresherThan(b))

	// Now show the inconsistency: for non-none threshold events the same call
	// returns false (the loop body never produces true on equal inputs).
	sa := thresholdEvent{T: softThreshold, Round: 1, Period: 0}
	sb := thresholdEvent{T: softThreshold, Round: 1, Period: 0}
	if sa.fresherThan(sb) {
		t.Fatalf("Sanity: softThreshold.fresherThan(softThreshold same period) should be false, got true")
	}
	t.Logf("Contrast: softThreshold.fresherThan(softThreshold same period) returned false")

	// And the cert-cert short-circuit (CR-4 related):
	ca := thresholdEvent{T: certThreshold, Round: 1, Period: 0}
	cb := thresholdEvent{T: certThreshold, Round: 1, Period: 1}
	// certThreshold from a later period (1) compared against an existing cert (0):
	// expectation: a strict partial order would say later period is fresher.
	// The code returns false because `if o.T == certThreshold { return false }` short-circuits.
	if ca.fresherThan(cb) || cb.fresherThan(ca) {
		t.Fatalf("Sanity: cert-cert returned true, expected false-false (cert-cert short circuit)")
	}
	t.Logf("Cert-cert short-circuit confirmed: neither (Per0 cert).fresherThan(Per1 cert) nor reverse is true")
}
EOF

cd "$REPO"
go test -count=1 -v -timeout=60s -run TestReproBugCR7FresherThanReflexivity ./agreement/
