// Reproduction test for CR3: evidence/verify.go:148-152 BFT-time check is unreachable
// when reached via evpool.verify() (the production caller), because line 81 has
// already filtered the same condition.
//
// Bug claim (code-review-only): line 148 is dead code; line 81 is the live gate.
//
// Code excerpt for context (verify.go in v1.0.1, line numbers approximate):
//
//   verify.go:81 (in evpool.verify, forward-lunatic branch):
//     if trustedHeader.Time.Before(ev.ConflictingBlock.Time) {
//         return fmt.Errorf("latest block time (%v) is before conflicting block time (%v)", ...)
//     }
//
//   verify.go:148 (in VerifyLightClientAttack, called immediately after):
//     if e.ConflictingBlock.Height > trustedHeader.Height && e.ConflictingBlock.Time.After(trustedHeader.Time) {
//         return fmt.Errorf("conflicting block doesn't violate monotonically increasing time ...")
//     }
//
// The two time predicates are logically equivalent:
//   `trustedHeader.Time.Before(ev.ConflictingBlock.Time)`  ==  `trustedHeader.Time < ev.ConflictingBlock.Time`
//   `e.ConflictingBlock.Time.After(trustedHeader.Time)`    ==  `ev.ConflictingBlock.Time > trustedHeader.Time`
// These are identical predicates.
//
// Reproduction approach (Level 0 — purely logical / numerical):
// For all relevant (trustedHeader.Time, ConflictingBlock.Time) pairs in the forward-
// lunatic branch (where trustedHeader is the *latest* local header and ConflictingBlock
// is at higher height), sweep and show:
//   (a) If line 81's condition is TRUE -> evpool.verify returns early; VerifyLightClientAttack
//       is never called; line 148 cannot fire (reachability=0).
//   (b) If line 81's condition is FALSE -> trustedHeader.Time >= ev.ConflictingBlock.Time
//       -> ev.ConflictingBlock.Time.After(trustedHeader.Time) is FALSE
//       -> line 148's compound condition is FALSE -> line 148 does not fire.
// In neither case does line 148 fire when reached through evpool.verify(). Hence dead.
package main

import (
	"fmt"
	"os"
	"time"
)

// Mirror of verify.go:81 predicate. Returns true iff line 81 rejects.
func line81Rejects(trustedTime, conflictingTime time.Time) bool {
	return trustedTime.Before(conflictingTime)
}

// Mirror of verify.go:148 predicate. Returns true iff line 148 rejects.
// In the forward-lunatic case reached through evpool.verify, the Height
// condition is always TRUE (ConflictingBlock.Height > latestHeight). We
// model that and focus on the time predicate.
func line148Rejects(trustedHeight, conflictingHeight int64, trustedTime, conflictingTime time.Time) bool {
	return conflictingHeight > trustedHeight && conflictingTime.After(trustedTime)
}

func main() {
	baseTime := time.Date(2026, 5, 19, 12, 0, 0, 0, time.UTC)

	// Sweep relative time offsets in [-60s, +60s] at 1s resolution.
	// trustedHeight < conflictingHeight (forward-lunatic precondition).
	const trustedHeight = int64(100)
	const conflictingHeight = int64(105)

	cases81OnlyRejects := 0
	cases148OnlyRejects := 0
	casesBothReject := 0
	casesNeitherRejects := 0
	cases148UnreachableViaVerify := 0
	cases148ReachableButFails := 0

	for delta := -60; delta <= 60; delta++ {
		trustedTime := baseTime
		conflictingTime := baseTime.Add(time.Duration(delta) * time.Second)

		l81 := line81Rejects(trustedTime, conflictingTime)
		l148 := line148Rejects(trustedHeight, conflictingHeight, trustedTime, conflictingTime)

		// Through evpool.verify, line 148 is only reached if line 81 did NOT reject.
		// So compute: is the path (line81=FALSE -> line148=TRUE) ever observed?
		reachableThroughVerify := !l81

		switch {
		case l81 && !l148:
			cases81OnlyRejects++
		case !l81 && l148:
			cases148OnlyRejects++
		case l81 && l148:
			casesBothReject++
		default:
			casesNeitherRejects++
		}

		if !reachableThroughVerify {
			cases148UnreachableViaVerify++
		} else if l148 {
			cases148ReachableButFails++
		}
	}

	fmt.Println("=== CR3: verify.go:148 dead-code reproduction ===")
	fmt.Printf("Total time-offset cases swept: %d\n", 121)
	fmt.Printf("Line 81 rejects only          : %d (path terminates at line 81; line 148 unreachable)\n", cases81OnlyRejects)
	fmt.Printf("Line 81 + 148 both reject     : %d (would reject at line 81; line 148 also fires if reached)\n", casesBothReject)
	fmt.Printf("Line 148 rejects but 81 didn't: %d (THIS IS WHAT WE EXPECT TO BE ZERO)\n", cases148OnlyRejects)
	fmt.Printf("Neither rejects               : %d (forward-lunatic at equal or earlier time — accepted)\n", casesNeitherRejects)
	fmt.Printf("Line 148 reached via verify   : %d (cases where evpool.verify falls through line 81 and reaches line 148)\n", cases148ReachableButFails+(121-cases148UnreachableViaVerify))
	fmt.Printf("Line 148 fires while reachable: %d\n", cases148ReachableButFails)

	failures := 0
	if cases148OnlyRejects > 0 {
		fmt.Printf("\nFAIL: line 148 rejected in %d cases where line 81 did not — unexpected (bug claim falsified)\n", cases148OnlyRejects)
		failures++
	}
	if cases148ReachableButFails > 0 {
		fmt.Printf("\nFAIL: line 148 reachable via evpool.verify and fired in %d cases — would contradict dead-code claim\n", cases148ReachableButFails)
		failures++
	}

	if failures == 0 {
		fmt.Println()
		fmt.Println("Reproduction: PASS — line 148's reject condition is a strict subset of line 81's.")
		fmt.Println("In all reachable paths through evpool.verify(), line 148 either does not fire (because")
		fmt.Println("trustedTime >= conflictingTime, the precondition for reaching it) or is preempted by")
		fmt.Println("line 81. CR3 confirmed as dead code under the production caller.")
		fmt.Println()
		fmt.Println("Note: line 148 IS reachable if VerifyLightClientAttack is invoked directly by")
		fmt.Println("external code paths (e.g., the verify_test.go tests at verify_test.go:45,50,...). Tests")
		fmt.Println("call it directly, bypassing evpool.verify's line 81 gate; line 148 then provides")
		fmt.Println("defense-in-depth for direct external callers. The TODO at verify.go:118 also notes")
		fmt.Println("`now` / `trustPeriod` parameters are unused — suggesting refactor candidates.")
		os.Exit(0)
	}
	fmt.Printf("\nReproduction: FAIL (%d assertion failure(s))\n", failures)
	os.Exit(1)
}
