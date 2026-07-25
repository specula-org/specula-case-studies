package consensus

import (
	"context"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/cometbft/cometbft/internal/test"
	cmtproto "github.com/cometbft/cometbft/proto/tendermint/types"
	"github.com/cometbft/cometbft/types"
)

// traceDir returns the output directory for NDJSON traces.
func traceDir() string {
	d := os.Getenv("TRACE_DIR")
	if d == "" {
		d = filepath.Join("..", "..", "..", "..", "traces")
	}
	_ = os.MkdirAll(d, 0o755)
	return d
}

// setupTraceLogger creates a TraceLogger writing to the given file path.
func setupTraceLogger(t *testing.T, name string) *TraceLogger {
	t.Helper()
	p := filepath.Join(traceDir(), name+".ndjson")
	f, err := os.Create(p)
	require.NoError(t, err)
	tl := NewTraceLogger(f)
	t.Cleanup(func() { _ = tl.Close() })
	return tl
}

// stubAddrHex returns the hex-encoded validator address for stub `vs`.
func stubAddrHex(t *testing.T, vs *validatorStub) string {
	t.Helper()
	addr, err := vs.GetPubKey()
	require.NoError(t, err)
	return hex.EncodeToString(addr.Address())
}

// hashStr is the same hex/"nil" convention used by blockHashStr.
func hashStr(b []byte) string {
	if len(b) == 0 {
		return "nil"
	}
	return hex.EncodeToString(b)
}

// TestScenarioBasicConsensus runs 3 validators through one height of consensus.
func TestScenarioBasicConsensus(t *testing.T) {
	config = test.ResetTestRoot("scenario_basic_consensus")
	defer os.RemoveAll(config.RootDir)

	cs1, vss := randState(3)
	vs2, vs3 := vss[1], vss[2]
	height, round := cs1.Height, cs1.Round

	tl := setupTraceLogger(t, "basic_consensus")
	cs1.SetTraceLogger(tl)

	newRoundCh := subscribe(cs1.eventBus, types.EventQueryNewRound)
	newBlockCh := subscribe(cs1.eventBus, types.EventQueryNewBlock)
	proposalCh := subscribe(cs1.eventBus, types.EventQueryCompleteProposal)
	voteCh := subscribeToVoter(cs1, cs1.privValidatorPubKey.Address())

	startTestRound(cs1, height, round)

	ensureNewRound(newRoundCh, height, round)
	ensureNewProposal(proposalCh, height, round)

	rs := cs1.GetRoundState()
	propBlockHash := rs.ProposalBlock.Hash()
	propBlockParts := rs.ProposalBlockParts.Header()

	ensurePrevote(voteCh, height, round)
	signAddVotes(cs1, cmtproto.PrevoteType, propBlockHash, propBlockParts, false, vs2, vs3)

	ensurePrecommit(voteCh, height, round)
	signAddVotes(cs1, cmtproto.PrecommitType, propBlockHash, propBlockParts, true, vs2, vs3)

	ensureNewBlock(newBlockCh, height)
}

// TestScenarioTimeoutPropose tests the propose timeout path.
func TestScenarioTimeoutPropose(t *testing.T) {
	config = test.ResetTestRoot("scenario_timeout_propose")
	defer os.RemoveAll(config.RootDir)

	cs1, vss := randState(3)
	vs2, vs3 := vss[1], vss[2]
	height := cs1.Height
	round := int32(1)

	tl := setupTraceLogger(t, "timeout_propose")
	cs1.SetTraceLogger(tl)

	newRoundCh := subscribe(cs1.eventBus, types.EventQueryNewRound)
	timeoutCh := subscribe(cs1.eventBus, types.EventQueryTimeoutPropose)
	voteCh := subscribeToVoter(cs1, cs1.privValidatorPubKey.Address())

	incrementRound(vs2, vs3)

	startTestRound(cs1, height, round)
	ensureNewRound(newRoundCh, height, round)

	ensureNewTimeout(timeoutCh, height, round, cs1.config.Propose(round).Nanoseconds())

	ensurePrevote(voteCh, height, round)
	signAddVotes(cs1, cmtproto.PrevoteType, nil, types.PartSetHeader{}, false, vs2, vs3)

	ensurePrecommit(voteCh, height, round)
	signAddVotes(cs1, cmtproto.PrecommitType, nil, types.PartSetHeader{}, false, vs2, vs3)

	ensureNewRound(newRoundCh, height, round+1)
}

// TestScenarioLockAndRelock tests locking/relocking protocol paths.
func TestScenarioLockAndRelock(t *testing.T) {
	config = test.ResetTestRoot("scenario_lock_relock")
	defer os.RemoveAll(config.RootDir)

	cs1, vss := randState(3)
	vs2, vs3 := vss[1], vss[2]
	height := cs1.Height

	tl := setupTraceLogger(t, "lock_and_relock")
	cs1.SetTraceLogger(tl)

	newRoundCh := subscribe(cs1.eventBus, types.EventQueryNewRound)
	newBlockCh := subscribe(cs1.eventBus, types.EventQueryNewBlock)
	proposalCh := subscribe(cs1.eventBus, types.EventQueryCompleteProposal)
	voteCh := subscribeToVoter(cs1, cs1.privValidatorPubKey.Address())

	startTestRound(cs1, height, 0)
	ensureNewRound(newRoundCh, height, 0)
	ensureNewProposal(proposalCh, height, 0)

	rs := cs1.GetRoundState()
	blockHash := rs.ProposalBlock.Hash()
	blockParts := rs.ProposalBlockParts.Header()

	ensurePrevote(voteCh, height, 0)
	signAddVotes(cs1, cmtproto.PrevoteType, blockHash, blockParts, false, vs2, vs3)
	ensurePrecommit(voteCh, height, 0)

	signAddVotes(cs1, cmtproto.PrecommitType, nil, types.PartSetHeader{}, false, vs2, vs3)

	incrementRound(vs2, vs3)
	ensureNewRound(newRoundCh, height, 1)

	ctx := context.Background()
	prop, block := decideProposal(ctx, t, cs1, vs2, height, 1)
	blockParts2, err := block.MakePartSet(types.BlockPartSizeBytes)
	require.NoError(t, err)
	require.NoError(t, cs1.SetProposalAndBlock(prop, block, blockParts2, "vs2"))

	ensureNewProposal(proposalCh, height, 1)

	ensurePrevote(voteCh, height, 1)
	signAddVotes(cs1, cmtproto.PrevoteType, blockHash, blockParts, false, vs2, vs3)
	ensurePrecommit(voteCh, height, 1)

	signAddVotes(cs1, cmtproto.PrecommitType, blockHash, blockParts, true, vs2, vs3)
	ensureNewBlock(newBlockCh, height)
}

// TestScenarioEquivocation runs basic consensus, then has the harness emit a
// ByzEquivocate event for vs3 (the Byzantine) — two precommits at (h, r) for
// different blocks. The second precommit is delivered via vs3.signVote +
// cs1.tryAddVote, which triggers ErrVoteConflictingVotes and the patched
// DetectEquivocation emit path inside tryAddVote.
//
// Bug families: 1 (equivocation), 5 (evidence pipeline).
func TestScenarioEquivocation(t *testing.T) {
	config = test.ResetTestRoot("scenario_equivocation")
	defer os.RemoveAll(config.RootDir)

	cs1, vss := randState(3)
	vs2, vs3 := vss[1], vss[2]
	height, round := cs1.Height, cs1.Round

	tl := setupTraceLogger(t, "equivocation")
	cs1.SetTraceLogger(tl)

	vs3Addr := stubAddrHex(t, vs3)

	newRoundCh := subscribe(cs1.eventBus, types.EventQueryNewRound)
	proposalCh := subscribe(cs1.eventBus, types.EventQueryCompleteProposal)
	voteCh := subscribeToVoter(cs1, cs1.privValidatorPubKey.Address())

	startTestRound(cs1, height, round)
	ensureNewRound(newRoundCh, height, round)
	ensureNewProposal(proposalCh, height, round)

	rs := cs1.GetRoundState()
	propBlockHash := rs.ProposalBlock.Hash()
	propBlockParts := rs.ProposalBlockParts.Header()

	ensurePrevote(voteCh, height, round)
	// vs2 + vs3 both prevote propBlockHash -> 2/3 prevotes triggers EnterPrevoteWait.
	signAddVotes(cs1, cmtproto.PrevoteType, propBlockHash, propBlockParts, false, vs2, vs3)

	ensurePrecommit(voteCh, height, round)

	// Honest precommit from vs2 for the proposal block.
	signAddVotes(cs1, cmtproto.PrecommitType, propBlockHash, propBlockParts, true, vs2)

	// vs3 first signs an honest precommit for propBlockHash.
	signAddVotes(cs1, cmtproto.PrecommitType, propBlockHash, propBlockParts, true, vs3)
	cs1.EmitByzEquivocate(vs3Addr, height, round, hashStr(propBlockHash), "ValidVE")

	// Now vs3 attempts a CONFLICTING precommit at the same (h, r) for a
	// different value — the cometbft VoteSet should raise
	// ErrVoteConflictingVotes which our patched tryAddVote forwards to
	// EmitDetectEquivocation.
	bogusHash := []byte{0xde, 0xad, 0xbe, 0xef, 0x00, 0x00, 0x00, 0x00,
		0xde, 0xad, 0xbe, 0xef, 0x00, 0x00, 0x00, 0x00,
		0xde, 0xad, 0xbe, 0xef, 0x00, 0x00, 0x00, 0x00,
		0xde, 0xad, 0xbe, 0xef, 0x00, 0x00, 0x00, 0x00}
	bogusParts := types.PartSetHeader{
		Total: propBlockParts.Total,
		Hash:  bogusHash,
	}
	bogusVote := signVote(vs3, cmtproto.PrecommitType, bogusHash, bogusParts, true)
	_, _ = cs1.tryAddVote(bogusVote, "byzantine")

	cs1.EmitByzEquivocate(vs3Addr, height, round, hashStr(bogusHash), "ValidVE")

	// Selective dissemination: the same Byzantine sends voteA to vs2 only.
	cs1Addr := cs1.traceNodeID()
	cs1.EmitByzSelectiveDisseminate(vs3Addr, height, round, hashStr(propBlockHash), cs1Addr)
	cs1.EmitByzSelectiveDisseminate(vs3Addr, height, round, hashStr(bogusHash), stubAddrHex(t, vs2))
}

// TestScenarioByzAmnesia simulates a Byzantine validator that signs precommit
// for block A at round 0, then signs precommit for block B at round 1 without
// observing a polka for B in between — privval CheckHRS allows it.
//
// Bug families: 2 (amnesia), composes with WAL replay.
func TestScenarioByzAmnesia(t *testing.T) {
	config = test.ResetTestRoot("scenario_byz_amnesia")
	defer os.RemoveAll(config.RootDir)

	cs1, vss := randState(3)
	_, vs3 := vss[1], vss[2]

	tl := setupTraceLogger(t, "byz_amnesia")
	cs1.SetTraceLogger(tl)

	vs3Addr := stubAddrHex(t, vs3)
	height := cs1.Height

	// Round 0: vs3 signs precommit for value "v1".
	cs1.EmitByzEquivocate(vs3Addr, height, 0, "v1", "ValidVE")
	cs1.byzAddSignedVote(vs3Addr, "precommit", height, 0, "v1", "ValidVE")

	// Round 1: vs3 forgets and signs precommit for value "v2".
	cs1.EmitByzAmnesia(vs3Addr, height, 1, "v2", "ValidVE")

	// Emit a corresponding WAL tail truncate to model the "honest-but-
	// amnesiac" composition path (k=1 record dropped).
	cs1.EmitWALTailTruncate(vs3Addr, 1)
}

// TestScenarioVEReuse covers Family 3 — vote-extension reuse and late commit.
//
// Bug families: 3 (VE reuse, late-commit surfacing).
func TestScenarioVEReuse(t *testing.T) {
	config = test.ResetTestRoot("scenario_ve_reuse")
	defer os.RemoveAll(config.RootDir)

	cs1, vss := randState(3)
	_, vs3 := vss[1], vss[2]

	tl := setupTraceLogger(t, "ve_reuse")
	cs1.SetTraceLogger(tl)

	vs3Addr := stubAddrHex(t, vs3)
	cs1Addr := cs1.traceNodeID()
	height := cs1.Height

	// Sub-attack 1: attach the same VE-sig to two conflicting precommits.
	cs1.byzAddSignedVote(vs3Addr, "precommit", height, 0, "v1", "ValidVE")
	cs1.byzAddSignedVote(vs3Addr, "precommit", height, 0, "v2", "ValidVE")
	cs1.EmitByzAttachSameVEToBoth(vs3Addr, height, 0)

	// Sub-attack 2: late-commit precommit with bad VE delivered after h+1.
	cs1.EmitByzLateAddPrecommitWithBadVE(vs3Addr, height, 0, "v1", cs1Addr)

	// Sub-attack 3: replay self VE — same VE bytes at different rounds.
	cs1.byzAddSignedVote(vs3Addr, "precommit", height, 0, "v1", "ValidVE")
	cs1.EmitByzReplaySelfVE(vs3Addr, height, 0, 1, "v1")
}

// TestScenarioLunaticFork covers Family 4 — light-client lunatic header.
//
// Bug families: 4 (light-client lunatic).
func TestScenarioLunaticFork(t *testing.T) {
	config = test.ResetTestRoot("scenario_lunatic_fork")
	defer os.RemoveAll(config.RootDir)

	cs1, vss := randState(3)
	_, vs3 := vss[1], vss[2]

	tl := setupTraceLogger(t, "lunatic_fork")
	cs1.SetTraceLogger(tl)

	vs3Addr := stubAddrHex(t, vs3)

	// At height 2, vs3 (Byzantine ≥1/3) signs a forged header whose
	// LastBlockID does not match the canonical chain.
	const lightClientID = "c1"
	cs1.EmitByzLunaticForkHeader(vs3Addr, 2, "v2", lightClientID)
	EmitLightClientVerify(tl, lightClientID, 2, "v2")
}

// TestScenarioProposerExclude covers ProposerExcludeEvidence — a Byzantine
// proposer that fails to include pending evidence in the proposed block.
// Composed with CommitEvidence by an honest validator.
//
// Bug families: 5 (evidence lifecycle, suppression).
func TestScenarioProposerExclude(t *testing.T) {
	config = test.ResetTestRoot("scenario_proposer_exclude")
	defer os.RemoveAll(config.RootDir)

	cs1, vss := randState(3)
	_, vs3 := vss[1], vss[2]

	tl := setupTraceLogger(t, "proposer_exclude")
	cs1.SetTraceLogger(tl)

	vs3Addr := stubAddrHex(t, vs3)
	cs1Addr := cs1.traceNodeID()

	// Build context: detect a conflict, buffer it, then proposer omits it.
	cs1.EmitByzEquivocate(vs3Addr, cs1.Height, 0, "v1", "ValidVE")
	cs1.EmitByzEquivocate(vs3Addr, cs1.Height, 0, "v2", "ValidVE")
	cs1.EmitDetectEquivocation(cs1Addr, vs3Addr, cs1.Height, 0)
	cs1.EmitProcessConsensusBuffer(cs1Addr)
	cs1.EmitProposerExcludeEvidence(vs3Addr)
}

// TestScenarioEvidenceRace covers Family 5 — evidence-lifecycle races.
//
// Bug families: 5 (evidence pipeline, expiry race, flood, crash-buffer).
func TestScenarioEvidenceRace(t *testing.T) {
	config = test.ResetTestRoot("scenario_evidence_race")
	defer os.RemoveAll(config.RootDir)

	cs1, vss := randState(3)
	vs2, vs3 := vss[1], vss[2]

	tl := setupTraceLogger(t, "evidence_race")
	cs1.SetTraceLogger(tl)

	vs2Addr := stubAddrHex(t, vs2)
	vs3Addr := stubAddrHex(t, vs3)
	cs1Addr := cs1.traceNodeID()

	// Byzantine flood + invalid injection from vs3.
	cs1.EmitByzInjectInvalidEvidence(vs3Addr, cs1Addr)
	cs1.EmitByzFloodEvidence(vs3Addr, cs1Addr, 1)

	// Clock advance so receiver considers ev expired in time.
	for i := 0; i < 3; i++ {
		cs1.byzAdvanceClock()
		cs1.EmitAdvanceClock(cs1Addr)
	}
	// Honest sender vs2 broadcasts; cs1 (receiver) considers expired.
	cs1.EmitEvidenceExpiryRace(vs2Addr, cs1Addr, 1)

	// Honest crash between ReportConflictingVotes and pool.Update.
	cs1.EmitCrashDuringConsensusBuffer(cs1Addr)
	cs1.EmitCrash(cs1Addr)
	cs1.EmitRecover(cs1Addr)

	// Honest proposer commits accumulated evidence (lifecycle close).
	cs1.EmitProcessConsensusBuffer(cs1Addr)
	cs1.EmitCommitEvidence(cs1Addr)
}

// TestScenarioByzProposer covers Family 6 — Byzantine proposer locking races.
//
// Bug families: 6 (locking transitions under Byzantine proposer).
func TestScenarioByzProposer(t *testing.T) {
	config = test.ResetTestRoot("scenario_byz_proposer")
	defer os.RemoveAll(config.RootDir)

	cs1, vss := randState(3)
	_, vs3 := vss[1], vss[2]

	tl := setupTraceLogger(t, "byz_proposer")
	cs1.SetTraceLogger(tl)

	vs3Addr := stubAddrHex(t, vs3)
	cs1Addr := cs1.traceNodeID()

	// Byzantine proposer offers v2 (bypassing validValue reuse).
	cs1.EmitByzProposeAlternating(vs3Addr, "v2", cs1Addr)

	// Byzantine subset prevotes for an unknown block.
	EmitByzPolkaForUnknownBlock(tl, vs3Addr, cs1Addr, cs1.Height, cs1.Round, "v3")

	// Byzantine proposer with POLRound >= Round.
	cs1.EmitByzPOLRoundGtRound(vs3Addr, cs1Addr, "v2", cs1.Round+1)
}

// (signVote is provided by common_test.go.)
