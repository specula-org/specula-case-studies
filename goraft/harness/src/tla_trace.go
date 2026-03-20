package raft

// TLA+ trace emission module for goraft/raft.
// Emits NDJSON trace events for trace validation against the TLA+ spec.
//
// Activated by calling InitTrace(path) before starting servers.
// Each event includes: tag, timestamp, event name, node ID, state snapshot,
// optional pre-state, from/to fields, and message fields.

import (
	"encoding/json"
	"fmt"
	"os"
	"sync"
	"time"
)

// traceWriter manages concurrent NDJSON output.
var (
	traceFile   *os.File
	traceMutex  sync.Mutex
	traceActive bool
)

// InitTrace opens a trace file for NDJSON output.
func InitTrace(path string) error {
	traceMutex.Lock()
	defer traceMutex.Unlock()

	f, err := os.Create(path)
	if err != nil {
		return fmt.Errorf("tla_trace: cannot create %s: %w", path, err)
	}
	traceFile = f
	traceActive = true
	return nil
}

// CloseTrace flushes and closes the trace file.
func CloseTrace() {
	traceMutex.Lock()
	defer traceMutex.Unlock()

	if traceFile != nil {
		traceFile.Sync()
		traceFile.Close()
		traceFile = nil
	}
	traceActive = false
}

// TraceState captures a server's state snapshot for trace validation.
type TraceState struct {
	Term         uint64 `json:"term"`
	Role         string `json:"role"`
	CommitIndex  uint64 `json:"commitIndex"`
	LastLogIndex uint64 `json:"lastLogIndex"`
	LastLogTerm  uint64 `json:"lastLogTerm"`
}

// TracePre captures pre-action state (term + role only).
type TracePre struct {
	Term uint64 `json:"term"`
	Role string `json:"role"`
}

// traceEvent is the NDJSON envelope for one trace line.
// Note: Node, From, To must NOT use omitempty — Trace.tla's IsMsgEvent
// eagerly evaluates logline.from/to before checking the event name.
type traceEvent struct {
	Tag   string      `json:"tag"`
	Ts    int64       `json:"ts"`
	Event string      `json:"event"`
	Node  string      `json:"node"`
	From  string      `json:"from"`
	To    string      `json:"to"`
	State *TraceState `json:"state,omitempty"`
	Pre   *TracePre   `json:"pre,omitempty"`
	Msg   interface{} `json:"msg,omitempty"`
}

// emitTrace writes one NDJSON line to the trace file.
func emitTrace(ev traceEvent) {
	if !traceActive {
		return
	}
	ev.Tag = "trace"
	ev.Ts = time.Now().UnixNano()

	traceMutex.Lock()
	defer traceMutex.Unlock()

	if traceFile == nil {
		return
	}
	data, err := json.Marshal(ev)
	if err != nil {
		return
	}
	traceFile.Write(data)
	traceFile.Write([]byte("\n"))
}

// captureState reads the full state of a server.
// MUST be called from the server's event loop goroutine (or with appropriate locks).
func captureState(s *server) *TraceState {
	return &TraceState{
		Term:         s.currentTerm,
		Role:         s.state,
		CommitIndex:  s.log.CommitIndex(),
		LastLogIndex: s.log.currentIndex(),
		LastLogTerm:  s.log.currentTerm(),
	}
}

// captureWeakState reads only term + role (for peer goroutines that lack full access).
func captureWeakState(s *server) *TraceState {
	return &TraceState{
		Term: s.currentTerm,
		Role: s.state,
	}
}

// capturePre captures the pre-action state (term + role).
func capturePre(s *server) *TracePre {
	return &TracePre{
		Term: s.currentTerm,
		Role: s.state,
	}
}

// --- Emit helpers for each event type ---

// emitTimeout emits a Timeout event (follower -> candidate).
func emitTimeout(s *server, pre *TracePre) {
	emitTrace(traceEvent{
		Event: "Timeout",
		Node:  s.name,
		State: captureState(s),
		Pre:   pre,
	})
}

// emitRequestVote emits a RequestVote event (candidate starts election).
func emitRequestVote(s *server, pre *TracePre) {
	emitTrace(traceEvent{
		Event: "RequestVote",
		Node:  s.name,
		State: captureState(s),
		Pre:   pre,
	})
}

// emitBecomeLeader emits a BecomeLeader event.
func emitBecomeLeader(s *server, pre *TracePre) {
	emitTrace(traceEvent{
		Event: "BecomeLeader",
		Node:  s.name,
		State: captureState(s),
		Pre:   pre,
	})
}

// emitHandleRequestVoteRequest emits after processing a vote request.
func emitHandleRequestVoteRequest(s *server, req *RequestVoteRequest, resp *RequestVoteResponse, pre *TracePre) {
	emitTrace(traceEvent{
		Event: "HandleRequestVoteRequest",
		Node:  s.name,
		From:  req.CandidateName,
		State: captureState(s),
		Pre:   pre,
		Msg: map[string]interface{}{
			"term":        resp.Term,
			"voteGranted": resp.VoteGranted,
		},
	})
}

// emitHandleRequestVoteResponse emits after processing a vote response.
func emitHandleRequestVoteResponse(s *server, resp *RequestVoteResponse, pre *TracePre) {
	from := ""
	if resp.peer != nil {
		from = resp.peer.Name
	}
	emitTrace(traceEvent{
		Event: "HandleRequestVoteResponse",
		Node:  s.name,
		From:  from,
		State: captureState(s),
		Pre:   pre,
		Msg: map[string]interface{}{
			"term":        resp.Term,
			"voteGranted": resp.VoteGranted,
		},
	})
}

// emitClientRequest emits after a client command is appended.
func emitClientRequest(s *server, pre *TracePre) {
	emitTrace(traceEvent{
		Event: "ClientRequest",
		Node:  s.name,
		State: captureState(s),
		Pre:   pre,
	})
}

// emitAppendNOP emits after the leader's NOP is appended.
func emitAppendNOP(s *server, pre *TracePre) {
	emitTrace(traceEvent{
		Event: "AppendNOP",
		Node:  s.name,
		State: captureState(s),
		Pre:   pre,
	})
}

// emitReplicate emits before sending AE with entries to a peer.
func emitReplicate(s *server, peerName string, prevLogIndex uint64, entryCount int) {
	emitTrace(traceEvent{
		Event: "Replicate",
		Node:  s.name,
		From:  s.name,
		To:    peerName,
		State: captureWeakState(s),
		Msg: map[string]interface{}{
			"prevLogIndex": prevLogIndex,
			"entries":      entryCount,
		},
	})
}

// emitSendHeartbeat emits before sending an empty AE (heartbeat) to a peer.
func emitSendHeartbeat(s *server, peerName string, term uint64) {
	emitTrace(traceEvent{
		Event: "SendHeartbeat",
		Node:  s.name,
		From:  s.name,
		To:    peerName,
		State: captureWeakState(s),
		Msg: map[string]interface{}{
			"term": term,
		},
	})
}

// emitHandleAppendEntriesRequest emits after processing an AE request.
func emitHandleAppendEntriesRequest(s *server, req *AppendEntriesRequest, resp *AppendEntriesResponse, pre *TracePre) {
	emitTrace(traceEvent{
		Event: "HandleAppendEntriesRequest",
		Node:  s.name,
		From:  req.LeaderName,
		State: captureState(s),
		Pre:   pre,
		Msg: map[string]interface{}{
			"term":         req.Term,
			"prevLogIndex": req.PrevLogIndex,
			"success":      resp.Success(),
		},
	})
}

// emitHandleAppendEntriesResponse emits after processing an AE response.
func emitHandleAppendEntriesResponse(s *server, resp *AppendEntriesResponse, pre *TracePre) {
	emitTrace(traceEvent{
		Event: "HandleAppendEntriesResponse",
		Node:  s.name,
		From:  resp.peer,
		State: captureState(s),
		Pre:   pre,
		Msg: map[string]interface{}{
			"term":    resp.Term(),
			"success": resp.Success(),
		},
	})
}

// emitAdvanceCommitIndex emits after the leader advances commitIndex.
func emitAdvanceCommitIndex(s *server, pre *TracePre) {
	emitTrace(traceEvent{
		Event: "AdvanceCommitIndex",
		Node:  s.name,
		State: captureState(s),
		Pre:   pre,
	})
}

// emitSendSnapshotRequest emits before sending a snapshot request to a peer.
func emitSendSnapshotRequest(s *server, peerName string) {
	emitTrace(traceEvent{
		Event: "SendSnapshotRequest",
		Node:  s.name,
		From:  s.name,
		To:    peerName,
		State: captureWeakState(s),
	})
}

// emitHandleSnapshotRequest emits after entering Snapshotting state.
func emitHandleSnapshotRequest(s *server, pre *TracePre) {
	emitTrace(traceEvent{
		Event: "HandleSnapshotRequest",
		Node:  s.name,
		State: captureState(s),
		Pre:   pre,
	})
}

// emitSendSnapshotRecoveryRequest emits before sending snapshot recovery to a peer.
func emitSendSnapshotRecoveryRequest(s *server, peerName string) {
	emitTrace(traceEvent{
		Event: "SendSnapshotRecoveryRequest",
		Node:  s.name,
		From:  s.name,
		To:    peerName,
		State: captureWeakState(s),
	})
}

// emitHandleSnapshotRecoveryRequest emits after snapshot recovery completes.
func emitHandleSnapshotRecoveryRequest(s *server, pre *TracePre) {
	emitTrace(traceEvent{
		Event: "HandleSnapshotRecoveryRequest",
		Node:  s.name,
		State: captureState(s),
		Pre:   pre,
	})
}

// emitCrash emits after a server crash+recovery.
func emitCrash(s *server, pre *TracePre) {
	emitTrace(traceEvent{
		Event: "Crash",
		Node:  s.name,
		State: captureState(s),
		Pre:   pre,
	})
}
