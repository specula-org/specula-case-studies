package evidence

// TLA+ trace emission for the CometBFT evidence pipeline.
//
// This file is added by the Specula harness — it is NOT part of upstream cometbft.
// It exports a thread-safe NDJSON writer and helpers that other evidence-package
// code calls at instrumentation points. Test code in evidence_test wires the
// writer up via the exported configurator functions below.

import (
	"encoding/hex"
	"encoding/json"
	"os"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	dbm "github.com/cometbft/cometbft-db"
	cmtproto "github.com/cometbft/cometbft/proto/tendermint/types"
	"github.com/cometbft/cometbft/types"
)

// -----------------------------------------------------------------------------
// Writer + global state
// -----------------------------------------------------------------------------

var (
	traceMu      sync.Mutex
	traceFile    *os.File
	traceEnabled atomic.Bool

	// per-pool nid (TLA Server label). Keyed by *Pool pointer.
	poolNid sync.Map // *Pool -> string

	// validator-address bytes (hex lowercase) -> "v1"/"v2"
	validatorMap sync.Map
	// blockID-hash bytes (hex lowercase) -> "b1"/"b2"
	blockIDMap sync.Map
	// auto-assignment of labels for previously-unseen hashes.
	autoLabelMu     sync.Mutex
	autoValidatorN  int
	autoBlockIDN    int
	autoLabelLimitV = 2 // matches Validator = {v1, v2} in Trace.cfg
	autoLabelLimitB = 2 // matches BlockID = {b1, b2} in Trace.cfg

	// shadow state -- one entry per node label
	shadowMu             sync.Mutex
	shadowCrashed        = map[string]bool{}
	shadowApplyPhase     = map[string]string{} // "none"|"remove"|"write"|"abci"|"done"
	shadowChainHeight    int
	shadowAppliedHeight  = map[string]int{} // per-node, advanced on Finish/Blocksync
	shadowSlashed        = map[string]bool{} // key: validator label -> true
	shadowSlashCount     = map[string]int{}
)

// TraceTLAEnable opens the trace file. Call once per test. Multiple calls reset.
func TraceTLAEnable(path string) error {
	traceMu.Lock()
	defer traceMu.Unlock()
	if traceFile != nil {
		_ = traceFile.Close()
		traceFile = nil
	}
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	traceFile = f
	traceEnabled.Store(true)
	return nil
}

// TraceTLAClose flushes + closes the trace file.
func TraceTLAClose() {
	traceMu.Lock()
	defer traceMu.Unlock()
	if traceFile != nil {
		_ = traceFile.Sync()
		_ = traceFile.Close()
		traceFile = nil
	}
	traceEnabled.Store(false)
}

// TraceTLAReset clears shadow state for a fresh test scenario.
func TraceTLAReset() {
	poolNid = sync.Map{}
	validatorMap = sync.Map{}
	blockIDMap = sync.Map{}
	autoLabelMu.Lock()
	autoValidatorN = 0
	autoBlockIDN = 0
	autoLabelMu.Unlock()
	shadowMu.Lock()
	defer shadowMu.Unlock()
	shadowCrashed = map[string]bool{}
	shadowApplyPhase = map[string]string{}
	shadowChainHeight = 0
	shadowAppliedHeight = map[string]int{}
	shadowSlashed = map[string]bool{}
	shadowSlashCount = map[string]int{}
}

// TraceTLABindPool attaches a node label (e.g. "s1") to a pool pointer.
func TraceTLABindPool(p *Pool, nid string) {
	poolNid.Store(p, nid)
	shadowMu.Lock()
	if _, ok := shadowApplyPhase[nid]; !ok {
		shadowApplyPhase[nid] = "none"
	}
	if _, ok := shadowCrashed[nid]; !ok {
		shadowCrashed[nid] = false
	}
	shadowMu.Unlock()
}

// TraceTLABindValidator maps a validator address (raw bytes) to its TLA label.
func TraceTLABindValidator(addr []byte, label string) {
	validatorMap.Store(hex.EncodeToString(addr), label)
}

// TraceTLABindBlockID maps a block-hash byte sequence to its TLA label.
func TraceTLABindBlockID(hash []byte, label string) {
	blockIDMap.Store(hex.EncodeToString(hash), label)
}

// TraceTLAEmitConfig writes the harness-level configuration line.
func TraceTLAEmitConfig(servers []string, byzServers []string, validators []string, byzValidators []string) {
	if !traceEnabled.Load() {
		return
	}
	cfg := map[string]any{
		"servers":       servers,
		"byzServers":    byzServers,
		"validators":    validators,
		"byzValidators": byzValidators,
	}
	writeLine(map[string]any{
		"tag":    "config",
		"ts":     time.Now().UnixNano(),
		"config": cfg,
	})
}

// TraceTLASetChainHeight is called by test orchestrators that drive a synthetic chain.
func TraceTLASetChainHeight(h int) {
	shadowMu.Lock()
	shadowChainHeight = h
	shadowMu.Unlock()
}

// -----------------------------------------------------------------------------
// Helpers for translation
// -----------------------------------------------------------------------------

func validatorLabel(addr []byte) string {
	if len(addr) == 0 {
		return "Nil"
	}
	key := hex.EncodeToString(addr)
	if v, ok := validatorMap.Load(key); ok {
		return v.(string)
	}
	// Auto-assign a label if we haven't exceeded the spec's Validator set.
	autoLabelMu.Lock()
	defer autoLabelMu.Unlock()
	// Re-check under lock.
	if v, ok := validatorMap.Load(key); ok {
		return v.(string)
	}
	if autoValidatorN < autoLabelLimitV {
		autoValidatorN++
		label := "v" + itoa(autoValidatorN)
		validatorMap.Store(key, label)
		return label
	}
	// Beyond capacity — return a placeholder. Trace validation will reject this,
	// surfacing the over-capacity setup as a harness bug.
	return "v?" + key[:8]
}

func blockIDLabel(b types.BlockID) string {
	if b.IsZero() || len(b.Hash) == 0 {
		return "nil_blk"
	}
	key := hex.EncodeToString(b.Hash)
	if v, ok := blockIDMap.Load(key); ok {
		return v.(string)
	}
	autoLabelMu.Lock()
	defer autoLabelMu.Unlock()
	if v, ok := blockIDMap.Load(key); ok {
		return v.(string)
	}
	if autoBlockIDN < autoLabelLimitB {
		autoBlockIDN++
		label := "b" + itoa(autoBlockIDN)
		blockIDMap.Store(key, label)
		return label
	}
	return "b?" + key[:8]
}

func itoa(n int) string {
	if n < 10 {
		return string(rune('0' + n))
	}
	// support up to two-digit labels for safety
	return string(rune('0'+n/10)) + string(rune('0'+n%10))
}

func voteTypeLabel(t cmtproto.SignedMsgType) string {
	switch t {
	case cmtproto.PrevoteType:
		return "Prevote"
	case cmtproto.PrecommitType:
		return "Precommit"
	default:
		return "Nil"
	}
}

// hashRecDVE builds the spec-shaped hash record for a DVE.
func hashRecDVE(ev *types.DuplicateVoteEvidence) map[string]any {
	return map[string]any{
		"kind": "DVE",
		"k1":   blockIDLabel(ev.VoteA.BlockID),
		"k2":   int(ev.VoteA.Round),
		"k3":   validatorLabel(ev.VoteA.ValidatorAddress),
		"k4":   int(ev.VoteA.Height),
		"k5":   voteTypeLabel(ev.VoteA.Type),
		"k6":   blockIDLabel(ev.VoteB.BlockID),
	}
}

// hashRecLCAE builds the spec-shaped hash record for an LCAE.
func hashRecLCAE(ev *types.LightClientAttackEvidence) map[string]any {
	hash := ""
	if ev.ConflictingBlock != nil {
		hash = blockIDLabel(types.BlockID{Hash: ev.ConflictingBlock.Hash()})
	} else {
		hash = "nil_blk"
	}
	return map[string]any{
		"kind": "LCAE",
		"k1":   hash,
		"k2":   int(ev.CommonHeight),
		"k3":   "Nil",
		"k4":   0,
		"k5":   "Nil",
		"k6":   "nil_blk",
	}
}

// evHashRec returns the spec-shaped hash for any Evidence.
func evHashRec(ev types.Evidence) map[string]any {
	switch e := ev.(type) {
	case *types.DuplicateVoteEvidence:
		return hashRecDVE(e)
	case *types.LightClientAttackEvidence:
		return hashRecLCAE(e)
	default:
		return map[string]any{
			"kind": "UNKNOWN",
		}
	}
}

func voteRec(v *types.Vote) map[string]any {
	if v == nil {
		return map[string]any{"_nil": true}
	}
	return map[string]any{
		"height":           int(v.Height),
		"round":            int(v.Round),
		"type":             voteTypeLabel(v.Type),
		"validatorAddress": validatorLabel(v.ValidatorAddress),
		"blockID":          blockIDLabel(v.BlockID),
		"signature":        "valid",
	}
}

// -----------------------------------------------------------------------------
// State capture
// -----------------------------------------------------------------------------

// captureState reads the per-node TLA state snapshot. Caller must NOT hold
// the pool mutex (we lock here as needed). Some fields (clist, evidenceSize,
// pendingHashes, committedHashes) read the pool's internal data structures.
func captureState(p *Pool, nid string) map[string]any {
	st := map[string]any{}
	shadowMu.Lock()
	st["crashed"] = shadowCrashed[nid]
	st["applyingPhase"] = shadowApplyPhase[nid]
	st["chainHeight"] = shadowChainHeight
	// appliedHeight is a shadow var (not read from evpool.state.LastBlockHeight)
	// because the pool's internal LBH advances inside Update() *before* the
	// per-evidence iteration of markEvidenceAsCommitted finishes. The spec
	// advances appliedHeight only on ApplyBlock_Finish / ApplyBlock_Blocksync.
	st["appliedHeight"] = shadowAppliedHeight[nid]
	// slashedSet + slashCountSum are global ghost vars over all validators
	slashedList := []string{}
	sum := 0
	for v, b := range shadowSlashed {
		if b {
			slashedList = append(slashedList, v)
		}
	}
	for _, c := range shadowSlashCount {
		sum += c
	}
	st["slashedSet"] = slashedList
	st["slashCountSum"] = sum
	shadowMu.Unlock()

	if p == nil {
		return st
	}

	// Volatile pool state.
	st["evidenceSize"] = int(atomic.LoadUint32(&p.evidenceSize))

	// clist hashes
	clistHashes := []map[string]any{}
	for e := p.evidenceList.Front(); e != nil; e = e.Next() {
		ev := e.Value.(types.Evidence)
		clistHashes = append(clistHashes, evHashRec(ev))
	}
	st["clistHashes"] = clistHashes

	// pendingHashes + committedHashes (iterate DB by prefix)
	pendingHashes, _ := iterateHashes(p.evidenceStore, baseKeyPending)
	committedHashes, _ := iterateHashes(p.evidenceStore, baseKeyCommitted)
	st["pendingHashes"] = pendingHashes
	st["committedHashes"] = committedHashes

	return st
}

func iterateHashes(db dbm.DB, prefix byte) ([]map[string]any, error) {
	out := []map[string]any{}
	iter, err := dbm.IteratePrefix(db, []byte{prefix})
	if err != nil {
		return out, err
	}
	defer iter.Close()
	for ; iter.Valid(); iter.Next() {
		var evpb cmtproto.Evidence
		if err := evpb.Unmarshal(iter.Value()); err != nil {
			continue
		}
		ev, err := types.EvidenceFromProto(&evpb)
		if err != nil {
			continue
		}
		out = append(out, evHashRec(ev))
	}
	return out, nil
}

// -----------------------------------------------------------------------------
// Emit
// -----------------------------------------------------------------------------

func writeLine(obj map[string]any) {
	traceMu.Lock()
	defer traceMu.Unlock()
	if traceFile == nil {
		return
	}
	bz, err := json.Marshal(obj)
	if err != nil {
		return
	}
	_, _ = traceFile.Write(bz)
	_, _ = traceFile.Write([]byte("\n"))
}

// emit assembles the standard envelope.
func emit(p *Pool, name, nid string, data map[string]any) {
	if !traceEnabled.Load() {
		return
	}
	state := captureState(p, nid)
	ev := map[string]any{
		"name":  name,
		"nid":   nid,
		"ts":    time.Now().UnixNano(),
		"state": state,
		"data":  data,
	}
	writeLine(map[string]any{
		"tag":   "trace",
		"ts":    time.Now().UnixNano(),
		"event": ev,
	})
}

// nidOf returns the configured server label for a pool (or empty string).
func nidOf(p *Pool) string {
	if v, ok := poolNid.Load(p); ok {
		return v.(string)
	}
	return ""
}

// -----------------------------------------------------------------------------
// Shadow-state mutators (called from instrumentation + harness orchestrator)
// -----------------------------------------------------------------------------

func setApplyPhase(nid, phase string) {
	shadowMu.Lock()
	shadowApplyPhase[nid] = phase
	shadowMu.Unlock()
}

func setCrashed(nid string, v bool) {
	shadowMu.Lock()
	shadowCrashed[nid] = v
	shadowMu.Unlock()
}

func recordMisbehaviorSlashing(misbehaviors []map[string]any) {
	shadowMu.Lock()
	defer shadowMu.Unlock()
	for _, m := range misbehaviors {
		v := m["validatorAddress"].(string)
		shadowSlashed[v] = true
		shadowSlashCount[v]++
	}
}

// -----------------------------------------------------------------------------
// Per-action emit helpers (called from instrumentation)
// -----------------------------------------------------------------------------

// EmitReportConflictingVotes is called from Pool.ReportConflictingVotes after
// the append. The pool lock is held; we capture state without re-locking.
func emitReportConflictingVotes(p *Pool, voteA, voteB *types.Vote) {
	nid := nidOf(p)
	if nid == "" {
		return
	}
	emit(p, "ReportConflictingVotes", nid, map[string]any{
		"voteA":     voteRec(voteA),
		"voteB":     voteRec(voteB),
		"validator": validatorLabel(voteA.ValidatorAddress),
	})
}

func emitProcessConsensusBuffer(p *Pool, validatorAddr []byte, outcome string, evHash map[string]any) {
	nid := nidOf(p)
	if nid == "" {
		return
	}
	data := map[string]any{
		"validator": validatorLabel(validatorAddr),
		"outcome":   outcome,
	}
	if outcome == "added" && evHash != nil {
		data["dveHash"] = evHash
	}
	emit(p, "ProcessConsensusBuffer", nid, data)
}

// callerOnStack reports whether any frame in the current goroutine's stack
// contains the substring needle (used to distinguish the gossip-driven
// AddEvidence path from direct API calls, per instrumentation-spec.md §2).
func callerOnStack(needle string) bool {
	pcs := make([]uintptr, 32)
	n := runtime.Callers(2, pcs)
	frames := runtime.CallersFrames(pcs[:n])
	for {
		fr, more := frames.Next()
		if strings.Contains(fr.Function, needle) {
			return true
		}
		if !more {
			break
		}
	}
	return false
}

func emitAddEvidence(p *Pool, ev types.Evidence, outcome string, fromGossip bool) {
	nid := nidOf(p)
	if nid == "" {
		return
	}
	// Per the instrumentation spec: AddEvidence vs AddEvidenceDirect is decided
	// by whether (*Reactor).Receive is on the call stack.
	if !fromGossip {
		if callerOnStack("evidence.(*Reactor).Receive") {
			fromGossip = true
		}
	}
	name := "AddEvidenceDirect"
	if fromGossip {
		name = "AddEvidence"
	}
	emit(p, name, nid, map[string]any{
		"evHash":  evHashRec(ev),
		"outcome": outcome,
		"srcPeer": "",
	})
}

func emitProposeBlockHonest(p *Pool, height int64, evList []types.Evidence) {
	nid := nidOf(p)
	if nid == "" {
		return
	}
	hashes := []map[string]any{}
	for _, ev := range evList {
		hashes = append(hashes, evHashRec(ev))
	}
	// chainHeight advances on propose
	shadowMu.Lock()
	shadowChainHeight = int(height)
	shadowMu.Unlock()
	emit(p, "ProposeBlock_Honest", nid, map[string]any{
		"height":   int(height),
		"evHashes": hashes,
	})
}

func emitApplyBlockReactorStart(p *Pool, height int64, evList []types.Evidence) {
	nid := nidOf(p)
	if nid == "" {
		return
	}
	hashes := []map[string]any{}
	for _, ev := range evList {
		hashes = append(hashes, evHashRec(ev))
	}
	setApplyPhase(nid, "remove")
	emit(p, "ApplyBlock_Reactor_Start", nid, map[string]any{
		"height":   int(height),
		"evHashes": hashes,
	})
}

func emitApplyBlockRemovePending(p *Pool, ev types.Evidence, wasPending bool) {
	nid := nidOf(p)
	if nid == "" {
		return
	}
	// Post-state: phase=write (per spec ApplyBlock_RemovePending). Capture AFTER
	// the phase transition so the trace's state field reflects the post-action.
	setApplyPhase(nid, "write")
	emit(p, "ApplyBlock_RemovePending", nid, map[string]any{
		"evHash":     evHashRec(ev),
		"wasPending": wasPending,
	})
}

func emitApplyBlockWriteCommitted(p *Pool, ev types.Evidence) {
	nid := nidOf(p)
	if nid == "" {
		return
	}
	// Post-state: phase=abci.
	setApplyPhase(nid, "abci")
	emit(p, "ApplyBlock_WriteCommitted", nid, map[string]any{
		"evHash": evHashRec(ev),
	})
}

// emitApplyBlockABCI emits the per-evidence ABCI handoff. If isLast is true,
// transitions to phase=done; otherwise phase=remove (next iteration).
func emitApplyBlockABCI(p *Pool, ev types.Evidence, isLast bool) {
	nid := nidOf(p)
	if nid == "" {
		return
	}
	misbehaviors := buildMisbehaviorRecords(ev)
	recordMisbehaviorSlashing(misbehaviors)
	if isLast {
		setApplyPhase(nid, "done")
	} else {
		setApplyPhase(nid, "remove")
	}
	emit(p, "ApplyBlock_ABCI", nid, map[string]any{
		"evHash":       evHashRec(ev),
		"misbehaviors": misbehaviors,
	})
}

func emitApplyBlockFinish(p *Pool, height int64) {
	nid := nidOf(p)
	if nid == "" {
		return
	}
	// Post-state per spec: applyingBlock=NoApply (phase=none), appliedHeight=h.
	shadowMu.Lock()
	shadowAppliedHeight[nid] = int(height)
	shadowApplyPhase[nid] = "none"
	shadowMu.Unlock()
	emit(p, "ApplyBlock_Finish", nid, map[string]any{
		"height": int(height),
	})
}

func emitApplyBlockBlocksync(p *Pool, height int64, evList []types.Evidence) {
	nid := nidOf(p)
	if nid == "" {
		return
	}
	hashes := []map[string]any{}
	allMb := []map[string]any{}
	for _, ev := range evList {
		hashes = append(hashes, evHashRec(ev))
		allMb = append(allMb, buildMisbehaviorRecords(ev)...)
	}
	recordMisbehaviorSlashing(allMb)
	// Spec semantics: Blocksync advances appliedHeight (and lbh, lbt) in one step.
	shadowMu.Lock()
	shadowAppliedHeight[nid] = int(height)
	shadowMu.Unlock()
	emit(p, "ApplyBlock_Blocksync", nid, map[string]any{
		"height":       int(height),
		"evHashes":     hashes,
		"misbehaviors": allMb,
	})
}

func emitCrash(p *Pool) {
	nid := nidOf(p)
	if nid == "" {
		return
	}
	emit(p, "Crash", nid, map[string]any{})
	setCrashed(nid, true)
	setApplyPhase(nid, "none")
}

func emitRecover(p *Pool) {
	nid := nidOf(p)
	if nid == "" {
		return
	}
	pendingHashes, _ := iterateHashes(p.evidenceStore, baseKeyPending)
	setCrashed(nid, false)
	emit(p, "Recover", nid, map[string]any{
		"pendingHashes": pendingHashes,
	})
}

func emitGossipForward(p *Pool, ev types.Evidence, targets []string) {
	nid := nidOf(p)
	if nid == "" {
		return
	}
	emit(p, "GossipForward", nid, map[string]any{
		"evHash":  evHashRec(ev),
		"targets": targets,
	})
}

func buildMisbehaviorRecords(ev types.Evidence) []map[string]any {
	out := []map[string]any{}
	switch e := ev.(type) {
	case *types.DuplicateVoteEvidence:
		out = append(out, map[string]any{
			"type":             "DVE",
			"validatorAddress": validatorLabel(e.VoteA.ValidatorAddress),
			"validatorPower":   int(e.ValidatorPower),
			"height":           int(e.VoteA.Height),
			"time":             int(e.VoteA.Height),
		})
	case *types.LightClientAttackEvidence:
		for _, v := range e.ByzantineValidators {
			out = append(out, map[string]any{
				"type":             "LCAE",
				"validatorAddress": validatorLabel(v.PubKey.Address()),
				"validatorPower":   int(v.VotingPower),
				"height":           int(e.CommonHeight),
				"time":             int(e.CommonHeight),
			})
		}
	}
	return out
}

// -----------------------------------------------------------------------------
// Exported wrappers for use from evidence_test scenarios
// -----------------------------------------------------------------------------

// TLATestEmitProposeBlockHonest is callable from test scenarios that simulate
// a chain. It is exported so tests in evidence_test can drive the apply pipeline.
func TLATestEmitProposeBlockHonest(p *Pool, height int64, evList []types.Evidence) {
	emitProposeBlockHonest(p, height, evList)
}

// TLATestEmitApplyBlockReactorStart wraps emitApplyBlockReactorStart.
func TLATestEmitApplyBlockReactorStart(p *Pool, height int64, evList []types.Evidence) {
	emitApplyBlockReactorStart(p, height, evList)
}

// TLATestEmitApplyBlockABCI wraps emitApplyBlockABCI for use in tests that
// don't run the full BlockExecutor (which is where the real ABCI handoff
// happens). isLast must be true when this is the final evidence in the block.
func TLATestEmitApplyBlockABCI(p *Pool, ev types.Evidence, isLast bool) {
	emitApplyBlockABCI(p, ev, isLast)
}

// TLATestEmitApplyBlockFinish wraps emitApplyBlockFinish.
func TLATestEmitApplyBlockFinish(p *Pool, height int64) {
	emitApplyBlockFinish(p, height)
}

// TLATestEmitApplyBlockBlocksync wraps the EmptyEvidencePool replay path.
func TLATestEmitApplyBlockBlocksync(p *Pool, height int64, evList []types.Evidence) {
	emitApplyBlockBlocksync(p, height, evList)
}

// TLATestEmitCrash + EmitRecover for tests that don't pass through NewPool.
func TLATestEmitCrash(p *Pool) {
	emitCrash(p)
}

func TLATestEmitRecover(p *Pool) {
	emitRecover(p)
}

func TLATestEmitGossipForward(p *Pool, ev types.Evidence, targets []string) {
	emitGossipForward(p, ev, targets)
}

func TLATestEmitAddEvidenceDirect(p *Pool, ev types.Evidence, outcome string) {
	emitAddEvidence(p, ev, outcome, false)
}
