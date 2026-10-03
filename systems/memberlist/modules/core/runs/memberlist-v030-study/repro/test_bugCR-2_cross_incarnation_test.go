package memberlist_test

import (
	"encoding/binary"
	"fmt"
	"io"
	"math"
	"net"
	"sync"
	"testing"
	"time"

	memberlist "github.com/hashicorp/memberlist"
)

// gateTransport models ordinary selective packet loss while leaving all
// memberlist message production, encoding, validation, and handling unchanged.
// Every delivered suspicion in this test is produced by a real memberlist
// probe; the transport never constructs or injects protocol messages.
type gateTransport struct {
	memberlist.NodeAwareTransport
	mu              sync.RWMutex
	blocked         map[string]bool
	dropDirectAlive map[string]bool
	suspectSent     chan time.Time
}

func newGateTransport(t memberlist.NodeAwareTransport) *gateTransport {
	return &gateTransport{
		NodeAwareTransport: t,
		blocked:            make(map[string]bool),
		dropDirectAlive:    make(map[string]bool),
		suspectSent:        make(chan time.Time, 32),
	}
}

func containsWireType(buf []byte, wanted byte) bool {
	if len(buf) >= 6 && buf[0] == 12 { // hasCrcMsg
		buf = buf[5:]
	}
	if len(buf) == 0 {
		return false
	}
	if buf[0] == wanted {
		return true
	}
	if buf[0] != 7 || len(buf) < 2 { // compoundMsg
		return false
	}
	count := int(buf[1])
	if len(buf) < 2+2*count {
		return false
	}
	lengths := buf[2 : 2+2*count]
	parts := buf[2+2*count:]
	for i := 0; i < count; i++ {
		n := int(binary.BigEndian.Uint16(lengths[2*i : 2*i+2]))
		if n > len(parts) {
			return false
		}
		if n > 0 && parts[0] == wanted {
			return true
		}
		parts = parts[n:]
	}
	return false
}

func (g *gateTransport) dropAlive(node string, drop bool) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.dropDirectAlive[node] = drop
}

func (g *gateTransport) block(node string, blocked bool) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.blocked[node] = blocked
}

func (g *gateTransport) isBlocked(node string) bool {
	g.mu.RLock()
	defer g.mu.RUnlock()
	return g.blocked[node]
}

func (g *gateTransport) WriteToAddress(buf []byte, addr memberlist.Address) (time.Time, error) {
	if containsWireType(buf, 3) { // suspectMsg
		select {
		case g.suspectSent <- time.Now():
		default:
		}
	}
	if g.isBlocked(addr.Name) || g.isBlocked(addr.Addr) {
		// A UDP drop is a successful local write from the sender's point of
		// view. This also lets the normal bounded broadcast queue age out.
		return time.Now(), nil
	}
	g.mu.RLock()
	dropAlive := g.dropDirectAlive[addr.Name] || g.dropDirectAlive[addr.Addr]
	g.mu.RUnlock()
	// aliveMsg has stable on-wire type 4. Drop the whole datagram whenever
	// it carries that update (standalone or piggybacked), exactly as a
	// network can; the packet itself is never altered.
	if dropAlive && containsWireType(buf, 4) {
		return time.Now(), nil
	}
	return g.NodeAwareTransport.WriteToAddress(buf, addr)
}

func (g *gateTransport) WriteTo(buf []byte, addr string) (time.Time, error) {
	return g.NodeAwareTransport.WriteTo(buf, addr)
}

func (g *gateTransport) DialAddressTimeout(addr memberlist.Address, timeout time.Duration) (net.Conn, error) {
	if g.isBlocked(addr.Name) || g.isBlocked(addr.Addr) {
		return nil, fmt.Errorf("selective partition to %s", addr.Name)
	}
	return g.NodeAwareTransport.DialAddressTimeout(addr, timeout)
}

type metaDelegate struct {
	mu   sync.RWMutex
	meta string
}

func (d *metaDelegate) set(v string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.meta = v
}

func (d *metaDelegate) NodeMeta(int) []byte {
	d.mu.RLock()
	defer d.mu.RUnlock()
	return []byte(d.meta)
}
func (*metaDelegate) NotifyMsg([]byte)                {}
func (*metaDelegate) GetBroadcasts(int, int) [][]byte { return nil }
func (*metaDelegate) LocalState(bool) []byte          { return nil }
func (*metaDelegate) MergeRemoteState([]byte, bool)   {}

func waitFor(t *testing.T, timeout time.Duration, what string, fn func() bool) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if fn() {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

func member(ml *memberlist.Memberlist, name string) *memberlist.Node {
	for _, n := range ml.Members() {
		if n.Name == name {
			return n
		}
	}
	return nil
}

func drainTimes(ch <-chan time.Time) {
	for {
		select {
		case <-ch:
		default:
			return
		}
	}
}

func TestBugCR2CrossIncarnationEvidenceAcceleratesOldTimer(t *testing.T) {
	const (
		observer  = "observer"
		confirmer = "confirmer"
		subject   = "subject"

		probeInterval = 500 * time.Millisecond
	)

	network := &memberlist.MockNetwork{}
	transports := map[string]*gateTransport{}
	events := map[string]chan memberlist.NodeEvent{}
	lists := map[string]*memberlist.Memberlist{}
	subjectMeta := &metaDelegate{meta: "epoch-1"}

	makeNode := func(name string, probeEvery time.Duration, delegate memberlist.Delegate) *memberlist.Memberlist {
		base := network.NewTransport(name)
		gate := newGateTransport(base)
		transports[name] = gate

		eventCh := make(chan memberlist.NodeEvent, 64)
		events[name] = eventCh

		cfg := memberlist.DefaultLANConfig()
		cfg.Name = name
		cfg.Transport = gate
		cfg.Events = &memberlist.ChannelEventDelegate{Ch: eventCh}
		cfg.Delegate = delegate
		cfg.ProbeInterval = probeEvery
		cfg.ProbeTimeout = probeEvery / 2
		cfg.IndirectChecks = 0
		cfg.DisableTcpPings = true
		cfg.GossipInterval = 50 * time.Millisecond
		cfg.PushPullInterval = 0
		cfg.SuspicionMult = 3 // k=1 in this three-member cluster.
		cfg.SuspicionMaxTimeoutMult = 20
		cfg.RetransmitMult = 2
		cfg.AwarenessMaxMultiplier = 0
		cfg.EnableCompression = false
		cfg.LogOutput = io.Discard

		ml, err := memberlist.Create(cfg)
		if err != nil {
			t.Fatalf("create %s: %v", name, err)
		}
		lists[name] = ml
		return ml
	}

	o := makeNode(observer, probeInterval, nil)
	time.Sleep(75 * time.Millisecond)
	// Keep these nodes' first probe outside the brief alive-filter window.
	c := makeNode(confirmer, 200*time.Millisecond, nil)
	time.Sleep(75 * time.Millisecond)
	s := makeNode(subject, probeInterval, subjectMeta)
	defer func() {
		for _, name := range []string{subject, confirmer, observer} {
			if err := lists[name].Shutdown(); err != nil {
				t.Errorf("shutdown %s: %v", name, err)
			}
		}
	}()

	if _, err := c.Join([]string{o.LocalNode().Address()}); err != nil {
		t.Fatalf("join confirmer: %v", err)
	}
	if _, err := s.Join([]string{o.LocalNode().Address()}); err != nil {
		t.Fatalf("join subject: %v", err)
	}
	waitFor(t, 3*time.Second, "three-node convergence", func() bool {
		return o.NumMembers() == 3 && c.NumMembers() == 3 && s.NumMembers() == 3
	})

	// Ignore setup join events so the next observer event is attributable
	// solely to the suspicion sequence below.
	for _, ch := range events {
	drain:
		for {
			select {
			case <-ch:
			default:
				break drain
			}
		}
	}

	// UpdateNode is the real API transition to the next incarnation. Let the
	// confirmer receive epoch-2 but selectively hide it from the observer.
	// Temporarily drop only standalone alive datagrams from
	// confirmer->observer so the bounded re-gossip ages out without
	// disturbing pings or acknowledgements.
	transports[subject].dropAlive(observer, true)
	transports[subject].dropAlive(o.LocalNode().Address(), true)
	transports[confirmer].dropAlive(observer, true)
	transports[confirmer].dropAlive(o.LocalNode().Address(), true)
	subjectMeta.set("epoch-2")
	if err := s.UpdateNode(2 * time.Second); err != nil {
		t.Fatalf("subject UpdateNode: %v", err)
	}
	waitFor(t, 2*time.Second, "confirmer to learn epoch-2", func() bool {
		n := member(c, subject)
		return n != nil && string(n.Meta) == "epoch-2"
	})
	if n := member(o, subject); n == nil || string(n.Meta) != "epoch-1" {
		t.Fatalf("observer unexpectedly learned updated epoch: %#v", n)
	}
	time.Sleep(150 * time.Millisecond)
	// Keep filtering only standalone epoch-2 alive datagrams through the
	// trigger. Pings and acknowledgements remain connected in both
	// directions; only observer->subject is partitioned below.

	// The observer now loses connectivity to subject and starts a genuine
	// old-epoch suspicion through its normal periodic probe.
	drainTimes(transports[observer].suspectSent)
	transports[observer].block(subject, true)
	transports[observer].block(s.LocalNode().Address(), true)
	var oldTimerStarted time.Time
	select {
	case oldTimerStarted = <-transports[observer].suspectSent:
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for observer's old-epoch suspicion broadcast")
	}

	// Age the old timer beyond the minimum timeout. It remains live because
	// its unconfirmed maximum is 10x the minimum.
	minimum := time.Duration(float64(3*probeInterval) * math.Log(4))
	time.Sleep(minimum + 150*time.Millisecond)

	// Only now isolate the confirmer from subject. Its normal probe creates
	// a legitimate Suspect for the newer incarnation it learned above.
	drainTimes(transports[confirmer].suspectSent)
	transports[confirmer].block(subject, true)
	transports[confirmer].block(s.LocalNode().Address(), true)
	var newEpochSuspicionSeen time.Time
	select {
	case newEpochSuspicionSeen = <-transports[confirmer].suspectSent:
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for confirmer's epoch-2 suspicion broadcast")
	}

	var leave memberlist.NodeEvent
	deadlineForLeave := time.After(1 * time.Second)
	for leave.Node == nil {
		select {
		case event := <-events[observer]:
			if event.Event == memberlist.NodeLeave && event.Node.Name == subject {
				leave = event
			}
		case <-deadlineForLeave:
			t.Fatal("observer did not emit a subject leave event")
		}
	}
	delayFromNewEpoch := time.Since(newEpochSuspicionSeen)
	if delayFromNewEpoch >= minimum {
		t.Fatalf("death was not accelerated across epochs: delay=%s minimum=%s", delayFromNewEpoch, minimum)
	}
	if string(leave.Node.Meta) != "epoch-1" {
		t.Fatalf("leave did not carry the observer's stale epoch: %#v", leave.Node)
	}
	if local := s.LocalNode(); local.State != memberlist.StateAlive || string(local.Meta) != "epoch-2" {
		t.Fatalf("subject was not alive in its newer epoch: %#v", local)
	}

	fmt.Printf("LEVEL 0: exported MockNetwork transport + Join + UpdateNode + normal probes\n")
	fmt.Printf("observer view before trigger: state=suspect meta=epoch-1\n")
	fmt.Printf("confirmer view before trigger: state=suspect meta=epoch-2\n")
	fmt.Printf("minimum timeout for a fresh epoch: %s\n", minimum)
	fmt.Printf("old timer age at epoch-2 suspicion: %s\n", newEpochSuspicionSeen.Sub(oldTimerStarted))
	fmt.Printf("observer leave delay after epoch-2 suspicion: %s\n", delayFromNewEpoch)
	fmt.Printf("consumer event: type=leave node=subject state=dead meta=%s\n", leave.Node.Meta)
	fmt.Printf("subject local state at leave: state=alive meta=%s\n", s.LocalNode().Meta)
	fmt.Printf("BUG: higher-incarnation evidence expired the old epoch before a fresh epoch's minimum timeout\n")

	// Demonstrate the distinction between membership convergence and consumer
	// harm. Healing allows refutation and a later join notification, but the
	// already-delivered leave event is not retracted from the consumer.
	transports[observer].block(subject, false)
	transports[observer].block(s.LocalNode().Address(), false)
	transports[subject].dropAlive(observer, false)
	transports[subject].dropAlive(o.LocalNode().Address(), false)
	transports[confirmer].dropAlive(observer, false)
	transports[confirmer].dropAlive(o.LocalNode().Address(), false)
	transports[confirmer].block(subject, false)
	transports[confirmer].block(s.LocalNode().Address(), false)

	var automaticJoin bool
	automaticDeadline := time.After(1 * time.Second)
automaticWait:
	for {
		select {
		case event := <-events[observer]:
			if event.Event == memberlist.NodeJoin && event.Node.Name == subject {
				automaticJoin = true
				break automaticWait
			}
		case <-automaticDeadline:
			break automaticWait
		}
	}

	joinObserved := automaticJoin
	if !joinObserved {
		// A later real update/refutation can repair the membership snapshot,
		// but cannot retract the event already delivered to the application.
		subjectMeta.set("epoch-3")
		if err := s.UpdateNode(2 * time.Second); err != nil {
			t.Fatalf("subject recovery UpdateNode: %v", err)
		}
		deadline := time.After(3 * time.Second)
		for !joinObserved {
			select {
			case event := <-events[observer]:
				if event.Event == memberlist.NodeJoin && event.Node.Name == subject {
					joinObserved = true
				}
			case <-deadline:
				t.Fatal("explicit subject update did not restore observer membership")
			}
		}
	}
	fmt.Printf("downstream convergence: automatic_after_heal=%t eventual_join=true; prior leave event remains delivered\n", automaticJoin)
}
