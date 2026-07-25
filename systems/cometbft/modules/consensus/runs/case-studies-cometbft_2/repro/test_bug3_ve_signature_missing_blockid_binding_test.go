// Reproduction of CometBFT Family 3 finding (Modeling brief §2.3):
//   The VoteExtension signature payload (`CanonicalizeVoteExtension`)
//   does NOT include BlockID. The signed bytes are
//   {Extension, Height, Round, ChainID} only — see types/canonical.go:71-78.
//
//   Consequence: the same VE signature is valid for two conflicting
//   precommits at the same (H, R) for different BlockIDs. A Byzantine
//   validator can equivocate at (H, R) and attach the same VE signature
//   to both precommits; both pass `vote.VerifyExtension`.
//
// This is the structural premise of Family 3 (MC-5). The harm requires
// composition with another action — e.g. it lets the same VE flow into
// `BuildExtendedCommitInfo` regardless of which conflicting precommit is
// later canonicalized — but the absence of BlockID binding is itself
// observable at the public API level.
//
// Test approach (Level 0 — pure black-box):
//   1. Build a signing key and a VoteExtension bytestring.
//   2. Construct precommit A at (h=10, r=0) with BlockID_A.
//   3. Sign the canonical VE bytes for the precommit.
//   4. Construct precommit B at (h=10, r=0) with BlockID_B ≠ BlockID_A
//      but carrying the SAME ExtensionSignature taken from A.
//   5. Call vote.VerifyExtension on both votes. Both should pass.
//
// Observable harm: the VE signature is not bound to BlockID at all —
// `types/canonical.go:CanonicalizeVoteExtension` deliberately omits it.

package repro_test

import (
	"testing"
	"time"

	"github.com/cometbft/cometbft/crypto/ed25519"
	cmtproto "github.com/cometbft/cometbft/proto/tendermint/types"
	"github.com/cometbft/cometbft/types"
)

func TestVEExtSignatureNotBoundToBlockID(t *testing.T) {
	const chainID = "repro-ve-blockid"
	key := ed25519.GenPrivKey()
	pub := key.PubKey()
	addr := pub.Address()

	ext := []byte("vote-extension-payload-v1")

	mkBlockID := func(seed string) types.BlockID {
		// 32-byte hash for BlockID, deterministic from seed.
		h := make([]byte, 32)
		copy(h, seed)
		ph := make([]byte, 32)
		copy(ph, seed+"-parts")
		return types.BlockID{
			Hash:          h,
			PartSetHeader: types.PartSetHeader{Total: 1, Hash: ph},
		}
	}

	blockIDA := mkBlockID("blockA-hash-data")
	blockIDB := mkBlockID("blockB-hash-data")

	// Build the canonical Extension sign-bytes (same for both A and B because
	// CanonicalizeVoteExtension omits BlockID).
	voteForExtSig := &types.Vote{
		Type:             cmtproto.PrecommitType,
		Height:           10,
		Round:            0,
		BlockID:          blockIDA, // anything non-zero; the BlockID is NOT in the canonical extension
		Timestamp:        time.Unix(1_700_000_000, 0),
		ValidatorAddress: addr,
		ValidatorIndex:   0,
		Extension:        ext,
	}
	v := voteForExtSig.ToProto()
	extSignBytes := types.VoteExtensionSignBytes(chainID, v)
	extSig, err := key.Sign(extSignBytes)
	if err != nil {
		t.Fatalf("key.Sign(extSignBytes): %v", err)
	}

	// Now construct two votes: A (with original BlockID) and B (different BlockID).
	// Both carry the same ExtensionSignature.
	voteA := &types.Vote{
		Type:               cmtproto.PrecommitType,
		Height:             10,
		Round:              0,
		BlockID:            blockIDA,
		Timestamp:          time.Unix(1_700_000_000, 0),
		ValidatorAddress:   addr,
		ValidatorIndex:     0,
		Extension:          ext,
		ExtensionSignature: extSig,
	}
	voteB := &types.Vote{
		Type:               cmtproto.PrecommitType,
		Height:             10,
		Round:              0,
		BlockID:            blockIDB,
		Timestamp:          time.Unix(1_700_000_000, 0),
		ValidatorAddress:   addr,
		ValidatorIndex:     0,
		Extension:          ext,
		ExtensionSignature: extSig, // same signature
	}

	if err := voteA.VerifyExtension(chainID, pub); err != nil {
		t.Fatalf("VerifyExtension(voteA) returned error: %v (expected pass)", err)
	}
	t.Logf("voteA (BlockID=%X): VerifyExtension PASSED", voteA.BlockID.Hash[:8])

	if err := voteB.VerifyExtension(chainID, pub); err != nil {
		t.Logf("VerifyExtension(voteB) returned error: %v -- this would be the FIX behavior", err)
		t.Logf("Bug not reproduced: signature appears bound to BlockID.")
		return
	}
	t.Logf("voteB (BlockID=%X): VerifyExtension PASSED with the SAME ExtensionSignature as voteA",
		voteB.BlockID.Hash[:8])

	t.Logf("BUG REPRODUCED: One VE ExtensionSignature is valid for two precommits")
	t.Logf("at the same (H=%d, R=%d) with DIFFERENT BlockIDs.", voteA.Height, voteA.Round)
	t.Logf("Root cause: types/canonical.go:71-78 CanonicalizeVoteExtension covers only")
	t.Logf("{Extension, Height, Round, ChainID} — BlockID is not in the canonical")
	t.Logf("payload, so a single signed extension binds to (H, R) only.")
	t.FailNow()
}
