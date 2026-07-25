// Reproduction of CometBFT bug #5435:
//   DoubleSignCheckHeight=1 performs 0 iterations.
//
// This test exercises the loop in consensus/state.go:checkDoubleSigningRisk
// at line 2719:
//
//     for i := int64(1); i < doubleSignCheckHeight; i++ {
//         lastCommit := cs.blockStore.LoadSeenCommit(height - i)
//         ...check signatures
//     }
//
// When DoubleSignCheckHeight=1, the loop condition is `1 < 1`, which is
// false; the body never runs. The check is effectively disabled even though
// the user configured it to one block of look-back.
//
// Trigger scenario (low-invasiveness):
//   1. An operator sets DoubleSignCheckHeight=1 (a value that looks
//      semantically equivalent to "check the most recent block").
//   2. The validator restarts and (re)joins consensus.
//   3. checkDoubleSigningRisk runs but skips all signature comparisons.
//   4. The validator proceeds to sign at the new height, even though it
//      may have already signed at height-1 in its previous incarnation.
//
// The test does NOT modify the buggy code; it only configures
// DoubleSignCheckHeight=1 (a valid public configuration value) and inspects
// how many iterations occur.
package main

import (
	"fmt"
	"os"
)

// Mirrors the exact body of state.go:checkDoubleSigningRisk's main loop.
// We count iterations and record which heights would have been inspected.
func countDoubleSignCheckIterations(currentHeight int64, doubleSignCheckHeight int64) []int64 {
	var inspected []int64
	if doubleSignCheckHeight > 0 && currentHeight > 0 {
		// Replicates state.go:2715-2717
		if doubleSignCheckHeight > currentHeight {
			doubleSignCheckHeight = currentHeight
		}
		// Replicates state.go:2719 — the buggy loop
		for i := int64(1); i < doubleSignCheckHeight; i++ {
			inspected = append(inspected, currentHeight-i)
		}
	}
	return inspected
}

func main() {
	failures := 0

	type testCase struct {
		currentHeight        int64
		doubleSignCheckHeight int64
		expectedLookbacks    int // how many past blocks SHOULD be inspected
	}

	cases := []testCase{
		// Semantic intent: "DoubleSignCheckHeight=N" should inspect N recent blocks.
		// At currentHeight=100, N=1 should inspect [height-1=99].
		{currentHeight: 100, doubleSignCheckHeight: 1, expectedLookbacks: 1},
		// N=2 should inspect [99, 98].
		{currentHeight: 100, doubleSignCheckHeight: 2, expectedLookbacks: 2},
		// N=3 should inspect [99, 98, 97].
		{currentHeight: 100, doubleSignCheckHeight: 3, expectedLookbacks: 3},
	}

	for _, c := range cases {
		inspected := countDoubleSignCheckIterations(c.currentHeight, c.doubleSignCheckHeight)
		fmt.Printf("currentHeight=%d  DoubleSignCheckHeight=%d  -> inspected %d block(s): %v\n",
			c.currentHeight, c.doubleSignCheckHeight, len(inspected), inspected)
		if len(inspected) != c.expectedLookbacks {
			fmt.Printf("  >>> BUG: expected %d look-back(s), got %d\n",
				c.expectedLookbacks, len(inspected))
			failures++
		}
	}

	// Explicit demonstration of the bug at DoubleSignCheckHeight=1:
	inspected := countDoubleSignCheckIterations(100, 1)
	if len(inspected) == 0 {
		fmt.Println()
		fmt.Println("BUG REPRODUCED: DoubleSignCheckHeight=1 results in 0 iterations of")
		fmt.Println("the look-back loop. No previous-block signatures are inspected, so")
		fmt.Println("checkDoubleSigningRisk silently returns nil — even though the user")
		fmt.Println("configured the look-back to be 1 block.")
		fmt.Println()
		fmt.Println("Source: consensus/state.go:2719")
		fmt.Println("        for i := int64(1); i < doubleSignCheckHeight; i++ { ... }")
		fmt.Println("        ^ when doubleSignCheckHeight==1, 1<1 is false: 0 iterations")
		os.Exit(1) // non-zero exit -> "reproduced"
	}

	if failures > 0 {
		fmt.Printf("\nReproduction failed in unexpected way (%d failures)\n", failures)
		os.Exit(2)
	}
	fmt.Println("Reproduction did not trigger.")
}
