// Reproduction of CometBFT issue #2252:
//   light/verifier.go:VerifyAdjacent does not cross-check the untrusted
//   header's LastBlockID against the trusted header. A Byzantine ≥1/3
//   of the trusted header's NextValidators can sign a header at H+1 with
//   LastBlockID pointing to a *different* prior block than the one in
//   trustedHeader, and VerifyAdjacent will still accept it.
//
// Test approach (Level 0 — black-box, public APIs only):
//   1. Build a trusted SignedHeader at height 1 (hash H1).
//   2. Build an "untrusted" SignedHeader at height 2 in which
//      LastBlockID.Hash is set to crypto-hash("fake-prior-block") instead
//      of H1. Same validator set; ≥2/3 of the same validators sign.
//   3. Call light.VerifyAdjacent(trusted, untrusted, ...). The function
//      should reject because LastBlockID points to a different block,
//      but it currently returns nil (accepts).
//
// Per the bug-confirmation skill:
//   - Public API used: light.VerifyAdjacent
//   - No internal state injection: both headers are constructed via
//     types.Header / SignedHeader and validators sign normally
//   - Observable harm: a light client following the canonical chain
//     would silently switch to a fork as long as ≥1/3 of the next
//     validator set is Byzantine (the DefaultTrustLevel boundary).
//
// Build/run:  go test -v ./test_bug2_verifyadjacent_lastblockid_test.go
package repro_test

import (
	"bytes"
	"testing"
	"time"

	"github.com/cometbft/cometbft/crypto"
	"github.com/cometbft/cometbft/crypto/ed25519"
	"github.com/cometbft/cometbft/crypto/tmhash"
	"github.com/cometbft/cometbft/light"
	cmtproto "github.com/cometbft/cometbft/proto/tendermint/types"
	cmtversion "github.com/cometbft/cometbft/proto/tendermint/version"
	"github.com/cometbft/cometbft/types"
	cmttime "github.com/cometbft/cometbft/types/time"
	"github.com/cometbft/cometbft/version"
)

type privKeys []crypto.PrivKey

func genPrivKeys(n int) privKeys {
	res := make(privKeys, n)
	for i := range res {
		res[i] = ed25519.GenPrivKey()
	}
	return res
}

func (pkz privKeys) toValidators(power int64) *types.ValidatorSet {
	res := make([]*types.Validator, len(pkz))
	for i, k := range pkz {
		res[i] = types.NewValidator(k.PubKey(), power)
	}
	return types.NewValidatorSet(res)
}

func makeVote(header *types.Header, valset *types.ValidatorSet,
	key crypto.PrivKey, blockID types.BlockID,
) *types.Vote {
	addr := key.PubKey().Address()
	idx, _ := valset.GetByAddress(addr)
	vote := &types.Vote{
		ValidatorAddress: addr,
		ValidatorIndex:   idx,
		Height:           header.Height,
		Round:            1,
		Timestamp:        cmttime.Now(),
		Type:             cmtproto.PrecommitType,
		BlockID:          blockID,
	}
	v := vote.ToProto()
	signBytes := types.VoteSignBytes(header.ChainID, v)
	sig, err := key.Sign(signBytes)
	if err != nil {
		panic(err)
	}
	vote.Signature = sig
	extSignBytes := types.VoteExtensionSignBytes(header.ChainID, v)
	extSig, err := key.Sign(extSignBytes)
	if err != nil {
		panic(err)
	}
	vote.ExtensionSignature = extSig
	return vote
}

func (pkz privKeys) signHeader(header *types.Header, valSet *types.ValidatorSet) *types.Commit {
	commitSigs := make([]types.CommitSig, len(pkz))
	for i := range commitSigs {
		commitSigs[i] = types.NewCommitSigAbsent()
	}
	blockID := types.BlockID{
		Hash:          header.Hash(),
		PartSetHeader: types.PartSetHeader{Total: 1, Hash: crypto.CRandBytes(32)},
	}
	for i := 0; i < len(pkz); i++ {
		vote := makeVote(header, valSet, pkz[i], blockID)
		commitSigs[vote.ValidatorIndex] = vote.CommitSig()
	}
	return &types.Commit{
		Height:     header.Height,
		Round:      1,
		BlockID:    blockID,
		Signatures: commitSigs,
	}
}

func mkHash(s string) []byte { return tmhash.Sum([]byte(s)) }

func genHeader(chainID string, height int64, bTime time.Time,
	valset, nextValset *types.ValidatorSet, lastBlockID types.BlockID,
) *types.Header {
	return &types.Header{
		Version:            cmtversion.Consensus{Block: version.BlockProtocol, App: 0},
		ChainID:            chainID,
		Height:             height,
		Time:               bTime,
		LastBlockID:        lastBlockID,
		ValidatorsHash:     valset.Hash(),
		NextValidatorsHash: nextValset.Hash(),
		DataHash:           types.Txs{}.Hash(),
		AppHash:            mkHash("app_hash"),
		ConsensusHash:      mkHash("cons_hash"),
		LastResultsHash:    mkHash("results_hash"),
		ProposerAddress:    valset.Validators[0].Address,
	}
}

// TestVerifyAdjacent_MissingLastBlockIDCheck demonstrates issue #2252:
// a Byzantine quorum of next-validators can sign a header at H+1 with
// LastBlockID pointing to a different prior block than the trusted one,
// and VerifyAdjacent will accept it.
func TestVerifyAdjacent_MissingLastBlockIDCheck(t *testing.T) {
	const chainID = "repro-2252"

	keys := genPrivKeys(4)
	vals := keys.toValidators(10) // equal weights → must sign 3 of 4 for ≥2/3
	bTime, _ := time.Parse(time.RFC3339, "2026-05-01T00:00:00Z")

	// Trusted header at height 1.
	trustedHdr := genHeader(chainID, 1, bTime, vals, vals, types.BlockID{})
	trustedSignedHdr := &types.SignedHeader{
		Header: trustedHdr,
		Commit: keys.signHeader(trustedHdr, vals),
	}

	trustedHash := trustedHdr.Hash()
	t.Logf("Trusted hash (height 1):       %X", trustedHash)

	// Untrusted (forked) header at height 2.
	// LastBlockID is a FAKE block id, NOT the trusted header's hash.
	fakeLastBlockID := types.BlockID{
		Hash:          mkHash("fake-prior-block"),
		PartSetHeader: types.PartSetHeader{Total: 1, Hash: mkHash("fake-parts")},
	}
	t.Logf("Forked LastBlockID.Hash:        %X", fakeLastBlockID.Hash)

	untrustedHdr := genHeader(chainID, 2, bTime.Add(1*time.Minute),
		vals, vals, fakeLastBlockID)
	untrustedSignedHdr := &types.SignedHeader{
		Header: untrustedHdr,
		Commit: keys.signHeader(untrustedHdr, vals),
	}

	if bytes.Equal(untrustedSignedHdr.Header.LastBlockID.Hash, trustedHash) {
		t.Fatalf("test setup error: untrustedHeader.LastBlockID equals trusted hash")
	}

	// Public-API call: VerifyAdjacent.
	err := light.VerifyAdjacent(
		trustedSignedHdr,
		untrustedSignedHdr,
		vals,
		3*time.Hour,
		bTime.Add(30*time.Minute),
		10*time.Second,
	)

	if err == nil {
		t.Logf("BUG REPRODUCED: VerifyAdjacent accepted an untrusted header whose")
		t.Logf("LastBlockID (%X) does not equal the trusted header hash (%X).",
			untrustedSignedHdr.Header.LastBlockID.Hash, trustedHash)
		t.Logf("Issue #2252: light/verifier.go:VerifyAdjacent does not cross-")
		t.Logf("check untrustedHeader.LastBlockID against trustedHeader.Hash.")
		// Per the test's purpose we expect a *failure* of the function;
		// since VerifyAdjacent silently accepted the fork, we surface that
		// as a test failure ("bug present").
		t.FailNow()
	} else {
		t.Logf("VerifyAdjacent rejected as expected: %v", err)
	}
}
