// TLA+ trace generation test scenarios for eliben/raft.
//
// Each test exercises a specific set of protocol code paths and writes
// NDJSON traces to the directory specified by RAFT_TRACE_DIR (or ".").
package raft

import (
	"testing"
)

// TestTraceBasicConsensus exercises the happy path:
// leader election -> client request -> log replication -> commit.
//
// Expected trace events: Timeout, HandleRequestVoteRequest,
// HandleRequestVoteResponse, BecomeLeader, ClientRequest,
// AppendEntries, HandleAppendEntriesRequest,
// HandleAppendEntriesResponse, AdvanceCommitIndex.
func TestTraceBasicConsensus(t *testing.T) {
	path := traceFilePath("basic_consensus.ndjson")
	if err := InitTrace(path); err != nil {
		t.Fatalf("InitTrace: %v", err)
	}
	defer CloseTrace()

	h := NewHarness(t, 3)
	defer h.Shutdown()

	// Wait for leader election
	leaderId, _ := h.CheckSingleLeader()

	// Submit a command
	isLeader := h.SubmitToServer(leaderId, 42) >= 0
	if !isLeader {
		t.Fatalf("server %d is not leader", leaderId)
	}

	// Wait for commit on all servers
	sleepMs(250)
	h.CheckCommittedN(42, 3)
}

// TestTraceLeaderReelection exercises leader disconnection and re-election:
// first leader elected -> submit -> disconnect leader -> new election ->
// submit to new leader -> reconnect old leader.
//
// Covers two election rounds and log replication across leader changes.
func TestTraceLeaderReelection(t *testing.T) {
	path := traceFilePath("leader_reelection.ndjson")
	if err := InitTrace(path); err != nil {
		t.Fatalf("InitTrace: %v", err)
	}
	defer CloseTrace()

	h := NewHarness(t, 3)
	defer h.Shutdown()

	// First leader
	origLeaderId, _ := h.CheckSingleLeader()
	h.SubmitToServer(origLeaderId, 10)
	sleepMs(250)
	h.CheckCommittedN(10, 3)

	// Disconnect leader, force new election
	h.DisconnectPeer(origLeaderId)
	sleepMs(350)

	newLeaderId, _ := h.CheckSingleLeader()
	h.SubmitToServer(newLeaderId, 20)
	sleepMs(250)
	h.CheckCommittedN(20, 2)

	// Reconnect old leader — it should catch up
	h.ReconnectPeer(origLeaderId)
	sleepMs(400)
	h.CheckCommittedN(20, 3)
}

// TestTraceCrashRecovery exercises crash-recovery:
// leader elected -> submit -> crash follower -> submit more ->
// restart follower -> verify catch-up.
//
// Covers Crash events and recovery via persisted state.
func TestTraceCrashRecovery(t *testing.T) {
	path := traceFilePath("crash_recovery.ndjson")
	if err := InitTrace(path); err != nil {
		t.Fatalf("InitTrace: %v", err)
	}
	defer CloseTrace()

	h := NewHarness(t, 3)
	defer h.Shutdown()

	leaderId, _ := h.CheckSingleLeader()
	h.SubmitToServer(leaderId, 5)
	sleepMs(250)
	h.CheckCommittedN(5, 3)

	// Crash a follower
	followerId := (leaderId + 1) % 3
	h.CrashPeer(followerId)

	// Submit while follower is down
	h.SubmitToServer(leaderId, 6)
	sleepMs(250)
	h.CheckCommittedN(6, 2)

	// Restart follower — should recover and catch up
	h.RestartPeer(followerId)
	sleepMs(650)
	h.CheckCommittedN(6, 3)
}
