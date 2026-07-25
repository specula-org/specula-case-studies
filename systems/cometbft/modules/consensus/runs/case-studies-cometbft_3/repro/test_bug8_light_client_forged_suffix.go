// Bug #8 reproduction — VerifyCommitLightTrusting accepts forged signatures past the
// trust threshold.
//
// Trigger: VerifyCommitLightTrusting (types/validation.go:148-194, internally
// verifyCommitLightTrustingInternal at :196-239) passes countAllSignatures=false to
// the verifier. The verifier returns nil as soon as enough valid signatures cover
// the trust level (e.g. 1/3 of voting power), without inspecting the remaining
// signatures. A Byzantine peer can craft a commit whose first 1/3 of signatures
// are valid and the rest are forged; the trusting verifier accepts it; the
// all-signatures variant would reject it.
//
// The cometbft suite already contains a near-identical canonical test:
//   types/validation_test.go:217-254
//   TestValidatorSet_VerifyCommitLightTrusting_ReturnsAsSoonAsTrustLevelSignedIffNotAllSigs
// which documents this behavior (mallet the 3rd signature, then verify Trusting
// accepts but TrustingAllSignatures rejects). That test passes today.
//
// Our repro is a thin wrapper that re-runs the same shape against the live code
// and prints the contrast explicitly.
//
// Copy to artifact/cometbft/types/bug8_trusting_test.go and run:
//   cd artifact/cometbft
//   go test -run TestBug8LightClientAcceptsForgedSuffix -v ./types/...
package types

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	cmtmath "github.com/cometbft/cometbft/libs/math"
	cmtproto "github.com/cometbft/cometbft/proto/tendermint/types"
)

func TestBug8LightClientAcceptsForgedSuffix(t *testing.T) {
	const (
		chainID = "test_chain_id"
		h       = int64(3)
	)
	blockID := makeBlockIDRandom()

	// 4 validators, equal voting power. Trust level 1/3 ⇒ 2 valid signatures cover it.
	voteSet, valSet, vals := randVoteSet(h, 0, cmtproto.PrecommitType, 4, 10, false)
	extCommit, err := MakeExtCommit(blockID, h, 0, voteSet, vals, time.Now(), false)
	require.NoError(t, err)
	commit := extCommit.ToCommit()

	// Pre-condition: pristine commit must verify under BOTH variants.
	require.NoError(t, valSet.VerifyCommit(chainID, blockID, h, commit), "pristine commit must verify-commit")
	require.NoError(t,
		valSet.VerifyCommitLightTrustingAllSignatures(chainID, commit, cmtmath.Fraction{Numerator: 1, Denominator: 3}),
		"pristine commit must pass *AllSignatures variant")

	// Adversary: mallet signature at index 2 (past the 1/3 threshold). Re-sign with a
	// different chain ID to invalidate the signature on the original chain ID.
	vote := voteSet.GetByIndex(2)
	v := vote.ToProto()
	require.NoError(t, vals[2].SignVote("CentaurusA", v)) // wrong chain → bad sig for our context
	vote.Signature = v.Signature
	vote.ExtensionSignature = v.ExtensionSignature
	commit.Signatures[2] = vote.CommitSig()

	// The trusting variant accepts the forged suffix because it exits at the 1/3
	// threshold (signatures 0 and 1 alone are enough).
	errTrust := valSet.VerifyCommitLightTrusting(chainID, commit, cmtmath.Fraction{Numerator: 1, Denominator: 3})
	assert.NoError(t, errTrust,
		"BUG: VerifyCommitLightTrusting accepted a commit whose 3rd signature is forged. "+
			"The verifier early-exits at 1/3 voting power (sigs 0,1 cover it); the forged sig at "+
			"index 2 is never read.")

	// The all-signatures variant detects the forgery because it tallies every sig.
	errAll := valSet.VerifyCommitLightTrustingAllSignatures(chainID, commit, cmtmath.Fraction{Numerator: 1, Denominator: 3})
	assert.Error(t, errAll,
		"sanity: VerifyCommitLightTrustingAllSignatures must reject the same forged commit "+
			"(counting all sigs)")

	t.Logf("CONFIRMED: VerifyCommitLightTrusting accepts forged-suffix commit (err=%v) while "+
		"VerifyCommitLightTrustingAllSignatures rejects the same input (err=%v). The trusting "+
		"variant's early-exit at the 1/3 threshold is documented behavior; the bug is that some "+
		"callers (statesync OfferSnapshot, light/detector.go) need the all-signatures variant.",
		errTrust, errAll)
}
