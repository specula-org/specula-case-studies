#!/usr/bin/env bash
set -euo pipefail

WORKTREE="/home/ubuntu/specula-etcd-ci-init-20260912.FNeLj3NS/ci-clean/runs/20260912-155814-e83f/etcd-raft/.specula-output/confirmation/CR-1/worktree"
RUNDIR="/home/ubuntu/specula-etcd-ci-init-20260912.FNeLj3NS/ci-clean/runs/20260912-155814-e83f/etcd-raft/.specula-output/confirmation/CR-1/tmp/repro-cr1-rawnode-emptylog-vote"

rm -rf "$RUNDIR"
mkdir -p "$RUNDIR"

cat >"$RUNDIR/go.mod" <<EOF
module cr1repro

go 1.13

require go.etcd.io/etcd/raft v0.0.0

replace go.etcd.io/etcd/raft => $WORKTREE
replace go.etcd.io/etcd/pkg => /home/ubuntu/specula-etcd-ci-init-20260912.FNeLj3NS/build/legacy-pkg
EOF

cat >"$RUNDIR/main.go" <<'EOF'
package main

import (
	"fmt"
	"os"

	raft "go.etcd.io/etcd/raft"
	pb "go.etcd.io/etcd/raft/raftpb"
)

func cfg(id uint64, st raft.Storage) *raft.Config {
	return &raft.Config{
		ID:              id,
		ElectionTick:    10,
		HeartbeatTick:   1,
		Storage:         st,
		MaxSizePerMsg:   4096,
		MaxInflightMsgs: 256,
	}
}

func persistAndAdvance(label string, rn *raft.RawNode, st *raft.MemoryStorage) raft.Ready {
	if !rn.HasReady() {
		fmt.Printf("%s: no Ready\n", label)
		return raft.Ready{}
	}
	rd := rn.Ready()
	fmt.Printf("%s: Ready HardState{Term:%d Vote:%d Commit:%d} Entries:%d Committed:%d Messages:%s MustSync:%v\n",
		label, rd.HardState.Term, rd.HardState.Vote, rd.HardState.Commit,
		len(rd.Entries), len(rd.CommittedEntries), summarizeMessages(rd.Messages), rd.MustSync)
	if len(rd.Entries) > 0 {
		if err := st.Append(rd.Entries); err != nil {
			fatalf("%s: append entries: %v", label, err)
		}
	}
	if !raft.IsEmptyHardState(rd.HardState) {
		if err := st.SetHardState(rd.HardState); err != nil {
			fatalf("%s: set hardstate: %v", label, err)
		}
	}
	rn.Advance(rd)
	return rd
}

func summarizeMessages(msgs []pb.Message) string {
	if len(msgs) == 0 {
		return "[]"
	}
	out := "["
	for i, m := range msgs {
		if i > 0 {
			out += " "
		}
		out += fmt.Sprintf("%s %d->%d term=%d reject=%v", m.Type, m.From, m.To, m.Term, m.Reject)
	}
	return out + "]"
}

func findMessage(rd raft.Ready, typ pb.MessageType, from, to uint64) pb.Message {
	for _, m := range rd.Messages {
		if m.Type == typ && m.From == from && m.To == to {
			return m
		}
	}
	fatalf("missing %s from %d to %d in %s", typ, from, to, summarizeMessages(rd.Messages))
	return pb.Message{}
}

func makeCandidate(id uint64) (*raft.RawNode, *raft.MemoryStorage, pb.Message) {
	st := raft.NewMemoryStorage()
	rn, err := raft.NewRawNode(cfg(id, st), []raft.Peer{{ID: 1}, {ID: 2}, {ID: 3}})
	if err != nil {
		fatalf("candidate %d NewRawNode: %v", id, err)
	}
	persistAndAdvance(fmt.Sprintf("candidate%d bootstrap", id), rn, st)
	if err := rn.Campaign(); err != nil {
		fatalf("candidate %d campaign: %v", id, err)
	}
	rd := persistAndAdvance(fmt.Sprintf("candidate%d campaign", id), rn, st)
	msg := findMessage(rd, pb.MsgVote, id, 1)
	fmt.Printf("candidate%d produced real vote request for node1: %s %d->%d term=%d index=%d logTerm=%d\n",
		id, msg.Type, msg.From, msg.To, msg.Term, msg.Index, msg.LogTerm)
	return rn, st, msg
}

func fatalf(format string, args ...interface{}) {
	fmt.Fprintf(os.Stderr, "FAIL: "+format+"\n", args...)
	os.Exit(1)
}

func main() {
	cand2, _, voteReq2 := makeCandidate(2)
	cand3, _, voteReq3 := makeCandidate(3)

	joinStore := raft.NewMemoryStorage()
	node1, err := raft.NewRawNode(cfg(1, joinStore), nil)
	if err != nil {
		fatalf("node1 initial NewRawNode: %v", err)
	}
	persistAndAdvance("node1 initial empty-log join", node1, joinStore)

	if err := node1.Step(voteReq2); err != nil {
		fatalf("node1 step candidate2 vote request: %v", err)
	}
	rdVote2 := persistAndAdvance("node1 grants candidate2 before crash", node1, joinStore)
	voteResp2 := findMessage(rdVote2, pb.MsgVoteResp, 1, 2)
	if rdVote2.HardState.Term != 2 || rdVote2.HardState.Vote != 2 {
		fatalf("expected node1 to persist vote for candidate2 at term 2, got HardState{%+v}", rdVote2.HardState)
	}

	node1, err = raft.NewRawNode(cfg(1, joinStore), nil)
	if err != nil {
		fatalf("node1 restart NewRawNode: %v", err)
	}
	rdRestart := persistAndAdvance("node1 restart from empty log", node1, joinStore)
	if rdRestart.HardState.Term >= 2 || rdRestart.HardState.Vote != 0 {
		fatalf("expected reproduced bug to emit regressed empty vote hardstate, got HardState{%+v}", rdRestart.HardState)
	}
	fmt.Printf("observed regression: persisted HardState moved from Term:2 Vote:2 to Term:%d Vote:%d while log remained empty\n",
		rdRestart.HardState.Term, rdRestart.HardState.Vote)

	if err := node1.Step(voteReq3); err != nil {
		fatalf("node1 step candidate3 vote request: %v", err)
	}
	rdVote3 := persistAndAdvance("node1 grants candidate3 after restart", node1, joinStore)
	voteResp3 := findMessage(rdVote3, pb.MsgVoteResp, 1, 3)
	if rdVote3.HardState.Term != 2 || rdVote3.HardState.Vote != 3 {
		fatalf("expected node1 to persist vote for candidate3 at term 2, got HardState{%+v}", rdVote3.HardState)
	}

	if err := cand2.Step(voteResp2); err != nil {
		fatalf("candidate2 step node1 vote response: %v", err)
	}
	status2 := cand2.Status()
	fmt.Printf("candidate2 status after node1 vote: state=%s term=%d lead=%d\n", status2.RaftState, status2.Term, status2.Lead)
	if status2.RaftState != raft.StateLeader {
		fatalf("candidate2 did not become leader")
	}

	if err := cand3.Step(voteResp3); err != nil {
		fatalf("candidate3 step node1 vote response: %v", err)
	}
	status3 := cand3.Status()
	fmt.Printf("candidate3 status after node1 second vote: state=%s term=%d lead=%d\n", status3.RaftState, status3.Term, status3.Lead)
	if status3.RaftState != raft.StateLeader {
		fatalf("candidate3 did not become leader")
	}

	if status2.Term == status3.Term && status2.RaftState == raft.StateLeader && status3.RaftState == raft.StateLeader {
		fmt.Printf("BUG REPRODUCED: node1 cast two durable votes in term %d (Vote=2 then Vote=3), allowing candidate2 and candidate3 to both observe quorum and become leaders.\n", status2.Term)
		return
	}
	fatalf("expected two leaders in same term, got candidate2=%s/%d candidate3=%s/%d", status2.RaftState, status2.Term, status3.RaftState, status3.Term)
}
EOF

cd "$RUNDIR"
timeout 2m go mod tidy
timeout 2m go run .
