#!/usr/bin/env bash
# PR #5341 (OPEN): panic when a vote verification task added while shutting down.
#
# AsyncVoteVerifier.Quit (asyncVoteVerifier.go:174-189) closes execpoolOut
# after wg.Wait(). A concurrent verifyVote can race the ctx.Done() check and
# enqueue work after ctxCancel but before Quit observes it. We exercise it as
# a black-box stress test under -race.
#
# Verify_vote() is called with a PRE-CANCELLED verctx so the worker takes the
# fast cancellation branch and does not deref the (nil) ledger.

set -euo pipefail
export PATH=/usr/local/go/bin:$PATH

REPO="/home/ubuntu/Specula/case-studies/algorand/artifact/go-algorand"
TEST_SRC="$REPO/agreement/repro_bug_pr5341_test.go"

cleanup() { rm -f "$TEST_SRC"; }
trap cleanup EXIT

cat > "$TEST_SRC" <<'EOF'
package agreement

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestReproBugPR5341AsyncVoteVerifierShutdownRace(t *testing.T) {
	const trials = 200
	var (
		closedChanPanics int64
		wgReusedPanics   int64
		otherPanics      int64
	)

	for trial := 0; trial < trials; trial++ {
		avv := MakeAsyncVoteVerifier(nil)
		out := make(chan asyncVerifyVoteResponse, 4096)
		// drain `out` continuously to keep the worker unblocked
		drainerDone := make(chan struct{})
		go func() {
			for range out {
			}
			close(drainerDone)
		}()

		// pre-canceled context so executeVoteVerification takes the cancellation branch
		verctx, vcCancel := context.WithCancel(context.Background())
		vcCancel()

		ready := make(chan struct{})
		var goroutineWg sync.WaitGroup
		const callers = 16
		const burst = 200
		for i := 0; i < callers; i++ {
			goroutineWg.Add(1)
			go func() {
				defer goroutineWg.Done()
				defer func() {
					if r := recover(); r != nil {
						s := fmt.Sprintf("%v", r)
						switch {
						case strings.Contains(s, "send on closed channel"):
							atomic.AddInt64(&closedChanPanics, 1)
						case strings.Contains(s, "WaitGroup is reused"):
							atomic.AddInt64(&wgReusedPanics, 1)
						default:
							atomic.AddInt64(&otherPanics, 1)
							t.Logf("caller panic (other): %v", r)
						}
					}
				}()
				<-ready
				for j := 0; j < burst; j++ {
					_ = avv.verifyVote(verctx, nil, unauthenticatedVote{}, uint64(j), message{}, out)
				}
			}()
		}

		close(ready)
		// nudge Quit to land while callers are still firing
		time.Sleep(time.Duration(trial%7) * time.Microsecond)

		func() {
			defer func() {
				if r := recover(); r != nil {
					s := fmt.Sprintf("%v", r)
					switch {
					case strings.Contains(s, "send on closed channel"):
						atomic.AddInt64(&closedChanPanics, 1)
					case strings.Contains(s, "WaitGroup is reused"):
						atomic.AddInt64(&wgReusedPanics, 1)
					default:
						atomic.AddInt64(&otherPanics, 1)
						t.Logf("Quit panic (other): %v", r)
					}
				}
			}()
			avv.Quit()
		}()

		goroutineWg.Wait()
		close(out)
		<-drainerDone
	}

	t.Logf("trials=%d closedChan=%d wgReused=%d other=%d", trials,
		atomic.LoadInt64(&closedChanPanics),
		atomic.LoadInt64(&wgReusedPanics),
		atomic.LoadInt64(&otherPanics))

	if closedChanPanics > 0 || wgReusedPanics > 0 || otherPanics > 0 {
		t.Logf("PR #5341 REPRODUCED: shutdown/verifyVote race produced %d closed-channel + %d wg-reused + %d other panics across %d trials",
			closedChanPanics, wgReusedPanics, otherPanics, trials)
		t.Fail()
	}
}
EOF

cd "$REPO"
echo "=== Run WITHOUT race detector ==="
go test -count=1 -v -timeout=600s -run TestReproBugPR5341AsyncVoteVerifierShutdownRace ./agreement/ 2>&1 | tail -80
echo
echo "=== Run WITH race detector (-race) ==="
go test -count=1 -race -v -timeout=600s -run TestReproBugPR5341AsyncVoteVerifierShutdownRace ./agreement/ 2>&1 | tail -160
