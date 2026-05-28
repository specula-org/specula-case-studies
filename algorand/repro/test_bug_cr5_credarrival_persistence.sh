#!/usr/bin/env bash
# CR-5: lowestCredentialArrivals is not persisted across crashes.
#
# Level: 0 (black-box: drive encode() then decode() and observe the state loss).
#
# Confirmed at persistence.go:246 / persistence.go:262:
#     p2.lowestCredentialArrivals = makeCredentialArrivalHistory(...)
# After decode the history is unconditionally replaced with a fresh empty
# circular buffer, regardless of what was persisted. Until 40 fresh samples
# accumulate post-crash, calculateFilterTimeout falls back to the default
# (defaultTimeout / FilterTimeout(0, ver)) per player.go:338-341. Safety is
# not affected; this is a documented liveness-latency regression.

set -euo pipefail
export PATH=/usr/local/go/bin:$PATH

REPO="/home/ubuntu/Specula/case-studies/algorand/artifact/go-algorand"
TEST_SRC="$REPO/agreement/repro_bug_cr5_test.go"

cleanup() { rm -f "$TEST_SRC"; }
trap cleanup EXIT

cat > "$TEST_SRC" <<'EOF'
package agreement

import (
	"testing"
	"time"

	"github.com/algorand/go-algorand/logging"
	"github.com/algorand/go-algorand/util/timers"
)

func TestReproBugCR5LowestCredentialArrivalsNotPersisted(t *testing.T) {
	p := player{Round: 350, Period: 0, Step: soft}
	p.lowestCredentialArrivals = makeCredentialArrivalHistory(dynamicFilterCredentialArrivalHistory)
	for i := 0; i < dynamicFilterCredentialArrivalHistory; i++ {
		p.lowestCredentialArrivals.store(time.Duration(100+i) * time.Millisecond)
	}
	if !p.lowestCredentialArrivals.isFull() {
		t.Fatalf("setup: history not full after storing %d samples", dynamicFilterCredentialArrivalHistory)
	}
	pre := p.lowestCredentialArrivals.orderStatistics(dynamicFilterTimeoutCredentialArrivalHistoryIdx)
	t.Logf("Before persist: history full=true, order_statistic[%d]=%v", dynamicFilterTimeoutCredentialArrivalHistoryIdx, pre)

	router := makeRootRouter(p)
	clock := timers.MakeMonotonicClock[TimeoutType](time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC))
	a := []action{checkpointAction{}}

	raw := encode(clock, router, p, a, false)

	t0 := timers.MakeMonotonicClock[TimeoutType](time.Date(2000, 1, 1, 0, 0, 0, 0, time.UTC))
	log := makeServiceLogger(logging.Base())

	_, _, p2, _, err := decode(raw, t0, log, false)
	if err != nil {
		t.Fatalf("decode failed: %v", err)
	}

	if p2.lowestCredentialArrivals.isFull() {
		t.Fatalf("CR-5 expectation failed: history should be reset to empty on decode, but is full")
	}
	t.Logf("After decode: history full=%v (expected false)", p2.lowestCredentialArrivals.isFull())
	t.Logf("CR-5 CONFIRMED: persistence.go:246/262 explicitly resets lowestCredentialArrivals on decode.")
	t.Logf("Until ~%d successful period-0 rounds pass post-crash, filter timeout reverts to default.", dynamicFilterCredentialArrivalHistory)
}
EOF

cd "$REPO"
go test -count=1 -v -timeout=60s -run TestReproBugCR5LowestCredentialArrivalsNotPersisted ./agreement/
