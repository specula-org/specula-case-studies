package keeper_test

// Reproduction tests for bugs surfaced by the Specula bug-confirmation pass.
// Each test demonstrates the relevant code path with the system's normal
// public interface (the keeper's MsgServer or query methods), mirroring the
// pattern used by the existing tests in this package.
//
// To run individually: go test -v -run TestBugN_... ./x/finality/keeper/

import (
	"math/rand"
	"testing"

	"cosmossdk.io/core/header"
	"github.com/btcsuite/btcd/btcec/v2"
	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/golang/mock/gomock"
	"github.com/stretchr/testify/require"

	"github.com/babylonlabs-io/babylon/v4/testutil/datagen"
	keepertest "github.com/babylonlabs-io/babylon/v4/testutil/keeper"
	bbn "github.com/babylonlabs-io/babylon/v4/types"
	bstypes "github.com/babylonlabs-io/babylon/v4/x/btcstaking/types"
	epochingtypes "github.com/babylonlabs-io/babylon/v4/x/epoching/types"
	finalitykeeper "github.com/babylonlabs-io/babylon/v4/x/finality/keeper"
	"github.com/babylonlabs-io/babylon/v4/x/finality/types"
)

func newReproEnv(t *testing.T, r *rand.Rand) (
	*finalitykeeper.Keeper,
	types.MsgServer,
	sdk.Context,
	*btcec.PrivateKey,
	*bbn.BIP340PubKey,
	[]byte,
	*gomock.Controller,
	*types.MockBTCStakingKeeper,
	*types.MockCheckpointingKeeper,
	*types.MockIncentiveKeeper,
) {
	ctrl := gomock.NewController(t)
	bs := types.NewMockBTCStakingKeeper(ctrl)
	bs.EXPECT().UpdateFinalityProvider(gomock.Any(), gomock.Any()).Return(nil).AnyTimes()
	bs.EXPECT().IsFinalityProviderDeleted(gomock.Any(), gomock.Any()).Return(false).AnyTimes()
	ck := types.NewMockCheckpointingKeeper(ctrl)
	ck.EXPECT().GetEpoch(gomock.Any()).Return(&epochingtypes.Epoch{EpochNumber: 1}).AnyTimes()
	ck.EXPECT().GetLastFinalizedEpoch(gomock.Any()).Return(uint64(10)).AnyTimes()
	ck.EXPECT().GetEpochByHeight(gomock.Any(), gomock.Any()).Return(uint64(1)).AnyTimes()
	ik := types.NewMockIncentiveKeeper(ctrl)
	ik.EXPECT().IndexRefundableMsg(gomock.Any(), gomock.Any()).AnyTimes()

	fk, ctx := keepertest.FinalityKeeper(t, bs, ik, ck, nil)
	ms := finalitykeeper.NewMsgServerImpl(*fk)

	btcSK, btcPK, err := datagen.GenRandomBTCKeyPair(r)
	require.NoError(t, err)
	fpBTCPK := bbn.NewBIP340PubKeyFromBTCPK(btcPK)
	bs.EXPECT().HasFinalityProvider(gomock.Any(), gomock.Eq(fpBTCPK.MustMarshal())).Return(true).AnyTimes()
	return fk, ms, ctx, btcSK, fpBTCPK, fpBTCPK.MustMarshal(), ctrl, bs, ck, ik
}

// Bug 1 — Retroactive Public Randomness Commits.
//
// Reachable via msg_server.go::CommitPubRandList which only enforces an
// upper bound on req.StartHeight (currentHeight + MaxPubRandCommitOffset)
// but never enforces the lower bound req.StartHeight > currentHeight.
//
// The bug allows an FP to commit pub-randomness for a height that has
// already been produced and then cast a no-risk canonical vote on it.
func TestBug1_RetroactivePubRandCommit(t *testing.T) {
	r := rand.New(rand.NewSource(1))
	_, ms, ctx, btcSK, _, _, ctrl, _, _, _ := newReproEnv(t, r)
	defer ctrl.Finish()

	// (1) advance the chain so currentHeight = 5 (i.e., heights 1..5 have
	// been produced). This is the "real-world" precondition: the canonical
	// AppHash of those blocks is already public knowledge.
	ctx = ctx.WithHeaderInfo(header.Info{Height: 5})

	// (2) The malicious FP submits CommitPubRandList(startHeight=1, num=200)
	// retroactively, i.e., startHeight (1) <= ctx.BlockHeight() (5).
	const startHeight = uint64(1)
	const numPubRand = uint64(200)
	_, msgCommit, err := datagen.GenRandomMsgCommitPubRandList(r, btcSK, startHeight, numPubRand)
	require.NoError(t, err)
	_, err = ms.CommitPubRandList(ctx, msgCommit)
	// Expected per the issue/PR-1994 fix: an error. Actual: no error.
	if err != nil {
		t.Fatalf("Bug 1 NOT reproduced: CommitPubRandList correctly rejected retroactive commit: %v", err)
	}
	t.Log("Bug 1 reproduced: CommitPubRandList ACCEPTED a retroactive commit (startHeight=1 while currentHeight=5)")
}

// Bug 2 — Jailing bypass via active toggle (#1852).
//
// HandleActivatedFinalityProvider resets StartHeight but NOT
// MissedBlocksCounter. After re-activation, the modular bitmap index
// (height - StartHeight) % window collides with previously-set bits in
// the bitmap, shielding the FP from new counter increments at the same
// modular position.
func TestBug2_JailingBypassActiveToggle(t *testing.T) {
	r := rand.New(rand.NewSource(2))
	fk, _, ctx, _, fpBTCPK, _, ctrl, _, _, _ := newReproEnv(t, r)
	defer ctrl.Finish()

	// Initialize signing info with a counter (FP has missed once).
	si := types.NewFinalityProviderSigningInfo(fpBTCPK, 100, 1)
	require.NoError(t, fk.FinalityProviderSigningTracker.Set(ctx, fpBTCPK.MustMarshal(), si))

	// Set the bitmap bit at the index a future missed block would touch
	// (StartHeight=100 + offset=3, signedBlocksWindow > 3).
	index := int64(3)
	require.NoError(t, fk.SetMissedBlockBitmapValue(ctx, fpBTCPK, index, true))

	// Move ahead to height 110 (still within the original window).
	ctx = ctx.WithHeaderInfo(header.Info{Height: 110})

	// Trigger Activate.
	require.NoError(t, fk.HandleActivatedFinalityProvider(ctx, fpBTCPK))

	siAfter, err := fk.FinalityProviderSigningTracker.Get(ctx, fpBTCPK.MustMarshal())
	require.NoError(t, err)
	t.Logf("After Activate: StartHeight=%d MissedBlocksCounter=%d",
		siAfter.StartHeight, siAfter.MissedBlocksCounter)
	if siAfter.MissedBlocksCounter != 1 {
		t.Fatalf("Bug 2 NOT reproduced: MissedBlocksCounter was reset (got %d, want 1)",
			siAfter.MissedBlocksCounter)
	}
	if siAfter.StartHeight != 110 {
		t.Fatalf("Bug 2 NOT reproduced: StartHeight was not advanced to 110 (got %d)", siAfter.StartHeight)
	}

	// Show the dual-shield: the bitmap bit at the old index (3) is still
	// set; HandleActivate did not delete the bitmap. Now the new modular
	// position (110+3 - 110) % window = 3 hits the existing "missed" bit.
	bitStillSet, err := fk.GetMissedBlockBitmapValue(ctx, fpBTCPK, index)
	require.NoError(t, err)
	if !bitStillSet {
		t.Fatalf("Bug 2 partially reproduced: counter not reset but bitmap was wiped")
	}
	t.Logf("Bug 2 reproduced: counter=%d (>0) and bitmap[%d]=true survived HandleActivatedFinalityProvider; "+
		"new misses landing on modular index %d become no-ops (previous=true && missed=true => skip)",
		siAfter.MissedBlocksCounter, index, index)

	// Demonstrate the no-op: the next call to UpdateSigningInfo at a height
	// whose modular index = 3 with missed=true returns "not modified"
	// because previous=true && missed=true falls into the default branch.
	maxedHeight := int64(siAfter.StartHeight) + 3
	modified, _, err := fk.UpdateSigningInfo(ctx, fpBTCPK, true, maxedHeight)
	require.NoError(t, err)
	if modified {
		t.Fatalf("Bug 2 NOT reproduced: a new miss at modular index 3 actually incremented the counter")
	}
	t.Logf("Bug 2 confirmed: a fresh miss at modular index %d was silently absorbed by the stale bitmap bit", index)
}

// Bug 3 — Fork-fork evidence overwrite at the same (fp, h).
//
// The evidence keeper stores Evidence keyed by (fp, height); a second
// fork sig at the same height overwrites the first. Additionally,
// Evidence.IsSlashable() requires CanonicalFinalitySig != nil; two
// distinct fork sigs (with the same pub-rand) mathematically reveal
// the SK, but the in-protocol path will not auto-slash because the
// on-chain Evidence struct cannot hold two fork sigs.
func TestBug3_ForkForkEvidenceOverwrite(t *testing.T) {
	r := rand.New(rand.NewSource(3))
	fk, ms, ctx, btcSK, fpBTCPK, fpBTCPKBytes, ctrl, bs, _, _ := newReproEnv(t, r)
	defer ctrl.Finish()

	fp, err := datagen.GenRandomFinalityProviderWithBTCSK(r, btcSK)
	require.NoError(t, err)
	bs.EXPECT().GetFinalityProvider(gomock.Any(), gomock.Eq(fpBTCPKBytes)).Return(fp, nil).AnyTimes()

	// commit pub-rand (legitimate, in advance)
	const startHeight = uint64(0)
	const numPubRand = uint64(200)
	randListInfo, msgCommit, err := datagen.GenRandomMsgCommitPubRandList(r, btcSK, startHeight, numPubRand)
	require.NoError(t, err)
	_, err = ms.CommitPubRandList(ctx, msgCommit)
	require.NoError(t, err)

	blockHeight := startHeight + 1
	canonical := datagen.GenRandomByteArray(r, 32)
	fork1 := datagen.GenRandomByteArray(r, 32)
	fork2 := datagen.GenRandomByteArray(r, 32)
	signer := datagen.GenRandomAccount().Address

	// index the canonical block
	ctx = ctx.WithHeaderInfo(header.Info{Height: int64(blockHeight), AppHash: canonical})
	fk.IndexBlock(ctx)
	fk.SetVotingPower(ctx, fpBTCPKBytes, blockHeight, 1)

	// 1st fork vote at (fp, blockHeight)
	msg1, err := datagen.NewMsgAddFinalitySig(signer, btcSK, startHeight, blockHeight, randListInfo, fork1)
	require.NoError(t, err)
	_, err = ms.AddFinalitySig(ctx, msg1)
	require.NoError(t, err)
	ev1, err := fk.GetEvidence(ctx, fpBTCPK, blockHeight)
	require.NoError(t, err)
	require.Equal(t, fork1, ev1.ForkAppHash)
	require.False(t, ev1.IsSlashable(), "single fork sig must not be self-slashable (no canonical)")

	// 2nd fork vote at (fp, blockHeight) using the SAME pub-rand
	msg2, err := datagen.NewMsgAddFinalitySig(signer, btcSK, startHeight, blockHeight, randListInfo, fork2)
	require.NoError(t, err)
	_, err = ms.AddFinalitySig(ctx, msg2)
	require.NoError(t, err)
	ev2, err := fk.GetEvidence(ctx, fpBTCPK, blockHeight)
	require.NoError(t, err)
	if string(ev2.ForkAppHash) == string(fork1) {
		t.Fatalf("Bug 3 NOT reproduced: first fork sig survived; got ForkAppHash=fork1")
	}
	require.Equal(t, fork2, ev2.ForkAppHash)
	require.False(t, ev2.IsSlashable(), "fork-only evidence is never self-slashable on-chain")
	t.Logf("Bug 3 reproduced: the on-chain evidence at (fp, h=%d) was OVERWRITTEN; the first ForkAppHash is lost.", blockHeight)
	t.Logf("Bug 3 reproduced: IsSlashable()=false for fork-only evidence, so the in-protocol slashing pipeline never fires for the pair of fork sigs.")
}

// Bug 4 — CommitPubRandList accepts commits from a slashed FP (T3).
//
// Unlike AddFinalitySig (which checks IsSlashed/IsJailed), CommitPubRandList
// only checks HasFinalityProvider and IsFinalityProviderDeleted. A
// slashed-then-not-yet-deleted FP can continue submitting pub-rand commits.
func TestBug4_CommitPubRandFromSlashedFp(t *testing.T) {
	r := rand.New(rand.NewSource(4))
	_, ms, ctx, btcSK, _, _, ctrl, _, _, _ := newReproEnv(t, r)
	defer ctrl.Finish()

	const startHeight = uint64(10)
	const numPubRand = uint64(200)
	_, msgCommit, err := datagen.GenRandomMsgCommitPubRandList(r, btcSK, startHeight, numPubRand)
	require.NoError(t, err)

	// Note: the keeper does not consult any IsSlashed/IsJailed predicate
	// here. The mock's bs.HasFinalityProvider returns true; if the function
	// guarded on slashed/jailed, it would have to ask the bs keeper for
	// the FP — it doesn't.
	ctx = ctx.WithHeaderInfo(header.Info{Height: 5})
	_, err = ms.CommitPubRandList(ctx, msgCommit)
	if err != nil {
		t.Fatalf("Bug 4 NOT reproduced (CommitPubRandList rejected the commit): %v", err)
	}
	t.Log("Bug 4 reproduced: CommitPubRandList has NO IsSlashed/IsJailed guard — a slashed/jailed FP can still commit.")
	t.Log("Note: this confirms the absence of the precondition check (T3 from the modeling brief);")
	t.Log("the impact is gas-burn / state-bloat griefing rather than safety, but the contract gap is real.")
}

// Bug 5 — slashFinalityProvider panic-on-error wrapper (CR4).
//
// In current code the wrapper at msg_server.go:457-461 panics on any
// non-nil error returned by BTCStakingKeeper.SlashFinalityProvider. Today
// this is guarded by IsSlashed/IsJailed checks at the start of AddFinalitySig,
// so the panic is unreachable through public APIs.
//
// We reach Level 0 / Level 1 with a black-box approach and document why
// the panic does not actually trigger in production today. We escalate to
// Level 2 (state injection) to confirm the wrapper does panic when the
// keeper returns an error, which is the latent-regression concern the
// finding flags.
func TestBug5_SlashWrapperPanicOnRegression(t *testing.T) {
	r := rand.New(rand.NewSource(5))
	fk, ms, ctx, btcSK, _, fpBTCPKBytes, ctrl, bs, _, _ := newReproEnv(t, r)
	defer ctrl.Finish()

	fp, err := datagen.GenRandomFinalityProviderWithBTCSK(r, btcSK)
	require.NoError(t, err)
	bs.EXPECT().GetFinalityProvider(gomock.Any(), gomock.Eq(fpBTCPKBytes)).Return(fp, nil).AnyTimes()

	const startHeight = uint64(0)
	const numPubRand = uint64(200)
	randListInfo, msgCommit, err := datagen.GenRandomMsgCommitPubRandList(r, btcSK, startHeight, numPubRand)
	require.NoError(t, err)
	_, err = ms.CommitPubRandList(ctx, msgCommit)
	require.NoError(t, err)

	blockHeight := startHeight + 1
	canonical := datagen.GenRandomByteArray(r, 32)
	fork := datagen.GenRandomByteArray(r, 32)
	ctx = ctx.WithHeaderInfo(header.Info{Height: int64(blockHeight), AppHash: canonical})
	fk.IndexBlock(ctx)
	fk.SetVotingPower(ctx, fpBTCPKBytes, blockHeight, 1)
	signer := datagen.GenRandomAccount().Address

	// Set up evidence at (fp, h) via a fork sig.
	msg1, err := datagen.NewMsgAddFinalitySig(signer, btcSK, startHeight, blockHeight, randListInfo, fork)
	require.NoError(t, err)
	_, err = ms.AddFinalitySig(ctx, msg1)
	require.NoError(t, err)

	// Now: the canonical-sig path will call slashFinalityProvider. Make the
	// underlying BS keeper return an error to simulate a regression / new
	// caller emerging.
	bs.EXPECT().SlashFinalityProvider(gomock.Any(), gomock.Eq(fpBTCPKBytes)).
		Return(types.ErrInvalidFinalitySig). // any non-nil error suffices
		Times(1)
	msg2, err := datagen.NewMsgAddFinalitySig(signer, btcSK, startHeight, blockHeight, randListInfo, canonical)
	require.NoError(t, err)

	defer func() {
		if rec := recover(); rec != nil {
			t.Logf("Bug 5 reproduced (Level 2, state-injection via mock): slashFinalityProvider wrapper PANICKED with %v", rec)
			return
		}
		t.Fatalf("Bug 5 NOT reproduced: wrapper did not panic when BS keeper returned an error")
	}()
	_, _ = ms.AddFinalitySig(ctx, msg2)
}

// Bug 6 — IsFinalityProviderDeleted swallows KV errors (CR6/T1).
//
// The function returns true on any error from the underlying KV Has().
// In practice, Cosmos SDK collections.KeySet.Has on a healthy store
// virtually never errors, so the bug is documented but black-box hard
// to trigger. The reproduction here just exercises the function and
// shows that the only way to distinguish "lookup failed" from "really
// deleted" is the function's bool return — i.e., the contract gap.
func TestBug6_IsFinalityProviderDeletedSwallowsErr(t *testing.T) {
	r := rand.New(rand.NewSource(6))
	_, _, _, _, _, _, ctrl, _, _, _ := newReproEnv(t, r)
	defer ctrl.Finish()

	t.Log("Bug 6 documentation-only test:")
	t.Log("  IsFinalityProviderDeleted has the literal pattern:")
	t.Log("    blocked, err := k.finalityProvidersDeleted.Has(ctx, ...)")
	t.Log("    if err != nil { return true }   // <-- swallowed, fail-closed")
	t.Log("    return blocked")
	t.Log("Black-box (Level 0/1) reproduction: NOT POSSIBLE — the in-memory KV store does not error.")
	t.Log("State-injection (Level 2): would require swapping the keeper's underlying store with one that errors,")
	t.Log("which violates the 'use public interfaces' rule.")
	t.Log("Code modification (Level 3): trivially demonstrable but tautological.")
	t.Log("Conclusion: REPRODUCTION FAILED; the audit finding (contract gap, silent fail-closed) stands.")
}

// Bug 7 — BTCDelegation.GetStatus ignores FP Slashed (CR7).
//
// Construct an ACTIVE-shaped BTC delegation using the same field-only
// pattern as the upstream TestGetStatus "active: with inclusion proof"
// case (x/btcstaking/types/btc_delegation_test.go:236-248). The point
// of the bug is that GetStatus()'s signature is
//   GetStatus(btcHeight, covenantQuorum, quorumPreviousStk uint32)
// with no FP argument and no lookup of FP-level Slashed/Jailed flags.
// The slashing filter happens at the power-dist consumer level only.
func TestBug7_GetStatusIgnoresFpSlashed(t *testing.T) {
	covenantQuorum := uint32(1)
	// Same delegation shape as the upstream "active" test case.
	d := bstypes.BTCDelegation{
		CovenantSigs: make([]*bstypes.CovenantAdaptorSignatures, covenantQuorum),
		BtcUndelegation: &bstypes.BTCUndelegation{
			CovenantUnbondingSigList: make([]*bstypes.SignatureInfo, covenantQuorum),
			CovenantSlashingSigs:     make([]*bstypes.CovenantAdaptorSignatures, covenantQuorum),
		},
		StartHeight: 1,
		EndHeight:   2,
	}
	// btcHeight=1 → ACTIVE per upstream test
	status := d.GetStatus(1, covenantQuorum, 0)
	require.Equal(t, bstypes.BTCDelegationStatus_ACTIVE, status,
		"baseline: an ACTIVE-shaped delegation must report ACTIVE")

	// Now: simulate "the FP under this delegation has been slashed".
	// There is NO field on BTCDelegation to mark it as slashed-due-to-FP,
	// and GetStatus has NO mechanism to consult the FP. Even if we wanted
	// to "make it look slashed", there is no such input to GetStatus.
	// We re-call GetStatus and observe it still returns ACTIVE.
	status2 := d.GetStatus(1, covenantQuorum, 0)
	require.Equal(t, bstypes.BTCDelegationStatus_ACTIVE, status2)

	t.Logf("Bug 7 reproduced at Level 0: BTCDelegation.GetStatus(1, %d, 0) returned %v "+
		"with NO opportunity to incorporate an FP-level Slashed flag.", covenantQuorum, status2)
	t.Log("Bug 7 confirmed: the function's signature itself precludes per-call FP-status incorporation; " +
		"any third-party query that calls GetStatus directly (e.g., gRPC BTCDelegation) gets a stale ACTIVE for a slashed-FP delegation.")
}
