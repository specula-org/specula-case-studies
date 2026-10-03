#!/usr/bin/env bash
set -euo pipefail

worktree="/home/ubuntu/specula-etcd-ci-init-20260912.FNeLj3NS/ci-clean/runs/20260912-155814-e83f/etcd-raft/.specula-output/confirmation/CR-6/worktree"
test_file="$worktree/test_bugCR6_admission_result_test.go"

cleanup() {
  rm -f "$test_file"
}
trap cleanup EXIT

cat >"$test_file" <<'GOEOF'
package raft_test

import (
	"context"
	"errors"
	"testing"
	"time"

	raft "go.etcd.io/etcd/raft"
	"go.etcd.io/etcd/raft/raftpb"
)

func testConfig(id uint64, storage *raft.MemoryStorage, maxUncommitted uint64) *raft.Config {
	return &raft.Config{
		ID:                        id,
		ElectionTick:              10,
		HeartbeatTick:             1,
		Storage:                   storage,
		MaxSizePerMsg:             1 << 20,
		MaxInflightMsgs:           256,
		MaxUncommittedEntriesSize: maxUncommitted,
	}
}

func applyCommittedConfChanges(n raft.Node, entries []raftpb.Entry) {
	for _, ent := range entries {
		if ent.Type != raftpb.EntryConfChange {
			continue
		}
		var cc raftpb.ConfChange
		if err := cc.Unmarshal(ent.Data); err != nil {
			panic(err)
		}
		n.ApplyConfChange(cc)
	}
}

func startSingletonNodeLeader(t *testing.T, maxUncommitted uint64) (raft.Node, *raft.MemoryStorage) {
	t.Helper()

	storage := raft.NewMemoryStorage()
	n := raft.StartNode(testConfig(1, storage, maxUncommitted), []raft.Peer{{ID: 1}})

	select {
	case rd := <-n.Ready():
		if err := storage.Append(rd.Entries); err != nil {
			n.Stop()
			t.Fatalf("initial Append returned %v", err)
		}
		applyCommittedConfChanges(n, rd.CommittedEntries)
		n.Advance()
	case <-time.After(2 * time.Second):
		n.Stop()
		t.Fatal("timed out waiting for initial Node Ready")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := n.Campaign(ctx); err != nil {
		n.Stop()
		t.Fatalf("Campaign returned %v", err)
	}

	deadline := time.After(2 * time.Second)
	for {
		select {
		case rd := <-n.Ready():
			if err := storage.Append(rd.Entries); err != nil {
				n.Stop()
				t.Fatalf("Append returned %v", err)
			}
			applyCommittedConfChanges(n, rd.CommittedEntries)
			leader := rd.SoftState != nil && rd.SoftState.Lead == 1
			n.Advance()
			if leader {
				return n, storage
			}
		case <-deadline:
			n.Stop()
			t.Fatal("timed out waiting for singleton Node to become leader")
		}
	}
}

func startSingletonRawNodeLeader(t *testing.T, maxUncommitted uint64) (*raft.RawNode, *raft.MemoryStorage) {
	t.Helper()

	storage := raft.NewMemoryStorage()
	rn, err := raft.NewRawNode(testConfig(1, storage, maxUncommitted), []raft.Peer{{ID: 1}})
	if err != nil {
		t.Fatalf("NewRawNode returned %v", err)
	}

	rd := rn.Ready()
	if err := storage.Append(rd.Entries); err != nil {
		t.Fatalf("initial Append returned %v", err)
	}
	rn.Advance(rd)

	if err := rn.Campaign(); err != nil {
		t.Fatalf("RawNode Campaign returned %v", err)
	}
	for i := 0; i < 4; i++ {
		if !rn.HasReady() {
			t.Fatal("RawNode had no Ready while campaigning")
		}
		rd = rn.Ready()
		if err := storage.Append(rd.Entries); err != nil {
			t.Fatalf("Append returned %v", err)
		}
		leader := rd.SoftState != nil && rd.SoftState.Lead == 1
		rn.Advance(rd)
		if leader {
			return rn, storage
		}
	}
	t.Fatal("RawNode did not become leader")
	return nil, nil
}

func containsConfChangeForNode(entries []raftpb.Entry, nodeID uint64) bool {
	for _, ent := range entries {
		if ent.Type != raftpb.EntryConfChange {
			continue
		}
		var cc raftpb.ConfChange
		if err := cc.Unmarshal(ent.Data); err != nil {
			panic(err)
		}
		if cc.NodeID == nodeID {
			return true
		}
	}
	return false
}

func TestBugCR6NodeConfChangeLosesAdmissionError(t *testing.T) {
	payload := []byte("payload")
	maxUncommitted := uint64(raft.PayloadSize(raftpb.Entry{Data: payload}))

	rn, _ := startSingletonRawNodeLeader(t, maxUncommitted)
	if err := rn.Propose(payload); err != nil {
		t.Fatalf("RawNode first proposal returned %v", err)
	}
	if err := rn.Propose(payload); !errors.Is(err, raft.ErrProposalDropped) {
		t.Fatalf("RawNode second proposal returned %v, want ErrProposalDropped", err)
	}
	cc := raftpb.ConfChange{Type: raftpb.ConfChangeAddNode, NodeID: 2}
	if err := rn.ProposeConfChange(cc); !errors.Is(err, raft.ErrProposalDropped) {
		t.Fatalf("RawNode conf-change proposal returned %v, want ErrProposalDropped", err)
	}
	t.Logf("control: RawNode ProposeConfChange returned ErrProposalDropped when quota admission rejected it")

	n, storage := startSingletonNodeLeader(t, maxUncommitted)
	defer n.Stop()

	if err := n.Propose(context.Background(), payload); err != nil {
		t.Fatalf("Node first proposal returned %v", err)
	}
	if err := n.Propose(context.Background(), payload); !errors.Is(err, raft.ErrProposalDropped) {
		t.Fatalf("Node second normal proposal returned %v, want ErrProposalDropped", err)
	}

	err := n.ProposeConfChange(context.Background(), cc)
	t.Logf("observed: Node ProposeConfChange returned %v under the same quota-exceeded admission state", err)
	if err != nil {
		t.Fatalf("current bug no longer reproduced: Node ProposeConfChange returned %v", err)
	}

	select {
	case rd := <-n.Ready():
		if err := storage.Append(rd.Entries); err != nil {
			t.Fatalf("Append returned %v", err)
		}
		accepted := containsConfChangeForNode(rd.Entries, 2) || containsConfChangeForNode(rd.CommittedEntries, 2)
		t.Logf("post-call Ready: entries=%d committed=%d contains_conf_change_for_node_2=%v", len(rd.Entries), len(rd.CommittedEntries), accepted)
		n.Advance()
		if accepted {
			t.Fatalf("conf change unexpectedly appeared in Ready despite admission quota rejection")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for Ready after accepted normal proposal")
	}

	t.Logf("BUG TRIGGERED: Node ProposeConfChange reported nil, while the conf-change proposal was rejected before appearing in Ready")
}
GOEOF

cd "$worktree"
go test -count=1 -run '^TestBugCR6NodeConfChangeLosesAdmissionError$' -v .
