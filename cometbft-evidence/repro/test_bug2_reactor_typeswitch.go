// Reproduction test for CR2: evidence/reactor.go:82 uses err.(type) instead of errors.As.
//
// Bug: evidence/reactor.go:82-92
//   err := evR.evpool.AddEvidence(ev)
//   switch err.(type) {
//   case *types.ErrInvalidEvidence:
//       evR.Switch.StopPeerForError(e.Src, err)  // punish the peer
//       return
//   case nil:
//   default:
//       evR.Logger.Error("Evidence has not been added", "evidence", evis, "err", err)
//   }
//
// Today, evidence/pool.go:162 returns `types.NewErrInvalidEvidence(ev, err)` directly,
// so the type switch matches the case at line 83 and the peer is stopped correctly.
//
// However:
//  - If any future caller wraps the error with `fmt.Errorf("verify: %w", ...)` or
//    `errors.Join(...)` between the verify step and the switch, the type switch
//    silently falls through to the `default` branch and a Byzantine peer that
//    repeatedly submits invalid evidence is NOT punished.
//  - There is ALREADY one call site that wraps: pool.go:167
//      return fmt.Errorf("can't add evidence to pending list: %w", err)
//    This is the *post*-verify branch (DB error path), so it doesn't matter for the
//    peer-punishment intent — but it shows the codebase already mixes wrapped and
//    unwrapped errors.
//
// Engineering principle violated: type-switch on error type is fragile and brittle;
// errors.As is the documented Go idiom (Go 1.13+).
//
// Reproduction approach (Level 0): exhibit two error-returning patterns — direct
// vs `%w`-wrapped — and show that the type-switch idiom (mirroring reactor.go:82)
// classifies them differently, while `errors.As` classifies them identically.
package main

import (
	"errors"
	"fmt"
	"os"
)

// Mirror of types.ErrInvalidEvidence (types/evidence.go:551-564).
type ErrInvalidEvidence struct {
	Reason error
}

func (e *ErrInvalidEvidence) Error() string {
	return fmt.Sprintf("Invalid evidence: %v", e.Reason)
}

// Mirror of the current reactor.go:82 classification: returns true if peer would be punished.
func classifyTypeSwitch(err error) (punishPeer bool, description string) {
	switch err.(type) {
	case *ErrInvalidEvidence:
		return true, "matched *ErrInvalidEvidence (peer punished)"
	case nil:
		return false, "nil (no action)"
	default:
		return false, "default branch (peer NOT punished, error only logged)"
	}
}

// Recommended fix using errors.As (Go 1.13+ idiom).
func classifyErrorsAs(err error) (punishPeer bool, description string) {
	if err == nil {
		return false, "nil (no action)"
	}
	var target *ErrInvalidEvidence
	if errors.As(err, &target) {
		return true, "errors.As matched *ErrInvalidEvidence (peer punished)"
	}
	return false, "errors.As did not match (peer NOT punished, error only logged)"
}

func main() {
	// Case A: today's AddEvidence verify branch returns a direct *ErrInvalidEvidence
	// (pool.go:162). The current code handles this correctly.
	directErr := &ErrInvalidEvidence{Reason: errors.New("signature mismatch")}

	// Case B: hypothetical wrapping — any caller that does fmt.Errorf("...: %w", originalErr)
	// would produce an error whose dynamic type is *fmt.wrapError, not *ErrInvalidEvidence.
	// This is the exact pattern already used at pool.go:167 for a non-verify path.
	wrappedErr := fmt.Errorf("during AddEvidence: %w", directErr)

	// Case C: errors.Join (Go 1.20+) — another common wrapping pattern.
	joinedErr := errors.Join(errors.New("other err"), directErr)

	fmt.Println("=== CR2: evidence/reactor.go err.(type) classification fragility ===")
	fmt.Println()
	fmt.Println("Pattern A (current AddEvidence behavior — direct *ErrInvalidEvidence):")
	pTS, dTS := classifyTypeSwitch(directErr)
	pAs, dAs := classifyErrorsAs(directErr)
	fmt.Printf("  err.(type) switch: punishPeer=%v  (%s)\n", pTS, dTS)
	fmt.Printf("  errors.As       : punishPeer=%v  (%s)\n", pAs, dAs)

	fmt.Println()
	fmt.Println("Pattern B (any caller wraps with fmt.Errorf(\"...: %w\", err)):")
	pTSb, dTSb := classifyTypeSwitch(wrappedErr)
	pAsb, dAsb := classifyErrorsAs(wrappedErr)
	fmt.Printf("  err.(type) switch: punishPeer=%v  (%s)\n", pTSb, dTSb)
	fmt.Printf("  errors.As       : punishPeer=%v  (%s)\n", pAsb, dAsb)

	fmt.Println()
	fmt.Println("Pattern C (errors.Join — Go 1.20+ pattern):")
	pTSc, dTSc := classifyTypeSwitch(joinedErr)
	pAsc, dAsc := classifyErrorsAs(joinedErr)
	fmt.Printf("  err.(type) switch: punishPeer=%v  (%s)\n", pTSc, dTSc)
	fmt.Printf("  errors.As       : punishPeer=%v  (%s)\n", pAsc, dAsc)

	failures := 0
	// Behavioral claim: type-switch loses the Invalid classification under wrapping.
	if pTSb {
		fmt.Println("\nFAIL: type-switch unexpectedly classified wrapped err as ErrInvalidEvidence")
		failures++
	}
	if pTSc {
		fmt.Println("\nFAIL: type-switch unexpectedly classified joined err as ErrInvalidEvidence")
		failures++
	}
	if !pAsb || !pAsc {
		fmt.Println("\nFAIL: errors.As should have classified wrapped/joined err correctly")
		failures++
	}

	if failures == 0 {
		fmt.Println()
		fmt.Println("Reproduction: PASS — type-switch silently downgrades wrapped *ErrInvalidEvidence")
		fmt.Println("to 'default' (no peer punishment), while errors.As classifies it correctly.")
		fmt.Println("This is a latent fragility: any future error-wrapping change in the AddEvidence")
		fmt.Println("call chain would silently disable peer-punishment for Byzantine evidence senders.")
		os.Exit(0)
	}
	fmt.Printf("\nReproduction: FAIL (%d assertion failure(s))\n", failures)
	os.Exit(1)
}
