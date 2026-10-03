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
	raw, err := raft.NewRawNode(&raft.Config{ID: id, ElectionTick: 10, HeartbeatTick: 1,
		Storage: storage, MaxSizePerMsg: 4096, MaxInflightMsgs: 256})
	if err != nil {
		log.Fatal(err)
	}
	return &node{raw: raw, storage: storage}
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
	for _, ent := range rd.CommittedEntries {
		n.applied = ent.Index
		switch ent.Type {
		case pb.EntryConfChange:
			var cc pb.ConfChange
			if err := cc.Unmarshal(ent.Data); err != nil {
				log.Fatal(err)
			}
			n.config = n.raw.ApplyConfChange(cc)
		case pb.EntryConfChangeV2:
			var cc pb.ConfChangeV2
			if err := cc.Unmarshal(ent.Data); err != nil {
				log.Fatal(err)
			}
			n.config = n.raw.ApplyConfChange(cc)
		}
	}
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

func ids(raw *raft.RawNode) []uint64 {
	var result []uint64
	raw.WithProgress(func(id uint64, _ raft.ProgressType, _ tracker.Progress) {
		result = append(result, id)
	})
	sort.Slice(result, func(i, j int) bool { return result[i] < result[j] })
	return result
}

func equal(got, want []uint64) bool {
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
	initial := &cluster{nodes: map[uint64]*node{}}
	peers := []raft.Peer{{ID: 1}, {ID: 2}, {ID: 3}}
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
	change := pb.ConfChangeV2{Transition: pb.ConfChangeTransitionJointExplicit,
		Changes: []pb.ConfChangeSingle{
			{Type: pb.ConfChangeRemoveNode, NodeID: 3},
			{Type: pb.ConfChangeAddNode, NodeID: 4},
		}}
	if err := initial.nodes[1].raw.ProposeConfChange(change); err != nil {
		log.Fatal(err)
	}
	initial.drain()
	joint := initial.nodes[1].config
	if joint == nil || !equal(joint.Voters, []uint64{1, 2, 4}) || !equal(joint.VotersOutgoing, []uint64{1, 2, 3}) {
		log.Fatalf("unexpected joint state: %+v", joint)
	}
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
	if got := ids(recovered.nodes[1].raw); !equal(got, []uint64{1, 2, 3, 4}) {
		log.Fatalf("complete joint configuration was not restored: %v", got)
	} else {
		fmt.Printf("complete restored progress set: %v\n", got)
	}
	if err := recovered.nodes[1].raw.Campaign(); err != nil {
		log.Fatal(err)
	}
	recovered.drain()
	if state := recovered.nodes[1].raw.Status().RaftState; state == raft.StateLeader {
		log.Fatal("incoming-only votes elected a leader despite the restored outgoing quorum")
	} else {
		fmt.Printf("incoming-only election remained %s without an outgoing majority\n", state)
	}
	fmt.Println("FIX CONFIRMED: full joint snapshot state is restored and both quorum halves constrain elections")
}
