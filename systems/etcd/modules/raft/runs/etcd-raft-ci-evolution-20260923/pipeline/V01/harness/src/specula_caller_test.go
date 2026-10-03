//go:build specula
// +build specula

package raft

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"sort"
	"testing"

	"go.etcd.io/etcd/raft/confchange"
	"go.etcd.io/etcd/raft/quorum"
	pb "go.etcd.io/etcd/raft/raftpb"
	"go.etcd.io/etcd/raft/tracker"
)

type sxStorage struct {
	*MemoryStorage
	available bool
	recovered *pb.ConfState
}

func (s *sxStorage) Snapshot() (pb.Snapshot, error) {
	if !s.available {
		return pb.Snapshot{}, ErrSnapshotTemporarilyUnavailable
	}
	return s.MemoryStorage.Snapshot()
}
func (s *sxStorage) InitialState() (pb.HardState, pb.ConfState, error) {
	h, c, e := s.MemoryStorage.InitialState()
	if s.recovered != nil {
		c = *s.recovered
	}
	return h, c, e
}

type sxDiskImage struct {
	HS       pb.HardState
	Log      map[uint64]pb.Entry
	Snapshot pb.Snapshot
	SavedApp []pb.Entry
}
type sxJob struct {
	Batch    uint64
	Snapshot pb.Snapshot
	Entries  []pb.Entry
}
type sxOptions struct {
	servers, boot, raw, pre, check, noForward []uint64
	maxMsg, maxReady, maxQuota                uint64
	early                                     bool
	send, persist, recovery                   string
	cancel                                    []uint64
}

func sxDefault() sxOptions {
	return sxOptions{servers: []uint64{1, 2, 3}, boot: []uint64{1, 2, 3}, raw: []uint64{1, 2, 3}, maxMsg: 64, maxReady: 64, maxQuota: 96, early: true, send: "Strict", persist: "Atomic", recovery: "AppliedAdapter"}
}
func sxContains(xs []uint64, n uint64) bool {
	for _, x := range xs {
		if x == n {
			return true
		}
	}
	return false
}

type sxNode struct {
	c                               *sxCluster
	id                              uint64
	r                               *raft
	raw                             *RawNode
	api                             Node
	storage                         *sxStorage
	alive                           bool
	incarnation, readySeq, nodeLead uint64
	proposals                       bool
	prevHS                          pb.HardState
	prevSS                          *SoftState
	boundary, resume                chan struct{}
	evidence                        map[uint64]sxSeq
	readInit                        map[uint64]sxR
	confirmAcks                     sxSet
	decision                        string
	compacted, cfgHist              sxSeq
	out                             []sxMessage
	dead                            sxR
	disk                            sxDiskImage
	pending                         *os.File
	rd                              Ready
	batch                           sxR
	remaining                       []sxMessage
	app                             []pb.Entry
	appCfg                          pb.ConfState
	jobs                            []sxJob
	reads                           sxSeq
}
type sxCluster struct {
	t              *testing.T
	opts           sxOptions
	nodes          map[uint64]*sxNode
	writer         sxWriter
	dir            string
	requests       map[uint64]sxR
	requestEntries map[uint64]pb.Entry
	contextRequest map[uint64]uint64
	delivered      map[uint64]sxR
	wire, sent     []sxMessage
	receiving      *sxMessage
	writes         sxSet
	branches       map[string]int
	blocked        map[uint64]bool
	dropMessage    func(pb.Message) bool
	delayApp       map[uint64]bool
	nextRequest    uint64
}

func (c *sxCluster) must(err error) {
	if err != nil {
		c.t.Fatal(err)
	}
}
func sxCloneEntries(es []pb.Entry) []pb.Entry {
	out := append([]pb.Entry(nil), es...)
	for i := range out {
		if es[i].Data != nil {
			out[i].Data = append([]byte{}, es[i].Data...)
		}
	}
	return out
}
func sxCloneMessage(m pb.Message) pb.Message {
	m.Entries = sxCloneEntries(m.Entries)
	m.Context = append([]byte(nil), m.Context...)
	m.Snapshot.Data = append([]byte(nil), m.Snapshot.Data...)
	return m
}
func sxCloneReady(r Ready) Ready {
	r.Entries = sxCloneEntries(r.Entries)
	r.CommittedEntries = sxCloneEntries(r.CommittedEntries)
	r.Messages = append([]pb.Message(nil), r.Messages...)
	for i := range r.Messages {
		r.Messages[i] = sxCloneMessage(r.Messages[i])
	}
	r.ReadStates = append([]ReadState(nil), r.ReadStates...)
	if r.SoftState != nil {
		s := *r.SoftState
		r.SoftState = &s
	}
	return r
}
func (c *sxCluster) config(n *sxNode, applied uint64) *Config {
	return &Config{ID: n.id, ElectionTick: 4, HeartbeatTick: 1, Storage: n.storage, Applied: applied, MaxSizePerMsg: c.opts.maxMsg, MaxCommittedSizePerReady: c.opts.maxReady, MaxUncommittedEntriesSize: c.opts.maxQuota, MaxInflightMsgs: 2, ReadOnlyOption: ReadOnlySafe, PreVote: sxContains(c.opts.pre, n.id), CheckQuorum: sxContains(c.opts.check, n.id), DisableProposalForwarding: sxContains(c.opts.noForward, n.id), Logger: &DefaultLogger{Logger: log.New(io.Discard, "", 0)}}
}
func sxNew(t *testing.T, name string, o sxOptions) *sxCluster {
	baseDir := os.Getenv("SPECULA_TRACE_DIR")
	if baseDir == "" {
		t.Fatal("SPECULA_TRACE_DIR must point inside this run")
	}
	dir := filepath.Join(os.Getenv("SPECULA_HARNESS_TMP"), name)
	if dir == name {
		t.Fatal("SPECULA_HARNESS_TMP required")
	}
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	f, err := os.Create(filepath.Join(baseDir, name+".ndjson"))
	if err != nil {
		t.Fatal(err)
	}
	c := &sxCluster{t: t, opts: o, nodes: map[uint64]*sxNode{}, dir: dir, writer: sxWriter{f: f}, requests: map[uint64]sxR{}, requestEntries: map[uint64]pb.Entry{}, contextRequest: map[uint64]uint64{}, delivered: map[uint64]sxR{}, writes: sxSet{}, branches: map[string]int{}, blocked: map[uint64]bool{}, delayApp: map[uint64]bool{}}
	for id := uint64(1); id <= 32; id++ {
		c.requests[id] = sxEmptyRequest()
	}
	speculaHook = c.hook
	for _, id := range o.servers {
		n := &sxNode{c: c, id: id, alive: true, storage: &sxStorage{MemoryStorage: NewMemoryStorage(), available: true}, prevSS: &SoftState{}, boundary: make(chan struct{}, 1), resume: make(chan struct{}), evidence: map[uint64]sxSeq{}, readInit: map[uint64]sxR{}, compacted: sxSeq{}, cfgHist: sxSeq{}, batch: sxEmptyReady(), reads: sxSeq{}, disk: sxDiskImage{Log: map[uint64]pb.Entry{}}}
		c.nodes[id] = n
		c.writeImage(n, n.disk)
		peers := []Peer{}
		if sxContains(o.boot, id) {
			for _, p := range o.boot {
				peers = append(peers, Peer{ID: p})
			}
		}
		if sxContains(o.raw, id) {
			n.raw, err = NewRawNode(c.config(n, 0))
			c.must(err)
			if len(peers) > 0 {
				c.must(n.raw.Bootstrap(peers))
			}
			n.r = n.raw.raft
		} else {
			n.api = StartNode(c.config(n, 0), peers)
			<-n.boundary
		}
		n.cfgHist = n.hist()
	}
	c.emit("Init", nil)
	t.Cleanup(func() {
		for _, id := range c.opts.servers {
			n := c.nodes[id]
			if n.alive && n.api != nil {
				n.resume <- struct{}{}
				n.api.Stop()
			}
			if n.pending != nil {
				_ = n.pending.Close()
			}
		}
		speculaHook = nil
		c.must(c.writer.f.Sync())
		c.must(c.writer.f.Close())
		b, _ := json.MarshalIndent(c.branches, "", "  ")
		c.must(os.WriteFile(filepath.Join(baseDir, name+".coverage.json"), append(b, '\n'), 0600))
		t.Logf("%s: %d real trace events", name, c.writer.count)
	})
	return c
}
func (c *sxCluster) settings() sxR {
	joining := []uint64{}
	for _, n := range c.opts.servers {
		if !sxContains(c.opts.boot, n) {
			joining = append(joining, n)
		}
	}
	requests := sxSet{}
	for id := uint64(1); id <= 32; id++ {
		requests = append(requests, id)
	}
	boot := sxSeq{}
	for _, id := range c.opts.boot {
		boot = append(boot, id)
	}
	weights, encoded := sxSet{}, sxSet{}
	for i := 0; i <= 256; i++ {
		weights = append(weights, i)
		if i > 0 {
			encoded = append(encoded, i)
		}
	}
	cc := pb.ConfChange{NodeID: 1, Type: pb.ConfChangeAddNode}
	data, err := cc.Marshal()
	c.must(err)
	e := pb.Entry{Term: 1, Index: 1, Type: pb.EntryConfChange, Data: data}
	empty := pb.Entry{}
	return sxR{"Server": sxIDs(c.opts.servers), "BootPeers": boot, "Joining": sxIDs(joining), "RawNodes": sxIDs(c.opts.raw), "PreVoteNodes": sxIDs(c.opts.pre), "CheckQuorumNodes": sxIDs(c.opts.check), "NoForwardNodes": sxIDs(c.opts.noForward), "RequestId": requests, "PayloadWeights": weights, "EncodedWeights": encoded, "ElectionTick": 4, "HeartbeatTick": 1, "MaxInflight": 2, "MaxMsgSize": c.opts.maxMsg, "MaxReadySize": c.opts.maxReady, "MaxUncommitted": c.opts.maxQuota, "SendPolicy": c.opts.send, "PersistPolicy": c.opts.persist, "EarlyAdvance": c.opts.early, "ReadFence": "Inclusive", "CancelChanges": sxIDs(c.opts.cancel), "CancelUnknownRemovals": true, "RecoveryMode": c.opts.recovery, "BootstrapPayload": len(data), "BootstrapEncoded": e.Size(), "EmptyEncoded": empty.Size()}
}
func (n *sxNode) diskValue() sxR {
	keys := []uint64{}
	for k := range n.disk.Log {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool { return keys[i] < keys[j] })
	m := sxMap{}
	for _, k := range keys {
		m = append(m, sxPair{k, sxEntry(n.disk.Log[k])})
	}
	return sxR{"hs": sxHS(n.disk.HS), "log": m, "snapshot": sxSnapshot(n.disk.Snapshot), "savedApp": sxEntries(n.disk.SavedApp)}
}
func (n *sxNode) appValue() sxR {
	jobs := sxSeq{}
	for _, j := range n.jobs {
		jobs = append(jobs, sxR{"batch": j.Batch, "snapshot": sxSnapshot(j.Snapshot), "entries": sxEntries(j.Entries)})
	}
	return sxR{"hist": sxEntries(n.app), "config": sxConfig(n.appCfg), "jobs": jobs, "reads": n.reads}
}
func (c *sxCluster) emit(name string, p sxR) {
	ra, di, re, ap, rq := sxMap{}, sxMap{}, sxMap{}, sxMap{}, sxMap{}
	for _, id := range c.opts.servers {
		n := c.nodes[id]
		ra = append(ra, sxPair{id, n.capture()})
		di = append(di, sxPair{id, n.diskValue()})
		re = append(re, sxPair{id, n.batch})
		ap = append(ap, sxPair{id, n.appValue()})
	}
	for id := uint64(1); id <= 32; id++ {
		rq = append(rq, sxPair{id, c.requests[id]})
	}
	c.writer.emit(name, p, c.settings(), sxR{"raft": ra, "disk": di, "ready": re, "application": ap, "requests": rq, "wire": sxBag(c.wire)})
	c.branches["event-"+name]++
}
func (n *sxNode) call(fn func()) {
	if n.api != nil {
		n.resume <- struct{}{}
		fn()
		<-n.boundary
	} else {
		fn()
	}
}
func (c *sxCluster) core(name string, id uint64, p sxR, fn func(*sxNode)) {
	n := c.nodes[id]
	if !n.alive {
		c.t.Fatal("call on crashed node")
	}
	n.call(func() { fn(n) })
	if name != "TickQuiesced" {
		p["timeout"] = n.r.randomizedElectionTimeout
	}
	c.emit(name, p)
}
func (c *sxCluster) campaign(id uint64) {
	c.core("Campaign", id, sxR{"node": id}, func(n *sxNode) {
		if n.raw != nil {
			c.must(n.raw.Campaign())
		} else {
			c.must(n.api.Campaign(context.Background()))
		}
	})
}
func (c *sxCluster) tick(id uint64) {
	c.core("Tick", id, sxR{"node": id}, func(n *sxNode) {
		if n.raw != nil {
			n.raw.Tick()
		} else {
			n.api.Tick()
		}
	})
}
func (c *sxCluster) quiesce(id uint64) {
	c.core("TickQuiesced", id, sxR{"node": id}, func(n *sxNode) { n.raw.TickQuiesced() })
}
func (c *sxCluster) transfer(id, target uint64) {
	c.core("TransferLeader", id, sxR{"node": id, "target": target}, func(n *sxNode) {
		if n.raw != nil {
			n.raw.TransferLeader(target)
		} else {
			n.api.TransferLeadership(context.Background(), id, target)
		}
	})
}

func (c *sxCluster) invoke(node uint64, kind string, target uint64, size int, parent uint64) uint64 {
	c.nextRequest++
	id := c.nextRequest
	if id > 32 {
		c.t.Fatal("request ID domain exhausted")
	}
	var entry pb.Entry
	ctx := uint64(0)
	if kind == "Normal" {
		if size < 8 {
			c.t.Fatal("normal command needs an eight-byte identity")
		}
		entry.Data = make([]byte, size)
		binary.BigEndian.PutUint64(entry.Data, id)
	} else if kind == "Read" {
		ctx = id
		c.contextRequest[ctx] = id
	} else {
		cc := pb.ConfChange{ID: id, NodeID: target}
		switch kind {
		case "AddVoter":
			cc.Type = pb.ConfChangeAddNode
		case "AddLearner":
			cc.Type = pb.ConfChangeAddLearnerNode
		case "Remove":
			cc.Type = pb.ConfChangeRemoveNode
		case "Update":
			cc.Type = pb.ConfChangeUpdateNode
		default:
			c.t.Fatal(kind)
		}
		data, err := cc.Marshal()
		c.must(err)
		entry = pb.Entry{Type: pb.EntryConfChange, Data: data}
	}
	w, z := len(entry.Data), entry.Size()
	if kind == "Read" {
		w, z = 0, 1
	}
	q := sxEmptyRequest()
	q["status"], q["node"], q["kind"], q["target"], q["weight"], q["encoded"], q["parent"], q["context"], q["beforeWrites"] = "Invoked", node, kind, target, w, z, parent, ctx, append(sxSet{}, c.writes...)
	if kind == "AddVoter" || kind == "AddLearner" || kind == "Remove" || kind == "Update" {
		q["changes"] = sxSeq{sxR{"kind": kind, "target": target}}
	}
	c.requests[id] = q
	c.requestEntries[id] = entry
	c.emit("Invoke", sxR{"node": node, "id": id, "kind": kind, "target": target, "weight": w, "encoded": z, "parent": parent, "context": ctx})
	return id
}
func sxChangeKind(t pb.ConfChangeType) string {
	switch t {
	case pb.ConfChangeAddNode:
		return "AddVoter"
	case pb.ConfChangeAddLearnerNode:
		return "AddLearner"
	case pb.ConfChangeRemoveNode:
		return "Remove"
	case pb.ConfChangeUpdateNode:
		return "Update"
	default:
		panic("conf type")
	}
}
func sxTransition(t pb.ConfChangeTransition) string {
	switch t {
	case pb.ConfChangeTransitionAuto:
		return "Auto"
	case pb.ConfChangeTransitionJointImplicit:
		return "JointImplicit"
	case pb.ConfChangeTransitionJointExplicit:
		return "JointExplicit"
	default:
		panic("conf transition")
	}
}
func (c *sxCluster) invokeV2(node uint64, changes []pb.ConfChangeSingle, transition pb.ConfChangeTransition, parent uint64) uint64 {
	c.nextRequest++
	id := c.nextRequest
	if id > 32 {
		c.t.Fatal("request ID domain exhausted")
	}
	cc := pb.ConfChangeV2{Transition: transition, Changes: append([]pb.ConfChangeSingle(nil), changes...), Context: sxContextBytes(id)}
	typ, data, err := pb.MarshalConfChange(cc)
	c.must(err)
	entry := pb.Entry{Type: typ, Data: data}
	encodedChanges := sxSeq{}
	for _, ch := range changes {
		encodedChanges = append(encodedChanges, sxR{"kind": sxChangeKind(ch.Type), "target": ch.NodeID})
	}
	q := sxEmptyRequest()
	q["status"], q["node"], q["kind"], q["changes"], q["transition"] = "Invoked", node, "V2", encodedChanges, sxTransition(transition)
	q["weight"], q["encoded"], q["parent"], q["context"], q["beforeWrites"] = len(data), entry.Size(), parent, id, append(sxSet{}, c.writes...)
	c.requests[id] = q
	c.requestEntries[id] = entry
	c.emit("InvokeV2", sxR{"node": node, "id": id, "changes": encodedChanges, "transition": sxTransition(transition), "weight": len(data), "encoded": entry.Size(), "parent": parent})
	return id
}
func (c *sxCluster) handoff(id uint64) {
	q := c.requests[id]
	n := c.nodes[sxNumber(q["node"])]
	var err error
	if q["kind"] == "Read" {
		n.call(func() {
			if n.raw != nil {
				n.raw.ReadIndex(sxContextBytes(sxNumber(q["context"])))
			} else {
				err = n.api.ReadIndex(context.Background(), sxContextBytes(sxNumber(q["context"])))
			}
		})
		c.must(err)
		q["status"], q["handoff"], q["result"] = "HandedOff", true, "Handoff"
		c.emit("ReadIndex", sxR{"node": n.id, "id": id, "timeout": n.r.randomizedElectionTimeout})
	} else {
		n.decision = ""
		e := c.requestEntries[id]
		n.call(func() {
			if q["kind"] == "Normal" {
				if n.raw != nil {
					err = n.raw.Propose(e.Data)
				} else {
					err = n.api.Propose(context.Background(), e.Data)
				}
			} else if q["kind"] == "V2" {
				var cc pb.ConfChangeV2
				if err := cc.Unmarshal(e.Data); err != nil {
					c.t.Fatalf("decode V2 proposal type=%s data=%x: %v", e.Type, e.Data, err)
				}
				if n.raw != nil {
					err = n.raw.ProposeConfChange(cc)
				} else {
					err = n.api.ProposeConfChange(context.Background(), cc)
				}
			} else {
				var cc pb.ConfChange
				c.must(cc.Unmarshal(e.Data))
				if n.raw != nil {
					err = n.raw.ProposeConfChange(cc)
				} else {
					err = n.api.ProposeConfChange(context.Background(), cc)
				}
			}
		})
		if err != nil && err != ErrProposalDropped {
			c.t.Fatal(err)
		}
		result := n.decision
		if n.api != nil && q["kind"] != "Normal" {
			result = "Handoff"
		}
		if result == "" {
			c.t.Fatal("proposal returned without a branch observation")
		}
		q["status"], q["handoff"], q["core"], q["result"] = "HandedOff", true, n.decision, result
		c.emit("Propose", sxR{"node": n.id, "id": id, "timeout": n.r.randomizedElectionTimeout})
	}
	q["status"] = "Returned"
	c.emit("ReturnAPI", sxR{"id": id})
}
func (c *sxCluster) propose(node uint64, kind string, target uint64, size int) uint64 {
	id := c.invoke(node, kind, target, size, 0)
	c.handoff(id)
	return id
}
func (c *sxCluster) proposeV2(node uint64, changes []pb.ConfChangeSingle, transition pb.ConfChangeTransition) uint64 {
	id := c.invokeV2(node, changes, transition, 0)
	c.handoff(id)
	return id
}
func (c *sxCluster) cancelBeforeHandoff(node uint64) {
	id := c.invoke(node, "Normal", 0, 8, 0)
	n := c.nodes[node]
	if n.api == nil {
		c.t.Fatal("cancellation requires Node")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	// The Node is parked with proposal input disabled. No handoff is possible.
	err := n.api.Propose(ctx, c.requestEntries[id].Data)
	if err != context.Canceled {
		c.t.Fatalf("cancel: %v", err)
	}
	c.requests[id]["status"], c.requests[id]["result"] = "Canceled", "Canceled"
	c.emit("Cancel", sxR{"id": id})
}

func (c *sxCluster) ready(id uint64) bool {
	n := c.nodes[id]
	if !n.alive || n.batch["active"].(bool) {
		return false
	}
	if n.raw != nil {
		if !n.raw.HasReady() {
			return false
		}
	} else {
		if !newReady(n.r, n.prevSS, n.prevHS).containsUpdates() {
			return false
		}
	}
	hs, ss, h, from, messages := n.r.hardState(), n.r.softState(), n.hist(), n.r.raftLog.applied, append([]sxMessage{}, n.out...)
	n.call(func() {
		if n.raw != nil {
			n.rd = sxCloneReady(n.raw.Ready())
		} else {
			n.rd = sxCloneReady(<-n.api.Ready())
		}
	})
	// RawNode.Ready is read-only in this revision. Node accepts the delivered
	// Ready in its run loop and clears messages/read states before parking.
	if n.raw == nil {
		n.out = nil
	}
	n.readySeq++
	rd := n.rd
	b := sxEmptyReady()
	b["active"], b["id"] = true, n.readySeq
	b["hs"], b["hasHS"], b["ss"], b["hasSS"] = sxHS(hs), !IsEmptyHardState(rd.HardState), sxSS(ss), rd.SoftState != nil
	n.remaining = messages
	reads := sxSeq{}
	for _, r := range rd.ReadStates {
		w := c.delivered[sxContext(r.RequestCtx)]
		if w == nil {
			c.t.Fatal("Ready read without provenance")
		}
		reads = append(reads, w)
	}
	b["entries"], b["snapshot"], b["committed"], b["messages"], b["remainingMessages"], b["reads"], b["hist"], b["cursor"], b["fromApplied"], b["mustSync"] = sxEntries(rd.Entries), sxSnapshot(rd.Snapshot), sxEntries(rd.CommittedEntries), sxBag(messages), sxBag(messages), reads, h, rd.appliedCursor(), from, rd.MustSync
	n.batch = b
	n.reads = append(n.reads, reads...)
	c.emit("Ready", sxR{"node": id})
	return true
}
func (c *sxCluster) diskPath(n *sxNode) string {
	return filepath.Join(c.dir, fmt.Sprintf("node-%d.json", n.id))
}
func (c *sxCluster) writeImage(n *sxNode, image sxDiskImage) {
	p := c.diskPath(n)
	f, err := os.Create(p + ".pending")
	c.must(err)
	c.must(json.NewEncoder(f).Encode(image))
	c.must(f.Sync())
	c.must(f.Close())
	c.must(os.Rename(p+".pending", p))
	d, err := os.Open(c.dir)
	c.must(err)
	c.must(d.Sync())
	c.must(d.Close())
	f, err = os.Open(p)
	c.must(err)
	c.must(json.NewDecoder(f).Decode(&n.disk))
	c.must(f.Close())
}
func (c *sxCluster) startPersist(id uint64, part string) {
	n := c.nodes[id]
	d := n.disk
	d.Log = map[uint64]pb.Entry{}
	for k, e := range n.disk.Log {
		d.Log[k] = e
	}
	if part == "All" || part == "Entries" {
		if len(n.rd.Entries) > 0 {
			for k := range d.Log {
				if k >= n.rd.Entries[0].Index {
					delete(d.Log, k)
				}
			}
			for _, e := range n.rd.Entries {
				d.Log[e.Index] = e
			}
		}
	}
	if (part == "All" || part == "HS") && !IsEmptyHardState(n.rd.HardState) {
		d.HS = n.rd.HardState
	}
	if (part == "All" || part == "Snapshot") && !IsEmptySnap(n.rd.Snapshot) {
		d.Snapshot = n.rd.Snapshot
	}
	f, err := os.Create(c.diskPath(n) + ".pending")
	c.must(err)
	c.must(json.NewEncoder(f).Encode(d))
	n.pending = f
	n.batch["started"] = append(n.batch["started"].(sxSet), part)
	c.emit("StartPersist", sxR{"node": id, "part": part})
}
func (c *sxCluster) completePersist(id uint64, part string) {
	n := c.nodes[id]
	c.must(n.pending.Sync())
	c.must(n.pending.Close())
	n.pending = nil
	c.must(os.Rename(c.diskPath(n)+".pending", c.diskPath(n)))
	dir, err := os.Open(c.dir)
	c.must(err)
	c.must(dir.Sync())
	c.must(dir.Close())
	f, err := os.Open(c.diskPath(n))
	c.must(err)
	c.must(json.NewDecoder(f).Decode(&n.disk))
	c.must(f.Close())
	if part == "All" {
		n.batch["done"] = sxSet{"All", "Entries", "HS", "Snapshot"}
	} else {
		n.batch["done"] = append(n.batch["done"].(sxSet), part)
	}
	c.emit("CompletePersist", sxR{"node": id, "part": part})
}
func (c *sxCluster) install(id uint64) {
	n := c.nodes[id]
	if !IsEmptySnap(n.rd.Snapshot) && n.rd.Snapshot.Metadata.Index > n.storage.snapshot.Metadata.Index {
		c.must(n.storage.ApplySnapshot(n.rd.Snapshot))
		n.compacted = sxSnapshot(n.rd.Snapshot)["hist"].(sxSeq)
	}
	n.batch["installed"] = sxSet{"Snapshot"}
	c.emit("StorageApplySnapshot", sxR{"node": id})
	c.must(n.storage.Append(n.rd.Entries))
	n.batch["installed"] = append(n.batch["installed"].(sxSet), "Entries")
	c.emit("StorageAppend", sxR{"node": id})
	if !IsEmptyHardState(n.rd.HardState) {
		c.must(n.storage.SetHardState(n.rd.HardState))
	}
	n.batch["installed"] = append(n.batch["installed"].(sxSet), "HS")
	c.emit("StorageSetHardState", sxR{"node": id})
}
func (c *sxCluster) publish(id uint64) {
	n := c.nodes[id]
	if len(n.remaining) > 0 {
		m := n.remaining[0]
		m.PB = sxCloneMessage(m.PB)
		c.wire = append(c.wire, m)
		c.sent = append(c.sent, m)
		n.remaining = n.remaining[1:]
	}
	n.batch["remainingMessages"], n.batch["published"] = sxBag(n.remaining), len(n.remaining) == 0
	c.emit("Publish", sxR{"node": id})
}
func (c *sxCluster) queue(id uint64) {
	n := c.nodes[id]
	if !IsEmptySnap(n.rd.Snapshot) || len(n.rd.CommittedEntries) > 0 {
		n.jobs = append(n.jobs, sxJob{n.readySeq, n.rd.Snapshot, sxCloneEntries(n.rd.CommittedEntries)})
	}
	n.batch["queued"] = true
	c.emit("QueueApplication", sxR{"node": id})
}
func (c *sxCluster) advance(id uint64) {
	n := c.nodes[id]
	if len(n.jobs) > 0 {
		c.branches["early-advance"]++
	}
	n.call(func() {
		if n.raw != nil {
			n.raw.Advance(n.rd)
		} else {
			n.api.Advance()
		}
	})
	if n.raw != nil {
		// RawNode.Advance combines acceptReady and commitReady.
		n.out = nil
	}
	n.batch = sxEmptyReady()
	n.rd = Ready{}
	n.remaining = nil
	c.emit("Advance", sxR{"node": id})
}
func sxTrackerConfState(p tracker.ProgressTracker) pb.ConfState {
	return pb.ConfState{Nodes: p.Voters[0].Slice(), NodesJoint: p.Voters[1].Slice(), Learners: quorum.MajorityConfig(p.Learners).Slice(), LearnersNext: quorum.MajorityConfig(p.LearnersNext).Slice(), AutoLeave: p.AutoLeave}
}
func sxConfContains(cs pb.ConfState, id uint64) bool {
	return sxContains(cs.Nodes, id) || sxContains(cs.NodesJoint, id) || sxContains(cs.Learners, id) || sxContains(cs.LearnersNext, id)
}
func sxEntryConfV2(e pb.Entry, canceled []uint64, current pb.ConfState) (pb.ConfChangeV2, bool) {
	switch e.Type {
	case pb.EntryConfChange:
		var cc pb.ConfChange
		if err := cc.Unmarshal(e.Data); err != nil {
			panic(err)
		}
		if sxContains(canceled, cc.ID) || (cc.Type == pb.ConfChangeRemoveNode && !sxConfContains(current, cc.NodeID)) {
			cc.NodeID = 0
		}
		return cc.AsV2(), true
	case pb.EntryConfChangeV2:
		var cc pb.ConfChangeV2
		if err := cc.Unmarshal(e.Data); err != nil {
			panic(err)
		}
		if sxContains(canceled, sxCommandID(cc.Context)) {
			for i := range cc.Changes {
				cc.Changes[i].NodeID = 0
			}
		}
		return cc, true
	default:
		return pb.ConfChangeV2{}, false
	}
}
func sxAppConfig(es []pb.Entry, canceled []uint64) pb.ConfState {
	p := tracker.MakeProgressTracker(2)
	for _, e := range es {
		cs := sxTrackerConfState(p)
		cc, ok := sxEntryConfV2(e, canceled, cs)
		if !ok {
			continue
		}
		changer := confchange.Changer{Tracker: p, LastIndex: e.Index}
		var err error
		if cc.LeaveJoint() {
			p.Config, p.Progress, err = changer.LeaveJoint()
		} else if autoLeave, joint := cc.EnterJoint(); joint {
			p.Config, p.Progress, err = changer.EnterJoint(autoLeave, cc.Changes...)
		} else {
			p.Config, p.Progress, err = changer.Simple(cc.Changes...)
		}
		if err != nil {
			panic(err)
		}
	}
	return sxTrackerConfState(p)
}
func (c *sxCluster) applyOne(id uint64) bool {
	n := c.nodes[id]
	if len(n.jobs) == 0 {
		return false
	}
	j := &n.jobs[0]
	if !IsEmptySnap(j.Snapshot) {
		if j.Snapshot.Metadata.Index > uint64(len(n.app)) {
			c.must(json.Unmarshal(j.Snapshot.Data, &n.app))
			n.appCfg = j.Snapshot.Metadata.ConfState
		}
		j.Snapshot = pb.Snapshot{}
		c.emit("ApplySnapshot", sxR{"node": id})
		return true
	}
	if len(j.Entries) > 0 {
		e := j.Entries[0]
		if e.Index > uint64(len(n.app)) {
			if e.Index != uint64(len(n.app)+1) {
				c.t.Fatal("application gap")
			}
			n.app = append(n.app, e)
		}
		if e.Type == pb.EntryConfChange || e.Type == pb.EntryConfChangeV2 {
			cc, _ := sxEntryConfV2(e, c.opts.cancel, n.appCfg)
			if sxEntry(e)["id"].(uint64) != 0 && sxContains(c.opts.cancel, sxEntry(e)["id"].(uint64)) {
				c.branches["canceled-conf-callback"]++
			}
			n.call(func() {
				if n.raw != nil {
					n.raw.ApplyConfChange(cc)
				} else {
					n.api.ApplyConfChange(cc)
				}
			})
			if e.Index > uint64(len(n.cfgHist)) {
				n.cfgHist = sxPrefix(sxEntries(n.app), e.Index)
			}
		}
		n.appCfg = sxAppConfig(n.app, c.opts.cancel)
		j.Entries = j.Entries[1:]
		c.emit("ApplyEntry", sxR{"node": id, "timeout": n.r.randomizedElectionTimeout})
		return true
	}
	n.jobs = n.jobs[1:]
	c.emit("FinishApplication", sxR{"node": id})
	return true
}
func (c *sxCluster) applyAll(id uint64) {
	for c.applyOne(id) {
	}
}
func (c *sxCluster) finishReady(id uint64) {
	n := c.nodes[id]
	parts := []string{"All"}
	if c.opts.persist != "Atomic" {
		parts = []string{"Entries", "HS", "Snapshot"}
	}
	for _, part := range parts {
		c.startPersist(id, part)
		// README permits a leader to publish a new append while the same
		// batch's entries are being saved. Use this only when HardState is
		// unchanged; followers still finish persistence before ACK publication.
		if c.opts.send == "SameBatch" && part == "All" && n.r.state == StateLeader && IsEmptyHardState(n.rd.HardState) && len(n.rd.Entries) > 0 {
			for !n.batch["published"].(bool) {
				c.publish(id)
			}
			c.branches["same-batch-publication-before-fsync"]++
		}
		c.completePersist(id, part)
	}
	c.install(id)
	for !n.batch["published"].(bool) {
		c.publish(id)
	}
	c.queue(id)
	if !c.opts.early || !c.delayApp[id] {
		c.applyAll(id)
	}
	c.advance(id)
}
func (c *sxCluster) deliver(k int) {
	m := c.wire[k]
	c.wire = append(c.wire[:k], c.wire[k+1:]...)
	n := c.nodes[m.PB.To]
	c.receiving = &m
	var err error
	n.call(func() {
		if n.raw != nil {
			err = n.raw.Step(sxCloneMessage(m.PB))
		} else {
			err = n.api.Step(context.Background(), sxCloneMessage(m.PB))
		}
	})
	c.receiving = nil
	if err != nil && err != ErrStepPeerNotFound && err != ErrProposalDropped {
		c.t.Fatal(err)
	}
	c.emit("Receive", sxR{"message": m.Value, "timeout": n.r.randomizedElectionTimeout})
}
func (c *sxCluster) lose(k int) {
	m := c.wire[k]
	c.wire = append(c.wire[:k], c.wire[k+1:]...)
	c.emit("Lose", sxR{"message": m.Value})
}
func (c *sxCluster) duplicate(k int) {
	m := c.wire[k]
	m.PB = sxCloneMessage(m.PB)
	c.wire = append(c.wire, m)
	c.emit("Duplicate", sxR{"message": m.Value})
}
func (c *sxCluster) drain() {
	for step := 0; step < 1500; step++ {
		changed := false
		for _, id := range c.opts.servers {
			if c.ready(id) {
				c.finishReady(id)
				changed = true
			}
		}
		if len(c.wire) > 0 {
			m := c.wire[0]
			if c.blocked[m.PB.From] || c.blocked[m.PB.To] || !c.nodes[m.PB.To].alive || (c.dropMessage != nil && c.dropMessage(m.PB)) {
				c.lose(0)
			} else {
				c.deliver(0)
			}
			changed = true
		}
		if !changed {
			return
		}
	}
	c.t.Fatal("scheduler exceeded finite service bound")
}

// Service public Ready/Step calls until an actually published message of the
// requested type is in the wire. Used to schedule transport status separately
// from snapshot reception; it neither constructs nor changes a message.
func (c *sxCluster) untilMessage(kind pb.MessageType, to uint64) int {
	for step := 0; step < 500; step++ {
		for _, id := range c.opts.servers {
			if c.ready(id) {
				c.finishReady(id)
			}
		}
		for k, m := range c.wire {
			if m.PB.Type == kind && m.PB.To == to {
				return k
			}
		}
		if len(c.wire) == 0 {
			c.t.Fatal("no work before requested transport message")
		}
		m := c.wire[0]
		if c.blocked[m.PB.From] || c.blocked[m.PB.To] || !c.nodes[m.PB.To].alive || (c.dropMessage != nil && c.dropMessage(m.PB)) {
			c.lose(0)
		} else {
			c.deliver(0)
		}
	}
	c.t.Fatal("transport service bound exceeded")
	return -1
}
func (c *sxCluster) save(id uint64) {
	n := c.nodes[id]
	d := n.disk
	d.SavedApp = sxCloneEntries(n.app)
	c.writeImage(n, d)
	c.emit("SaveApplication", sxR{"node": id})
}
func (c *sxCluster) completeWrite(node, id uint64) {
	n := c.nodes[node]
	for k, e := range n.app {
		if e.Type == pb.EntryNormal && sxCommandID(e.Data) == id {
			c.writes = append(c.writes, sxEntries(n.app[:k+1]))
			c.requests[id]["completed"] = true
			c.emit("CompleteWrite", sxR{"node": node, "id": id})
			return
		}
	}
	c.t.Fatal("no applied write to complete")
}
func (c *sxCluster) completeRead(node, id uint64) {
	n := c.nodes[node]
	ctx := sxNumber(c.requests[id]["context"])
	for k, w := range n.reads {
		r := w.(sxR)
		if sxNumber(r["id"]) == ctx {
			if uint64(len(n.app)) < sxNumber(r["index"]) {
				c.t.Fatal("application read fence not reached")
			}
			c.requests[id]["completed"] = true
			c.emit("CompleteRead", sxR{"node": node, "id": id, "position": k + 1})
			return
		}
	}
	c.t.Fatal("no delivered read to complete")
}
func (c *sxCluster) snapshot(id uint64) pb.Snapshot {
	n := c.nodes[id]
	data, err := json.Marshal(n.app)
	c.must(err)
	s, err := n.storage.CreateSnapshot(uint64(len(n.app)), &n.appCfg, data)
	c.must(err)
	c.emit("CreateSnapshot", sxR{"node": id, "index": s.Metadata.Index})
	return s
}
func (c *sxCluster) persistSnapshot(id uint64) {
	n := c.nodes[id]
	d := n.disk
	d.Snapshot = n.storage.snapshot
	c.writeImage(n, d)
	c.emit("PersistLocalSnapshot", sxR{"node": id})
}
func (c *sxCluster) compact(id, index uint64) {
	n := c.nodes[id]
	n.compacted = sxPrefix(n.storeHistory(), index)
	c.must(n.storage.Compact(index))
	c.emit("Compact", sxR{"node": id, "index": index})
}
func (c *sxCluster) available(id uint64, v bool) {
	c.nodes[id].storage.available = v
	c.emit("SnapshotAvailability", sxR{"node": id, "available": v})
}
func (c *sxCluster) report(m sxMessage, failed bool, snapshot bool) {
	id := m.PB.From
	event := "ReportUnreachable"
	p := sxR{"node": id, "message": m.Value}
	if snapshot {
		event = "ReportSnapshot"
		p["failed"] = failed
	}
	c.core(event, id, p, func(n *sxNode) {
		if snapshot {
			status := SnapshotFinish
			if failed {
				status = SnapshotFailure
			}
			if n.raw != nil {
				n.raw.ReportSnapshot(m.PB.To, status)
			} else {
				n.api.ReportSnapshot(m.PB.To, status)
			}
		} else {
			if n.raw != nil {
				n.raw.ReportUnreachable(m.PB.To)
			} else {
				n.api.ReportUnreachable(m.PB.To)
			}
		}
	})
}
func (c *sxCluster) crash(id uint64, stop bool) {
	n := c.nodes[id]
	n.dead = n.capture()
	if n.api != nil {
		n.resume <- struct{}{}
		n.api.Stop()
	}
	if n.pending != nil {
		c.must(n.pending.Close())
		n.pending = nil
	}
	n.alive = false
	n.dead["alive"], n.dead["out"] = false, sxMap{}
	n.out = nil
	n.raw = nil
	n.api = nil
	n.r = nil
	n.app = nil
	n.appCfg = pb.ConfState{}
	n.jobs = nil
	n.reads = sxSeq{}
	n.batch = sxEmptyReady()
	n.rd = Ready{}
	n.remaining = nil
	event := "Crash"
	if stop {
		event = "Stop"
	}
	c.emit(event, sxR{"node": id})
}
func (c *sxCluster) restart(id uint64) {
	n := c.nodes[id]
	f, err := os.Open(c.diskPath(n))
	c.must(err)
	n.disk = sxDiskImage{}
	c.must(json.NewDecoder(f).Decode(&n.disk))
	c.must(f.Close())
	n.storage = &sxStorage{MemoryStorage: NewMemoryStorage(), available: true}
	d := n.disk
	n.compacted = sxSeq{}
	if !IsEmptySnap(d.Snapshot) {
		c.must(n.storage.ApplySnapshot(d.Snapshot))
		n.compacted = sxSnapshot(d.Snapshot)["hist"].(sxSeq)
	}
	keys := []uint64{}
	for k := range d.Log {
		if k > d.Snapshot.Metadata.Index {
			keys = append(keys, k)
		}
	}
	sort.Slice(keys, func(i, j int) bool { return keys[i] < keys[j] })
	es := []pb.Entry{}
	for _, k := range keys {
		es = append(es, d.Log[k])
	}
	c.must(n.storage.Append(es))
	c.must(n.storage.SetHardState(d.HS))
	if c.opts.recovery == "AppliedAdapter" {
		n.app = sxCloneEntries(d.SavedApp)
		cs := sxAppConfig(n.app, c.opts.cancel)
		n.storage.recovered = &cs
	} else if !IsEmptySnap(d.Snapshot) {
		c.must(json.Unmarshal(d.Snapshot.Data, &n.app))
	}
	n.appCfg = sxAppConfig(n.app, c.opts.cancel)
	n.cfgHist = sxEntries(n.app)
	n.reads = sxSeq{}
	n.evidence = map[uint64]sxSeq{}
	n.readInit = map[uint64]sxR{}
	n.decision = ""
	n.readySeq = 0
	n.nodeLead = 0
	n.proposals = false
	n.incarnation++
	n.alive = true
	n.prevSS = &SoftState{}
	n.prevHS = pb.HardState{}
	if sxContains(c.opts.raw, id) {
		n.raw, err = NewRawNode(c.config(n, uint64(len(n.app))))
		c.must(err)
		n.r = n.raw.raft
	} else {
		n.api = RestartNode(c.config(n, uint64(len(n.app))))
		<-n.boundary
	}
	c.emit("Restart", sxR{"node": id, "timeout": n.r.randomizedElectionTimeout})
}
