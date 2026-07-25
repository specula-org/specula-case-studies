package evidence_test

// Specula trace-harness scenarios for the CometBFT evidence pipeline.
//
// These tests drive the real pool through controlled state transitions while
// the evidence package emits NDJSON trace events (see evidence/trace_tla.go).
// Each scenario writes a separate trace file under traces/.

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/mock"
	"github.com/stretchr/testify/require"

	dbm "github.com/cometbft/cometbft-db"

	"github.com/cometbft/cometbft/evidence"
	"github.com/cometbft/cometbft/evidence/mocks"
	"github.com/cometbft/cometbft/libs/log"
	sm "github.com/cometbft/cometbft/state"
	smmocks "github.com/cometbft/cometbft/state/mocks"
	"github.com/cometbft/cometbft/types"
)

const traceChainID = "tla_trace_chain"

func tracePath(name string) string {
	dir := os.Getenv("TLA_TRACE_DIR")
	if dir == "" {
		dir = "../../traces"
	}
	_ = os.MkdirAll(dir, 0o755)
	return filepath.Join(dir, name+".ndjson")
}

// traceSetup binds the validator address(es) to TLA labels and emits the config
// line. The first validator is bound to v2 (Byzantine) — most scenarios
// equivocate a single Byzantine validator. Tests that need v1 should rebind
// after setup.
func traceSetup(t *testing.T, name string, validators []types.PrivValidator) {
	t.Helper()
	require.NoError(t, evidence.TraceTLAEnable(tracePath(name)))
	evidence.TraceTLAReset()
	// We bind the first validator to v2 (Byzantine) by default. The TLA config
	// declares ByzValidator = {v2}, so equivocators must label as v2.
	if len(validators) >= 1 {
		pk, _ := validators[0].GetPubKey()
		evidence.TraceTLABindValidator(pk.Address(), "v2")
	}
	if len(validators) >= 2 {
		pk, _ := validators[1].GetPubKey()
		evidence.TraceTLABindValidator(pk.Address(), "v1")
	}
	// The current Trace.cfg declares Server = {s1, s2, s3}, ByzServer = {s3}.
	evidence.TraceTLAEmitConfig(
		[]string{"s1", "s2", "s3"},
		[]string{"s3"},
		[]string{"v1", "v2"},
		[]string{"v2"},
	)
}

// makeTracedPool creates an evidence pool wired up for tracing as node nid.
// `height` is the historical state.LastBlockHeight to start at; for genesis
// pass 0.
func makeTracedPool(t *testing.T, nid string, height int64, val types.PrivValidator) *evidence.Pool {
	t.Helper()
	pubKey, err := val.GetPubKey()
	require.NoError(t, err)
	validator := &types.Validator{Address: pubKey.Address(), VotingPower: 10, PubKey: pubKey}
	valSet := &types.ValidatorSet{
		Validators: []*types.Validator{validator},
		Proposer:   validator,
	}

	state := sm.State{
		ChainID:                     traceChainID,
		InitialHeight:               1,
		LastBlockHeight:             height,
		LastBlockTime:               time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC),
		Validators:                  valSet,
		NextValidators:              valSet.CopyIncrementProposerPriority(1),
		LastValidators:              valSet,
		LastHeightValidatorsChanged: 1,
		ConsensusParams: types.ConsensusParams{
			Block: types.BlockParams{MaxBytes: 22020096, MaxGas: -1},
			Evidence: types.EvidenceParams{
				MaxAgeNumBlocks: 20,
				MaxAgeDuration:  20 * time.Minute,
				MaxBytes:        1000,
			},
		},
	}

	stateStoreDB := dbm.NewMemDB()
	stateStore := sm.NewStore(stateStoreDB, sm.StoreOptions{DiscardABCIResponses: false})
	for i := int64(0); i <= height; i++ {
		state.LastBlockHeight = i
		require.NoError(t, stateStore.Save(state))
	}

	blockStore := &mocks.BlockStore{}
	blockStore.On("LoadBlockMeta", mock.AnythingOfType("int64")).Return(
		&types.BlockMeta{Header: types.Header{Time: state.LastBlockTime}},
	)

	evDB := dbm.NewMemDB()
	pool, err := evidence.NewPool(evDB, stateStore, blockStore)
	require.NoError(t, err)
	pool.SetLogger(log.TestingLogger())
	evidence.TraceTLABindPool(pool, nid)
	return pool
}

// -----------------------------------------------------------------------------
// Scenario 1: DVE lifecycle — bootstrap → RCV → PCB → apply DVE in block.
//
// Spec ordering modeled by the trace:
//   PBH(1, [])         — chainHeight=1
//   Blocksync(1, [])   — appliedHeight=1 (empty block apply uses Blocksync)
//   RCV(voteA, voteB)  — buffer the pair
//   PBH(2, [])         — chainHeight=2
//   PCB(added)         — DVE built and added to pool
//   Blocksync(2, [])   — appliedHeight=2 (the empty block 2 is applied)
//   PBH(3, [dve])      — chainHeight=3
//   Reactor_Start(3, [dve])
//   RemovePending(dve, wasPending=true)
//   WriteCommitted(dve)
//   ABCI(dve, isLast=true)
//   Finish(3)
// -----------------------------------------------------------------------------

func TestTLATraceDVELifecycle(t *testing.T) {
	pv := types.NewMockPV()
	traceSetup(t, "scenario_dve_lifecycle", []types.PrivValidator{pv})
	defer evidence.TraceTLAClose()

	// Start at genesis (LBH=0) so the trace mirrors the spec's Init.
	pool := makeTracedPool(t, "s1", 0, pv)

	// Build a DVE at height 1 — same validator, same (h,r,type), different blockIDs.
	voteA, err := types.NewMockDuplicateVoteEvidenceWithValidator(
		1, time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC), pv, traceChainID,
	)
	require.NoError(t, err)
	// Above gives us a full DVE; we'll need just its VoteA/VoteB.
	voteAa := voteA.VoteA
	voteAb := voteA.VoteB

	// --- Block 1 (empty) bootstrap ---
	evidence.TLATestEmitProposeBlockHonest(pool, 1, nil)
	evidence.TLATestEmitApplyBlockBlocksync(pool, 1, nil)

	// Advance the impl pool too so its evpool.state.LBH=1 for subsequent calls.
	state1 := pool.State()
	state1.LastBlockHeight = 1
	state1.LastBlockTime = voteAa.Timestamp
	pool.Update(state1, types.EvidenceList{})

	// --- RCV ---
	pool.ReportConflictingVotes(voteAa, voteAb)

	// --- Block 2 (empty) — used to give the spec a clean Update opportunity ---
	evidence.TLATestEmitProposeBlockHonest(pool, 2, nil)

	// Drive Update to convert the buffered DVE. The impl emits PCB(added)
	// inside processConsensusBuffer.
	state2 := state1
	state2.LastBlockHeight = 2
	state2.LastBlockTime = voteAa.Timestamp.Add(time.Minute)
	pool.Update(state2, types.EvidenceList{})

	// Now apply the (empty) block 2 in the spec via Blocksync.
	evidence.TLATestEmitApplyBlockBlocksync(pool, 2, nil)

	// Confirm the DVE landed in the pool.
	pendingEv, _ := pool.PendingEvidence(1000)
	require.Equal(t, 1, len(pendingEv))
	dve := pendingEv[0]

	// --- Block 3 with the DVE — full apply pipeline ---
	evidence.TLATestEmitProposeBlockHonest(pool, 3, []types.Evidence{dve})

	require.NoError(t, pool.CheckEvidence(types.EvidenceList{dve}))
	evidence.TLATestEmitApplyBlockReactorStart(pool, 3, []types.Evidence{dve})

	state3 := state2
	state3.LastBlockHeight = 3
	state3.LastBlockTime = state2.LastBlockTime.Add(time.Minute)
	// Update emits RemovePending + WriteCommitted via instrumented markEvidenceAsCommitted.
	pool.Update(state3, types.EvidenceList{dve})

	// ABCI is per-evidence; this is the last (and only) evidence in the block.
	evidence.TLATestEmitApplyBlockABCI(pool, dve, true)
	evidence.TLATestEmitApplyBlockFinish(pool, 3)

	remaining, _ := pool.PendingEvidence(1000)
	assert.Empty(t, remaining)
}

// -----------------------------------------------------------------------------
// Scenario 2: AddEvidence direct API call.
//
//   PBH(1, [])         — chainHeight=1
//   Blocksync(1, [])   — appliedHeight=1
//   AddEvidence(direct) — verify passes, ev added
//   AddEvidence(direct) — already_pending branch
//   GossipForward(ev, {s2}) — emit gossip
// -----------------------------------------------------------------------------

func TestTLATraceAddEvidenceDirect(t *testing.T) {
	pv := types.NewMockPV()
	traceSetup(t, "scenario_add_evidence_direct", []types.PrivValidator{pv})
	defer evidence.TraceTLAClose()

	pool := makeTracedPool(t, "s1", 0, pv)

	// Bootstrap to height 1.
	evidence.TLATestEmitProposeBlockHonest(pool, 1, nil)
	evidence.TLATestEmitApplyBlockBlocksync(pool, 1, nil)
	state1 := pool.State()
	state1.LastBlockHeight = 1
	state1.LastBlockTime = time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	pool.Update(state1, types.EvidenceList{})

	// Build DVE at height 1.
	ev, err := types.NewMockDuplicateVoteEvidenceWithValidator(
		1, time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC), pv, traceChainID,
	)
	require.NoError(t, err)

	// First AddEvidence — "added" outcome.
	require.NoError(t, pool.AddEvidence(ev))
	// Second AddEvidence — "already_pending" branch.
	require.NoError(t, pool.AddEvidence(ev))

	// Gossip forward to s2.
	evidence.TLATestEmitGossipForward(pool, ev, []string{"s2"})

	pendingEv, _ := pool.PendingEvidence(1000)
	require.Equal(t, 1, len(pendingEv))
}

// -----------------------------------------------------------------------------
// Scenario 3: Crash and Recover with persistent pending evidence.
//
//   PBH(1, []) + Blocksync(1, []) — bootstrap
//   AddEvidence(direct)
//   Crash(s1)
//   Recover(s1)  — clist re-populated from DB
// -----------------------------------------------------------------------------

func TestTLATraceCrashRecover(t *testing.T) {
	pv := types.NewMockPV()
	traceSetup(t, "scenario_crash_recover", []types.PrivValidator{pv})
	defer evidence.TraceTLAClose()

	// Build a shared evidenceDB so the new pool sees the same persistent state.
	pubKey, err := pv.GetPubKey()
	require.NoError(t, err)
	validator := &types.Validator{Address: pubKey.Address(), VotingPower: 10, PubKey: pubKey}
	valSet := &types.ValidatorSet{
		Validators: []*types.Validator{validator},
		Proposer:   validator,
	}
	stateStoreDB := dbm.NewMemDB()
	stateStore := sm.NewStore(stateStoreDB, sm.StoreOptions{DiscardABCIResponses: false})
	baseState := sm.State{
		ChainID:                     traceChainID,
		InitialHeight:               1,
		LastBlockHeight:             0,
		LastBlockTime:               time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC),
		Validators:                  valSet,
		NextValidators:              valSet.CopyIncrementProposerPriority(1),
		LastValidators:              valSet,
		LastHeightValidatorsChanged: 1,
		ConsensusParams: types.ConsensusParams{
			Block: types.BlockParams{MaxBytes: 22020096, MaxGas: -1},
			Evidence: types.EvidenceParams{
				MaxAgeNumBlocks: 20,
				MaxAgeDuration:  20 * time.Minute,
				MaxBytes:        1000,
			},
		},
	}
	require.NoError(t, stateStore.Save(baseState))
	blockStore := &mocks.BlockStore{}
	blockStore.On("LoadBlockMeta", mock.AnythingOfType("int64")).Return(
		&types.BlockMeta{Header: types.Header{Time: baseState.LastBlockTime}},
	)

	evDB := dbm.NewMemDB()
	pool, err := evidence.NewPool(evDB, stateStore, blockStore)
	require.NoError(t, err)
	pool.SetLogger(log.TestingLogger())
	evidence.TraceTLABindPool(pool, "s1")

	// Bootstrap.
	evidence.TLATestEmitProposeBlockHonest(pool, 1, nil)
	evidence.TLATestEmitApplyBlockBlocksync(pool, 1, nil)
	state1 := pool.State()
	state1.LastBlockHeight = 1
	pool.Update(state1, types.EvidenceList{})

	// Add evidence.
	ev, err := types.NewMockDuplicateVoteEvidenceWithValidator(
		1, time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC), pv, traceChainID,
	)
	require.NoError(t, err)
	require.NoError(t, pool.AddEvidence(ev))

	// Crash — the pool's volatile state is lost.
	evidence.TLATestEmitCrash(pool)

	// Recover — fresh pool over the same DBs; NewPool reloads pending from disk.
	newPool, err := evidence.NewPool(evDB, stateStore, blockStore)
	require.NoError(t, err)
	newPool.SetLogger(log.TestingLogger())
	evidence.TraceTLABindPool(newPool, "s1")
	evidence.TLATestEmitRecover(newPool)

	pendingEv, _ := newPool.PendingEvidence(1000)
	require.Equal(t, 1, len(pendingEv))
}

// -----------------------------------------------------------------------------
// Scenario 4: ApplyBlock_Blocksync path explicitly with non-empty evidence.
//
//   PBH(1, [ev])       — chainHeight=1, byzantine proposer in spec terms
//   Blocksync(1, [ev]) — appliedHeight=1, ABCI handoff via Blocksync
// -----------------------------------------------------------------------------

func TestTLATraceBlocksync(t *testing.T) {
	pv := types.NewMockPV()
	traceSetup(t, "scenario_blocksync", []types.PrivValidator{pv})
	defer evidence.TraceTLAClose()

	pool := makeTracedPool(t, "s1", 0, pv)

	ev, err := types.NewMockDuplicateVoteEvidenceWithValidator(
		1, time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC), pv, traceChainID,
	)
	require.NoError(t, err)

	evidence.TLATestEmitProposeBlockHonest(pool, 1, []types.Evidence{ev})
	evidence.TLATestEmitApplyBlockBlocksync(pool, 1, []types.Evidence{ev})
}

// -----------------------------------------------------------------------------
// Scenario 5: an LCAE traveling through the pool (AddEvidence direct path).
// -----------------------------------------------------------------------------

func TestTLATraceLCAELifecycle(t *testing.T) {
	pv := types.NewMockPV()
	traceSetup(t, "scenario_lcae_lifecycle", []types.PrivValidator{pv})
	defer evidence.TraceTLAClose()

	// Build LCAE artifacts via the verify_test helpers.
	commonHeight := int64(2)
	height := int64(10)
	ev, trusted, common := makeLunaticEvidence(
		t, height, commonHeight, 10, 5, 5,
		time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC),
		time.Date(2026, 1, 1, 1, 0, 0, 0, time.UTC),
	)

	state := sm.State{
		LastBlockTime:   time.Date(2026, 1, 1, 2, 0, 0, 0, time.UTC),
		LastBlockHeight: 110,
		ConsensusParams: *types.DefaultConsensusParams(),
	}
	stateStoreMock := &smmocks.Store{}
	stateStoreMock.On("LoadValidators", height).Return(trusted.ValidatorSet, nil)
	stateStoreMock.On("LoadValidators", commonHeight).Return(common.ValidatorSet, nil)
	stateStoreMock.On("Load").Return(state, nil)

	blockStore := &mocks.BlockStore{}
	blockStore.On("LoadBlockMeta", height).Return(&types.BlockMeta{Header: *trusted.Header})
	blockStore.On("LoadBlockMeta", commonHeight).Return(&types.BlockMeta{Header: *common.Header})
	blockStore.On("LoadBlockCommit", height).Return(trusted.Commit)
	blockStore.On("LoadBlockCommit", commonHeight).Return(common.Commit)

	pool, err := evidence.NewPool(dbm.NewMemDB(), stateStoreMock, blockStore)
	require.NoError(t, err)
	pool.SetLogger(log.TestingLogger())
	evidence.TraceTLABindPool(pool, "s1")
	_ = pv

	// First AddEvidence — added.
	require.NoError(t, pool.AddEvidence(ev))
	// Second AddEvidence — already_pending.
	require.NoError(t, pool.AddEvidence(ev))

	pendingEv, _ := pool.PendingEvidence(state.ConsensusParams.Evidence.MaxBytes)
	require.Equal(t, 1, len(pendingEv))
}
