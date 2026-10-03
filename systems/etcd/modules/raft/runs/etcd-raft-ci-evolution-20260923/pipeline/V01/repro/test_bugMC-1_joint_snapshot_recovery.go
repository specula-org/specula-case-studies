package main

import (
	"fmt"
	"log"
	"sort"

	raft "go.etcd.io/etcd/raft"
	pb "go.etcd.io/etcd/raft/raftpb"
	"go.etcd.io/etcd/raft/tracker"
)

type node struct {
	id      uint64
	raw     *raft.RawNode
	storage *raft.MemoryStorage
	applied uint64
	config  *pb.ConfState
}

type cluster struct {
	nodes map[uint64]*node
	queue []pb.Message
}

func newNode(id uint64, storage *raft.MemoryStorage) *node {
	raw, err := raft.NewRawNode(&raft.Config{
		ID:              id,
		ElectionTick:    10,
		HeartbeatTick:   1,
		Storage:         storage,
		MaxSizePerMsg:   4096,
		MaxInflightMsgs: 256,
	})
	if err != nil {
		log.Fatal(err)
	}
	return &node{id: id, raw: raw, storage: storage}
}

func applyCommitted(n *node, rd raft.Ready) {
	for _, ent := range rd.CommittedEntries {
		n.applied = ent.Index
		switch ent.Type {
		case pb.EntryConfChange:
			var change pb.ConfChange
			if err := change.Unmarshal(ent.Data); err != nil {
				log.Fatal(err)
			}
			n.config = n.raw.ApplyConfChange(change)
		case pb.EntryConfChangeV2:
			var change pb.ConfChangeV2
			if err := change.Unmarshal(ent.Data); err != nil {
				log.Fatal(err)
			}
			n.config = n.raw.ApplyConfChange(change)
		}
	}
}

func (c *cluster) handleReady(n *node) bool {
	if !n.raw.HasReady() {
		return false
	}
	rd := n.raw.Ready()
	if len(rd.Entries) != 0 {
		if err := n.storage.Append(rd.Entries); err != nil {
			log.Fatal(err)
		}
	}
	if !raft.IsEmptyHardState(rd.HardState) {
		if err := n.storage.SetHardState(rd.HardState); err != nil {
			log.Fatal(err)
		}
	}
	if !raft.IsEmptySnap(rd.Snapshot) {
		if err := n.storage.ApplySnapshot(rd.Snapshot); err != nil {
			log.Fatal(err)
		}
	}
	applyCommitted(n, rd)
	c.queue = append(c.queue, rd.Messages...)
	n.raw.Advance(rd)
	return true
}

func (c *cluster) drain() {
	for turns := 0; turns < 200; turns++ {
		progress := false
		ids := make([]int, 0, len(c.nodes))
		for id := range c.nodes {
			ids = append(ids, int(id))
		}
		sort.Ints(ids)
		for _, id := range ids {
			progress = c.handleReady(c.nodes[uint64(id)]) || progress
		}
		messages := c.queue
		c.queue = nil
		for _, message := range messages {
			if target := c.nodes[message.To]; target != nil {
				if err := target.raw.Step(message); err != nil {
					log.Fatal(err)
				}
				progress = true
			}
		}
		if !progress {
			return
		}
	}
	log.Fatal("message drain did not quiesce")
}

func progressIDs(raw *raft.RawNode) []uint64 {
	var ids []uint64
	raw.WithProgress(func(id uint64, _ raft.ProgressType, _ tracker.Progress) {
		ids = append(ids, id)
	})
	sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })
	return ids
}

func equalIDs(got, want []uint64) bool {
	if len(got) != len(want) {
		return false
	}
	for i := range got {
		if got[i] != want[i] {
			return false
		}
	}
	return true
}

func main() {
	peers := []raft.Peer{{ID: 1}, {ID: 2}, {ID: 3}}
	initial := &cluster{nodes: map[uint64]*node{}}
	for _, id := range []uint64{1, 2, 3} {
		n := newNode(id, raft.NewMemoryStorage())
		if err := n.raw.Bootstrap(peers); err != nil {
			log.Fatal(err)
		}
		initial.nodes[id] = n
	}
	initial.drain()

	if err := initial.nodes[1].raw.Campaign(); err != nil {
		log.Fatal(err)
	}
	initial.drain()
	if state := initial.nodes[1].raw.Status().RaftState; state != raft.StateLeader {
		log.Fatalf("bootstrap election did not elect node 1: %s", state)
	}

	change := pb.ConfChangeV2{
		Transition: pb.ConfChangeTransitionJointExplicit,
		Changes: []pb.ConfChangeSingle{
			{Type: pb.ConfChangeRemoveNode, NodeID: 3},
			{Type: pb.ConfChangeAddNode, NodeID: 4},
		},
	}
	if err := initial.nodes[1].raw.ProposeConfChange(change); err != nil {
		log.Fatal(err)
	}
	initial.drain()
	joint := initial.nodes[1].config
	if joint == nil || !equalIDs(joint.Nodes, []uint64{1, 2, 4}) || !equalIDs(joint.NodesJoint, []uint64{1, 2, 3}) {
		log.Fatalf("did not reach the expected public joint state: %+v", joint)
	}
	fmt.Printf("joint configuration persisted: incoming=%v outgoing=%v\n", joint.Nodes, joint.NodesJoint)

	snapshot, err := initial.nodes[1].storage.CreateSnapshot(initial.nodes[1].applied, joint, []byte("joint-state"))
	if err != nil {
		log.Fatal(err)
	}

	recovered := &cluster{nodes: map[uint64]*node{}}
	for _, id := range []uint64{1, 4} {
		storage := raft.NewMemoryStorage()
		if err := storage.ApplySnapshot(snapshot); err != nil {
			log.Fatal(err)
		}
		recovered.nodes[id] = newNode(id, storage)
	}
	if ids := progressIDs(recovered.nodes[1].raw); !equalIDs(ids, []uint64{1, 2, 4}) {
		log.Fatalf("unexpected restored members: %v", ids)
	} else {
		fmt.Printf("restart exposed only incoming voters: %v; outgoing voter 3 was lost\n", ids)
	}

	if err := recovered.nodes[1].raw.Campaign(); err != nil {
		log.Fatal(err)
	}
	recovered.drain() // node 2 is deliberately unavailable; node 4 is the only remote vote.
	if state := recovered.nodes[1].raw.Status().RaftState; state != raft.StateLeader {
		log.Fatalf("expected the lost-outgoing quorum to elect node 1 with votes from {1,4}, got %s", state)
	}
	fmt.Println("BUG REPRODUCED: a valid joint snapshot was restored as only its incoming configuration, so votes {1,4} elected a leader although they lack a majority of the persisted outgoing voters {1,2,3}.")
}
