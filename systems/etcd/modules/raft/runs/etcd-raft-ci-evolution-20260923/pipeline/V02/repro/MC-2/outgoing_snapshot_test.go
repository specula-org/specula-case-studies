package mc2_test

import (
	"fmt"
	"math"
	"testing"

	raft "go.etcd.io/etcd/raft"
	pb "go.etcd.io/etcd/raft/raftpb"
)

// TestOutgoingOnlyJointVoterSnapshotRecovery exercises only exported Raft
// interfaces. Node 3 starts from the old configuration, then receives a newer
// valid joint snapshot in which it is a voter solely in VotersOutgoing.
func TestOutgoingOnlyJointVoterSnapshotRecovery(t *testing.T) {
	storage := raft.NewMemoryStorage()
	initial := pb.Snapshot{Metadata: pb.SnapshotMetadata{
		Index: 4,
		Term:  2,
		ConfState: pb.ConfState{
			Voters: []uint64{1, 2, 3},
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
			Voters:         []uint64{1, 2, 4},
			VotersOutgoing: []uint64{1, 2, 3},
		},
	}}
	message := pb.Message{From: 1, To: 3, Term: 2, Type: pb.MsgSnap, Snapshot: joint}

	for attempt := 1; attempt <= 3; attempt++ {
		if err := rn.Step(message); err != nil {
			t.Fatalf("step snapshot attempt %d: %v", attempt, err)
		}
		rd := rn.Ready()
		if !raft.IsEmptySnap(rd.Snapshot) {
			t.Fatalf("snapshot unexpectedly accepted on attempt %d; recovery discrepancy not present", attempt)
		}
		if len(rd.Messages) != 1 || rd.Messages[0].Type != pb.MsgAppResp || rd.Messages[0].Index != 4 {
			t.Fatalf("attempt %d response = %+v, want stale MsgAppResp at index 4", attempt, rd.Messages)
		}
		fmt.Printf("attempt %d: valid joint snapshot index=5 rejected; response index=%d\n", attempt, rd.Messages[0].Index)
		rn.Advance(rd)
	}

	fmt.Println("REPRODUCED: outgoing-only joint voter remains at index 4 after repeated valid recovery snapshots")
}
