// Package scenarios contains Specula trace-harness scenarios that exercise
// Babylon's instrumented keeper code paths.  Each scenario writes one NDJSON
// trace file (set via BABYLON_TLA_TRACE_FILE) covering one bug-family
// hypothesis from the modelling brief.
//
// These tests reuse Babylon's own keeper-test infrastructure (mock keepers
// + datagen helpers) rather than reimplementing protocol logic.  Trace
// events are emitted from the *real* keeper methods via the instrumentation
// inserted by harness/patches/apply.py.
package scenarios

import (
	"math/rand"
	"os"
	"testing"
	"time"

	"cosmossdk.io/core/header"
	"github.com/golang/mock/gomock"
	"github.com/stretchr/testify/require"

	"github.com/babylonlabs-io/babylon/v4/testutil/datagen"
	keepertest "github.com/babylonlabs-io/babylon/v4/testutil/keeper"
	bbn "github.com/babylonlabs-io/babylon/v4/types"
	bstypes "github.com/babylonlabs-io/babylon/v4/x/btcstaking/types"
	"github.com/babylonlabs-io/babylon/v4/x/finality/keeper"
	"github.com/babylonlabs-io/babylon/v4/x/finality/types"
	ftypes "github.com/babylonlabs-io/babylon/v4/x/finality/types"
	epochingtypes "github.com/babylonlabs-io/babylon/v4/x/epoching/types"
	"github.com/babylonlabs-io/babylon/v4/x/tlatrace"
)

func setupTrace(t *testing.T) func() {
	t.Helper()
	if os.Getenv("BABYLON_TLA_TRACE_FILE") == "" {
		t.Skip("BABYLON_TLA_TRACE_FILE not set; skipping trace scenario")
	}
	tlatrace.Reset()
	tlatrace.Init()
	tlatrace.EmitConfig(map[string]interface{}{
		"Validators":        []string{"v1", "v2", "v3", "v4"},
		"Faulty":            []string{"v4"},
		"FinalityProviders": []string{"fp1", "fp2", "fp3"},
	})
	return tlatrace.Close
}

// TestTraceScenarioFinality drives CommitPubRand + AddFinalitySig canonical
// and fork branches against a real msg server, exercising bug-family 1
// (EOTS double-sign extraction).
func TestTraceScenarioFinality(t *testing.T) {
	defer setupTrace(t)()

	r := rand.New(rand.NewSource(1))
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	bsKeeper := types.NewMockBTCStakingKeeper(ctrl)
	bsKeeper.EXPECT().UpdateFinalityProvider(gomock.Any(), gomock.Any()).Return(nil).AnyTimes()
	bsKeeper.EXPECT().IsFinalityProviderDeleted(gomock.Any(), gomock.Any()).Return(false).AnyTimes()
	cKeeper := types.NewMockCheckpointingKeeper(ctrl)
	iKeeper := types.NewMockIncentiveKeeper(ctrl)
	iKeeper.EXPECT().IndexRefundableMsg(gomock.Any(), gomock.Any()).AnyTimes()
	fKeeper, ctx := keepertest.FinalityKeeper(t, bsKeeper, iKeeper, cKeeper, nil)
	ms := keeper.NewMsgServerImpl(*fKeeper)

	// Finality provider with a stable BTC key pair.
	btcSK, btcPK, err := datagen.GenRandomBTCKeyPair(r)
	require.NoError(t, err)
	fp, err := datagen.GenRandomFinalityProviderWithBTCSK(r, btcSK)
	require.NoError(t, err)
	fpBTCPK := bbn.NewBIP340PubKeyFromBTCPK(btcPK)
	fpBTCPKBytes := fpBTCPK.MustMarshal()

	bsKeeper.EXPECT().HasFinalityProvider(gomock.Any(), gomock.Eq(fpBTCPKBytes)).Return(true).AnyTimes()
	committedEpochNum := uint64(1)
	cKeeper.EXPECT().GetEpoch(gomock.Any()).Return(&epochingtypes.Epoch{EpochNumber: committedEpochNum}).AnyTimes()
	cKeeper.EXPECT().GetLastFinalizedEpoch(gomock.Any()).Return(committedEpochNum).AnyTimes()

	// Commit pub-rand list.
	startHeight := uint64(0)
	numPubRand := uint64(200)
	randListInfo, msg, err := datagen.GenRandomMsgCommitPubRandList(r, btcSK, startHeight, numPubRand)
	require.NoError(t, err)
	_, err = ms.CommitPubRandList(ctx, msg)
	require.NoError(t, err)

	// Cast a canonical finality sig.
	blockHeight := startHeight + 1
	canonicalHash := datagen.GenRandomByteArray(r, 32)
	ctx = ctx.WithHeaderInfo(header.Info{Height: int64(blockHeight), AppHash: canonicalHash})
	fKeeper.IndexBlock(ctx)
	fKeeper.SetVotingPower(ctx, fpBTCPKBytes, blockHeight, 1)
	cKeeper.EXPECT().GetEpochByHeight(gomock.Any(), gomock.Any()).Return(committedEpochNum).AnyTimes()
	bsKeeper.EXPECT().GetFinalityProvider(gomock.Any(), gomock.Eq(fpBTCPKBytes)).Return(fp, nil).AnyTimes()
	signer := datagen.GenRandomAccount().Address
	canonicalSig, err := datagen.NewMsgAddFinalitySig(signer, btcSK, startHeight, blockHeight, randListInfo, canonicalHash)
	require.NoError(t, err)
	_, err = ms.AddFinalitySig(ctx, canonicalSig)
	require.NoError(t, err)

	// Cast a fork sig at the same height → fork branch + inline slash.
	// The mock's SlashFinalityProvider mutates fp.SlashedBabylonHeight so
	// subsequent GetFinalityProvider sees IsSlashed()==true (matches the
	// spec post-state fpSlashed'=TRUE).
	forkHash := datagen.GenRandomByteArray(r, 32)
	bsKeeper.EXPECT().
		SlashFinalityProvider(gomock.Any(), gomock.Eq(fpBTCPKBytes)).
		DoAndReturn(func(_ interface{}, _ []byte) error {
			fp.SlashedBabylonHeight = blockHeight
			return nil
		}).
		AnyTimes()
	forkMsg, err := datagen.NewMsgAddFinalitySig(signer, btcSK, startHeight, blockHeight, randListInfo, forkHash)
	require.NoError(t, err)
	_, err = ms.AddFinalitySig(ctx, forkMsg)
	require.NoError(t, err)

	// Verify evidence was recorded.
	_, err = fKeeper.GetEvidence(ctx, fpBTCPK, blockHeight)
	require.NoError(t, err)
}

// TestTraceScenarioCommitPubRandRetroactive exercises bug-family 1:
// retroactive pub-rand commit (startHeight < currentHeight).  We commit at
// a startHeight LOWER than the current block height, which the impl allows
// but the spec ought to forbid.
func TestTraceScenarioCommitPubRandRetroactive(t *testing.T) {
	defer setupTrace(t)()

	r := rand.New(rand.NewSource(2))
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	bsKeeper := types.NewMockBTCStakingKeeper(ctrl)
	cKeeper := types.NewMockCheckpointingKeeper(ctrl)
	bsKeeper.EXPECT().IsFinalityProviderDeleted(gomock.Any(), gomock.Any()).Return(false).AnyTimes()
	fKeeper, ctx := keepertest.FinalityKeeper(t, bsKeeper, nil, cKeeper, nil)
	ms := keeper.NewMsgServerImpl(*fKeeper)

	btcSK, btcPK, err := datagen.GenRandomBTCKeyPair(r)
	require.NoError(t, err)
	fpBTCPK := bbn.NewBIP340PubKeyFromBTCPK(btcPK)
	bsKeeper.EXPECT().HasFinalityProvider(gomock.Any(), gomock.Eq(fpBTCPK.MustMarshal())).Return(true).AnyTimes()
	cKeeper.EXPECT().GetEpoch(gomock.Any()).Return(&epochingtypes.Epoch{EpochNumber: 1}).AnyTimes()

	// Advance the context height to 50.  Then commit pub-rand starting at
	// height 10 (retroactive).  This is the bug — impl accepts it.
	ctx = ctx.WithHeaderInfo(header.Info{Height: 50})

	_, msg, err := datagen.GenRandomMsgCommitPubRandList(r, btcSK, 10, 200)
	require.NoError(t, err)
	_, err = ms.CommitPubRandList(ctx, msg)
	require.NoError(t, err)
}

// TestTraceScenarioLiveness drives HandleFinalityProviderLiveness across a
// full SignedBlocksWindow, jailing an FP, then re-activating it via
// HandleActivatedFinalityProvider WITHOUT resetting the missed counter
// (Family 2 — issue #1852).
//
// Uses SignedBlocksWindow=3 / MaxMissed=1 so the height range fits inside
// the trace cfg bound (MaxBlockHeight=8).
func TestTraceScenarioLiveness(t *testing.T) {
	defer setupTrace(t)()

	r := rand.New(rand.NewSource(3))
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	bsKeeper := types.NewMockBTCStakingKeeper(ctrl)
	bsKeeper.EXPECT().JailFinalityProvider(gomock.Any(), gomock.Any()).Return(nil).AnyTimes()

	iKeeper := types.NewMockIncentiveKeeper(ctrl)
	cKeeper := types.NewMockCheckpointingKeeper(ctrl)
	fKeeper, ctx := keepertest.FinalityKeeper(t, bsKeeper, iKeeper, cKeeper, nil)
	blockTime := time.Now()
	ctx = ctx.WithHeaderInfo(header.Info{Time: blockTime})

	params := fKeeper.GetParams(ctx)
	params.SignedBlocksWindow = 3
	// MinSignedPerWindow = 0.66... → MaxMissed = window - ceil(2/3 * 3) = 3 - 2 = 1
	require.NoError(t, fKeeper.SetParams(ctx, params))
	params = fKeeper.GetParams(ctx)

	fpPk, err := datagen.GenRandomBIP340PubKey(r)
	require.NoError(t, err)
	bsKeeper.EXPECT().
		GetFinalityProvider(gomock.Any(), fpPk.MustMarshal()).
		Return(&bstypes.FinalityProvider{Jailed: false}, nil).
		AnyTimes()
	signingInfo := types.NewFinalityProviderSigningInfo(fpPk, 1, 0)
	require.NoError(t, fKeeper.FinalityProviderSigningTracker.Set(ctx, fpPk.MustMarshal(), signingInfo))

	activatedHeight := int64(2)

	height := activatedHeight
	for ; height < activatedHeight+params.SignedBlocksWindow; height++ {
		require.NoError(t, fKeeper.HandleFinalityProviderLiveness(ctx, fpPk, false, height))
	}

	minSignedPerWindow := params.MinSignedPerWindowInt()
	maxMissed := params.SignedBlocksWindow - minSignedPerWindow
	sluggishHeight := height + maxMissed
	for ; height < sluggishHeight; height++ {
		require.NoError(t, fKeeper.HandleFinalityProviderLiveness(ctx, fpPk, true, height))
	}

	// One more missed block triggers jailing.
	require.NoError(t, fKeeper.HandleFinalityProviderLiveness(ctx, fpPk, true, height))

	// Now flip the FP back to active *without* resetting missed counter.
	// This is Family 2 — HandleActivatedFinalityProvider only resets
	// StartHeight, leaving MissedBlocksCounter at its previous value.
	require.NoError(t, fKeeper.HandleActivatedFinalityProvider(ctx, fpPk))
}

// TestTraceScenarioUnjail drives the UnjailFinalityProvider msg path,
// emitting an `UnjailFp` trace event.
func TestTraceScenarioUnjail(t *testing.T) {
	defer setupTrace(t)()

	r := rand.New(rand.NewSource(4))
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	bsKeeper := types.NewMockBTCStakingKeeper(ctrl)
	cKeeper := types.NewMockCheckpointingKeeper(ctrl)
	fKeeper, ctx := keepertest.FinalityKeeper(t, bsKeeper, nil, cKeeper, nil)
	ms := keeper.NewMsgServerImpl(*fKeeper)

	btcSK, btcPK, err := datagen.GenRandomBTCKeyPair(r)
	require.NoError(t, err)
	fp, err := datagen.GenRandomFinalityProviderWithBTCSK(r, btcSK)
	require.NoError(t, err)
	fpBTCPK := bbn.NewBIP340PubKeyFromBTCPK(btcPK)
	fpBTCPKBytes := fpBTCPK.MustMarshal()

	fp.Jailed = true
	jailedTime := time.Now()
	signingInfo := types.FinalityProviderSigningInfo{FpBtcPk: fpBTCPK, JailedUntil: jailedTime}
	require.NoError(t, fKeeper.FinalityProviderSigningTracker.Set(ctx, fpBTCPKBytes, signingInfo))

	msg := &types.MsgUnjailFinalityProvider{Signer: fp.Addr, FpBtcPk: fpBTCPK}
	ctx = ctx.WithHeaderInfo(header.Info{Time: jailedTime.Add(2 * time.Second)})
	bsKeeper.EXPECT().GetFinalityProvider(gomock.Any(), fpBTCPKBytes).Return(fp, nil).AnyTimes()
	bsKeeper.EXPECT().UnjailFinalityProvider(gomock.Any(), fpBTCPKBytes).Return(nil).AnyTimes()
	_, err = ms.UnjailFinalityProvider(ctx, msg)
	require.NoError(t, err)
}

// Reference imports kept to silence the lint when ftypes is otherwise
// unused above in some build configurations.
var _ = ftypes.ModuleName
