package main

import (
	"context"
	"fmt"
	"log"
	"time"

	raft "go.etcd.io/etcd/raft"
	pb "go.etcd.io/etcd/raft/raftpb"
)

func must(err error) {
	if err != nil {
		log.Fatal(err)
	}
}

func nextReady(n raft.Node, label string) raft.Ready {
	select {
	case rd := <-n.Ready():
		fmt.Printf("%s: entries=%d committed=%d\n", label, len(rd.Entries), len(rd.CommittedEntries))
		return rd
	case <-time.After(3 * time.Second):
		log.Fatalf("%s: timed out waiting for Ready", label)
	}
	return raft.Ready{}
}

func persist(storage *raft.MemoryStorage, rd raft.Ready) {
	if !raft.IsEmptySnap(rd.Snapshot) {
		must(storage.ApplySnapshot(rd.Snapshot))
	}
	must(storage.Append(rd.Entries))
	if !raft.IsEmptyHardState(rd.HardState) {
		must(storage.SetHardState(rd.HardState))
	}
}

func confAt(rd raft.Ready, nodeID uint64) (pb.Entry, pb.ConfChange, bool) {
	for _, entry := range rd.CommittedEntries {
		if entry.Type != pb.EntryConfChange {
			continue
		}
		var change pb.ConfChange
		if err := change.Unmarshal(entry.Data); err != nil {
			log.Fatal(err)
		}
		if change.NodeID == nodeID {
			return entry, change, true
		}
	}
	return pb.Entry{}, pb.ConfChange{}, false
}

func apply(n raft.Node, rd raft.Ready) {
	for _, entry := range rd.CommittedEntries {
		if entry.Type != pb.EntryConfChange {
			continue
		}
		var change pb.ConfChange
		if err := change.Unmarshal(entry.Data); err != nil {
			log.Fatal(err)
		}
		state := n.ApplyConfChange(change)
		fmt.Printf("applied index=%d node=%d voters=%v\n", entry.Index, change.NodeID, state.Voters)
	}
}

func main() {
	ctx := context.Background()
	storage := raft.NewMemoryStorage()
	n := raft.StartNode(&raft.Config{ID: 1, ElectionTick: 10, HeartbeatTick: 1,
		Storage: storage, MaxSizePerMsg: 4096, MaxInflightMsgs: 256}, []raft.Peer{{ID: 1}})
	defer n.Stop()

	rd := nextReady(n, "bootstrap")
	persist(storage, rd)
	apply(n, rd)
	n.Advance()
	must(n.Campaign(ctx))
	rd = nextReady(n, "campaign")
	persist(storage, rd)
	apply(n, rd)
	n.Advance()

	must(n.ProposeConfChange(ctx, pb.ConfChange{Type: pb.ConfChangeAddNode, NodeID: 2}))
	first := nextReady(n, "first-change")
	persist(storage, first)
	firstEntry, _, ok := confAt(first, 2)
	if !ok {
		log.Fatal("first configuration change did not commit")
	}
	fmt.Printf("first change committed at index=%d; application intentionally deferred\n", firstEntry.Index)
	n.Advance()

	must(n.ProposeConfChange(ctx, pb.ConfChange{Type: pb.ConfChangeAddNode, NodeID: 3}))
	second := nextReady(n, "second-change")
	persist(storage, second)
	secondEntry, _, ok := confAt(second, 3)
	if !ok {
		log.Fatal("second change was not committed before the first was applied")
	}
	fmt.Printf("CONDITION OBSERVED: second change committed at index=%d before ApplyConfChange for index=%d\n", secondEntry.Index, firstEntry.Index)
	apply(n, first)
	apply(n, second)
	n.Advance()
}
