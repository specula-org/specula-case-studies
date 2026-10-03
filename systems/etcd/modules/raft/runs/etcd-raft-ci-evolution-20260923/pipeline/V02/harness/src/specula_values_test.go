//go:build specula
// +build specula

package raft

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"os"
	"reflect"
	"sort"
	"strings"
	"sync"
	"time"

	"go.etcd.io/etcd/raft/quorum"
	pb "go.etcd.io/etcd/raft/raftpb"
)

// These types only encode observed values. They contain no Raft transitions.
type sxR map[string]interface{}
type sxSeq []interface{}
type sxSet []interface{}
type sxPair struct{ Key, Value interface{} }
type sxMap []sxPair

func sxEncode(v interface{}) interface{} {
	tag := "atom"
	var body interface{} = v
	switch x := v.(type) {
	case sxR:
		tag = "record"
		m := map[string]interface{}{}
		for k, value := range x {
			m[k] = sxEncode(value)
		}
		body = m
	case sxSeq:
		tag = "seq"
		a := make([]interface{}, len(x))
		for k := range x {
			a[k] = sxEncode(x[k])
		}
		body = a
	case sxSet:
		tag = "set"
		a := make([]interface{}, len(x))
		for k := range x {
			a[k] = sxEncode(x[k])
		}
		body = a
	case sxMap:
		tag = "map"
		a := make([]interface{}, len(x))
		for k, p := range x {
			a[k] = map[string]interface{}{"key": sxEncode(p.Key), "value": sxEncode(p.Value)}
		}
		body = a
	default:
		switch reflect.TypeOf(v).Kind() {
		case reflect.Bool, reflect.String, reflect.Int, reflect.Uint64:
		default:
			panic(fmt.Sprintf("untyped trace value %T", v))
		}
	}
	return map[string]interface{}{"tag": tag, "value": body}
}
func sxCopy(r sxR) sxR {
	c := sxR{}
	for k, v := range r {
		c[k] = v
	}
	return c
}
func sxPrefix(s sxSeq, n uint64) sxSeq {
	if n > uint64(len(s)) {
		panic("observed prefix beyond history")
	}
	return append(sxSeq{}, s[:n]...)
}
func sxIDs(ids []uint64) sxSet {
	a := sxSet{}
	for _, id := range ids {
		a = append(a, id)
	}
	return a
}
func sxNumber(v interface{}) uint64 {
	switch n := v.(type) {
	case uint64:
		return n
	case int:
		return uint64(n)
	}
	panic(fmt.Sprintf("not numeric %T", v))
}
func sxKeys(m map[uint64]bool) []uint64 {
	ids := []uint64{}
	for id := range m {
		ids = append(ids, id)
	}
	sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })
	return ids
}
func sxEmptyConfig() sxR {
	return sxR{"voters": sxSet{}, "outgoing": sxSet{}, "learners": sxSet{}, "learnersNext": sxSet{}, "autoLeave": false}
}
func sxConfig(cs pb.ConfState) sxR {
	return sxR{"voters": sxIDs(cs.Voters), "outgoing": sxIDs(cs.VotersOutgoing), "learners": sxIDs(cs.Learners), "learnersNext": sxIDs(cs.LearnersNext), "autoLeave": cs.AutoLeave}
}
func sxCoreConfig(r *raft) sxR {
	return sxConfig(pb.ConfState{Voters: r.prs.Voters[0].Slice(), VotersOutgoing: r.prs.Voters[1].Slice(), Learners: quorum.MajorityConfig(r.prs.Learners).Slice(), LearnersNext: quorum.MajorityConfig(r.prs.LearnersNext).Slice(), AutoLeave: r.prs.AutoLeave})
}
func sxHS(h pb.HardState) sxR { return sxR{"term": h.Term, "vote": h.Vote, "commit": h.Commit} }
func sxSS(s *SoftState) sxR {
	return sxR{"role": strings.TrimPrefix(s.RaftState.String(), "State"), "lead": s.Lead}
}
func sxEmptySnapshot() sxR {
	return sxR{"index": uint64(0), "term": uint64(0), "hist": sxSeq{}, "config": sxEmptyConfig()}
}
func sxContext(b []byte) uint64 {
	if len(b) == 0 {
		return 0
	}
	if len(b) != 8 {
		panic("unknown read context")
	}
	return binary.BigEndian.Uint64(b)
}
func sxContextBytes(id uint64) []byte {
	if id == 0 {
		return nil
	}
	b := make([]byte, 8)
	binary.BigEndian.PutUint64(b, id)
	return b
}
func sxCommandID(b []byte) uint64 {
	if len(b) == 0 {
		return 0
	}
	if len(b) < 8 {
		panic("command too small")
	}
	return binary.BigEndian.Uint64(b[:8])
}
func sxEntry(e pb.Entry) sxR {
	kind := "Normal"
	target, id := uint64(0), uint64(0)
	changes := sxSeq{}
	transition := "Legacy"
	if e.Type == pb.EntryConfChange {
		var cc pb.ConfChange
		if err := cc.Unmarshal(e.Data); err != nil {
			panic(err)
		}
		target, id = cc.NodeID, cc.ID
		switch cc.Type {
		case pb.ConfChangeAddNode:
			kind = "AddVoter"
		case pb.ConfChangeAddLearnerNode:
			kind = "AddLearner"
		case pb.ConfChangeRemoveNode:
			kind = "Remove"
		case pb.ConfChangeUpdateNode:
			kind = "Update"
		default:
			panic("conf type")
		}
		changes = append(changes, sxR{"kind": kind, "target": target})
	} else if e.Type == pb.EntryConfChangeV2 {
		var cc pb.ConfChangeV2
		if err := cc.Unmarshal(e.Data); err != nil {
			panic(err)
		}
		kind, id = "V2", sxCommandID(cc.Context)
		switch cc.Transition {
		case pb.ConfChangeTransitionAuto:
			transition = "Auto"
		case pb.ConfChangeTransitionJointImplicit:
			transition = "JointImplicit"
		case pb.ConfChangeTransitionJointExplicit:
			transition = "JointExplicit"
		default:
			panic("conf transition")
		}
		for _, ch := range cc.Changes {
			ck := "Update"
			switch ch.Type {
			case pb.ConfChangeAddNode:
				ck = "AddVoter"
			case pb.ConfChangeAddLearnerNode:
				ck = "AddLearner"
			case pb.ConfChangeRemoveNode:
				ck = "Remove"
			case pb.ConfChangeUpdateNode:
			default:
				panic("conf type")
			}
			changes = append(changes, sxR{"kind": ck, "target": ch.NodeID})
		}
	} else {
		id = sxCommandID(e.Data)
	}
	return sxR{"term": e.Term, "index": e.Index, "kind": kind, "id": id, "target": target, "changes": changes, "transition": transition, "weight": len(e.Data), "encoded": e.Size()}
}
func sxEntries(es []pb.Entry) sxSeq {
	s := sxSeq{}
	for _, e := range es {
		s = append(s, sxEntry(e))
	}
	return s
}
func sxSnapshot(s pb.Snapshot) sxR {
	if IsEmptySnap(s) {
		return sxEmptySnapshot()
	}
	var es []pb.Entry
	if err := json.Unmarshal(s.Data, &es); err != nil {
		panic(err)
	}
	return sxR{"index": s.Metadata.Index, "term": s.Metadata.Term, "hist": sxEntries(es), "config": sxConfig(s.Metadata.ConfState)}
}
func sxEmptyRead() sxR {
	return sxR{"id": uint64(0), "rid": uint64(0), "requester": uint64(0), "index": uint64(0), "term": uint64(0), "leader": uint64(0), "config": sxEmptyConfig(), "acks": sxSet{}, "hist": sxSeq{}, "confirmConfig": sxEmptyConfig(), "confirmAcks": sxSet{}, "confirmTerm": uint64(0), "singleton": false}
}
func sxEmptyReady() sxR {
	return sxR{"active": false, "id": uint64(0), "hs": sxHS(pb.HardState{}), "hasHS": false, "ss": sxSS(&SoftState{}), "hasSS": false, "entries": sxSeq{}, "snapshot": sxEmptySnapshot(), "committed": sxSeq{}, "messages": sxMap{}, "remainingMessages": sxMap{}, "reads": sxSeq{}, "hist": sxSeq{}, "cursor": uint64(0), "fromApplied": uint64(0), "mustSync": false, "started": sxSet{}, "done": sxSet{}, "installed": sxSet{}, "published": false, "queued": false}
}
func sxEmptyRequest() sxR {
	return sxR{"status": "Unused", "node": uint64(0), "kind": "Normal", "target": uint64(0), "changes": sxSeq{}, "transition": "Legacy", "weight": 0, "encoded": 1, "parent": uint64(0), "handoff": false, "core": "", "result": "", "context": uint64(0), "beforeWrites": sxSet{}, "completed": false}
}

type sxMessage struct {
	PB    pb.Message
	Value sxR
}

func sxBag(ms []sxMessage) sxMap {
	indices := map[string]int{}
	b := sxMap{}
	for _, m := range ms {
		j, _ := json.Marshal(sxEncode(m.Value))
		key := string(j)
		if k, ok := indices[key]; ok {
			b[k].Value = b[k].Value.(int) + 1
		} else {
			indices[key] = len(b)
			b = append(b, sxPair{m.Value, 1})
		}
	}
	return b
}

type sxWriter struct {
	mu    sync.Mutex
	f     *os.File
	count int
}

func (w *sxWriter) emit(event string, params, settings, post sxR) {
	w.mu.Lock()
	defer w.mu.Unlock()
	e := map[string]interface{}{"tag": "trace", "ts": time.Now().UTC().Format(time.RFC3339Nano), "event": event, "post": sxEncode(post)}
	if event == "Init" {
		e["settings"] = sxEncode(settings)
	} else {
		e["params"] = sxEncode(params)
	}
	if err := json.NewEncoder(w.f).Encode(e); err != nil {
		panic(err)
	}
	w.count++
}

func (n *sxNode) storeHistory() sxSeq {
	ms := n.storage.MemoryStorage
	ms.Lock()
	defer ms.Unlock()
	cut := ms.ents[0].Index
	h := sxPrefix(n.compacted, cut)
	if cut > 0 && sxNumber(h[cut-1].(sxR)["term"]) != ms.ents[0].Term {
		panic("dummy term differs from retained observation")
	}
	return append(h, sxEntries(ms.ents[1:])...)
}
func (n *sxNode) hist() sxSeq {
	r := n.r
	h := n.storeHistory()
	if r.raftLog.unstable.snapshot != nil {
		h = sxSnapshot(*r.raftLog.unstable.snapshot)["hist"].(sxSeq)
	}
	if len(r.raftLog.unstable.entries) > 0 {
		h = append(sxPrefix(h, r.raftLog.unstable.offset-1), sxEntries(r.raftLog.unstable.entries)...)
	}
	return h
}
func (n *sxNode) readWitness(m pb.Message) sxR {
	ctx := sxContext(m.Entries[0].Data)
	id := n.c.contextRequest[ctx]
	requester := m.From
	if requester == 0 {
		requester = n.id
	}
	rd := sxEmptyRead()
	rd["id"], rd["rid"], rd["requester"] = ctx, id, requester
	rd["index"], rd["term"], rd["leader"] = n.r.raftLog.committed, n.r.Term, n.id
	rd["config"], rd["acks"], rd["hist"] = sxCoreConfig(n.r), sxSet{n.id}, sxPrefix(n.hist(), n.r.raftLog.committed)
	return rd
}
func (n *sxNode) message(m pb.Message) sxMessage {
	ctx := uint64(0)
	forced := bytes.Equal(m.Context, []byte(campaignTransfer))
	if !forced {
		ctx = sxContext(m.Context)
	}
	req := uint64(0)
	es := sxEntries(m.Entries)
	rd := sxEmptyRead()
	witness := sxSeq{}
	switch m.Type {
	case pb.MsgProp:
		if len(m.Entries) > 0 {
			req = sxNumber(es[0].(sxR)["id"])
		}
	case pb.MsgReadIndex, pb.MsgReadIndexResp:
		ctx = sxContext(m.Entries[0].Data)
		req = n.c.contextRequest[ctx]
		es = sxSeq{}
		if m.Type == pb.MsgReadIndexResp {
			rd = n.c.delivered[ctx]
			if rd == nil {
				panic("read response lacks release observation")
			}
			req = ctx
		}
	case pb.MsgApp, pb.MsgHeartbeat:
		witness = n.hist()
	case pb.MsgAppResp:
		if !m.Reject && m.Index > 0 {
			witness = sxPrefix(n.hist(), m.Index)
		}
	}
	v := sxR{"type": m.Type.String(), "from": m.From, "to": m.To, "term": m.Term, "index": m.Index, "logTerm": m.LogTerm, "commit": m.Commit, "entries": es, "reject": m.Reject, "hint": m.RejectHint, "context": ctx, "snapshot": sxSnapshot(m.Snapshot), "request": req, "witness": witness, "read": rd, "forced": forced}
	return sxMessage{m, v}
}
func (n *sxNode) capture() sxR {
	if !n.alive {
		return n.dead
	}
	r := n.r
	prs := sxMap{}
	progressIDs := make([]uint64, 0, len(r.prs.Progress))
	for p := range r.prs.Progress {
		progressIDs = append(progressIDs, p)
	}
	sort.Slice(progressIDs, func(i, j int) bool { return progressIDs[i] < progressIDs[j] })
	for _, p := range progressIDs {
		pr := r.prs.Progress[p]
		fl := sxSeq{}
		for _, i := range pr.Inflights.SpeculaInflights() {
			fl = append(fl, i)
		}
		ev := n.evidence[p]
		if ev == nil {
			ev = sxSeq{}
		}
		prs = append(prs, sxPair{p, sxR{"match": pr.Match, "next": pr.Next, "mode": strings.TrimPrefix(pr.State.String(), "State"), "probe": pr.ProbeSent, "pending": pr.PendingSnapshot, "active": pr.RecentActive, "inflight": fl, "evidence": ev}})
	}
	yes, no := sxSet{}, sxSet{}
	for _, id := range sxKeys(r.prs.Votes) {
		if r.prs.Votes[id] {
			yes = append(yes, id)
		} else {
			no = append(no, id)
		}
	}
	usnap := sxEmptySnapshot()
	if r.raftLog.unstable.snapshot != nil {
		usnap = sxSnapshot(*r.raftLog.unstable.snapshot)
	}
	queue := sxSeq{}
	for _, ctx := range r.readOnly.readIndexQueue {
		rs := r.readOnly.pendingReadIndex[ctx]
		w := sxCopy(n.readInit[sxContext([]byte(ctx))])
		if len(w) == 0 {
			panic("unobserved pending read")
		}
		w["acks"] = sxIDs(sxKeys(rs.acks))
		queue = append(queue, w)
	}
	reads := sxSeq{}
	for _, rs := range r.readStates {
		w := n.c.delivered[sxContext(rs.RequestCtx)]
		if w == nil {
			panic("unobserved ReadState")
		}
		if sxNumber(w["index"]) != rs.Index {
			panic("ReadState index mismatch")
		}
		reads = append(reads, w)
	}
	prevHS, prevSS := n.prevHS, n.prevSS
	if n.raw != nil {
		prevHS, prevSS = n.raw.prevHardSt, n.raw.prevSoftSt
	}
	if len(n.out) != len(r.msgs) {
		panic(fmt.Sprintf("outgoing observation count node %d: %d != %d", n.id, len(n.out), len(r.msgs)))
	}
	return sxR{"id": n.id, "alive": n.alive, "incarnation": n.incarnation, "term": r.Term, "vote": r.Vote, "role": strings.TrimPrefix(r.state.String(), "State"), "lead": r.lead, "config": sxCoreConfig(r), "cfgHist": n.cfgHist, "store": sxR{"hist": n.storeHistory(), "snapshot": sxSnapshot(n.storage.snapshot), "cut": n.storage.ents[0].Index, "hs": sxHS(n.storage.hardState)}, "unstable": sxEntries(r.raftLog.unstable.entries), "uoff": r.raftLog.unstable.offset, "usnap": usnap, "commit": r.raftLog.committed, "applied": r.raftLog.applied, "prs": prs, "yes": yes, "no": no, "pendingConf": r.pendingConfIndex, "quota": r.uncommittedSize, "elapsed": r.electionElapsed, "heartbeat": r.heartbeatElapsed, "timeout": r.randomizedElectionTimeout, "transfer": r.leadTransferee, "preVote": r.preVote, "checkQuorum": r.checkQuorum, "noForward": r.disableProposalForwarding, "out": sxBag(n.out), "readQueue": queue, "readStates": reads, "snapAvailable": n.storage.available, "fatal": "", "prevHS": sxHS(prevHS), "prevSS": sxSS(prevSS), "readySeq": n.readySeq, "nodeLead": n.nodeLead, "propcEnabled": n.proposals, "decision": n.decision}
}

func (c *sxCluster) hook(kind string, r *raft, m pb.Message, data interface{}) {
	n := c.nodes[r.id]
	if n == nil {
		return
	}
	n.r = r
	c.branches[kind]++
	switch kind {
	case "node-loop":
		s := data.(speculaLoopState)
		n.prevHS, n.prevSS, n.nodeLead, n.proposals = s.HS, s.SS, s.Lead, s.Proposals
		n.boundary <- struct{}{}
		<-n.resume
	case "reset":
		n.evidence = map[uint64]sxSeq{}
		n.readInit = map[uint64]sxR{}
	case "self-append":
		n.evidence[n.id] = n.hist()
	case "match":
		if c.receiving == nil || c.receiving.PB.From != m.From || c.receiving.PB.Index != m.Index {
			panic("match lacks actual received-message provenance")
		}
		n.evidence[m.From] = c.receiving.Value["witness"].(sxSeq)
	case "send":
		n.out = append(n.out, n.message(m))
	case "read-add":
		ctx := sxContext(m.Entries[0].Data)
		if n.readInit[ctx] == nil {
			n.readInit[ctx] = n.readWitness(m)
		}
	case "read-singleton":
		w := n.readWitness(m)
		w["singleton"] = true
		w["confirmConfig"], w["confirmAcks"], w["confirmTerm"] = sxCoreConfig(r), sxSet{n.id}, r.Term
		c.delivered[sxNumber(w["id"])] = w
	case "read-confirm":
		rs := r.readOnly.pendingReadIndex[string(m.Context)]
		if rs == nil {
			panic("confirmation lacks pending request")
		}
		n.confirmAcks = sxIDs(sxKeys(rs.acks))
	case "read-release":
		for _, rs := range data.([]*readIndexStatus) {
			ctx := sxContext(rs.req.Entries[0].Data)
			w := sxCopy(n.readInit[ctx])
			w["acks"] = sxIDs(sxKeys(rs.acks))
			w["confirmConfig"], w["confirmAcks"], w["confirmTerm"] = sxCoreConfig(r), n.confirmAcks, r.Term
			c.delivered[ctx] = w
		}
	case "restore":
		n.cfgHist = sxSnapshot(m.Snapshot)["hist"].(sxSeq)
		n.evidence = map[uint64]sxSeq{}
	case "Accepted", "Forwarded", "DropNoLeader", "DropForwardDisabled", "DropRemoved", "DropQuota", "DropTransfer":
		n.decision = kind
	}
}
