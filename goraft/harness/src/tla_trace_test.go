package raft

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// traceTestCommand is a simple command for trace test scenarios.
type traceTestCommand struct {
	Val string `json:"val"`
}

func init() {
	RegisterCommand(&traceTestCommand{})
}

func (c *traceTestCommand) CommandName() string {
	return "trace_cmd"
}

func (c *traceTestCommand) Apply(server Server) (interface{}, error) {
	return nil, nil
}

// traceDir returns the traces output directory, creating it if needed.
func traceDir() string {
	// Resolve relative to the artifact root
	dir := os.Getenv("TRACE_DIR")
	if dir == "" {
		dir = "../../traces"
	}
	os.MkdirAll(dir, 0755)
	return dir
}

// makeTracingTransporter creates a testTransporter that routes messages between
// servers in the lookup map, with timeout handling.
func makeTracingTransporter(mutex *sync.RWMutex, servers map[string]Server) *testTransporter {
	t := &testTransporter{}

	t.sendVoteRequestFunc = func(s Server, peer *Peer, req *RequestVoteRequest) *RequestVoteResponse {
		mutex.RLock()
		target, ok := servers[peer.Name]
		mutex.RUnlock()
		if !ok || target == nil {
			return nil
		}

		// Clone request via JSON to avoid shared pointers
		b, _ := json.Marshal(req)
		clonedReq := &RequestVoteRequest{}
		json.Unmarshal(b, clonedReq)

		c := make(chan *RequestVoteResponse, 1)
		go func() {
			c <- target.RequestVote(clonedReq)
		}()
		select {
		case resp := <-c:
			return resp
		case <-time.After(200 * time.Millisecond):
			return nil
		}
	}

	t.sendAppendEntriesRequestFunc = func(s Server, peer *Peer, req *AppendEntriesRequest) *AppendEntriesResponse {
		mutex.RLock()
		target, ok := servers[peer.Name]
		mutex.RUnlock()
		if !ok || target == nil {
			return nil
		}

		b, _ := json.Marshal(req)
		clonedReq := &AppendEntriesRequest{}
		json.Unmarshal(b, clonedReq)

		c := make(chan *AppendEntriesResponse, 1)
		go func() {
			c <- target.AppendEntries(clonedReq)
		}()
		select {
		case resp := <-c:
			return resp
		case <-time.After(200 * time.Millisecond):
			return nil
		}
	}

	t.sendSnapshotRequestFunc = func(s Server, peer *Peer, req *SnapshotRequest) *SnapshotResponse {
		mutex.RLock()
		target, ok := servers[peer.Name]
		mutex.RUnlock()
		if !ok || target == nil {
			return nil
		}
		return target.RequestSnapshot(req)
	}

	return t
}

// TestTLATraceBasicConsensus exercises the core Raft protocol:
// 1. Three servers start, one becomes leader via election
// 2. Leader appends NOP (automatic) + client commands
// 3. Entries replicate to followers and commit
//
// Expected trace events: Timeout, RequestVote, HandleRequestVoteRequest,
// HandleRequestVoteResponse, BecomeLeader, AppendNOP, ClientRequest,
// Replicate, HandleAppendEntriesRequest, HandleAppendEntriesResponse,
// AdvanceCommitIndex, SendHeartbeat
func TestTLATraceBasicConsensus(t *testing.T) {
	tracePath := filepath.Join(traceDir(), "basic_consensus.ndjson")
	if err := InitTrace(tracePath); err != nil {
		t.Fatalf("InitTrace failed: %v", err)
	}
	defer CloseTrace()

	var mutex sync.RWMutex
	servers := map[string]Server{}
	transporter := makeTracingTransporter(&mutex, servers)

	names := []string{"s1", "s2", "s3"}

	// Create servers
	for _, name := range names {
		s := newTestServer(name, transporter)
		s.SetElectionTimeout(testElectionTimeout)
		s.SetHeartbeatInterval(testHeartbeatInterval)
		mutex.Lock()
		servers[name] = s
		mutex.Unlock()
	}

	// Start first server and self-join to become leader
	servers["s1"].Start()
	if _, err := servers["s1"].Do(&DefaultJoinCommand{Name: "s1"}); err != nil {
		t.Fatalf("s1 self-join failed: %v", err)
	}

	// Add peers
	for _, name := range names[1:] {
		servers[name].Start()
		if _, err := servers["s1"].Do(&DefaultJoinCommand{Name: name}); err != nil {
			t.Fatalf("Join %s failed: %v", name, err)
		}
	}

	// Wait for replication of join commands
	time.Sleep(3 * testHeartbeatInterval)

	// Submit client commands
	for i := 0; i < 3; i++ {
		if _, err := servers["s1"].Do(&traceTestCommand{Val: fmt.Sprintf("cmd-%d", i)}); err != nil {
			t.Fatalf("Command %d failed: %v", i, err)
		}
	}

	// Wait for replication and commit
	time.Sleep(3 * testHeartbeatInterval)

	// Verify basic state
	if servers["s1"].State() != Leader {
		t.Fatalf("s1 should be leader, got %s", servers["s1"].State())
	}

	for _, name := range names {
		servers[name].Stop()
	}

	t.Logf("Trace written to %s", tracePath)
}

// TestTLATraceLeaderElection exercises leader election with timeout:
// 1. Three servers start with existing log entries (promotable)
// 2. Election timeout fires, one becomes candidate
// 3. Candidate wins election and becomes leader
//
// Expected trace events: Timeout, RequestVote, HandleRequestVoteRequest,
// HandleRequestVoteResponse, BecomeLeader, AppendNOP, SendHeartbeat
func TestTLATraceLeaderElection(t *testing.T) {
	tracePath := filepath.Join(traceDir(), "leader_election.ndjson")
	if err := InitTrace(tracePath); err != nil {
		t.Fatalf("InitTrace failed: %v", err)
	}
	defer CloseTrace()

	var mutex sync.RWMutex
	servers := map[string]Server{}
	transporter := makeTracingTransporter(&mutex, servers)

	// Create servers with pre-existing log entries (so they're promotable)
	tmpLog := newLog()
	e0, _ := newLogEntry(tmpLog, nil, 1, 1, &traceTestCommand{Val: "init"})
	names := []string{"s1", "s2", "s3"}

	for _, name := range names {
		s := newTestServerWithLog(name, transporter, []*LogEntry{e0})
		s.SetElectionTimeout(testElectionTimeout)
		s.SetHeartbeatInterval(testHeartbeatInterval)
		mutex.Lock()
		servers[name] = s
		mutex.Unlock()
	}

	// Start all servers and add peers
	for _, name := range names {
		servers[name].Start()
	}
	for _, s := range servers {
		for _, name := range names {
			s.AddPeer(name, "")
		}
	}

	// Wait for election to complete
	time.Sleep(3 * testElectionTimeout)

	// Verify a leader was elected
	leaderCount := 0
	for _, name := range names {
		if servers[name].State() == Leader {
			leaderCount++
		}
	}
	if leaderCount != 1 {
		t.Fatalf("Expected 1 leader, got %d", leaderCount)
	}

	// Let heartbeats and NOP propagate
	time.Sleep(3 * testHeartbeatInterval)

	for _, name := range names {
		servers[name].Stop()
	}

	t.Logf("Trace written to %s", tracePath)
}

// TestTLATraceLeaderFailover exercises leader change:
// 1. Three servers, s1 becomes leader via self-join
// 2. Client commands replicated
// 3. s1 stops (simulating crash)
// 4. New leader elected among s2/s3
//
// Expected trace events: all election + replication events, plus
// events from the new election round.
func TestTLATraceLeaderFailover(t *testing.T) {
	tracePath := filepath.Join(traceDir(), "leader_failover.ndjson")
	if err := InitTrace(tracePath); err != nil {
		t.Fatalf("InitTrace failed: %v", err)
	}
	defer CloseTrace()

	var mutex sync.RWMutex
	servers := map[string]Server{}
	transporter := makeTracingTransporter(&mutex, servers)

	names := []string{"s1", "s2", "s3"}

	// Create servers
	for _, name := range names {
		s := newTestServer(name, transporter)
		s.SetElectionTimeout(testElectionTimeout)
		s.SetHeartbeatInterval(testHeartbeatInterval)
		mutex.Lock()
		servers[name] = s
		mutex.Unlock()
	}

	// s1 starts and becomes leader
	servers["s1"].Start()
	if _, err := servers["s1"].Do(&DefaultJoinCommand{Name: "s1"}); err != nil {
		t.Fatalf("s1 self-join failed: %v", err)
	}

	for _, name := range names[1:] {
		servers[name].Start()
		if _, err := servers["s1"].Do(&DefaultJoinCommand{Name: name}); err != nil {
			t.Fatalf("Join %s failed: %v", name, err)
		}
	}

	// Wait for replication
	time.Sleep(3 * testHeartbeatInterval)

	// Submit a command
	if _, err := servers["s1"].Do(&traceTestCommand{Val: "before-failover"}); err != nil {
		t.Fatalf("Command failed: %v", err)
	}
	time.Sleep(3 * testHeartbeatInterval)

	// Stop s1 (simulates crash — no Crash event since we just stop it)
	servers["s1"].Stop()

	// Wait for new election
	time.Sleep(3 * testElectionTimeout)

	// Check that a new leader was elected
	newLeader := ""
	for _, name := range names[1:] {
		if servers[name].State() == Leader {
			newLeader = name
		}
	}
	if newLeader == "" {
		t.Fatalf("No new leader elected after s1 stopped")
	}

	// Submit command to new leader
	if _, err := servers[newLeader].Do(&traceTestCommand{Val: "after-failover"}); err != nil {
		t.Fatalf("Command to new leader failed: %v", err)
	}
	time.Sleep(3 * testHeartbeatInterval)

	for _, name := range names[1:] {
		servers[name].Stop()
	}

	t.Logf("Trace written to %s", tracePath)
}
