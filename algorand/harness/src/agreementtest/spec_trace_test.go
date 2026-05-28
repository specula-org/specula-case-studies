// Copyright (C) 2019-2026 Algorand Foundation Ltd.
// This file is part of go-algorand
//
// Specula harness: trace-collection scenarios.
//
// Each Test* function below drives the agreement Simulate driver for a small
// number of rounds with the trace writer enabled. The trace destination is
// taken from SPECULA_TRACE_DIR/<scenario>.ndjson; if unset, an in-tree path
// under t.TempDir() is used and the test still passes — so this file is
// safe to run in normal CI.
//
// These scenarios exist purely to exercise instrumented code paths. They do
// not assert on specific trace contents (that is the spec validator's job in
// Phase 3); they only assert that the underlying protocol still drives to
// completion.

package agreementtest

import (
	"math/rand"
	"os"
	"path/filepath"
	"strconv"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/algorand/go-algorand/agreement"
	"github.com/algorand/go-algorand/data/basics"
	basics_testing "github.com/algorand/go-algorand/data/basics/testing"
	"github.com/algorand/go-algorand/logging"
)

// resolveTracePath returns the file where this scenario should write its trace.
//
//  1. If $SPECULA_TRACE_DIR is set: $SPECULA_TRACE_DIR/<scenario>.ndjson
//  2. Else if $SPECULA_TRACE is set: that exact path
//  3. Else: <t.TempDir()>/<scenario>.ndjson
func resolveTracePath(t *testing.T, scenario string) string {
	if dir := os.Getenv("SPECULA_TRACE_DIR"); dir != "" {
		_ = os.MkdirAll(dir, 0o755)
		return filepath.Join(dir, scenario+".ndjson")
	}
	if path := os.Getenv("SPECULA_TRACE"); path != "" {
		return path
	}
	return filepath.Join(t.TempDir(), scenario+".ndjson")
}

// runSimulateWithTrace runs the existing Simulate driver under trace
// emission.
func runSimulateWithTrace(t *testing.T, scenario string, numAccounts int, numRounds basics.Round, seed int64) {
	path := resolveTracePath(t, scenario)
	require.True(t, agreement.SpecTraceInit(path), "specula trace init failed for %s", path)
	defer agreement.SpecTraceClose()

	logging.Base().SetLevel(logging.Warn) // keep test output tidy

	maxMoneyAtStart := 100001
	minMoneyAtStart := 100000

	genesis := make(map[basics.Address]basics.AccountData)
	incentivePoolAtStart := uint64(1000 * 1000)
	accData := basics_testing.MakeAccountData(basics.NotParticipating, basics.MicroAlgos{Raw: incentivePoolAtStart})
	genesis[poolAddr] = accData
	gen := rand.New(rand.NewSource(seed))

	_, accs, release := generateNAccounts(t, numAccounts, 0, numRounds+50, minMoneyAtStart)
	defer release()

	for i, acc := range accs {
		amount := basics.MicroAlgos{Raw: uint64(minMoneyAtStart + (gen.Int() % (maxMoneyAtStart - minMoneyAtStart)))}
		genesis[acc.Address()] = basics.AccountData{
			Status:      basics.Online,
			MicroAlgos:  amount,
			SelectionID: acc.VRFSecrets().PK,
			VoteID:      acc.VotingSecrets().OneTimeSignatureVerifier,
		}
		// Pre-register each address with a stable n<i> id so trace files have
		// predictable senders regardless of which one shows up first on the wire.
		agreement.SpecTraceRegisterServer(acc.Address(), "n"+strconv.Itoa(i+1))
	}

	l := makeTestLedger(genesis)
	err := Simulate(t.Name(), numRounds, deadline, l, SimpleKeyManager(accs), testBlockFactory{}, testBlockValidator{}, logging.Base())
	require.NoError(t, err)
}

// TestTrace_NormalAgreement: 5 accounts, 6 rounds, no faults — the happy
// path. Drives ProposeBlock / Issue*Vote / BroadcastVote / PersistState /
// EnterRound at minimum.
func TestTrace_NormalAgreement(t *testing.T) {
	runSimulateWithTrace(t, "normal_agreement", 5, basics.Round(6), 42)
}

// TestTrace_LargerCommittee: 10 accounts, 4 rounds. More keys per pseudonode
// produces more votes per step, increasing the chance of UpdateNextThresholdCache
// and UpdateFreshest events.
func TestTrace_LargerCommittee(t *testing.T) {
	runSimulateWithTrace(t, "larger_committee", 10, basics.Round(4), 7)
}

// TestTrace_ShortRun: 3 accounts, 3 rounds — small smoke test that runs fast.
func TestTrace_ShortRun(t *testing.T) {
	runSimulateWithTrace(t, "short_run", 3, basics.Round(3), 99)
}

// TestTrace_DiverseSeeds: identical setup to short_run but with a different
// random source. Useful for exercising different proposer selections.
func TestTrace_DiverseSeeds(t *testing.T) {
	runSimulateWithTrace(t, "diverse_seeds", 4, basics.Round(4), 12345)
}
