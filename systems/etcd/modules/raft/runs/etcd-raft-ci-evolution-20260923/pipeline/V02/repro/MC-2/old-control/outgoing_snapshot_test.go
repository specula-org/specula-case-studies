package mc2old_test

import (
	"fmt"
	"math"
	"testing"

	raft "go.etcd.io/etcd/raft"
	pb "go.etcd.io/etcd/raft/raftpb"
)

func TestOutgoingOnlyJointVoterSnapshotRecoveryOldControl(t *testing.T) {
	storage := raft.NewMemoryStorage()
	initial := pb.Snapshot{Metadata: pb.SnapshotMetadata{
		Index: 4,
		Term:  2,
		ConfState: pb.ConfState{
			Nodes: []uint64{1, 2, 3},
		},
	}}
	if err := storage.ApplySnapshot(initial); err != nil {
		t.Fatal(err)
	}
	if err := storage.SetHardState(pb.HardState{Term: 2, Commit: 4}); err != nil {
		t.Fatal(err)
	}
	rn, err := raft.NewRawNode(&raft.Config{
		ID:                        3,
		ElectionTick:              10,
		HeartbeatTick:             1,
		Storage:                   storage,
		Applied:                   4,
		MaxSizePerMsg:             math.MaxUint64,
		MaxCommittedSizePerReady: math.MaxUint64,
		MaxInflightMsgs:           16,
	})
	if err != nil {
		t.Fatal(err)
	}

	joint := pb.Snapshot{Metadata: pb.SnapshotMetadata{
		Index: 5,
		Term:  2,
		ConfState: pb.ConfState{
			Nodes:      []uint64{1, 2, 4},
			NodesJoint: []uint64{1, 2, 3},
		},
	}}
	message := pb.Message{From: 1, To: 3, Term: 2, Type: pb.MsgSnap, Snapshot: joint}
	if err := rn.Step(message); err != nil {
		t.Fatal(err)
	}
	rd := rn.Ready()
	if !raft.IsEmptySnap(rd.Snapshot) {
		t.Fatal("old revision unexpectedly accepted the outgoing-only member snapshot")
	}
	if len(rd.Messages) != 1 || rd.Messages[0].Type != pb.MsgAppResp || rd.Messages[0].Index != 4 {
		t.Fatalf("response = %+v, want stale MsgAppResp at index 4", rd.Messages)
	}
	fmt.Printf("OLD CONTROL: valid joint snapshot index=5 rejected; response index=%d\n", rd.Messages[0].Index)
}
