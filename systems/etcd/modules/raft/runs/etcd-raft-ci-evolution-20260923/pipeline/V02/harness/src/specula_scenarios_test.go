//go:build specula
// +build specula

package raft

import (
	pb "go.etcd.io/etcd/raft/raftpb"
	"testing"
)

// Public-interface bootstrap/Ready patterns are adapted from
// TestRawNodeStart, TestRawNodeProposeAndConfChange and TestNodeRestart.
// Their direct Step substitutions and injected Raft states are not reused.
func TestSpeculaRawElectionsReadsRecovery(t *testing.T) {
	o := sxDefault()
	o.pre = []uint64{1, 2, 3}
	o.check = []uint64{1, 2, 3}
	c := sxNew(t, "raw-elections-reads-recovery", o)
	c.drain()
	c.campaign(1)
	c.drain()
	if c.nodes[1].r.state != StateLeader {
		t.Fatal("campaign did not elect node 1")
	}
	w := c.propose(1, "Normal", 0, 16)
	c.drain()
	c.completeWrite(1, w)
	w = c.propose(2, "Normal", 0, 40)
	c.drain()
	c.completeWrite(2, w)
	c.delayApp[2] = true
	w = c.propose(1, "Normal", 0, 24)
	c.drain()
	r1 := c.propose(2, "Read", 0, 0)
	r2 := c.propose(1, "Read", 0, 0)
	c.drain()
	if uint64(len(c.nodes[2].app)) >= c.nodes[2].r.raftLog.applied {
		t.Fatal("delayed application was not exercised")
	}
	c.applyAll(2)
	c.delayApp[2] = false
	c.completeWrite(1, w)
	c.completeRead(2, r1)
	c.completeRead(1, r2)
	for _, id := range o.servers {
		c.save(id)
	}
	c.crash(3, false)
	c.restart(3)
	c.drain()
	c.transfer(1, 2)
	c.drain()
	if c.nodes[2].r.state != StateLeader {
		t.Fatal("transfer did not complete")
	}
	c.tick(2)
	c.drain()
	for _, id := range o.servers {
		c.quiesce(id)
	}
	c.blocked[2] = true
	for i := 0; i < 8 && c.nodes[2].r.state == StateLeader; i++ {
		c.tick(2)
		c.drain()
	}
	if c.nodes[2].r.state != StateFollower {
		t.Fatal("CheckQuorum did not step down after losing responses")
	}
}

func TestSpeculaNodeLifecycle(t *testing.T) {
	o := sxDefault()
	o.servers = []uint64{1}
	o.boot = []uint64{1}
	o.raw = nil
	o.pre = []uint64{1}
	o.maxReady = 24
	c := sxNew(t, "node-lifecycle", o)
	c.cancelBeforeHandoff(1)
	c.drain()
	c.campaign(1)
	c.drain()
	c.delayApp[1] = true
	w1 := c.propose(1, "Normal", 0, 16)
	w2 := c.propose(1, "Normal", 0, 40)
	c.drain()
	r := c.propose(1, "Read", 0, 0)
	c.drain()
	c.applyAll(1)
	c.delayApp[1] = false
	c.completeWrite(1, w1)
	c.completeWrite(1, w2)
	c.completeRead(1, r)
	c.save(1)
	s := c.snapshot(1)
	c.persistSnapshot(1)
	c.compact(1, s.Metadata.Index)
	c.crash(1, true)
	c.restart(1)
	c.drain()
	c.campaign(1)
	c.drain()
	r = c.propose(1, "Read", 0, 0)
	c.drain()
	c.completeRead(1, r)
	c.tick(1)
	c.drain()
}

func TestSpeculaMembershipSnapshots(t *testing.T) {
	o := sxDefault()
	o.servers = []uint64{1, 2, 3, 4}
	o.raw = o.servers
	o.maxMsg = 32
	o.maxReady = 32
	o.cancel = []uint64{8}
	c := sxNew(t, "membership-snapshots", o)
	c.drain()
	c.campaign(1)
	c.drain()
	c.propose(1, "AddLearner", 4, 0)
	c.drain()
	c.tick(1)
	c.drain()
	if !c.nodes[4].r.isLearner {
		t.Fatal("joining node was not installed as learner")
	}
	c.transfer(1, 4) // Public management request to learner is ignored.
	// Retain an uncommitted entry at the learner while dropping its ACK and
	// later commit-bearing appends. A real compacted leader subsequently sends
	// a snapshot whose term/index already match the learner's retained entry.
	fastIndex := c.nodes[1].r.raftLog.lastIndex() + 1
	c.dropMessage = func(m pb.Message) bool {
		return (m.From == 4 && m.Type == pb.MsgAppResp) || (m.To == 4 && m.Type == pb.MsgApp && m.Commit >= fastIndex)
	}
	c.propose(1, "Normal", 0, 24)
	c.drain()
	if c.nodes[4].r.raftLog.lastIndex() < fastIndex || c.nodes[4].r.raftLog.committed >= fastIndex {
		t.Fatal("fast restore preconditions were not observed")
	}
	fast := c.snapshot(1)
	c.persistSnapshot(1)
	c.compact(1, fast.Metadata.Index)
	for _, m := range c.sent {
		if m.PB.From == 1 && m.PB.To == 4 && m.PB.Type == pb.MsgApp {
			c.report(m, false, false)
			break
		}
	}
	c.tick(1)
	c.drain()
	if c.nodes[4].r.raftLog.committed != fastIndex || c.nodes[4].r.raftLog.unstable.snapshot != nil {
		t.Fatal("matching snapshot did not fast-forward commit")
	}
	for i := len(c.sent) - 1; i >= 0; i-- {
		m := c.sent[i]
		if m.PB.Type == pb.MsgSnap && m.PB.To == 4 {
			c.report(m, false, true)
			break
		}
	}
	c.dropMessage = nil
	c.tick(1)
	c.drain()
	c.blocked[4] = true
	c.propose(1, "Normal", 0, 24)
	c.drain()
	c.propose(1, "Normal", 0, 24)
	c.drain()
	s := c.snapshot(1)
	c.persistSnapshot(1)
	c.compact(1, s.Metadata.Index)
	c.available(1, false)
	c.blocked[4] = false
	c.tick(1)
	c.drain()
	c.available(1, true)
	c.tick(1)
	k := c.untilMessage(pb.MsgSnap, 4)
	c.report(c.wire[k], true, true)
	c.lose(k)
	c.drain()
	c.tick(1)
	k = c.untilMessage(pb.MsgSnap, 4)
	c.report(c.wire[k], false, true)
	c.drain()
	if uint64(len(c.nodes[4].app)) < s.Metadata.Index {
		t.Fatal("snapshot application did not catch learner up")
	}
	r := c.propose(4, "Read", 0, 0)
	c.drain()
	c.completeRead(4, r)
	c.propose(1, "AddVoter", 4, 0)
	c.propose(1, "Update", 2, 0) // Rewritten while the prior change is pending.
	c.drain()
	// Deterministic canceled callback (request 8) preserves the four voters.
	c.propose(1, "Remove", 4, 0)
	c.drain()
	if !sxContains(c.nodes[1].appCfg.Voters, 4) {
		t.Fatal("deterministic cancellation did not preserve voter")
	}
	c.propose(1, "Update", 2, 0)
	c.drain()
	c.propose(1, "Remove", 4, 0)
	c.drain()
	for _, id := range []uint64{1, 2, 3} {
		c.save(id)
	}
	c.crash(2, false)
	c.restart(2)
	c.drain()
}

func TestSpeculaSameBatchReplay(t *testing.T) {
	o := sxDefault()
	o.send = "SameBatch"
	o.recovery = "Replay"
	o.early = false
	c := sxNew(t, "same-batch-replay", o)
	c.drain()
	c.campaign(1)
	c.drain()
	w := c.propose(1, "Normal", 0, 24)
	c.drain()
	c.completeWrite(1, w)
	if c.branches["same-batch-publication-before-fsync"] == 0 {
		t.Fatal("same-batch overlap unvisited")
	}
	c.crash(3, false)
	c.restart(3)
	c.drain()
	r := c.propose(3, "Read", 0, 0)
	c.drain()
	// A recovered follower learns the current leader on a real heartbeat.
	c.tick(1)
	c.drain()
	r = c.propose(3, "Read", 0, 0)
	c.drain()
	c.completeRead(3, r)
}

func TestSpeculaPartitionBatching(t *testing.T) {
	o := sxDefault()
	o.maxMsg = 32
	o.maxReady = 32
	o.maxQuota = 48
	o.noForward = []uint64{3}
	c := sxNew(t, "partition-batching", o)
	c.drain()
	c.propose(1, "Normal", 0, 16) // RawNode explicitly rejects before any leader exists.
	c.campaign(1)
	if c.ready(1) {
		c.finishReady(1)
	}
	if len(c.wire) > 0 {
		c.duplicate(0)
		c.deliver(len(c.wire) - 1)
	} // A real vote is duplicated and delivered out of order.
	c.drain()
	c.propose(3, "Normal", 0, 16)
	c.blocked[3] = true
	for i := 0; i < 3; i++ {
		c.propose(1, "Normal", 0, 16)
		c.drain()
	}
	c.blocked[2] = true
	c.propose(1, "Normal", 0, 80) // Oversized first proposal is admitted.
	dropped := c.propose(1, "Normal", 0, 16)
	if c.requests[dropped]["core"] != "DropQuota" {
		t.Fatal("quota rejection unvisited")
	}
	if c.ready(1) {
		c.finishReady(1)
	}
	c.drain()
	c.transfer(1, 3)
	dropped = c.propose(1, "Normal", 0, 16)
	if c.requests[dropped]["core"] != "DropTransfer" {
		t.Fatal("transfer rejection unvisited")
	}
	for i := 0; i < 4; i++ {
		c.tick(1)
		c.drain()
	}
	if c.nodes[1].r.leadTransferee != 0 {
		t.Fatal("transfer timeout unvisited")
	}
	// The isolated leader has an uncommitted suffix. The other two voters
	// elect a leader using their actual logs, then ordinary Append repairs it.
	c.blocked[1] = true
	c.blocked[2] = false
	c.blocked[3] = false
	c.campaign(2)
	c.drain()
	if c.nodes[2].r.state != StateLeader {
		t.Fatal("partition election failed")
	}
	w := c.propose(2, "Normal", 0, 24)
	c.drain()
	c.completeWrite(2, w)
	c.blocked[1] = false
	c.tick(2)
	c.drain()
	for _, m := range c.sent {
		if m.PB.From == 2 && m.PB.To == 1 && m.PB.Type == pb.MsgApp {
			c.report(m, false, false)
			break
		}
	}
	c.tick(2)
	c.drain()
	for _, id := range o.servers {
		c.save(id)
	}
	// Crash after writing but before fsync: the completed image survives.
	c.propose(2, "Normal", 0, 16)
	if !c.ready(2) {
		t.Fatal("expected persistence batch")
	}
	c.startPersist(2, "All")
	c.crash(2, false)
	c.restart(2)
	c.drain()
}

// JointExplicit exercises both quorum halves, a staged voter replacement, and
// the explicit zero-change leave entry through the public ConfChangeV2 API.
func TestSpeculaJointExplicit(t *testing.T) {
	o := sxDefault()
	o.servers = []uint64{1, 2, 3, 4}
	o.raw = o.servers
	c := sxNew(t, "joint-explicit", o)
	c.drain()
	c.campaign(1)
	c.drain()
	c.proposeV2(1, []pb.ConfChangeSingle{
		{Type: pb.ConfChangeRemoveNode, NodeID: 3},
		{Type: pb.ConfChangeAddNode, NodeID: 4},
	}, pb.ConfChangeTransitionJointExplicit)
	c.drain()
	if len(c.nodes[1].r.prs.Voters[1]) == 0 || c.nodes[1].r.prs.AutoLeave {
		t.Fatal("explicit joint configuration was not retained")
	}
	// A safe ReadIndex in the joint state must collect both old and new quorums.
	r := c.propose(1, "Read", 0, 0)
	c.drain()
	c.completeRead(1, r)
	c.proposeV2(1, nil, pb.ConfChangeTransitionAuto)
	c.drain()
	if len(c.nodes[1].r.prs.Voters[1]) != 0 {
		t.Fatal("explicit leave did not finalize incoming voters")
	}
	c.branches["joint-explicit-enter-leave"]++
}

// JointAutoLeave covers the new Advance-side append after application of an
// implicit joint entry. A heartbeat drives the appended leave entry to peers.
func TestSpeculaJointAutoLeave(t *testing.T) {
	o := sxDefault()
	o.servers = []uint64{1, 2, 3, 4}
	o.raw = o.servers
	c := sxNew(t, "joint-autoleave", o)
	c.drain()
	c.campaign(1)
	c.drain()
	c.proposeV2(1, []pb.ConfChangeSingle{
		{Type: pb.ConfChangeRemoveNode, NodeID: 3},
		{Type: pb.ConfChangeAddNode, NodeID: 4},
	}, pb.ConfChangeTransitionAuto)
	c.drain()
	foundLeave := false
	for _, raw := range c.nodes[1].hist() {
		e := raw.(sxR)
		if e["kind"] == "V2" && len(e["changes"].(sxSeq)) == 0 {
			foundLeave = true
		}
	}
	if !foundLeave {
		t.Fatal("Advance did not append automatic leave")
	}
	c.tick(1)
	c.drain()
	if len(c.nodes[1].r.prs.Voters[1]) != 0 || c.nodes[1].r.prs.AutoLeave {
		t.Fatal("automatic leave did not finalize joint configuration")
	}
	c.branches["joint-auto-leave"]++
}

// JointSnapshotRecovery requires the constructor to preserve the complete joint
// ConfState and then exercises that restored configuration through an election.
func TestSpeculaJointSnapshotRecovery(t *testing.T) {
	o := sxDefault()
	o.servers = []uint64{1, 2, 3, 4}
	o.raw = o.servers
	o.recovery = "AppliedAdapter"
	c := sxNew(t, "joint-snapshot-recovery", o)
	c.drain()
	c.campaign(1)
	c.drain()
	c.proposeV2(1, []pb.ConfChangeSingle{
		{Type: pb.ConfChangeRemoveNode, NodeID: 3},
		{Type: pb.ConfChangeAddNode, NodeID: 4},
	}, pb.ConfChangeTransitionJointExplicit)
	c.drain()
	if len(c.nodes[2].appCfg.VotersOutgoing) == 0 {
		t.Fatal("joint ConfState did not reach the application")
	}
	c.save(2)
	s := c.snapshot(2)
	if len(s.Metadata.ConfState.VotersOutgoing) == 0 {
		t.Fatal("snapshot omitted outgoing voters before restart")
	}
	c.persistSnapshot(2)
	c.compact(2, s.Metadata.Index)
	c.crash(2, false)
	c.restart(2)
	if err := s.Metadata.ConfState.Equivalent(sxTrackerConfState(c.nodes[2].r.prs)); err != nil {
		t.Fatalf("complete joint configuration not restored: %v", err)
	}
	c.branches["joint-configuration-preserved-on-restart"]++
	c.blocked[1] = true
	c.campaign(2)
	c.drain()
	if c.nodes[2].r.state != StateLeader {
		t.Fatal("restored joint configuration did not support election")
	}
}

// LearnerVote exercises the lag-tolerance path in which a promoted voter has
// not learned its own promotion but grants a vote to a candidate that has.
func TestSpeculaLearnerVote(t *testing.T) {
	o := sxDefault()
	o.servers = []uint64{1, 2, 3, 4}
	o.raw = o.servers
	c := sxNew(t, "learner-vote", o)
	c.drain()
	c.campaign(1)
	c.drain()
	c.propose(1, "AddLearner", 4, 0)
	c.drain()
	c.tick(1)
	c.drain()
	if !c.nodes[4].r.isLearner {
		t.Fatal("node 4 did not become a learner")
	}
	c.dropMessage = func(m pb.Message) bool {
		return m.To == 4 && m.Type == pb.MsgApp
	}
	c.propose(1, "AddVoter", 4, 0)
	c.drain()
	if !c.nodes[4].r.isLearner || !sxContains(c.nodes[3].r.prs.Voters[0].Slice(), 4) {
		t.Fatal("promotion lag precondition not established")
	}
	c.dropMessage = nil
	c.blocked[1] = true
	c.campaign(3)
	c.drain()
	if c.nodes[3].r.state != StateLeader {
		t.Fatal("candidate did not win with learner grant")
	}
	c.branches["learner-vote-granted"]++
}

// ReadyInterveningOutput leaves one accepted Ready pending, produces another
// heartbeat, and verifies that Advance of the first batch does not erase it.
func TestSpeculaReadyInterveningOutput(t *testing.T) {
	o := sxDefault()
	o.servers = []uint64{1, 2}
	o.boot = o.servers
	o.raw = o.servers
	c := sxNew(t, "ready-intervening-output", o)
	c.drain()
	c.campaign(1)
	c.drain()
	c.tick(1)
	if !c.ready(1) {
		t.Fatal("expected heartbeat Ready")
	}
	c.startPersist(1, "All")
	c.completePersist(1, "All")
	c.install(1)
	for !c.nodes[1].batch["published"].(bool) {
		c.publish(1)
	}
	c.queue(1)
	c.tick(1)
	if len(c.nodes[1].out) == 0 {
		t.Fatal("intervening heartbeat output not produced")
	}
	c.advance(1)
	if len(c.nodes[1].out) == 0 {
		t.Fatal("Advance erased output produced after Ready")
	}
	c.branches["post-ready-output-preserved"]++
	c.drain()
}

// OutgoingSnapshotRestore sends a real compacted joint snapshot to an
// outgoing-only voter. The unchanged membership precheck currently rejects it.
func TestSpeculaOutgoingSnapshotRestore(t *testing.T) {
	o := sxDefault()
	o.servers = []uint64{1, 2, 3, 4}
	o.raw = o.servers
	c := sxNew(t, "outgoing-snapshot-restore", o)
	c.drain()
	c.campaign(1)
	c.drain()
	c.blocked[3] = true
	c.proposeV2(1, []pb.ConfChangeSingle{
		{Type: pb.ConfChangeRemoveNode, NodeID: 3},
		{Type: pb.ConfChangeAddNode, NodeID: 4},
	}, pb.ConfChangeTransitionJointExplicit)
	c.drain()
	if !sxContains(c.nodes[1].r.prs.Voters[1].Slice(), 3) || sxContains(c.nodes[1].r.prs.Voters[0].Slice(), 3) {
		t.Fatal("node 3 is not outgoing-only at leader")
	}
	s := c.snapshot(1)
	c.persistSnapshot(1)
	c.compact(1, s.Metadata.Index)
	c.blocked[3] = false
	c.tick(1)
	k := c.untilMessage(pb.MsgSnap, 3)
	before := c.nodes[3].r.raftLog.committed
	c.deliver(k)
	if c.nodes[3].r.raftLog.committed != before || c.nodes[3].r.raftLog.unstable.snapshot != nil {
		t.Fatal("expected outgoing-only snapshot membership rejection")
	}
	c.branches["outgoing-only-snapshot-rejected"]++
}
