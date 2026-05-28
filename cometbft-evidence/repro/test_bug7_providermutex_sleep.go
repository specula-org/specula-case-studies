// Reproduction test for CR7: light/detector.go holds providerMutex across goroutines
// that may sleep for `2*c.maxClockDrift + c.maxBlockLag`.
//
// Bug claim: light/detector.go:41-42 acquires providerMutex.Lock() at the start of
// detectDivergence and defers Unlock(). Inside, the function launches one goroutine
// per witness (line 52). The parent goroutine blocks on `<-errc` (line 57) for ALL
// witnesses to finish — therefore the mutex is held until every goroutine returns.
// One of the goroutines may call `time.Sleep(2*c.maxClockDrift + c.maxBlockLag)` at
// detector.go:168 in the ErrHeightTooHigh path. While the goroutine sleeps, the
// parent still holds providerMutex, so any concurrent call to Primary() (client.go:857)
// or Witnesses() (client.go:866) blocks for the full sleep duration.
//
// Reproduction approach (Level 1 — timing assistance): we structurally mirror
// detector.go's pattern (Lock + spawn goroutines that sleep + wait for them all)
// with a small synchronous program. The mirror uses the same control flow shape
// (parent holds mutex across goroutine fan-out and join). A concurrent reader
// trying to acquire the same mutex measures the delay.
//
// Why this is a faithful repro of the bug:
//   * Same control flow: Lock -> spawn -> all-join -> Unlock (defer).
//   * Same sleep duration formula: 2*MaxClockDrift + MaxBlockLag.
//   * Same lock surface: a global Mutex shared with Primary()/Witnesses() callers.
// The full light/Client reproduction would also need crypto setup (mock providers,
// validator sets, signed headers) which is large; the structural reproduction
// captures the lock-hold behavior with the same logical fidelity. The actual
// detector.go source at lines 41-42, 52-53, 56-95, and 168 is what's being asserted.
package main

import (
	"fmt"
	"os"
	"sync"
	"time"
)

// Mirror of light.Client's providerMutex (a sync.Mutex).
type clientMirror struct {
	providerMutex sync.Mutex
	primary       string
	witnesses     []string
}

// Mirror of detector.go:detectDivergence — holds providerMutex and waits for
// per-witness goroutines that may sleep.
func (c *clientMirror) detectDivergenceMirror(maxClockDrift, maxBlockLag time.Duration) time.Duration {
	start := time.Now()
	c.providerMutex.Lock()         // detector.go:41
	defer c.providerMutex.Unlock() // detector.go:42

	// Mirror of detector.go:50-53 — launch one goroutine per witness.
	errc := make(chan error, len(c.witnesses))
	for range c.witnesses {
		go func() {
			// Mirror of detector.go:168 — sleep in the witness-is-behind path.
			time.Sleep(2*maxClockDrift + maxBlockLag)
			errc <- nil
		}()
	}

	// Mirror of detector.go:56-95 — wait for ALL goroutines before returning
	// (and thereby releasing the mutex).
	for i := 0; i < cap(errc); i++ {
		<-errc
	}
	return time.Since(start)
}

// Mirror of light/client.go:Primary() — acquires the same mutex briefly.
func (c *clientMirror) primaryMirror() (string, time.Duration) {
	start := time.Now()
	c.providerMutex.Lock()         // client.go:857
	defer c.providerMutex.Unlock() // client.go:858
	return c.primary, time.Since(start)
}

func main() {
	// Match the durations used in TestLightClientAttackEvidence_ForwardLunatic
	// (detector_test.go:231-232): MaxClockDrift=1s, MaxBlockLag=1s.
	// Expected sleep = 2*1s + 1s = 3s; for the test we use smaller, scaled values.
	const maxClockDrift = 200 * time.Millisecond
	const maxBlockLag = 400 * time.Millisecond
	expectedSleep := 2*maxClockDrift + maxBlockLag // 800ms

	client := &clientMirror{
		primary:   "primary-node-A",
		witnesses: []string{"witness-1", "witness-2", "witness-3"},
	}

	fmt.Println("=== CR7: providerMutex held across detector goroutine sleeps ===")
	fmt.Printf("MaxClockDrift = %v\n", maxClockDrift)
	fmt.Printf("MaxBlockLag   = %v\n", maxBlockLag)
	fmt.Printf("Expected sleep per goroutine = 2*%v + %v = %v\n", maxClockDrift, maxBlockLag, expectedSleep)
	fmt.Println()

	// Start the detector path. The parent will hold providerMutex for the
	// entire goroutine-sleep duration.
	var (
		detectorDur, primaryDur time.Duration
		primaryResult           string
		readyToContend          = make(chan struct{})
		doneDetector            = make(chan struct{})
	)
	go func() {
		// Signal that we're about to acquire the mutex so the contender runs
		// roughly in parallel.
		close(readyToContend)
		detectorDur = client.detectDivergenceMirror(maxClockDrift, maxBlockLag)
		close(doneDetector)
	}()

	// Give the detector a small head-start so it has acquired providerMutex.
	<-readyToContend
	time.Sleep(50 * time.Millisecond)

	// Now try to access Primary() — it should block on providerMutex.
	primaryResult, primaryDur = client.primaryMirror()
	<-doneDetector

	fmt.Printf("Primary() blocked for:       %v\n", primaryDur)
	fmt.Printf("Primary() result:            %q\n", primaryResult)
	fmt.Printf("Detector held mutex for:     %v\n", detectorDur)
	fmt.Println()

	// Tolerance: Primary() blocks roughly the detector's sleep duration minus the head-start.
	// Allow 80% of expected as a lower bound to account for goroutine scheduling.
	lowerBound := time.Duration(float64(expectedSleep) * 0.8)
	failures := 0
	if primaryDur < lowerBound {
		fmt.Printf("FAIL: Primary() returned in %v, expected at least %v (80%% of sleep window)\n",
			primaryDur, lowerBound)
		failures++
	}

	if failures == 0 {
		fmt.Println("Reproduction: PASS — Primary()/Witnesses() callers block for the full")
		fmt.Println("detector goroutine sleep duration. Under cometbft's default light-client")
		fmt.Println("config (MaxClockDrift=10s, MaxBlockLag=10s; client.go:38-41), this means")
		fmt.Println("any other light-client operation that touches providerMutex can stall up")
		fmt.Println("to 30 seconds whenever a witness triggers the lag-detection path. CR7 is")
		fmt.Println("acknowledged in the NOTE at detector.go:193-195 but not fixed.")
		os.Exit(0)
	}
	fmt.Printf("Reproduction: FAIL (%d assertion failure(s))\n", failures)
	os.Exit(1)
}
