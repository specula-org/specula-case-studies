package consensus

import (
	"encoding/hex"
	"encoding/json"
	"io"
	"sync"
	"time"

	cstypes "github.com/cometbft/cometbft/consensus/types"
)

// TraceEvent is the NDJSON event envelope for TLA+ trace validation
// (round 2 — BFT extensions).
type TraceEvent struct {
	Name    string          `json:"name"`
	Nid     string          `json:"nid"`
	State   TraceStateSnap  `json:"state"`
	Msg     *TraceMsgFields `json:"msg,omitempty"`
	ByzVote *TraceByzVote   `json:"byzVote,omitempty"`
	K       *int            `json:"k,omitempty"`
}

// TraceStateSnap captures the consensus state fields needed by Trace.tla
// (round 2 — adds validatorClock for the evidence-expiry race family).
type TraceStateSnap struct {
	Height         int64  `json:"height"`
	Round          int32  `json:"round"`
	Step           string `json:"step"`
	LockedRound    int32  `json:"lockedRound"`
	LockedValue    string `json:"lockedValue"`
	ValidRound     int32  `json:"validRound"`
	ValidValue     string `json:"validValue"`
	ValidatorClock int64  `json:"validatorClock"`
}

// TraceMsgFields captures message fields for vote/proposal/evidence events.
type TraceMsgFields struct {
	Source   string `json:"source"`
	Dest     string `json:"dest,omitempty"`
	Type     string `json:"type,omitempty"`
	Value    string `json:"value"`
	Round    int32  `json:"round"`
	PolRound int32  `json:"polRound,omitempty"`
	VE       string `json:"ve,omitempty"`
	EvType   string `json:"evtype,omitempty"`
	LateAdd  bool   `json:"lateAdd,omitempty"`
}

// TraceByzVote captures Byzantine-vote substructure for BFT actions.
type TraceByzVote struct {
	VType    string `json:"vtype"`
	Height   int64  `json:"height"`
	Round    int32  `json:"round"`
	OldRound int32  `json:"oldRound,omitempty"`
	NewRound int32  `json:"newRound,omitempty"`
	Value    string `json:"value"`
	VE       string `json:"ve,omitempty"`
}

// TraceLine is the full NDJSON line written to the trace file.
type TraceLine struct {
	Timestamp time.Time   `json:"ts"`
	Tag       string      `json:"tag"`
	Event     *TraceEvent `json:"event"`
}

// TraceLogger writes NDJSON trace events to a writer.
type TraceLogger struct {
	mu     sync.Mutex
	enc    *json.Encoder
	closer io.Closer
}

// NewTraceLogger creates a new TraceLogger that writes to w.
func NewTraceLogger(w io.WriteCloser) *TraceLogger {
	return &TraceLogger{
		enc:    json.NewEncoder(w),
		closer: w,
	}
}

// Emit writes a trace event as an NDJSON line.
func (tl *TraceLogger) Emit(evt *TraceEvent) {
	if tl == nil || evt == nil {
		return
	}
	tl.mu.Lock()
	defer tl.mu.Unlock()
	_ = tl.enc.Encode(TraceLine{
		Timestamp: time.Now().UTC(),
		Tag:       "trace",
		Event:     evt,
	})
}

// Close closes the underlying writer.
func (tl *TraceLogger) Close() error {
	if tl == nil || tl.closer == nil {
		return nil
	}
	return tl.closer.Close()
}

// stepString maps RoundStepType to the string expected by Trace.tla.
func stepString(s cstypes.RoundStepType) string {
	switch s {
	case cstypes.RoundStepNewHeight:
		return "NewHeight"
	case cstypes.RoundStepNewRound:
		return "NewRound"
	case cstypes.RoundStepPropose:
		return "Propose"
	case cstypes.RoundStepPrevote:
		return "Prevote"
	case cstypes.RoundStepPrevoteWait:
		return "PrevoteWait"
	case cstypes.RoundStepPrecommit:
		return "Precommit"
	case cstypes.RoundStepPrecommitWait:
		return "PrecommitWait"
	case cstypes.RoundStepCommit:
		return "Commit"
	default:
		return "Unknown"
	}
}

// captureState creates a TraceStateSnap from the current consensus state.
// Must be called while holding cs.mtx or from within receiveRoutine.
// validatorClock is sourced from cs.byzClock — the harness-driven local clock
// counter used by the Family 5 evidence-expiry race.
func (cs *State) captureState() TraceStateSnap {
	lockedValue := "nil"
	if cs.LockedBlock != nil {
		lockedValue = hex.EncodeToString(cs.LockedBlock.Hash())
	}
	validValue := "nil"
	if cs.ValidBlock != nil {
		validValue = hex.EncodeToString(cs.ValidBlock.Hash())
	}
	return TraceStateSnap{
		Height:         cs.Height,
		Round:          cs.Round,
		Step:           stepString(cs.Step),
		LockedRound:    cs.LockedRound,
		LockedValue:    lockedValue,
		ValidRound:     cs.ValidRound,
		ValidValue:     validValue,
		ValidatorClock: cs.byzClock,
	}
}

// traceNodeID returns the node identifier for trace events.
func (cs *State) traceNodeID() string {
	if cs.privValidatorPubKey != nil {
		return hex.EncodeToString(cs.privValidatorPubKey.Address())
	}
	return "unknown"
}

// blockHashStr returns hex-encoded block hash or "nil".
func blockHashStr(hash []byte) string {
	if len(hash) == 0 {
		return "nil"
	}
	return hex.EncodeToString(hash)
}

// intPtr returns a pointer to an int (helper for TraceEvent.K).
func intPtr(v int) *int { return &v }
