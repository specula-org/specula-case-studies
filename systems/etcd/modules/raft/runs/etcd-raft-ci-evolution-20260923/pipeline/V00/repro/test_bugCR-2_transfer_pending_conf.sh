#!/usr/bin/env bash
set -euo pipefail

WORKTREE="/home/ubuntu/specula-etcd-ci-init-20260912.FNeLj3NS/ci-clean/runs/20260912-155814-e83f/etcd-raft/.specula-output/confirmation/CR-2/worktree"
TEST_FILE="$WORKTREE/bug_cr2_transfer_pending_conf_test.go"

cleanup() {
  rm -f "$TEST_FILE"
}
trap cleanup EXIT

cat >"$TEST_FILE" <<'GOEOF'
package raft

import (
	"testing"

	pb "go.etcd.io/etcd/raft/raftpb"
)

func TestBugCR2TransferBypassesPendingRemovalConfig(t *testing.T) {
	nt := newNetwork(nil, nil, nil)
	nt.send(pb.Message{From: 1, To: 1, Type: pb.MsgHup})

	leader := nt.peers[1].(*raft)
	transferee := nt.peers[2].(*raft)
	if leader.state != StateLeader || leader.lead != 1 {
		t.Fatalf("setup failed: node 1 state=%s lead=%d, want StateLeader lead=1", leader.state, leader.lead)
	}

	removeTransferee := pb.ConfChange{Type: pb.ConfChangeRemoveNode, NodeID: 2}
	data, err := removeTransferee.Marshal()
	if err != nil {
		t.Fatal(err)
	}

	nt.send(pb.Message{
		From: 1,
		To:   1,
		Type: pb.MsgProp,
		Entries: []pb.Entry{{
			Type: pb.EntryConfChange,
			Data: data,
		}},
	})
	nt.send(pb.Message{From: 1, To: 1, Type: pb.MsgBeat})

	if transferee.raftLog.committed <= transferee.raftLog.applied {
		t.Fatalf("setup failed: transferee has no committed-unapplied entries: committed=%d applied=%d",
			transferee.raftLog.committed, transferee.raftLog.applied)
	}
	ents, err := transferee.raftLog.slice(transferee.raftLog.applied+1, transferee.raftLog.committed+1, noLimit)
	if err != nil {
		t.Fatal(err)
	}
	if n := numOfPendingConf(ents); n == 0 {
		t.Fatalf("setup failed: committed-unapplied tail has no config change: ents=%v", ents)
	}

	termBeforeHup := transferee.Term
	nt.send(pb.Message{From: 2, To: 2, Type: pb.MsgHup})
	if transferee.state != StateFollower || transferee.Term != termBeforeHup {
		t.Fatalf("control failed: MsgHup was not blocked by pending config; state=%s term=%d want StateFollower term=%d",
			transferee.state, transferee.Term, termBeforeHup)
	}
	t.Logf("control: MsgHup blocked while ConfChangeRemoveNode(2) was committed but unapplied (committed=%d applied=%d)",
		transferee.raftLog.committed, transferee.raftLog.applied)

	nt.send(pb.Message{From: 2, To: 1, Type: pb.MsgTransferLeader})
	if transferee.state != StateLeader || transferee.lead != 2 {
		t.Fatalf("bug not reproduced: transfer did not elect node 2; state=%s lead=%d term=%d",
			transferee.state, transferee.lead, transferee.Term)
	}
	t.Logf("BUG TRIGGERED: MsgTimeoutNow transfer elected node 2 while ConfChangeRemoveNode(2) was still committed but unapplied (committed=%d applied=%d term=%d)",
		transferee.raftLog.committed, transferee.raftLog.applied, transferee.Term)

	cs := transferee.applyConfChange(removeTransferee)
	if _, ok := transferee.prs.Progress[2]; ok {
		t.Fatalf("setup failed: node 2 still has self progress after applying removal: %v", transferee.prs.Config)
	}
	if transferee.state != StateLeader {
		t.Fatalf("bug masked or fixed: applying self-removal changed state to %s, want to observe current buggy StateLeader", transferee.state)
	}

	err = transferee.Step(pb.Message{
		From: 2,
		To:   2,
		Type: pb.MsgProp,
		Entries: []pb.Entry{{
			Data: []byte("proposal after self-removal"),
		}},
	})
	if err != ErrProposalDropped {
		t.Fatalf("bug not reproduced: proposal to removed leader returned %v, want %v", err, ErrProposalDropped)
	}
	t.Logf("BUG TRIGGERED: after applying its own removal, node 2 remains %s with no self progress; client proposal returns %v; confstate=%s",
		transferee.state, err, cs.String())
}
GOEOF

cd "$WORKTREE"
timeout 5m go test -run TestBugCR2TransferBypassesPendingRemovalConfig -count=1 -v
