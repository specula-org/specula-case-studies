package consensus

import (
	"encoding/json"
	"fmt"
	"os"
	"sync"
	"time"

	cstypes "github.com/cometbft/cometbft/consensus/types"
	cmtproto "github.com/cometbft/cometbft/proto/tendermint/types"
	"github.com/cometbft/cometbft/types"
)

// TraceEvent represents a single trace event in NDJSON format
type TraceEvent struct {
	Tag       string      `json:"tag"`
	EventName string      `json:"eventName"`
	NodeID    string      `json:"nodeID"`
	Timestamp int64       `json:"timestamp"`
	Height    int64       `json:"height"`
	Round     int32       `json:"round"`
	Step      string      `json:"step"`
	ProposedBlock interface{} `json:"proposedBlock"`
	LockedBlock   interface{} `json:"lockedBlock"`
	LockedRound   int32       `json:"lockedRound"`
	ValidBlock    interface{} `json:"validBlock"`
	ValidRound    int32       `json:"validRound"`

	// Vote fields (optional)
	VoteHeight    int64       `json:"voteHeight,omitempty"`
	VoteRound     int32       `json:"voteRound,omitempty"`
	VoteType      string      `json:"voteType,omitempty"`
	VoteBlockID   interface{} `json:"voteBlockID,omitempty"`
	Extension     interface{} `json:"extension,omitempty"`
	Sender        string      `json:"sender,omitempty"`
	Receiver      string      `json:"receiver,omitempty"`
}

var (
	traceFile   *os.File
	traceMutex  sync.Mutex
	traceOutput = os.Getenv("TRACE_OUTPUT")
)

// InitTrace initializes the trace file
func InitTrace(filename string) error {
	traceMutex.Lock()
	defer traceMutex.Unlock()

	var err error
	traceFile, err = os.Create(filename)
	if err != nil {
		return fmt.Errorf("failed to create trace file: %w", err)
	}
	return nil
}

// CloseTrace closes the trace file
func CloseTrace() error {
	traceMutex.Lock()
	defer traceMutex.Unlock()

	if traceFile != nil {
		return traceFile.Close()
	}
	return nil
}

// EmitTrace writes a trace event to the NDJSON file
func EmitTrace(event TraceEvent) error {
	if traceFile == nil && traceOutput == "" {
		return nil // Tracing disabled
	}

	traceMutex.Lock()
	defer traceMutex.Unlock()

	event.Tag = "trace"
	if event.Timestamp == 0 {
		event.Timestamp = time.Now().UnixNano()
	}

	data, err := json.Marshal(event)
	if err != nil {
		return fmt.Errorf("failed to marshal trace event: %w", err)
	}

	if traceFile != nil {
		_, err = traceFile.WriteString(string(data) + "\n")
		if err != nil {
			return fmt.Errorf("failed to write trace event: %w", err)
		}
	}

	if traceOutput == "stdout" {
		fmt.Println(string(data))
	}

	return nil
}

// StepToString converts RoundStepType to string
func StepToString(step cstypes.RoundStepType) string {
	switch step {
	case cstypes.RoundStepNewHeight:
		return "newheight"
	case cstypes.RoundStepPropose:
		return "propose"
	case cstypes.RoundStepPrevote:
		return "prevote"
	case cstypes.RoundStepPrevoteWait:
		return "prevotewait"
	case cstypes.RoundStepPrecommit:
		return "precommit"
	case cstypes.RoundStepPrecommitWait:
		return "precommitWait"
	case cstypes.RoundStepCommit:
		return "commit"
	default:
		return "unknown"
	}
}

// VoteTypeToString converts vote type to string
func VoteTypeToString(voteType cmtproto.SignedMsgType) string {
	switch voteType {
	case cmtproto.PrevoteType:
		return "prevote"
	case cmtproto.PrecommitType:
		return "precommit"
	default:
		return "unknown"
	}
}

// BlockIDToString converts BlockID to a string representation
func BlockIDToString(blockID *types.BlockID) interface{} {
	if blockID == nil || blockID.IsZero() {
		return nil
	}
	return blockID.Hash.String()
}

// CaptureState captures the current consensus state
func CaptureState(cs *State, nodeID string) TraceEvent {
	return TraceEvent{
		NodeID:        nodeID,
		Height:        cs.Height,
		Round:         cs.Round,
		Step:          StepToString(cs.Step),
		ProposedBlock: BlockIDToString(cs.ProposalBlock),
		LockedBlock:   BlockIDToString(cs.LockedBlock),
		LockedRound:   cs.LockedRound,
		ValidBlock:    BlockIDToString(cs.ValidBlock),
		ValidRound:    cs.ValidRound,
	}
}

// EmitEnterNewRound emits EnterNewRound event
func (cs *State) EmitEnterNewRound(nodeID string) error {
	event := CaptureState(cs, nodeID)
	event.EventName = "EnterNewRound"
	return EmitTrace(event)
}

// EmitEnterPrevote emits EnterPrevote event
func (cs *State) EmitEnterPrevote(nodeID string) error {
	event := CaptureState(cs, nodeID)
	event.EventName = "EnterPrevote"
	return EmitTrace(event)
}

// EmitEnterPrecommit emits EnterPrecommit event
func (cs *State) EmitEnterPrecommit(nodeID string) error {
	event := CaptureState(cs, nodeID)
	event.EventName = "EnterPrecommit"
	return EmitTrace(event)
}

// EmitAddVote emits AddVote event
func (cs *State) EmitAddVote(nodeID string, vote *types.Vote) error {
	event := CaptureState(cs, nodeID)
	event.EventName = "AddVote"
	event.VoteHeight = vote.Height
	event.VoteRound = vote.Round
	event.VoteType = VoteTypeToString(vote.Type)
	event.VoteBlockID = BlockIDToString(&vote.BlockID)
	if len(vote.Extension) > 0 {
		event.Extension = fmt.Sprintf("%x", vote.Extension)
	}
	return EmitTrace(event)
}

// EmitReceiveProposal emits ReceiveProposal event
func (cs *State) EmitReceiveProposal(nodeID string) error {
	event := CaptureState(cs, nodeID)
	event.EventName = "ReceiveProposal"
	return EmitTrace(event)
}

// EmitReceiveBlockPart emits ReceiveBlockPart event
func (cs *State) EmitReceiveBlockPart(nodeID string) error {
	event := CaptureState(cs, nodeID)
	event.EventName = "ReceiveBlockPart"
	return EmitTrace(event)
}

// EmitHandleCompleteProposal emits HandleCompleteProposal event
func (cs *State) EmitHandleCompleteProposal(nodeID string) error {
	event := CaptureState(cs, nodeID)
	event.EventName = "HandleCompleteProposal"
	return EmitTrace(event)
}

// EmitUnlockOnPol emits UnlockOnPol event
func (cs *State) EmitUnlockOnPol(nodeID string) error {
	event := CaptureState(cs, nodeID)
	event.EventName = "UnlockOnPol"
	return EmitTrace(event)
}

// EmitUpdateValidBlock emits UpdateValidBlock event
func (cs *State) EmitUpdateValidBlock(nodeID string) error {
	event := CaptureState(cs, nodeID)
	event.EventName = "UpdateValidBlock"
	return EmitTrace(event)
}

// EmitCrashAndRecover emits CrashAndRecover event
func (cs *State) EmitCrashAndRecover(nodeID string) error {
	event := CaptureState(cs, nodeID)
	event.EventName = "CrashAndRecover"
	return EmitTrace(event)
}
