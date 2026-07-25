// Bug #7 reproduction attempt — Untrusted proto ValidatorSet → int64 overflow panic.
//
// Claim from the MC bug report: a Byzantine peer can supply a cmtproto.ValidatorSet
// whose summed voting power exceeds MaxInt64 (or MaxTotalVotingPower = MaxInt64/8),
// and reach a production call site of the panicking variant TotalVotingPower()
// (consensus/state.go:1856, 2298, 2590, 2621, 2644, blocksync/reactor.go:453,
//  light/detector.go:429-433, types/evidence.go:75, types/validation.go:40,121,216).
//
// Investigation: every reachable peer-input boundary deserialises proto via
// ValidatorSetFromProto (types/validator_set.go:976-1011), which at line 1006 calls
// TotalVotingPowerSafe() and returns an error on overflow. So a malformed proto is
// rejected before the panicking variant ever sees it. The other call sites all
// operate on a ValidatorSet already in trusted local state (cs.Validators,
// state.Validators) or already gated by ValidatorSetFromProto (LightBlockFromProto
// at types/light.go:88-112, via light/store/db/db.go:127 and statesync).
//
// This test exercises the boundary path and confirms: a crafted overflow proto is
// REJECTED at deserialisation with an explicit error; no panic. That refutes the
// bug claim in its current framing.
//
// Copy to artifact/cometbft/types/bug7_overflow_test.go and run:
//   cd artifact/cometbft
//   go test -run TestBug7ProtoOverflowRejectedAtBoundary -v ./types/...
package types

import (
	"math"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/cometbft/cometbft/crypto/ed25519"
	cryptoenc "github.com/cometbft/cometbft/crypto/encoding"
	cmtproto "github.com/cometbft/cometbft/proto/tendermint/types"
)

func TestBug7ProtoOverflowRejectedAtBoundary(t *testing.T) {
	// Craft 9 fake validators, each with VotingPower = MaxInt64/8. Sum = 9 * (MaxInt64/8)
	// which overflows int64 — but is also strictly greater than MaxTotalVotingPower
	// (= MaxInt64/8), so the safe-add early-return at types/validator_set.go:338-341
	// must trip.
	const numVals = 9
	pp := int64(math.MaxInt64 / 8)

	protoVals := make([]*cmtproto.Validator, numVals)
	for i := 0; i < numVals; i++ {
		priv := ed25519.GenPrivKey()
		pk := priv.PubKey()
		pkProto, err := cryptoenc.PubKeyToProto(pk)
		require.NoError(t, err)
		protoVals[i] = &cmtproto.Validator{
			Address:          pk.Address(),
			PubKey:           pkProto,
			VotingPower:      pp,
			ProposerPriority: 0,
		}
	}

	pbVS := &cmtproto.ValidatorSet{
		Validators: protoVals,
		Proposer:   protoVals[0],
		// TotalVotingPower in proto is *ignored* (re-computed in Go), per
		// types/validator_set.go:1000-1008 note.
	}

	// The byzantine peer's proto is fed to ValidatorSetFromProto. Per the safe-from-
	// proto guarantee, this MUST return an error and not panic.
	vs, err := ValidatorSetFromProto(pbVS)
	require.Error(t, err, "Byzantine proto with overflowing voting power must be rejected at deserialisation")
	require.Nil(t, vs)
	require.Contains(t, err.Error(), "exceeds maximum",
		"the safe check at validator_set.go:340 must be the error source (got: %v)", err)

	t.Logf("REFUTED IN CURRENT FRAMING: the ValidatorSetFromProto boundary at "+
		"types/validator_set.go:976-1011 rejects a peer-supplied proto with overflowing "+
		"voting power (error=%q). All listed production call sites of TotalVotingPower() "+
		"either operate on trusted local state or on values already gated by "+
		"ValidatorSetFromProto/LightBlockFromProto. The panic path is therefore not "+
		"reachable from a Byzantine peer in the bug report's stated form. The hygiene "+
		"recommendation to migrate every site to TotalVotingPowerSafe still stands.", err)
}
