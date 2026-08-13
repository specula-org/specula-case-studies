package evidence_test

import (
	"errors"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	dbm "github.com/cometbft/cometbft-db"

	"github.com/cometbft/cometbft/evidence"
	"github.com/cometbft/cometbft/libs/log"
	"github.com/cometbft/cometbft/types"
)

type failNextSetDB struct {
	dbm.DB
	failNextSet bool
}

func (db *failNextSetDB) Set(key []byte, value []byte) error {
	if db.failNextSet {
		db.failNextSet = false
		return errors.New("simulated loss of committed marker write")
	}
	return db.DB.Set(key, value)
}

func TestSpeculaCommittedMarkerWriteFailureReacceptsEvidence(t *testing.T) {
	height := int64(21)
	val := types.NewMockPV()
	valAddress := val.PrivKey.PubKey().Address()

	evidenceDB := &failNextSetDB{DB: dbm.NewMemDB()}
	stateStore := initializeValidatorState(val, height)
	state, err := stateStore.Load()
	require.NoError(t, err)
	blockStore, err := initializeBlockStore(dbm.NewMemDB(), state, valAddress)
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

	err = pool.CheckEvidence(types.EvidenceList{ev})
	require.Error(t, err, "evidence should still be rejected after the committed-marker write is lost")
}
