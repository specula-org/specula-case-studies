#!/usr/bin/env bash
set -euo pipefail

WORKTREE="/home/ubuntu/specula-etcd-ci-init-20260912.FNeLj3NS/ci-clean/runs/20260912-155814-e83f/etcd-raft/.specula-output/confirmation/CR-5/worktree"
RUN_ROOT="/home/ubuntu/specula-etcd-ci-init-20260912.FNeLj3NS"
TMPROOT="/home/ubuntu/specula-etcd-ci-init-20260912.FNeLj3NS/ci-clean/runs/20260912-155814-e83f/etcd-raft/.specula-output/confirmation/CR-5/tmp"
REPRO_DIR="$TMPROOT/cr5-removed-leader-readindex"

rm -rf "$REPRO_DIR"
mkdir -p "$REPRO_DIR" "$TMPROOT/gocache" "$TMPROOT/gomodcache"

cat > "$REPRO_DIR/go.mod" <<EOF_GO_MOD
module cr5repro

go 1.13

require go.etcd.io/etcd/raft v0.0.0

replace go.etcd.io/etcd/raft => $WORKTREE
replace go.etcd.io/etcd/pkg => $RUN_ROOT/build/legacy-pkg
EOF_GO_MOD

cat > "$REPRO_DIR/main.go" <<'EOF_GO'
package main

import (
	"bytes"
	"fmt"
	"log"
	"sort"
	"strings"

	raft "go.etcd.io/etcd/raft"
	pb "go.etcd.io/etcd/raft/raftpb"
)

type localNode struct {
	id         uint64
	rn         *raft.RawNode
	storage    *raft.MemoryStorage
	applied    uint64
	value      string
	valueIndex uint64
	reads      []raft.ReadState
}

type harness struct {
	nodes map[uint64]*localNode
	outbox []pb.Message

	readCtx             []byte
	holdReadHeartbeat   bool
	heldReadHeartbeats  []pb.Message
	holdReadResponse    bool
	heldReadResponses   []pb.Message
	dropFromRemovedLead bool
}

func must(err error) {
	if err != nil {
		log.Fatal(err)
	}
}

func newLocalNode(id uint64) *localNode {
	st := raft.NewMemoryStorage()
	cfg := &raft.Config{
		ID:              id,
		ElectionTick:    10,
		HeartbeatTick:   1,
		Storage:         st,
		MaxSizePerMsg:   4096,
		MaxInflightMsgs: 256,
	}
	rn, err := raft.NewRawNode(cfg, []raft.Peer{{ID: 1}, {ID: 2}})
	must(err)
	return &localNode{id: id, rn: rn, storage: st}
}

func newHarness() *harness {
	return &harness{nodes: map[uint64]*localNode{
		1: newLocalNode(1),
		2: newLocalNode(2),
	}}
}

func sortedIDs(m map[uint64]*localNode) []uint64 {
	ids := make([]uint64, 0, len(m))
	for id := range m {
		ids = append(ids, id)
	}
	sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })
	return ids
}

func messageSummary(m pb.Message) string {
	ctx := ""
	if len(m.Context) > 0 {
		ctx = fmt.Sprintf(" ctx=%q", string(m.Context))
	}
	return fmt.Sprintf("%s %d->%d term=%d%s", m.Type, m.From, m.To, m.Term, ctx)
}

func (h *harness) processReady(n *localNode) bool {
	if !n.rn.HasReady() {
		return false
	}

	rd := n.rn.Ready()
	if len(rd.Entries) > 0 {
		must(n.storage.Append(rd.Entries))
	}
	if !raft.IsEmptyHardState(rd.HardState) {
		must(n.storage.SetHardState(rd.HardState))
	}
	if !raft.IsEmptySnap(rd.Snapshot) {
		must(n.storage.ApplySnapshot(rd.Snapshot))
	}

	for _, m := range rd.Messages {
		h.outbox = append(h.outbox, m)
	}

	for _, ent := range rd.CommittedEntries {
		n.applied = ent.Index
		switch ent.Type {
		case pb.EntryNormal:
			if len(ent.Data) > 0 {
				n.value = string(ent.Data)
				n.valueIndex = ent.Index
				fmt.Printf("apply: node=%d index=%d normal value=%q\n", n.id, ent.Index, n.value)
			}
		case pb.EntryConfChange:
			var cc pb.ConfChange
			must(cc.Unmarshal(ent.Data))
			cs := n.rn.ApplyConfChange(cc)
			fmt.Printf("apply: node=%d index=%d confchange type=%s node=%d voters=%v learners=%v\n",
				n.id, ent.Index, cc.Type, cc.NodeID, cs.Nodes, cs.Learners)
		}
	}

	for _, rs := range rd.ReadStates {
		n.reads = append(n.reads, rs)
		fmt.Printf("readstate: node=%d index=%d ctx=%q applied=%d value=%q\n",
			n.id, rs.Index, string(rs.RequestCtx), n.applied, n.value)
	}

	n.rn.Advance(rd)
	return true
}

func (h *harness) deliver(m pb.Message) bool {
	if h.holdReadHeartbeat && m.Type == pb.MsgHeartbeat && bytes.Equal(m.Context, h.readCtx) {
		h.heldReadHeartbeats = append(h.heldReadHeartbeats, m)
		fmt.Printf("hold: %s\n", messageSummary(m))
		return true
	}
	if h.holdReadResponse && m.Type == pb.MsgHeartbeatResp && bytes.Equal(m.Context, h.readCtx) {
		h.heldReadResponses = append(h.heldReadResponses, m)
		fmt.Printf("hold: %s\n", messageSummary(m))
		return true
	}
	if h.dropFromRemovedLead && m.From == 1 && m.To == 2 {
		fmt.Printf("drop-after-removal: %s\n", messageSummary(m))
		return true
	}

	to := h.nodes[m.To]
	if to == nil {
		fmt.Printf("drop-unknown-target: %s\n", messageSummary(m))
		return true
	}
	must(to.rn.Step(m))
	fmt.Printf("deliver: %s\n", messageSummary(m))
	return true
}

func (h *harness) drain(label string, limit int) {
	fmt.Printf("\n-- drain: %s --\n", label)
	for i := 0; i < limit; i++ {
		progress := false
		for _, id := range sortedIDs(h.nodes) {
			if h.processReady(h.nodes[id]) {
				progress = true
			}
		}
		if len(h.outbox) > 0 {
			msgs := h.outbox
			h.outbox = nil
			for _, m := range msgs {
				if h.deliver(m) {
					progress = true
				}
			}
		}
		if !progress {
			fmt.Printf("-- idle: %s --\n", label)
			return
		}
	}
	log.Fatalf("drain %q exceeded iteration limit", label)
}

func progressIDs(st *raft.Status) string {
	ids := make([]uint64, 0, len(st.Progress))
	for id := range st.Progress {
		ids = append(ids, id)
	}
	sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })
	parts := make([]string, 0, len(ids))
	for _, id := range ids {
		parts = append(parts, fmt.Sprint(id))
	}
	return "[" + strings.Join(parts, " ") + "]"
}

func main() {
	h := newHarness()

	fmt.Println("LEVEL 0: public RawNode API with ordinary message delay/reordering")
	h.drain("initial bootstrapping entries", 1000)

	must(h.nodes[1].rn.Campaign())
	h.drain("elect node 1", 1000)
	if st := h.nodes[1].rn.Status(); st.RaftState != raft.StateLeader {
		log.Fatalf("node 1 was not elected leader: %s", st.RaftState)
	}

	must(h.nodes[1].rn.Propose([]byte("value-before-removal")))
	h.drain("commit initial value on leader 1", 1000)

	h.readCtx = []byte("cr5-stale-read")
	readIndexAtRequest := h.nodes[1].rn.Status().Commit
	h.holdReadHeartbeat = true
	h.nodes[1].rn.ReadIndex(h.readCtx)
	h.drain("queue ReadIndex and delay its heartbeat proof", 1000)
	if len(h.heldReadHeartbeats) == 0 {
		log.Fatal("expected to hold a ReadIndex heartbeat but none was captured")
	}
	fmt.Printf("checkpoint: read requested on node 1 at committed index %d while node 1 is still a voter\n", readIndexAtRequest)

	must(h.nodes[1].rn.ProposeConfChange(pb.ConfChange{Type: pb.ConfChangeRemoveNode, NodeID: 1}))
	h.drain("commit and apply removal of leader 1", 1000)
	st1AfterRemove := h.nodes[1].rn.Status()
	_, selfStillVoter := st1AfterRemove.Progress[1]
	fmt.Printf("checkpoint: node1 status after applying self-removal state=%s term=%d commit=%d applied=%d progressIDs=%s selfInProgress=%v\n",
		st1AfterRemove.RaftState, st1AfterRemove.Term, st1AfterRemove.Commit, h.nodes[1].applied, progressIDs(st1AfterRemove), selfStillVoter)
	if st1AfterRemove.RaftState != raft.StateLeader || selfStillVoter {
		log.Fatalf("unexpected post-removal state: state=%s selfInProgress=%v", st1AfterRemove.RaftState, selfStillVoter)
	}
	if h.nodes[1].applied <= readIndexAtRequest {
		log.Fatalf("expected removed leader applied index to pass the read index: applied=%d readIndex=%d", h.nodes[1].applied, readIndexAtRequest)
	}

	h.holdReadHeartbeat = false
	h.holdReadResponse = true
	heldHeartbeats := h.heldReadHeartbeats
	h.heldReadHeartbeats = nil
	for _, m := range heldHeartbeats {
		h.deliver(m)
	}
	h.drain("turn delayed heartbeat into an old-term response, but keep response delayed", 1000)
	if len(h.heldReadResponses) == 0 {
		log.Fatal("expected to hold a delayed heartbeat response but none was captured")
	}

	h.dropFromRemovedLead = true
	for i := 0; i < 20; i++ {
		h.nodes[2].rn.Tick()
		h.drain(fmt.Sprintf("tick node 2 election timer %02d", i+1), 1000)
		if h.nodes[2].rn.Status().RaftState == raft.StateLeader {
			break
		}
	}
	if st := h.nodes[2].rn.Status(); st.RaftState != raft.StateLeader {
		log.Fatalf("node 2 did not become leader after removal; state=%s", st.RaftState)
	}

	must(h.nodes[2].rn.Propose([]byte("value-after-removal")))
	h.drain("commit newer value on sole remaining voter node 2", 1000)
	if h.nodes[2].value != "value-after-removal" {
		log.Fatalf("node 2 did not apply the newer value, has %q", h.nodes[2].value)
	}

	h.holdReadResponse = false
	heldResponses := h.heldReadResponses
	h.heldReadResponses = nil
	for _, m := range heldResponses {
		h.deliver(m)
	}
	h.drain("release old ReadIndex proof to removed leader 1", 1000)

	var observed *raft.ReadState
	for i := range h.nodes[1].reads {
		rs := &h.nodes[1].reads[i]
		if bytes.Equal(rs.RequestCtx, h.readCtx) {
			observed = rs
		}
	}
	if observed == nil {
		log.Fatal("removed leader did not emit a ReadState for the delayed read")
	}

	fmt.Printf("checkpoint: node2 committed newer value at index=%d applied=%d before old proof was released\n",
		h.nodes[2].valueIndex, h.nodes[2].applied)
	fmt.Printf("checkpoint: removed node1 emitted ReadState index=%d with applied=%d local value=%q\n",
		observed.Index, h.nodes[1].applied, h.nodes[1].value)

	if !(observed.Index == readIndexAtRequest &&
		h.nodes[1].applied > observed.Index &&
		h.nodes[1].value == "value-before-removal" &&
		h.nodes[2].value == "value-after-removal") {
		log.Fatalf("bug condition not met: readIndex=%d requested=%d node1Applied=%d node1Value=%q node2Value=%q",
			observed.Index, readIndexAtRequest, h.nodes[1].applied, h.nodes[1].value, h.nodes[2].value)
	}

	fmt.Println("BUG TRIGGERED: Ready.ReadStates on removed leader 1 authorizes a read at the old index after node 2 already committed/applied a newer value.")
}
EOF_GO

cd "$REPRO_DIR"
GOCACHE="$TMPROOT/gocache" GOMODCACHE="$TMPROOT/gomodcache" go run -mod=mod .
