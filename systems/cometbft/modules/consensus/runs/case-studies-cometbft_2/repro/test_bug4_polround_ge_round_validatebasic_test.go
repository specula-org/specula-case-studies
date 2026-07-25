// Reproduction of CR-7 (Modeling brief §6.3 / §2.6):
//   types/proposal.go:Proposal.ValidateBasic accepts a proposal where
//   POLRound >= Round. By protocol semantics a Proof-of-Lock round must
//   refer to a PRIOR round, i.e. POLRound < Round.
//
// Code source (types/proposal.go:59-61):
//
//     if p.POLRound < -1 {
//         return errors.New("negative POLRound (exception: -1)")
//     }
//
// There is no upper bound check against `p.Round`. A Byzantine proposer
// can publish a proposal with `POLRound = Round` or `POLRound > Round`
// that passes ValidateBasic. Whether enterPrecommit recovers from the
// downstream lookup is a separate question; ValidateBasic itself is the
// first defensive gate and it does not enforce the protocol invariant.
//
// Test approach (Level 0 — pure public API):
//   1. Build a Proposal with POLRound = Round.
//   2. Call ValidateBasic. It should return an error per the protocol
//      semantics that POLRound must be a prior round (POLRound < Round).
//   3. Build a Proposal with POLRound > Round. Same expectation.

package repro_test

import (
	"strings"
	"testing"
	"time"

	cmtproto "github.com/cometbft/cometbft/proto/tendermint/types"
	"github.com/cometbft/cometbft/types"
)

func TestPOLRoundNotLessThanRoundPassesValidateBasic(t *testing.T) {
	// Construct a complete BlockID so ValidateBasic doesn't reject for that.
	blockID := types.BlockID{
		Hash: bytes32("repro-polround-blockid-hash-XX"),
		PartSetHeader: types.PartSetHeader{
			Total: 1,
			Hash:  bytes32("repro-polround-parts-XXXXXXX"),
		},
	}

	mk := func(round, polRound int32) *types.Proposal {
		return &types.Proposal{
			Type:      cmtproto.ProposalType,
			Height:    10,
			Round:     round,
			POLRound:  polRound,
			BlockID:   blockID,
			Timestamp: time.Unix(1_700_000_000, 0),
			Signature: bytes64("nonzero-signature-XX"),
		}
	}

	cases := []struct {
		name             string
		round, polRound  int32
		expectReject     bool
		semanticReason   string
	}{
		{"POLRound==Round (boundary)", 3, 3, true,
			"POLRound must be < Round (proof-of-lock is from a prior round)"},
		{"POLRound>Round (future)", 3, 7, true,
			"POLRound > Round refers to a future round that cannot yet have a polka"},
		{"POLRound==Round-1 (legitimate)", 3, 2, false,
			"prior round is valid"},
		{"POLRound=-1 (no lock)", 3, -1, false,
			"-1 sentinel means no lock"},
	}

	for _, c := range cases {
		p := mk(c.round, c.polRound)
		err := p.ValidateBasic()
		if c.expectReject {
			if err == nil {
				t.Logf("BUG REPRODUCED [%s]: ValidateBasic accepted Round=%d POLRound=%d",
					c.name, c.round, c.polRound)
				t.Logf("    semantics: %s", c.semanticReason)
			} else {
				t.Logf("[%s] ValidateBasic correctly rejected: %v", c.name, err)
			}
		} else {
			if err != nil && !strings.Contains(err.Error(), "POLRound") {
				t.Logf("[%s] ValidateBasic unexpected error (not about POLRound): %v",
					c.name, err)
			} else if err != nil {
				t.Logf("[%s] ValidateBasic rejected (with POLRound complaint): %v",
					c.name, err)
			} else {
				t.Logf("[%s] ValidateBasic accepted (as expected)", c.name)
			}
		}
	}

	// Final assertion: if a Round=3, POLRound=3 proposal slips past
	// ValidateBasic, that is the bug.
	if err := mk(3, 3).ValidateBasic(); err == nil {
		t.Logf("CONFIRMED: Proposal{Round=3, POLRound=3} passes ValidateBasic.")
		t.Logf("Fix location: types/proposal.go:59-61 — add `if p.POLRound >= p.Round && p.POLRound != -1`.")
		t.FailNow()
	}
}

// Helpers — produce deterministic 32-byte / 64-byte slices.
func bytes32(s string) []byte {
	b := make([]byte, 32)
	copy(b, s)
	return b
}
func bytes64(s string) []byte {
	b := make([]byte, 64)
	copy(b, s)
	return b
}
