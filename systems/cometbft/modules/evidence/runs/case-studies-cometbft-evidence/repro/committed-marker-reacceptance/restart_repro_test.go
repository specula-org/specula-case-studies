package evidence_test

import (
	"errors"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	dbm "github.com/cometbft/cometbft-db"

	"github.com/cometbft/cometbft/evidence"
	"github.com/cometbft/cometbft/libs/log"
	sm "github.com/cometbft/cometbft/state"
	"github.com/cometbft/cometbft/store"
	"github.com/cometbft/cometbft/types"
)

type failNextSetPersistentDB struct {
	dbm.DB
	failNextSet bool
}

func (db *failNextSetPersistentDB) Set(key []byte, value []byte) error {
	if db.failNextSet {
		db.failNextSet = false
		return errors.New("simulated loss of committed marker write")
	}
	return db.DB.Set(key, value)
}

func TestSpeculaCommittedMarkerWriteFailureSurvivesRestart(t *testing.T) {
	height := int64(21)
	val := types.NewMockPV()
	valAddress := val.PrivKey.PubKey().Address()
	dbRoot := t.TempDir()

	evidenceDir := filepath.Join(dbRoot, "evidence")
	stateDir := filepath.Join(dbRoot, "state")
	blockDir := filepath.Join(dbRoot, "blockstore")

	evidenceRawDB, err := dbm.NewDB("evidence", dbm.GoLevelDBBackend, evidenceDir)
	require.NoError(t, err)
	evidenceDB := &failNextSetPersistentDB{DB: evidenceRawDB}

	stateDB, err := dbm.NewDB("state", dbm.GoLevelDBBackend, stateDir)
	require.NoError(t, err)
	stateStore, state := initializePersistentValidatorState(t, stateDB, val, height)

	blockDB, err := dbm.NewDB("blockstore", dbm.GoLevelDBBackend, blockDir)
	require.NoError(t, err)
	blockStore, err := initializeBlockStore(blockDB, state, valAddress)
	require.NoError(t, err)

	pool, err := evidence.NewPool(evidenceDB, stateStore, blockStore)
	require.NoError(t, err)
	pool.SetLogger(log.TestingLogger())

	ev, err := types.NewMockDuplicateVoteEvidenceWithValidator(
		height,
		defaultEvidenceTime.Add(21*time.Minute),
		val,
		evidenceChainID,
	)
	require.NoError(t, err)

	require.NoError(t, pool.CheckEvidence(types.EvidenceList{ev}))

	state.LastBlockHeight = height + 1
	state.LastBlockTime = defaultEvidenceTime.Add(22 * time.Minute)
	evidenceDB.failNextSet = true
	pool.Update(state, types.EvidenceList{ev})
	require.NoError(t, stateStore.Save(state), "ApplyBlock saves state after updating the evidence pool")

	require.NoError(t, pool.Close())
	require.NoError(t, blockStore.Close())
	require.NoError(t, stateStore.Close())

	recoveredEvidenceDB, err := dbm.NewDB("evidence", dbm.GoLevelDBBackend, evidenceDir)
	require.NoError(t, err)
	defer recoveredEvidenceDB.Close()

	recoveredStateDB, err := dbm.NewDB("state", dbm.GoLevelDBBackend, stateDir)
	require.NoError(t, err)
	recoveredStateStore := sm.NewStore(recoveredStateDB, sm.StoreOptions{DiscardABCIResponses: false})
	defer recoveredStateStore.Close()

	recoveredState, err := recoveredStateStore.Load()
	require.NoError(t, err)
	require.Equal(t, height+1, recoveredState.LastBlockHeight)

	recoveredBlockDB, err := dbm.NewDB("blockstore", dbm.GoLevelDBBackend, blockDir)
	require.NoError(t, err)
	recoveredBlockStore := store.NewBlockStore(recoveredBlockDB)
	defer recoveredBlockStore.Close()

	recoveredPool, err := evidence.NewPool(recoveredEvidenceDB, recoveredStateStore, recoveredBlockStore)
	require.NoError(t, err)
	recoveredPool.SetLogger(log.TestingLogger())

	err = recoveredPool.CheckEvidence(types.EvidenceList{ev})
	require.Error(t, err, "restarted pool should still reject already-committed evidence")
}

func initializePersistentValidatorState(
	t *testing.T,
	stateDB dbm.DB,
	privVal types.PrivValidator,
	height int64,
) (sm.Store, sm.State) {
	t.Helper()

	pubKey, err := privVal.GetPubKey()
	require.NoError(t, err)
	validator := &types.Validator{Address: pubKey.Address(), VotingPower: 10, PubKey: pubKey}
	valSet := &types.ValidatorSet{
		Validators: []*types.Validator{validator},
		Proposer:   validator,
	}

	stateStore := sm.NewStore(stateDB, sm.StoreOptions{DiscardABCIResponses: false})
	state := sm.State{
		ChainID:                     evidenceChainID,
		InitialHeight:               1,
		LastBlockTime:               defaultEvidenceTime,
		Validators:                  valSet,
		NextValidators:              valSet.CopyIncrementProposerPriority(1),
		LastValidators:              valSet,
		LastHeightValidatorsChanged: 1,
		ConsensusParams: types.ConsensusParams{
			Block: types.BlockParams{
				MaxBytes: 22020096,
				MaxGas:   -1,
			},
			Evidence: types.EvidenceParams{
				MaxAgeNumBlocks: 20,
				MaxAgeDuration:  20 * time.Minute,
				MaxBytes:        defaultEvidenceMaxBytes,
			},
		},
	}

	for i := int64(0); i <= height; i++ {
		state.LastBlockHeight = i
		require.NoError(t, stateStore.Save(state))
	}

	loadedState, err := stateStore.Load()
	require.NoError(t, err)
	return stateStore, loadedState
}
