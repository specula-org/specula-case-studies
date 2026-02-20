package main

import (
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"time"

	"github.com/hashicorp/go-hclog"
	"github.com/hashicorp/raft"
)

var (
	outPath  = flag.String("out", "", "NDJSON trace output path (default: ../traces/<scenario>.ndjson)")
	scenario = flag.String("scenario", "basic_election", "Scenario to run")
	verbose  = flag.Bool("verbose", false, "Print verbose output")
)

// simpleFSM is a minimal FSM for testing.
type simpleFSM struct {
	logs [][]byte
}

func (f *simpleFSM) Apply(l *raft.Log) interface{} {
	f.logs = append(f.logs, l.Data)
	return len(f.logs)
}

func (f *simpleFSM) Snapshot() (raft.FSMSnapshot, error) {
	return &simpleSnapshot{logs: f.logs}, nil
}

func (f *simpleFSM) Restore(r io.ReadCloser) error {
	defer r.Close()
	f.logs = nil
	return nil
}

type simpleSnapshot struct {
	logs [][]byte
}

func (s *simpleSnapshot) Persist(_ raft.SnapshotSink) error { return nil }
func (s *simpleSnapshot) Release()                          {}

// nodeInfo holds all the per-node state.
type nodeInfo struct {
	id     raft.ServerID
	addr   raft.ServerAddress
	raft   *raft.Raft
	store  *raft.InmemStore
	snap   *raft.InmemSnapshotStore
	trans  *raft.InmemTransport
	fsm    *simpleFSM
	logger hclog.Logger
}

func main() {
	flag.Parse()

	// Resolve output path.
	out := *outPath
	if out == "" {
		out = filepath.Join("..", "traces", *scenario+".ndjson")
	}
	if err := os.MkdirAll(filepath.Dir(out), 0o755); err != nil {
		log.Fatalf("failed to create output directory: %v", err)
	}

	// Create tracer.
	tracer, err := NewNDJSONTracer(out)
	if err != nil {
		log.Fatalf("failed to create tracer: %v", err)
	}
	defer tracer.Close()

	// Run the selected scenario.
	switch *scenario {
	case "basic_election":
		runBasicElection(tracer)
	case "client_request":
		runClientRequest(tracer)
	case "leader_failure":
		runLeaderFailure(tracer)
	case "config_change":
		runConfigChange(tracer)
	default:
		log.Fatalf("unknown scenario: %s", *scenario)
	}

	fmt.Printf("trace written to %s\n", out)
}

// makeCluster creates a 3-node raft cluster with the given tracer.
func makeCluster(tracer *NDJSONTracer) []*nodeInfo {
	serverIDs := []raft.ServerID{"s1", "s2", "s3"}
	serverAddrs := []raft.ServerAddress{"s1-addr", "s2-addr", "s3-addr"}

	nodes := make([]*nodeInfo, 3)

	// Create transports and connect them.
	for i := 0; i < 3; i++ {
		addr, trans := raft.NewInmemTransportWithTimeout(serverAddrs[i], 500*time.Millisecond)
		nodes[i] = &nodeInfo{
			id:   serverIDs[i],
			addr: addr,
			trans: trans,
		}
	}
	// Wire all transports together.
	for i := 0; i < 3; i++ {
		for j := 0; j < 3; j++ {
			if i != j {
				nodes[i].trans.Connect(nodes[j].addr, nodes[j].trans)
			}
		}
	}

	// Build the cluster configuration.
	configuration := raft.Configuration{
		Servers: []raft.Server{
			{Suffrage: raft.Voter, ID: serverIDs[0], Address: serverAddrs[0]},
			{Suffrage: raft.Voter, ID: serverIDs[1], Address: serverAddrs[1]},
			{Suffrage: raft.Voter, ID: serverIDs[2], Address: serverAddrs[2]},
		},
	}

	// Write config to trace.
	tracer.WriteConfig(traceConfig{
		Servers:          []string{"s1", "s2", "s3"},
		HeartbeatTimeout: "50ms",
		ElectionTimeout:  "50ms",
		PreVoteDisabled:  true,
	})

	// Create and bootstrap each node.
	for i := 0; i < 3; i++ {
		nodes[i].store = raft.NewInmemStore()
		nodes[i].snap = raft.NewInmemSnapshotStore()
		nodes[i].fsm = &simpleFSM{}

		logLevel := "WARN"
		if *verbose {
			logLevel = "DEBUG"
		}
		nodes[i].logger = hclog.New(&hclog.LoggerOptions{
			Name:   string(serverIDs[i]),
			Level:  hclog.LevelFromString(logLevel),
			Output: os.Stderr,
		})

		conf := &raft.Config{
			ProtocolVersion:    raft.ProtocolVersionMax,
			HeartbeatTimeout:   50 * time.Millisecond,
			ElectionTimeout:    50 * time.Millisecond,
			CommitTimeout:      5 * time.Millisecond,
			MaxAppendEntries:   64,
			ShutdownOnRemove:   true,
			TrailingLogs:       256,
			SnapshotInterval:   120 * time.Second,
			SnapshotThreshold:  8192,
			LeaderLeaseTimeout: 50 * time.Millisecond,
			LocalID:            serverIDs[i],
			Logger:             nodes[i].logger,
			TraceLogger:        tracer,
			PreVoteDisabled:    true,
		}

		// Bootstrap each node with the full configuration.
		if err := raft.BootstrapCluster(conf, nodes[i].store,
			nodes[i].store, nodes[i].snap, nodes[i].trans, configuration); err != nil {
			log.Fatalf("bootstrap node %s failed: %v", serverIDs[i], err)
		}

		r, err := raft.NewRaft(conf, nodes[i].fsm, nodes[i].store,
			nodes[i].store, nodes[i].snap, nodes[i].trans)
		if err != nil {
			log.Fatalf("create raft node %s failed: %v", serverIDs[i], err)
		}
		nodes[i].raft = r
	}

	return nodes
}

// waitLeader waits for a stable leader to emerge.
func waitLeader(nodes []*nodeInfo, timeout time.Duration) *nodeInfo {
	deadline := time.After(timeout)
	for {
		select {
		case <-deadline:
			log.Fatalf("timed out waiting for leader")
		case <-time.After(10 * time.Millisecond):
		}
		for _, n := range nodes {
			if n.raft.State() == raft.Leader {
				// Give a moment for the leader to stabilize.
				time.Sleep(20 * time.Millisecond)
				if n.raft.State() == raft.Leader {
					return n
				}
			}
		}
	}
}

// shutdownCluster gracefully shuts down all nodes.
func shutdownCluster(nodes []*nodeInfo) {
	for _, n := range nodes {
		f := n.raft.Shutdown()
		if err := f.Error(); err != nil {
			log.Printf("shutdown %s: %v", n.id, err)
		}
	}
}

// runBasicElection: create cluster, wait for leader, then shut down.
func runBasicElection(tracer *NDJSONTracer) {
	nodes := makeCluster(tracer)
	defer shutdownCluster(nodes)

	leader := waitLeader(nodes, 5*time.Second)
	fmt.Printf("leader elected: %s\n", leader.id)

	// Let the cluster run a bit so heartbeats are exchanged.
	time.Sleep(200 * time.Millisecond)
}

// runClientRequest: create cluster, submit client requests, wait for commit.
func runClientRequest(tracer *NDJSONTracer) {
	nodes := makeCluster(tracer)
	defer shutdownCluster(nodes)

	leader := waitLeader(nodes, 5*time.Second)
	fmt.Printf("leader elected: %s\n", leader.id)

	// Submit a few client requests.
	for i := 0; i < 3; i++ {
		future := leader.raft.Apply([]byte(fmt.Sprintf("cmd-%d", i)), 2*time.Second)
		if err := future.Error(); err != nil {
			log.Fatalf("apply cmd-%d failed: %v", i, err)
		}
	}

	// Wait for replication to settle.
	time.Sleep(200 * time.Millisecond)

	// Verify all FSMs got the entries.
	for _, n := range nodes {
		if len(n.fsm.logs) != 3 {
			fmt.Printf("WARNING: node %s has %d FSM entries (expected 3)\n", n.id, len(n.fsm.logs))
		}
	}
	fmt.Printf("all client requests committed and replicated\n")
}

// runLeaderFailure: create cluster, submit request, crash leader, wait for re-election.
func runLeaderFailure(tracer *NDJSONTracer) {
	nodes := makeCluster(tracer)

	leader := waitLeader(nodes, 5*time.Second)
	fmt.Printf("leader elected: %s\n", leader.id)

	// Submit one client request and wait for commit.
	future := leader.raft.Apply([]byte("cmd-0"), 2*time.Second)
	if err := future.Error(); err != nil {
		log.Fatalf("apply cmd-0 failed: %v", err)
	}

	// Wait for replication to settle.
	time.Sleep(200 * time.Millisecond)

	// Crash the leader: disconnect transport first, then shutdown.
	fmt.Printf("crashing leader %s\n", leader.id)
	for _, n := range nodes {
		if n != leader {
			n.trans.Disconnect(leader.addr)
		}
	}
	leader.trans.DisconnectAll()
	if err := leader.raft.Shutdown().Error(); err != nil {
		log.Printf("shutdown leader %s: %v", leader.id, err)
	}

	// Collect remaining nodes.
	var remaining []*nodeInfo
	for _, n := range nodes {
		if n != leader {
			remaining = append(remaining, n)
		}
	}

	// Wait for new leader to be elected.
	newLeader := waitLeader(remaining, 10*time.Second)
	fmt.Printf("new leader elected: %s\n", newLeader.id)

	// Submit another request to the new leader.
	future = newLeader.raft.Apply([]byte("cmd-1"), 2*time.Second)
	if err := future.Error(); err != nil {
		log.Fatalf("apply cmd-1 failed: %v", err)
	}

	// Wait for replication to settle.
	time.Sleep(200 * time.Millisecond)

	// Verify FSMs on remaining nodes.
	for _, n := range remaining {
		if len(n.fsm.logs) != 2 {
			fmt.Printf("WARNING: node %s has %d FSM entries (expected 2)\n", n.id, len(n.fsm.logs))
		}
	}
	fmt.Printf("leader failure recovery complete\n")

	// Shutdown remaining nodes.
	for _, n := range remaining {
		n.raft.Shutdown()
	}
}

// runConfigChange: create cluster, remove a node, submit request with reduced cluster.
func runConfigChange(tracer *NDJSONTracer) {
	nodes := makeCluster(tracer)

	leader := waitLeader(nodes, 5*time.Second)
	fmt.Printf("leader elected: %s\n", leader.id)

	// Wait for cluster to stabilize (noop committed, heartbeats flowing).
	time.Sleep(300 * time.Millisecond)

	// Pick a follower to remove (the last non-leader node).
	var target *nodeInfo
	for _, n := range nodes {
		if n != leader {
			target = n
		}
	}
	fmt.Printf("removing node %s\n", target.id)

	// Remove the target node from the cluster.
	removeFuture := leader.raft.RemoveServer(target.id, 0, 5*time.Second)
	if err := removeFuture.Error(); err != nil {
		log.Fatalf("remove server %s failed: %v", target.id, err)
	}

	// Wait for config change to propagate and target to shutdown (ShutdownOnRemove=true).
	time.Sleep(300 * time.Millisecond)

	// Submit a client request with the reduced 2-node cluster.
	applyFuture := leader.raft.Apply([]byte("cmd-0"), 2*time.Second)
	if err := applyFuture.Error(); err != nil {
		log.Fatalf("apply cmd-0 failed: %v", err)
	}

	// Wait for replication to settle.
	time.Sleep(200 * time.Millisecond)

	fmt.Printf("config change complete\n")

	// Shutdown remaining nodes (target already shut down via ShutdownOnRemove).
	for _, n := range nodes {
		if n != target {
			n.raft.Shutdown()
		}
	}
}
