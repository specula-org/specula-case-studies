package privval

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/cometbft/cometbft/crypto/tmhash"
	cmtproto "github.com/cometbft/cometbft/proto/tendermint/types"
	"github.com/cometbft/cometbft/types"
)

const speculaHRSRollbackChainID = "specula-hrs-rollback"

func TestSpeculaHRSRollbackAllowsConflictingVoteSignatures(t *testing.T) {
	// Level-2 state injection: restore a previously valid HRS state file to model
	// the rollback state made reachable by a power loss after atomic rename but
	// before the parent directory is durable.
	dir := t.TempDir()
	keyPath := filepath.Join(dir, "priv_validator_key.json")
	statePath := filepath.Join(dir, "priv_validator_state.json")

	pv := GenFilePV(keyPath, statePath)
	pv.Save()

	preSignState, err := os.ReadFile(statePath)
	if err != nil {
		t.Fatalf("read pre-sign state: %v", err)
	}

	voteA := speculaRollbackVote(pv.Key.Address, speculaRollbackBlockID(0xa1))
	if err := pv.SignVote(speculaHRSRollbackChainID, voteA); err != nil {
		t.Fatalf("sign vote A: %v", err)
	}
	signBytesA := types.VoteSignBytes(speculaHRSRollbackChainID, voteA)
	signatureA := append([]byte(nil), voteA.Signature...)
	if !pv.Key.PubKey.VerifySignature(signBytesA, signatureA) {
		t.Fatalf("vote A signature does not verify")
	}

	conflictingBeforeRollback := speculaRollbackVote(pv.Key.Address, speculaRollbackBlockID(0xb2))
	err = pv.SignVote(speculaHRSRollbackChainID, conflictingBeforeRollback)
	if err == nil || !strings.Contains(err.Error(), "conflicting data") {
		t.Fatalf("expected live FilePV to reject conflicting same-HRS vote before rollback, got %v", err)
	}

	if err := os.WriteFile(statePath, preSignState, 0o600); err != nil {
		t.Fatalf("restore pre-sign state: %v", err)
	}

	pvAfterRollback := LoadFilePV(keyPath, statePath)
	voteB := speculaRollbackVote(pvAfterRollback.Key.Address, speculaRollbackBlockID(0xb2))
	if err := pvAfterRollback.SignVote(speculaHRSRollbackChainID, voteB); err != nil {
		t.Fatalf("sign vote B after HRS rollback: %v", err)
	}
	signBytesB := types.VoteSignBytes(speculaHRSRollbackChainID, voteB)
	signatureB := append([]byte(nil), voteB.Signature...)
	if !pvAfterRollback.Key.PubKey.VerifySignature(signBytesB, signatureB) {
		t.Fatalf("vote B signature does not verify")
	}

	if bytes.Equal(signBytesA, signBytesB) {
		t.Fatalf("test setup error: vote A and vote B sign bytes are identical")
	}
	if bytes.Equal(signatureA, signatureB) {
		t.Fatalf("expected distinct signatures for conflicting votes")
	}

	t.Logf("SPECULA_DOUBLE_SIGN_CONSEQUENCE: rollback allowed conflicting signatures at same H/R/S height=%d round=%d type=%v first_hash=%X second_hash=%X",
		voteA.Height, voteA.Round, voteA.Type, voteA.BlockID.Hash, voteB.BlockID.Hash)
}

func TestSpeculaFilePVSignVoteWritesHRSStateThroughAtomicRename(t *testing.T) {
	// This test deliberately drives the real FilePV.SignVote entry point. The
	// shell wrapper traces this test and checks the persistence syscalls.
	dir := t.TempDir()
	statePath := filepath.Join(dir, "priv_validator_state.json")
	pv := GenFilePV(filepath.Join(dir, "priv_validator_key.json"), statePath)

	vote := speculaRollbackVote(pv.Key.Address, speculaRollbackBlockID(0xc3))
	if err := pv.SignVote(speculaHRSRollbackChainID, vote); err != nil {
		t.Fatalf("sign vote for syscall probe: %v", err)
	}
	if _, err := os.Stat(statePath); err != nil {
		t.Fatalf("expected state file to exist after SignVote: %v", err)
	}

	t.Logf("SPECULA_HRS_STATE_PATH=%s", statePath)
}

func speculaRollbackVote(address types.Address, blockID types.BlockID) *cmtproto.Vote {
	vote := &types.Vote{
		Type:             cmtproto.PrevoteType,
		Height:           100,
		Round:            0,
		BlockID:          blockID,
		Timestamp:        time.Unix(100, 0).UTC(),
		ValidatorAddress: address,
		ValidatorIndex:   0,
	}
	return vote.ToProto()
}

func speculaRollbackBlockID(tag byte) types.BlockID {
	blockHash := bytes.Repeat([]byte{tag}, tmhash.Size)
	partSetHash := bytes.Repeat([]byte{tag ^ 0x55}, tmhash.Size)
	return types.BlockID{
		Hash: blockHash,
		PartSetHeader: types.PartSetHeader{
			Total: 1,
			Hash:  partSetHash,
		},
	}
}
