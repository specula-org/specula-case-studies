package main

import (
	"context"
	"fmt"
	"log"
	"time"

	raft "go.etcd.io/etcd/raft"
	pb "go.etcd.io/etcd/raft/raftpb"
)

func config(storage *raft.MemoryStorage, limit uint64) *raft.Config {
	return &raft.Config{
		ID:                        1,
		ElectionTick:              10,
		HeartbeatTick:             1,
		Storage:                   storage,
		MaxSizePerMsg:             4096,
		MaxInflightMsgs:           256,
		MaxUncommittedEntriesSize: limit,
	}
}

func nextReady(n raft.Node, label string) raft.Ready {
	select {
	case ready := <-n.Ready():
		fmt.Printf("%s: entries=%d committed=%d\n", label, len(ready.Entries), len(ready.CommittedEntries))
		return ready
	case <-time.After(2 * time.Second):
		log.Fatalf("timeout waiting for %s", label)
	}
	return raft.Ready{}
}

func persist(storage *raft.MemoryStorage, ready raft.Ready) {
	if !raft.IsEmptySnap(ready.Snapshot) {
		if err := storage.ApplySnapshot(ready.Snapshot); err != nil {
			log.Fatal(err)
		}
	}
	if err := storage.Append(ready.Entries); err != nil {
		log.Fatal(err)
	}
	if !raft.IsEmptyHardState(ready.HardState) {
		if err := storage.SetHardState(ready.HardState); err != nil {
			log.Fatal(err)
		}
	}
}

func applyChanges(n raft.Node, ready raft.Ready) {
	for _, entry := range ready.CommittedEntries {
		if entry.Type != pb.EntryConfChange {
			continue
		}
		var change pb.ConfChange
		if err := change.Unmarshal(entry.Data); err != nil {
			log.Fatal(err)
		}
		n.ApplyConfChange(change)
	}
}

func containsConfChange(ready raft.Ready) bool {
	for _, entries := range [][]pb.Entry{ready.Entries, ready.CommittedEntries} {
		for _, entry := range entries {
			if entry.Type == pb.EntryConfChange || entry.Type == pb.EntryConfChangeV2 {
				return true
			}
		}
	}
	return false
}

func main() {
	payload := []byte("quota-bound proposal")
	storage := raft.NewMemoryStorage()
	node := raft.StartNode(config(storage, uint64(raft.PayloadSize(pb.Entry{Data: payload}))), []raft.Peer{{ID: 1}})
	defer node.Stop()

	ready := nextReady(node, "bootstrap")
	persist(storage, ready)
	applyChanges(node, ready)
	node.Advance()

	if err := node.Campaign(context.Background()); err != nil {
		log.Fatal(err)
	}
	for {
		ready = nextReady(node, "campaign")
		persist(storage, ready)
		applyChanges(node, ready)
		leader := ready.SoftState != nil && ready.SoftState.RaftState == raft.StateLeader
		node.Advance()
		if leader {
			break
		}
	}

	if err := node.Propose(context.Background(), payload); err != nil {
		log.Fatalf("normal proposal unexpectedly failed: %v", err)
	}
	handoff := make(chan error, 1)
	go func() {
		handoff <- node.ProposeConfChange(context.Background(), pb.ConfChange{Type: pb.ConfChangeAddNode, NodeID: 2})
	}()

	ready = nextReady(node, "quota-bound Ready")
	persist(storage, ready)
	if containsConfChange(ready) {
		log.Fatal("configuration change unexpectedly reached Ready despite the full proposal quota")
	}
	fmt.Println("control: quota-bound Ready contains only the normal proposal")
	node.Advance()

	select {
	case err := <-handoff:
		if err != nil {
			log.Fatalf("ProposeConfChange returned %v", err)
		}
	case <-time.After(2 * time.Second):
		log.Fatal("ProposeConfChange did not return")
	}

	select {
	case later := <-node.Ready():
		if !containsConfChange(later) {
			log.Fatal("configuration change was neither in the first Ready nor the next Ready")
		}
		fmt.Println("FIXED CONTROL: after the preceding Advance released quota, the configuration change appeared in the next Ready")
		node.Advance()
	case <-time.After(100 * time.Millisecond):
		log.Fatal("configuration change did not appear after the preceding Advance")
	}
	fmt.Println("FIXED: Node.ProposeConfChange handoff did not lose the configuration change on this revision.")
}
