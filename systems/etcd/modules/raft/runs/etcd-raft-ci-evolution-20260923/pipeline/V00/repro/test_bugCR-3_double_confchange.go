package main

import (
	"context"
	"fmt"
	"log"
	"os"
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
		fmt.Printf("%s: ready entries=%d committed=%d mustSync=%v\n", label, len(rd.Entries), len(rd.CommittedEntries), rd.MustSync)
		return rd
	case <-time.After(3 * time.Second):
		log.Fatalf("%s: timed out waiting for Ready", label)
	}
	return raft.Ready{}
}

func persist(st *raft.MemoryStorage, rd raft.Ready) {
	if !raft.IsEmptySnap(rd.Snapshot) {
		must(st.ApplySnapshot(rd.Snapshot))
	}
	must(st.Append(rd.Entries))
	if !raft.IsEmptyHardState(rd.HardState) {
		must(st.SetHardState(rd.HardState))
	}
}

func decodeConfChange(e pb.Entry) (pb.ConfChange, bool) {
	if e.Type != pb.EntryConfChange {
		return pb.ConfChange{}, false
	}
	var cc pb.ConfChange
	if err := cc.Unmarshal(e.Data); err != nil {
		log.Fatalf("failed to decode confchange at index %d: %v", e.Index, err)
	}
	return cc, true
}

func findConfChange(rd raft.Ready, nodeID uint64) (pb.Entry, pb.ConfChange, bool) {
	for _, e := range rd.CommittedEntries {
		cc, ok := decodeConfChange(e)
		if ok && cc.NodeID == nodeID {
			return e, cc, true
		}
	}
	return pb.Entry{}, pb.ConfChange{}, false
}

func applyAllConfChanges(n raft.Node, rd raft.Ready) {
	for _, e := range rd.CommittedEntries {
		if cc, ok := decodeConfChange(e); ok {
			cs := n.ApplyConfChange(cc)
			fmt.Printf("applied confchange index=%d type=%s node=%d -> voters=%v learners=%v\n",
				e.Index, cc.Type, cc.NodeID, cs.Nodes, cs.Learners)
		}
	}
}

func main() {
	ctx := context.Background()
	storage := raft.NewMemoryStorage()
	cfg := &raft.Config{
		ID:              1,
		ElectionTick:    10,
		HeartbeatTick:   1,
		Storage:         storage,
		MaxSizePerMsg:   4096,
		MaxInflightMsgs: 256,
	}

	n := raft.StartNode(cfg, []raft.Peer{{ID: 1}})
	defer n.Stop()

	// Normal bootstrap: persist, apply the initial self-add confchange, and Advance.
	rd := nextReady(n, "bootstrap")
	persist(storage, rd)
	applyAllConfChanges(n, rd)
	n.Advance()

	must(n.Campaign(ctx))
	rd = nextReady(n, "campaign")
	persist(storage, rd)
	applyAllConfChanges(n, rd)
	n.Advance()

	first := pb.ConfChange{Type: pb.ConfChangeAddNode, NodeID: 2}
	must(n.ProposeConfChange(ctx, first))
	firstReady := nextReady(n, "first-confchange")
	persist(storage, firstReady)
	firstEntry, firstCC, ok := findConfChange(firstReady, 2)
	if !ok {
		fmt.Println("FAIL: first confchange was not committed")
		os.Exit(1)
	}
	fmt.Printf("first confchange committed at index=%d for node=%d; intentionally delaying ApplyConfChange\n",
		firstEntry.Index, firstCC.NodeID)

	// Publicly documented optimization: release the Ready before application completes.
	n.Advance()
	fmt.Println("called Advance for first confchange Ready before ApplyConfChange")

	second := pb.ConfChange{Type: pb.ConfChangeAddNode, NodeID: 3}
	must(n.ProposeConfChange(ctx, second))
	secondReady := nextReady(n, "second-confchange")
	persist(storage, secondReady)
	secondEntry, secondCC, ok := findConfChange(secondReady, 3)
	if !ok {
		fmt.Println("PASS: bug not present; second proposal was not committed as a config change before first ApplyConfChange")
		os.Exit(1)
	}

	fmt.Printf("BUG: second confchange committed at index=%d for node=%d before first ApplyConfChange ran\n",
		secondEntry.Index, secondCC.NodeID)
	applyAllConfChanges(n, firstReady)
	applyAllConfChanges(n, secondReady)
	n.Advance()
	fmt.Println("REPRODUCED: raft accepted and committed two membership changes while only released, not applied, progress separated them")
}
