package state_test

import (
	"context"
	"fmt"
	"testing"
	"time"

	dbm "github.com/cometbft/cometbft-db"
	"github.com/stretchr/testify/require"

	abci "github.com/cometbft/cometbft/abci/types"
	cmtproto "github.com/cometbft/cometbft/api/cometbft/types/v1"
	"github.com/cometbft/cometbft/crypto/ed25519"
	sm "github.com/cometbft/cometbft/internal/state"
	store "github.com/cometbft/cometbft/internal/store"
	"github.com/cometbft/cometbft/libs/log"
	"github.com/cometbft/cometbft/mempool"
	"github.com/cometbft/cometbft/proxy"
	"github.com/cometbft/cometbft/types"
)

// parameterUpdateApp is a normal in-process ABCI application. FinalizeBlock
// returns the configured parameter update through the public ABCI interface;
// Commit records whether CometBFT allowed the application to persist height H.
type parameterUpdateApp struct {
	abci.BaseApplication
	update      *cmtproto.ConsensusParams
	delay       time.Duration
	commitCalls int
}

func (app *parameterUpdateApp) FinalizeBlock(
	_ context.Context,
	req *abci.FinalizeBlockRequest,
) (*abci.FinalizeBlockResponse, error) {
	if app.delay > 0 {
		time.Sleep(app.delay)
	}
	return &abci.FinalizeBlockResponse{
		TxResults:             make([]*abci.ExecTxResult, len(req.Txs)),
		ConsensusParamUpdates: app.update,
		AppHash:               []byte("app-hash-at-H"),
	}, nil
}

func (app *parameterUpdateApp) Commit(
	context.Context,
	*abci.CommitRequest,
) (*abci.CommitResponse, error) {
	app.commitCalls++
	return &abci.CommitResponse{}, nil
}

type applyHarness struct {
	input      sm.State
	stateStore sm.Store
	executor   *sm.BlockExecutor
	proxyApp   proxy.AppConns
	block      *types.Block
	blockID    types.BlockID
}

func newApplyHarness(t *testing.T, app *parameterUpdateApp) *applyHarness {
	t.Helper()

	privKey := ed25519.GenPrivKey()
	pubKey := privKey.PubKey()
	genesis := &types.GenesisDoc{
		GenesisTime:   time.Unix(1_700_000_000, 0).UTC(),
		ChainID:       "cr-1-parameter-update",
		InitialHeight: 1,
		Validators: []types.GenesisValidator{{
			Address: pubKey.Address(),
			PubKey:  pubKey,
			Power:   10,
		}},
		ConsensusParams: types.DefaultConsensusParams(),
	}

	state, err := sm.MakeGenesisState(genesis)
	require.NoError(t, err)
	stateStore := sm.NewStore(dbm.NewMemDB(), sm.StoreOptions{
		DiscardABCIResponses: false,
	})
	require.NoError(t, stateStore.Save(state))

	clientCreator := proxy.NewLocalClientCreator(app)
	proxyApp := proxy.NewAppConns(clientCreator, proxy.NopMetrics())
	require.NoError(t, proxyApp.Start())
	t.Cleanup(func() { require.NoError(t, proxyApp.Stop()) })

	blockStore := store.NewBlockStore(dbm.NewMemDB())
	executor := sm.NewBlockExecutor(
		stateStore,
		log.NewNopLogger(),
		proxyApp.Consensus(),
		&mempool.NopMempool{},
		sm.EmptyEvidencePool{},
		blockStore,
	)

	block := state.MakeBlock(
		state.InitialHeight,
		nil,
		new(types.Commit),
		nil,
		pubKey.Address(),
	)
	partSet, err := block.MakePartSet(types.BlockPartSizeBytes)
	require.NoError(t, err)

	return &applyHarness{
		input:      state,
		stateStore: stateStore,
		executor:   executor,
		proxyApp:   proxyApp,
		block:      block,
		blockID: types.BlockID{
			Hash:          block.Hash(),
			PartSetHeader: partSet.Header(),
		},
	}
}

func runRejectedCase(
	t *testing.T,
	name string,
	update *cmtproto.ConsensusParams,
	delay time.Duration,
	wantError string,
) {
	t.Helper()

	app := &parameterUpdateApp{update: update, delay: delay}
	h := newApplyHarness(t, app)
	before := h.input.Copy()

	returned, applyErr := h.executor.ApplyBlock(h.input, h.blockID, h.block)
	require.ErrorContains(t, applyErr, wantError)
	require.True(t, returned.Equals(before), "error return must be the input state")
	require.True(t, h.input.Equals(before), "ApplyBlock must not mutate its input state")
	require.Equal(t, 0, app.commitCalls, "invalid update must be rejected before application Commit")

	persistedState, err := h.stateStore.Load()
	require.NoError(t, err)
	require.True(t, persistedState.Equals(before), "invalid update must not advance persisted state")

	persistedResponse, err := h.stateStore.LoadFinalizeBlockResponse(h.block.Height)
	require.NoError(t, err)
	require.Equal(t, update, persistedResponse.ConsensusParamUpdates,
		"FinalizeBlock response is deliberately durable before validation")

	t.Logf(
		"%s: rejected=%q input_height=%d persisted_height=%d commit_calls=%d response_durable=%t",
		name,
		applyErr,
		returned.LastBlockHeight,
		persistedState.LastBlockHeight,
		app.commitCalls,
		persistedResponse.ConsensusParamUpdates != nil,
	)
}

func TestBugCR1ParameterUpdateValidationAndInstallation(t *testing.T) {
	t.Run("level0_complete_update_rejected_by_ValidateBasic", func(t *testing.T) {
		params := types.DefaultConsensusParams().ToProto()
		params.Block.MaxBytes = 0
		runRejectedCase(t, "complete-invalid", &params, 0, "block.MaxBytes cannot be 0")
	})

	t.Run("level0_partial_subrecord_rejected_by_ValidateBasic", func(t *testing.T) {
		update := &cmtproto.ConsensusParams{
			Evidence: &cmtproto.EvidenceParams{
				MaxAgeNumBlocks: 123,
				// Omitted fields decode as zero. Update replaces the entire
				// non-nil Evidence subrecord, so ValidateBasic must reject it.
			},
		}
		runRejectedCase(t, "partial-invalid", update, 0, "evidence.MaxAgeDuration")
	})

	t.Run("level0_basic_valid_transition_rejected_by_ValidateUpdate", func(t *testing.T) {
		update := &cmtproto.ConsensusParams{
			Abci: &cmtproto.ABCIParams{VoteExtensionsEnableHeight: 1},
		}
		runRejectedCase(t, "transition-invalid", update, 0, "cannot be updated to a past height")
	})

	t.Run("level0_accepted_update_is_installed_for_H_plus_1", func(t *testing.T) {
		const newAppVersion uint64 = 7
		update := &cmtproto.ConsensusParams{
			Version: &cmtproto.VersionParams{App: newAppVersion},
		}
		app := &parameterUpdateApp{update: update}
		h := newApplyHarness(t, app)
		before := h.input.Copy()

		returned, err := h.executor.ApplyBlock(h.input, h.blockID, h.block)
		require.NoError(t, err)
		require.True(t, h.input.Equals(before), "successful ApplyBlock must not mutate its input value")
		require.Equal(t, 1, app.commitCalls)
		require.Equal(t, newAppVersion, returned.ConsensusParams.Version.App)
		require.Equal(t, newAppVersion, returned.Version.Consensus.App)
		require.Equal(t, h.block.Height+1, returned.LastHeightConsensusParamsChanged)

		persistedState, err := h.stateStore.Load()
		require.NoError(t, err)
		require.True(t, persistedState.Equals(returned))
		paramsAtNextHeight, err := h.stateStore.LoadConsensusParams(h.block.Height + 1)
		require.NoError(t, err)
		require.Equal(t, newAppVersion, paramsAtNextHeight.Version.App)

		t.Logf(
			"accepted: block_height=%d state_height=%d active_height=%d app_version=%d commit_calls=%d",
			h.block.Height,
			returned.LastBlockHeight,
			returned.LastHeightConsensusParamsChanged,
			paramsAtNextHeight.Version.App,
			app.commitCalls,
		)
	})

	t.Run("level1_finalize_delay_does_not_cross_validation_commit_boundary", func(t *testing.T) {
		update := &cmtproto.ConsensusParams{
			Block: &cmtproto.BlockParams{MaxBytes: 0, MaxGas: -1},
		}
		runRejectedCase(t, "timing-assisted-invalid", update, 25*time.Millisecond, "block.MaxBytes cannot be 0")
	})
}

func TestBugCR1EscalationSoundness(t *testing.T) {
	// Level 2 would require injecting the only concerning recovery state:
	// application height H together with a rejected response at H. The public
	// ApplyBlock sequence above proves that state unreachable because Commit is
	// never called after validation rejects the candidate. Injecting it would
	// violate the bug-confirmation reachability rule.
	//
	// Level 3 delay patches cannot change this deterministic same-goroutine order:
	// Update -> ValidateBasic -> ValidateUpdate -> Commit. Source modification is
	// therefore neither necessary nor sound for manufacturing a different result.
	t.Log(fmt.Sprintf(
		"levels2-3: not injected/patched; rejected updates cannot reach app height H because Commit calls=%d",
		0,
	))
}
