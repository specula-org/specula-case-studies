package consensus

// Run from the supplied CometBFT worktree with:
//
//   set -o pipefail
//   timeout 10m go test -overlay=<CR-3-work-dir>/repro-overlay.json \
//     ./internal/consensus -run '^TestBugCR3HeightMatrix$' -count=1 -v \
//     | grep -E -- 'CR3\||--- PASS|^PASS$|^ok[[:space:]]'
//
// The overlay maps this file to internal/consensus/test_bugCR3_height_matrix_test.go.
// It lets the reproducer exercise the package's real startup Handshaker without
// modifying the supplied source tree.

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	dbm "github.com/cometbft/cometbft-db"
	"github.com/stretchr/testify/require"

	abci "github.com/cometbft/cometbft/abci/types"
	cmtproto "github.com/cometbft/cometbft/api/cometbft/types/v1"
	cfg "github.com/cometbft/cometbft/config"
	sm "github.com/cometbft/cometbft/internal/state"
	blockstore "github.com/cometbft/cometbft/internal/store"
	"github.com/cometbft/cometbft/internal/test"
	"github.com/cometbft/cometbft/libs/log"
	"github.com/cometbft/cometbft/privval"
	"github.com/cometbft/cometbft/proxy"
	"github.com/cometbft/cometbft/types"
)

const (
	cr3GasAtHeight1 int64 = 111
	cr3GasAtHeight2 int64 = 222
)

// cr3ReplayApp is a deterministic ABCI application whose durable state is its
// committed height/hash. It emits consensus-parameter updates at heights 1 and
// 2 so every state-mutating replay has a value a later block consumer checks.
type cr3ReplayApp struct {
	abci.BaseApplication

	maxBytes int64

	committedHeight int64
	committedHash   []byte
	pendingHeight   int64
	pendingHash     []byte

	infoHeightOverride *int64
	initCalls          int
	finalizeCalls      int
	commitCalls        int
}

func (app *cr3ReplayApp) Info(context.Context, *abci.InfoRequest) (*abci.InfoResponse, error) {
	height := app.committedHeight
	if app.infoHeightOverride != nil {
		height = *app.infoHeightOverride
	}
	return &abci.InfoResponse{
		LastBlockHeight:  height,
		LastBlockAppHash: bytes.Clone(app.committedHash),
	}, nil
}

func (app *cr3ReplayApp) InitChain(context.Context, *abci.InitChainRequest) (*abci.InitChainResponse, error) {
	app.initCalls++
	return &abci.InitChainResponse{}, nil
}

func (app *cr3ReplayApp) FinalizeBlock(_ context.Context, req *abci.FinalizeBlockRequest) (*abci.FinalizeBlockResponse, error) {
	app.finalizeCalls++
	if req.Height != app.committedHeight+1 {
		return nil, fmt.Errorf("non-sequential FinalizeBlock: committed=%d requested=%d", app.committedHeight, req.Height)
	}

	app.pendingHeight = req.Height
	app.pendingHash = []byte{byte(req.Height)}
	response := &abci.FinalizeBlockResponse{AppHash: bytes.Clone(app.pendingHash)}

	switch req.Height {
	case 1:
		response.ConsensusParamUpdates = &cmtproto.ConsensusParams{
			Block: &cmtproto.BlockParams{MaxBytes: app.maxBytes, MaxGas: cr3GasAtHeight1},
		}
	case 2:
		response.ConsensusParamUpdates = &cmtproto.ConsensusParams{
			Block: &cmtproto.BlockParams{MaxBytes: app.maxBytes, MaxGas: cr3GasAtHeight2},
		}
	}
	return response, nil
}

func (app *cr3ReplayApp) Commit(context.Context, *abci.CommitRequest) (*abci.CommitResponse, error) {
	app.commitCalls++
	if app.pendingHeight != app.committedHeight+1 {
		return nil, fmt.Errorf("Commit without next pending height: committed=%d pending=%d", app.committedHeight, app.pendingHeight)
	}
	app.committedHeight = app.pendingHeight
	app.committedHash = bytes.Clone(app.pendingHash)
	return &abci.CommitResponse{}, nil
}

type cr3FailStateSave struct {
	sm.Store
	failHeight int64
	armed      bool
}

func (store *cr3FailStateSave) Save(state sm.State) error {
	if store.armed && state.LastBlockHeight == store.failHeight {
		return errors.New("CR3 injected crash after app Commit, before state Save")
	}
	return store.Store.Save(state)
}

type cr3Fixture struct {
	config     *cfg.Config
	genDoc     *types.GenesisDoc
	stateStore sm.Store
	blockStore *blockstore.BlockStore
	app        *cr3ReplayApp
	proxyApp   proxy.AppConns
	state0     sm.State
	state1     sm.State
	block1     *types.Block
	block2     *types.Block
	block1ID   types.BlockID
	block2ID   types.BlockID
	commit2    *types.Commit
}

func cr3StartProxy(t *testing.T, app *cr3ReplayApp) proxy.AppConns {
	t.Helper()
	proxyApp := proxy.NewAppConns(proxy.NewLocalClientCreator(app), proxy.NopMetrics())
	require.NoError(t, proxyApp.Start())
	t.Cleanup(func() { require.NoError(t, proxyApp.Stop()) })
	return proxyApp
}

func cr3BlockID(t *testing.T, block *types.Block) (types.BlockID, *types.PartSet) {
	t.Helper()
	parts, err := block.MakePartSet(types.BlockPartSizeBytes)
	require.NoError(t, err)
	return types.BlockID{Hash: block.Hash(), PartSetHeader: parts.Header()}, parts
}

func cr3Apply(t *testing.T, stateStore sm.Store, blockStore *blockstore.BlockStore,
	proxyApp proxy.AppConns, state sm.State, id types.BlockID, block *types.Block,
) (sm.State, error) {
	t.Helper()
	executor := sm.NewBlockExecutor(
		stateStore,
		log.NewNopLogger(),
		proxyApp.Consensus(),
		emptyMempool{},
		sm.EmptyEvidencePool{},
		blockStore,
	)
	return executor.ApplyBlock(state, id, block)
}

// cr3NewFixture performs a clean genesis handshake, then processes block 1 via
// the normal BlockExecutor path and durably stores block 2 without applying it.
// The resulting A=1, B=2, S=1 state is the real crash cut after block storage.
func cr3NewFixture(t *testing.T) *cr3Fixture {
	t.Helper()

	fixtureName := strings.NewReplacer("/", "_", "\\", "_").Replace(t.Name())
	config := ResetConfig("cr3_" + fixtureName)
	t.Cleanup(func() { require.NoError(t, os.RemoveAll(config.RootDir)) })

	genDoc, err := sm.MakeGenesisDocFromFile(config.GenesisFile())
	require.NoError(t, err)
	state0, err := sm.MakeGenesisState(genDoc)
	require.NoError(t, err)

	stateDB := dbm.NewMemDB()
	stateStore := sm.NewStore(stateDB, sm.StoreOptions{DiscardABCIResponses: false})
	t.Cleanup(func() { require.NoError(t, stateStore.Close()) })
	blockStore := blockstore.NewBlockStore(dbm.NewMemDB())
	t.Cleanup(func() { require.NoError(t, blockStore.Close()) })

	app := &cr3ReplayApp{maxBytes: state0.ConsensusParams.Block.MaxBytes}
	proxyApp := cr3StartProxy(t, app)
	handshaker := NewHandshaker(stateStore, state0, blockStore, genDoc)
	require.NoError(t, handshaker.Handshake(context.Background(), proxyApp))
	require.Equal(t, 1, app.initCalls)
	state0, err = stateStore.Load()
	require.NoError(t, err)

	filePV := privval.LoadFilePV(config.PrivValidatorKeyFile(), config.PrivValidatorStateFile())
	block1 := state0.MakeBlock(
		state0.InitialHeight,
		nil,
		new(types.Commit),
		nil,
		state0.Validators.GetProposer().Address,
	)
	block1ID, block1Parts := cr3BlockID(t, block1)
	commit1, err := test.MakeCommit(
		block1ID,
		block1.Height,
		0,
		state0.Validators,
		[]types.PrivValidator{filePV},
		state0.ChainID,
		state0.LastBlockTime.Add(time.Second),
	)
	require.NoError(t, err)
	blockStore.SaveBlock(block1, block1Parts, commit1)

	state1, err := cr3Apply(t, stateStore, blockStore, proxyApp, state0, block1ID, block1)
	require.NoError(t, err)
	require.Equal(t, int64(1), state1.LastBlockHeight)
	require.Equal(t, cr3GasAtHeight1, state1.ConsensusParams.Block.MaxGas)
	require.Equal(t, int64(1), app.committedHeight)

	block2 := state1.MakeBlock(
		state1.LastBlockHeight+1,
		nil,
		commit1,
		nil,
		state1.Validators.GetProposer().Address,
	)
	block2ID, block2Parts := cr3BlockID(t, block2)
	commit2, err := test.MakeCommit(
		block2ID,
		block2.Height,
		0,
		state1.Validators,
		[]types.PrivValidator{filePV},
		state1.ChainID,
		block2.Time.Add(time.Second),
	)
	require.NoError(t, err)
	blockStore.SaveBlock(block2, block2Parts, commit2)
	require.Equal(t, int64(2), blockStore.Height())

	return &cr3Fixture{
		config:     config,
		genDoc:     genDoc,
		stateStore: stateStore,
		blockStore: blockStore,
		app:        app,
		proxyApp:   proxyApp,
		state0:     state0,
		state1:     state1,
		block1:     block1,
		block2:     block2,
		block1ID:   block1ID,
		block2ID:   block2ID,
		commit2:    commit2,
	}
}

func (fixture *cr3Fixture) applySecond(t *testing.T, stateStore sm.Store) (sm.State, error) {
	t.Helper()
	return cr3Apply(t, stateStore, fixture.blockStore, fixture.proxyApp,
		fixture.state1, fixture.block2ID, fixture.block2)
}

func cr3AssertRecoveredState(t *testing.T, stateStore sm.Store) sm.State {
	t.Helper()
	state, err := stateStore.Load()
	require.NoError(t, err)
	require.Equal(t, int64(2), state.LastBlockHeight)
	require.Equal(t, []byte{2}, state.AppHash)
	require.Equal(t, cr3GasAtHeight2, state.ConsensusParams.Block.MaxGas)
	require.Equal(t, int64(3), state.LastHeightConsensusParamsChanged)
	paramsAtNextHeight, err := stateStore.LoadConsensusParams(3)
	require.NoError(t, err)
	require.Equal(t, cr3GasAtHeight2, paramsAtNextHeight.Block.MaxGas)
	return state
}

func cr3FreshAppAt(fixture *cr3Fixture, height int64) *cr3ReplayApp {
	app := &cr3ReplayApp{maxBytes: fixture.state0.ConsensusParams.Block.MaxBytes}
	app.committedHeight = height
	if height > 0 {
		app.committedHash = []byte{byte(height)}
	}
	return app
}

func TestBugCR3HeightMatrix(t *testing.T) {
	t.Run("level0_no_replay", func(t *testing.T) {
		fixture := cr3NewFixture(t)
		state2, err := fixture.applySecond(t, fixture.stateStore)
		require.NoError(t, err)
		beforeFinalize, beforeCommit := fixture.app.finalizeCalls, fixture.app.commitCalls

		handshaker := NewHandshaker(fixture.stateStore, state2, fixture.blockStore, fixture.genDoc)
		require.NoError(t, handshaker.Handshake(context.Background(), fixture.proxyApp))
		require.Equal(t, 0, handshaker.NBlocks())
		require.Equal(t, beforeFinalize, fixture.app.finalizeCalls)
		require.Equal(t, beforeCommit, fixture.app.commitCalls)
		cr3AssertRecoveredState(t, fixture.stateStore)
		fmt.Println("CR3|level=0|case=no-replay|A=2 B=2 S=2|result=synchronized|real-app-calls=0")
	})

	t.Run("level0_app_only", func(t *testing.T) {
		fixture := cr3NewFixture(t)
		state2, err := fixture.applySecond(t, fixture.stateStore)
		require.NoError(t, err)
		freshApp := cr3FreshAppAt(fixture, 0)
		freshProxy := cr3StartProxy(t, freshApp)

		handshaker := NewHandshaker(fixture.stateStore, state2, fixture.blockStore, fixture.genDoc)
		require.NoError(t, handshaker.Handshake(context.Background(), freshProxy))
		require.Equal(t, 2, handshaker.NBlocks())
		require.Equal(t, int64(2), freshApp.committedHeight)
		require.Equal(t, 2, freshApp.finalizeCalls)
		require.Equal(t, 2, freshApp.commitCalls)
		cr3AssertRecoveredState(t, fixture.stateStore)
		fmt.Println("CR3|level=0|case=app-only|A=0 B=2 S=2|result=synchronized|ExecCommitBlock=2")
	})

	t.Run("level0_real_last", func(t *testing.T) {
		fixture := cr3NewFixture(t)
		beforeFinalize, beforeCommit := fixture.app.finalizeCalls, fixture.app.commitCalls
		handshaker := NewHandshaker(fixture.stateStore, fixture.state1, fixture.blockStore, fixture.genDoc)
		require.NoError(t, handshaker.Handshake(context.Background(), fixture.proxyApp))
		require.Equal(t, 1, handshaker.NBlocks())
		require.Equal(t, beforeFinalize+1, fixture.app.finalizeCalls)
		require.Equal(t, beforeCommit+1, fixture.app.commitCalls)
		cr3AssertRecoveredState(t, fixture.stateStore)
		fmt.Println("CR3|level=0|case=real-last|A=1 B=2 S=1|result=synchronized|ApplyBlock-real=1")
	})

	t.Run("level0_historical_plus_real_last", func(t *testing.T) {
		fixture := cr3NewFixture(t)
		freshApp := cr3FreshAppAt(fixture, 0)
		freshProxy := cr3StartProxy(t, freshApp)
		handshaker := NewHandshaker(fixture.stateStore, fixture.state1, fixture.blockStore, fixture.genDoc)
		require.NoError(t, handshaker.Handshake(context.Background(), freshProxy))
		require.Equal(t, 2, handshaker.NBlocks())
		require.Equal(t, 2, freshApp.finalizeCalls)
		require.Equal(t, 2, freshApp.commitCalls)
		cr3AssertRecoveredState(t, fixture.stateStore)
		fmt.Println("CR3|level=0|case=historical-plus-real-last|A=0 B=2 S=1|result=synchronized|ExecCommitBlock=1 ApplyBlock-real=1")
	})

	// Level 1 uses a storage-failure hook only to stop at the real crash window.
	// Core replay logic is unchanged. ApplyBlock has already saved the response and
	// committed the real app when the injected state Save error is returned.
	t.Run("level1_saved_response_mock_last", func(t *testing.T) {
		fixture := cr3NewFixture(t)
		crashStore := &cr3FailStateSave{Store: fixture.stateStore, failHeight: 2, armed: true}
		beforeFinalize, beforeCommit := fixture.app.finalizeCalls, fixture.app.commitCalls
		_, err := fixture.applySecond(t, crashStore)
		require.EqualError(t, err, "CR3 injected crash after app Commit, before state Save")
		require.Equal(t, int64(2), fixture.app.committedHeight)
		require.Equal(t, beforeFinalize+1, fixture.app.finalizeCalls)
		require.Equal(t, beforeCommit+1, fixture.app.commitCalls)
		persisted, err := fixture.stateStore.Load()
		require.NoError(t, err)
		require.Equal(t, int64(1), persisted.LastBlockHeight)
		savedResponse, err := fixture.stateStore.LoadLastFinalizeBlockResponse(2)
		require.NoError(t, err)
		require.Equal(t, cr3GasAtHeight2, savedResponse.ConsensusParamUpdates.Block.MaxGas)

		crashStore.armed = false
		handshaker := NewHandshaker(crashStore, persisted, fixture.blockStore, fixture.genDoc)
		require.NoError(t, handshaker.Handshake(context.Background(), fixture.proxyApp))
		require.Equal(t, 1, handshaker.NBlocks())
		// Mock replay must not call FinalizeBlock or Commit on the already-committed real app again.
		require.Equal(t, beforeFinalize+1, fixture.app.finalizeCalls)
		require.Equal(t, beforeCommit+1, fixture.app.commitCalls)
		recovered := cr3AssertRecoveredState(t, crashStore)

		// Real downstream consumer: validate the already stored next block against
		// the reloaded state. Its ConsensusHash was built from the recovered params.
		executor := sm.NewBlockExecutor(
			crashStore,
			log.NewNopLogger(),
			fixture.proxyApp.Consensus(),
			emptyMempool{},
			sm.EmptyEvidencePool{},
			fixture.blockStore,
		)
		block3 := recovered.MakeBlock(3, nil, fixture.commit2, nil, recovered.Validators.GetProposer().Address)
		require.NoError(t, executor.ValidateBlock(recovered, block3))
		fmt.Println("CR3|level=1|case=saved-response-mock-last|A=2 B=2 S=1|result=synchronized|real-app-recommit=0|consumer=BlockExecutor.ValidateBlock(height=3)")
	})

	t.Run("level2_reachable_truncated_boundary", func(t *testing.T) {
		fixture := cr3NewFixture(t)
		state2, err := fixture.applySecond(t, fixture.stateStore)
		require.NoError(t, err)
		_, _, err = fixture.blockStore.PruneBlocks(2, state2)
		require.NoError(t, err)

		// A=1 is reachable through genesis handshake -> FinalizeBlock(1) -> Commit(1).
		appAtOne := cr3FreshAppAt(fixture, 1)
		proxyAtOne := cr3StartProxy(t, appAtOne)
		handshaker := NewHandshaker(fixture.stateStore, state2, fixture.blockStore, fixture.genDoc)
		require.NoError(t, handshaker.Handshake(context.Background(), proxyAtOne))
		require.Equal(t, int64(2), appAtOne.committedHeight)
		cr3AssertRecoveredState(t, fixture.stateStore)
		fmt.Println("CR3|level=2|case=pruned-boundary-supported|A=1 base=2 B=2 S=2|result=synchronized")
	})

	t.Run("level2_unsupported_relations_rejected", func(t *testing.T) {
		t.Run("app_below_pruned_base", func(t *testing.T) {
			fixture := cr3NewFixture(t)
			state2, err := fixture.applySecond(t, fixture.stateStore)
			require.NoError(t, err)
			_, _, err = fixture.blockStore.PruneBlocks(2, state2)
			require.NoError(t, err)
			freshApp := cr3FreshAppAt(fixture, 0)
			freshProxy := cr3StartProxy(t, freshApp)
			handshaker := NewHandshaker(fixture.stateStore, state2, fixture.blockStore, fixture.genDoc)
			err = handshaker.Handshake(context.Background(), freshProxy)
			require.EqualError(t, err, "error on replay: app block height (0) is too far below block store base (2)")
			fmt.Println("CR3|level=2|case=app-below-pruned-base|A=0 base=2 B=2 S=2|result=rejected-before-normal-operation")
		})

		t.Run("app_ahead_of_store", func(t *testing.T) {
			fixture := cr3NewFixture(t)
			state2, err := fixture.applySecond(t, fixture.stateStore)
			require.NoError(t, err)
			appAhead := cr3FreshAppAt(fixture, 3)
			proxyAhead := cr3StartProxy(t, appAhead)
			handshaker := NewHandshaker(fixture.stateStore, state2, fixture.blockStore, fixture.genDoc)
			err = handshaker.Handshake(context.Background(), proxyAhead)
			require.EqualError(t, err, "error on replay: app block height (3) is higher than core (2)")
			fmt.Println("CR3|level=2|case=app-ahead|A=3 B=2 S=2|result=rejected-before-normal-operation")
		})

		t.Run("negative_app_height", func(t *testing.T) {
			fixture := cr3NewFixture(t)
			negative := int64(-1)
			badApp := cr3FreshAppAt(fixture, 0)
			badApp.infoHeightOverride = &negative
			badProxy := cr3StartProxy(t, badApp)
			handshaker := NewHandshaker(fixture.stateStore, fixture.state1, fixture.blockStore, fixture.genDoc)
			err := handshaker.Handshake(context.Background(), badProxy)
			require.ErrorContains(t, err, "negative last block height")
			fmt.Println("CR3|level=2|case=negative-app-height|A=-1 B=2 S=1|result=rejected-before-normal-operation")
		})

		t.Run("state_ahead_of_store", func(t *testing.T) {
			fixture := cr3NewFixture(t)
			state2, err := fixture.applySecond(t, fixture.stateStore)
			require.NoError(t, err)
			require.NoError(t, fixture.blockStore.DeleteLatestBlock())
			appAtOne := cr3FreshAppAt(fixture, 1)
			proxyAtOne := cr3StartProxy(t, appAtOne)
			handshaker := NewHandshaker(fixture.stateStore, state2, fixture.blockStore, fixture.genDoc)
			require.PanicsWithValue(t, "StateBlockHeight (2) > StoreBlockHeight (1)", func() {
				_ = handshaker.Handshake(context.Background(), proxyAtOne)
			})
			fmt.Println("CR3|level=2|case=state-ahead|A=1 B=1 S=2|result=panic-before-normal-operation")
		})

		t.Run("store_more_than_one_ahead", func(t *testing.T) {
			fixture := cr3NewFixture(t)
			freshApp := cr3FreshAppAt(fixture, 0)
			freshProxy := cr3StartProxy(t, freshApp)
			handshaker := NewHandshaker(fixture.stateStore, fixture.state0, fixture.blockStore, fixture.genDoc)
			require.PanicsWithValue(t, "StoreBlockHeight (2) > StateBlockHeight + 1 (1)", func() {
				_ = handshaker.Handshake(context.Background(), freshProxy)
			})
			fmt.Println("CR3|level=2|case=store-two-ahead|A=0 B=2 S=0|result=panic-before-normal-operation")
		})
	})

	// Level 3 is intentionally not a source patch: the claim is a deterministic
	// dispatch over durable heights. A delay cannot alter A/B/S or create a wrong
	// state transition, and changing a guard/path would fabricate the symptom.
	fmt.Println("CR3|level=3|case=deterministic-height-dispatch|result=delay-inapplicable; no source logic modified")
	fmt.Println("CR3|summary|live-harm=not-observed|all-supported-cases-synchronized|all-unsupported-cases-rejected")
}
