package consensus

import (
	"fmt"
	"testing"

	"github.com/stretchr/testify/require"

	abcicli "github.com/cometbft/cometbft/abci/client"
	"github.com/cometbft/cometbft/abci/example/kvstore"
	cfg "github.com/cometbft/cometbft/config"
	cstypes "github.com/cometbft/cometbft/consensus/types"
	cmtbytes "github.com/cometbft/cometbft/libs/bytes"
	cmtlog "github.com/cometbft/cometbft/libs/log"
	cmtos "github.com/cometbft/cometbft/libs/os"
	mempl "github.com/cometbft/cometbft/mempool"
	"github.com/cometbft/cometbft/p2p"
	"github.com/cometbft/cometbft/privval"
	cmtproto "github.com/cometbft/cometbft/proto/tendermint/types"
	"github.com/cometbft/cometbft/proxy"
	sm "github.com/cometbft/cometbft/state"
	"github.com/cometbft/cometbft/store"
	"github.com/cometbft/cometbft/types"
	cmttime "github.com/cometbft/cometbft/types/time"
)

// TestTraceNormalExecution exercises normal consensus flow
func TestTraceNormalExecution(t *testing.T) {
	traceFile := "/tmp/trace_normal.ndjson"
	err := InitTrace(traceFile)
	require.NoError(t, err)
	defer CloseTrace()

	conf := ResetConfig("consensus_normal_test")
	defer cmtos.RemoveAll(conf.RootDir)

	privVals := make([]types.PrivValidator, 1)
	privVals[0] = privval.LoadOrGenFilePV(conf.PrivValidatorKeyFile(), conf.PrivValidatorStateFile())

	genDoc, _ := types.GenesisDocFromFile(conf.GenesisFile())
	stateDB, blockStoreDB, _ := setupDBs()

	blockStore := store.NewBlockStore(blockStoreDB)
	state, _ := sm.LoadStateFromDBOrGenesisDoc(stateDB, genDoc)

	blockExec := sm.NewBlockExecutor(
		stateDB,
		cmtlog.NewNopLogger(),
		abcicli.NewLocalClient(cmtlog.NewNopLogger(), kvstore.NewApplication()),
		mempl.NewNullMempool(),
		sm.EmptyEvidencePool{},
		blockStore,
	)

	cs := NewState(
		cmtlog.NewNopLogger(),
		conf.Consensus,
		state,
		blockExec,
		blockStore,
		mempl.NewNullMempool(),
		sm.EmptyEvidencePool{},
	)
	cs.SetPrivValidator(privVals[0])

	validators := state.Validators
	cs.validators = validators
	cs.SetProposer(validators.Validators[0])

	// Start consensus
	cs.Start()
	defer cs.Stop()

	// Wait for EnterNewRound
	<-cs.NewRoundEvent()

	// Emit EnterNewRound event
	nodeID := validators.Validators[0].Address.String()
	_ = cs.EmitEnterNewRound(nodeID)

	// Advance to propose step
	cs.mtx.Lock()
	cs.Step = cstypes.RoundStepPropose
	cs.mtx.Unlock()

	// Propose a block (simplified)
	<-cs.ProposalEvent()

	// Advance to prevote step and emit event
	cs.mtx.Lock()
	cs.Step = cstypes.RoundStepPrevote
	_ = cs.EmitEnterPrevote(nodeID)
	cs.mtx.Unlock()

	// Create and add a vote
	vote := &types.Vote{
		Type:      cmtproto.PrevoteType,
		Height:    cs.Height,
		Round:     cs.Round,
		BlockID:   types.BlockID{Hash: cmtbytes.HexBytes("test")},
		Timestamp: cmttime.Now(),
	}
	cs.mtx.Lock()
	_ = cs.EmitAddVote(nodeID, vote)
	cs.mtx.Unlock()

	// Advance to precommit step
	cs.mtx.Lock()
	cs.Step = cstypes.RoundStepPrecommit
	_ = cs.EmitEnterPrecommit(nodeID)
	cs.mtx.Unlock()
}

// TestTraceProposalReception exercises proposal reception paths
func TestTraceProposalReception(t *testing.T) {
	traceFile := "/tmp/trace_proposal.ndjson"
	err := InitTrace(traceFile)
	require.NoError(t, err)
	defer CloseTrace()

	conf := ResetConfig("consensus_proposal_test")
	defer cmtos.RemoveAll(conf.RootDir)

	privVals := make([]types.PrivValidator, 1)
	privVals[0] = privval.LoadOrGenFilePV(conf.PrivValidatorKeyFile(), conf.PrivValidatorStateFile())

	genDoc, _ := types.GenesisDocFromFile(conf.GenesisFile())
	stateDB, blockStoreDB, _ := setupDBs()

	blockStore := store.NewBlockStore(blockStoreDB)
	state, _ := sm.LoadStateFromDBOrGenesisDoc(stateDB, genDoc)

	blockExec := sm.NewBlockExecutor(
		stateDB,
		cmtlog.NewNopLogger(),
		abcicli.NewLocalClient(cmtlog.NewNopLogger(), kvstore.NewApplication()),
		mempl.NewNullMempool(),
		sm.EmptyEvidencePool{},
		blockStore,
	)

	cs := NewState(
		cmtlog.NewNopLogger(),
		conf.Consensus,
		state,
		blockExec,
		blockStore,
		mempl.NewNullMempool(),
		sm.EmptyEvidencePool{},
	)
	cs.SetPrivValidator(privVals[0])

	validators := state.Validators
	cs.validators = validators

	// Emit trace events for proposal handling
	nodeID := validators.Validators[0].Address.String()

	cs.mtx.Lock()
	cs.Height = 1
	cs.Round = 0
	cs.Step = cstypes.RoundStepNewHeight
	_ = cs.EmitReceiveProposal(nodeID)

	cs.Step = cstypes.RoundStepPropose
	_ = cs.EmitReceiveBlockPart(nodeID)
	_ = cs.EmitHandleCompleteProposal(nodeID)
	cs.mtx.Unlock()
}

// TestTraceLockingBehavior exercises locking and unlocking behaviors
func TestTraceLockingBehavior(t *testing.T) {
	traceFile := "/tmp/trace_locking.ndjson"
	err := InitTrace(traceFile)
	require.NoError(t, err)
	defer CloseTrace()

	conf := ResetConfig("consensus_locking_test")
	defer cmtos.RemoveAll(conf.RootDir)

	privVals := make([]types.PrivValidator, 1)
	privVals[0] = privval.LoadOrGenFilePV(conf.PrivValidatorKeyFile(), conf.PrivValidatorStateFile())

	genDoc, _ := types.GenesisDocFromFile(conf.GenesisFile())
	stateDB, blockStoreDB, _ := setupDBs()

	blockStore := store.NewBlockStore(blockStoreDB)
	state, _ := sm.LoadStateFromDBOrGenesisDoc(stateDB, genDoc)

	blockExec := sm.NewBlockExecutor(
		stateDB,
		cmtlog.NewNopLogger(),
		abcicli.NewLocalClient(cmtlog.NewNopLogger(), kvstore.NewApplication()),
		mempl.NewNullMempool(),
		sm.EmptyEvidencePool{},
		blockStore,
	)

	cs := NewState(
		cmtlog.NewNopLogger(),
		conf.Consensus,
		state,
		blockExec,
		blockStore,
		mempl.NewNullMempool(),
		sm.EmptyEvidencePool{},
	)
	cs.SetPrivValidator(privVals[0])

	validators := state.Validators
	cs.validators = validators

	nodeID := validators.Validators[0].Address.String()

	// Simulate locking behavior
	cs.mtx.Lock()
	cs.Height = 1
	cs.Round = 0
	cs.Step = cstypes.RoundStepNewHeight
	cs.LockedBlock = &types.Block{
		Header: types.Header{Height: 1},
		Data:   types.Data{},
	}
	cs.LockedRound = 0
	_ = cs.EmitEnterNewRound(nodeID)

	// Emit unlock event
	cs.LockedBlock = nil
	cs.LockedRound = -1
	_ = cs.EmitUnlockOnPol(nodeID)

	// Emit ValidBlock update
	cs.ValidBlock = &types.Block{
		Header: types.Header{Height: 1},
		Data:   types.Data{},
	}
	cs.ValidRound = 0
	_ = cs.EmitUpdateValidBlock(nodeID)
	cs.mtx.Unlock()
}

// TestTraceCrashRecovery exercises crash and recovery paths
func TestTraceCrashRecovery(t *testing.T) {
	traceFile := "/tmp/trace_crash_recovery.ndjson"
	err := InitTrace(traceFile)
	require.NoError(t, err)
	defer CloseTrace()

	conf := ResetConfig("consensus_crash_test")
	defer cmtos.RemoveAll(conf.RootDir)

	privVals := make([]types.PrivValidator, 1)
	privVals[0] = privval.LoadOrGenFilePV(conf.PrivValidatorKeyFile(), conf.PrivValidatorStateFile())

	genDoc, _ := types.GenesisDocFromFile(conf.GenesisFile())
	stateDB, blockStoreDB, _ := setupDBs()

	blockStore := store.NewBlockStore(blockStoreDB)
	state, _ := sm.LoadStateFromDBOrGenesisDoc(stateDB, genDoc)

	blockExec := sm.NewBlockExecutor(
		stateDB,
		cmtlog.NewNopLogger(),
		abcicli.NewLocalClient(cmtlog.NewNopLogger(), kvstore.NewApplication()),
		mempl.NewNullMempool(),
		sm.EmptyEvidencePool{},
		blockStore,
	)

	// Create initial state
	cs := NewState(
		cmtlog.NewNopLogger(),
		conf.Consensus,
		state,
		blockExec,
		blockStore,
		mempl.NewNullMempool(),
		sm.EmptyEvidencePool{},
	)
	cs.SetPrivValidator(privVals[0])

	validators := state.Validators
	cs.validators = validators

	nodeID := validators.Validators[0].Address.String()

	cs.mtx.Lock()
	cs.Height = 2
	cs.Round = 1
	cs.Step = cstypes.RoundStepPrecommit
	_ = cs.EmitCrashAndRecover(nodeID)
	cs.mtx.Unlock()
}

// Helper function to setup test databases
func setupDBs() (sm.DB, store.DB, error) {
	stateDB := sm.NewMemoryStateDB()
	blockStoreDB := store.NewMemoryBlockStore()
	return stateDB, blockStoreDB, nil
}

// Helper to format event for testing
func formatEvent(eventName, nodeID string, height int64, round int32, step string) string {
	return fmt.Sprintf(`{"tag":"trace","eventName":"%s","nodeID":"%s","height":%d,"round":%d,"step":"%s"}`,
		eventName, nodeID, height, round, step)
}
