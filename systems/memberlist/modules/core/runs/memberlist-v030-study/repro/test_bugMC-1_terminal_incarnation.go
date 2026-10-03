// Copyright IBM Corp. 2013, 2026
// SPDX-License-Identifier: MPL-2.0

package memberlist

import (
	"fmt"
	"io"
	"net"
	"sync"
	"testing"
	"time"
)

type mc1Events struct {
	mu     sync.Mutex
	joins  int
	leaves int
}

func (e *mc1Events) NotifyJoin(*Node) {
	e.mu.Lock()
	e.joins++
	e.mu.Unlock()
}

func (e *mc1Events) NotifyLeave(*Node) {
	e.mu.Lock()
	e.leaves++
	e.mu.Unlock()
}

func (e *mc1Events) NotifyUpdate(*Node) {}

func (e *mc1Events) reset() {
	e.mu.Lock()
	e.joins = 0
	e.leaves = 0
	e.mu.Unlock()
}

func (e *mc1Events) counts() (int, int) {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.joins, e.leaves
}

func mc1Config(name string) *Config {
	c := DefaultLANConfig()
	c.Name = name
	c.BindAddr = "127.0.0.1"
	c.BindPort = 0
	c.AdvertiseAddr = "127.0.0.1"
	c.AdvertisePort = 0
	c.LogOutput = io.Discard
	c.ProbeInterval = 20 * time.Millisecond
	c.ProbeTimeout = 5 * time.Millisecond
	c.SuspicionMult = 1
	c.SuspicionMaxTimeoutMult = 1
	c.IndirectChecks = 0
	c.DisableTcpPings = true
	c.GossipInterval = 5 * time.Millisecond
	c.GossipNodes = 3
	c.PushPullInterval = 0
	return c
}

func mc1Create(t *testing.T, c *Config) *Memberlist {
	t.Helper()
	m, err := Create(c)
	if err != nil {
		t.Fatalf("Create(%s): %v", c.Name, err)
	}
	t.Cleanup(func() { _ = m.Shutdown() })
	return m
}

func mc1HasMember(m *Memberlist, name string) bool {
	for _, node := range m.Members() {
		if node.Name == name {
			return true
		}
	}
	return false
}

func mc1Wait(t *testing.T, timeout time.Duration, what string, fn func() bool) {
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

// Level 0 uses only Create, Join, Shutdown, and Members. It establishes that a
// simple crash is handled, but cannot create the cross-observer incarnation
// skew needed by MC-1.
func mc1Level0(t *testing.T) {
	victim := mc1Create(t, mc1Config("mc1-l0-victim"))
	observer := mc1Create(t, mc1Config("mc1-l0-observer"))

	if _, err := observer.Join([]string{victim.LocalNode().Address()}); err != nil {
		t.Fatalf("Level 0 Join: %v", err)
	}
	mc1Wait(t, 2*time.Second, "Level 0 membership convergence", func() bool {
		return mc1HasMember(observer, "mc1-l0-victim")
	})

	if err := victim.Shutdown(); err != nil {
		t.Fatalf("Level 0 victim Shutdown: %v", err)
	}
	mc1Wait(t, 2*time.Second, "Level 0 crash detection", func() bool {
		return !mc1HasMember(observer, "mc1-l0-victim")
	})
	time.Sleep(100 * time.Millisecond)
	if mc1HasMember(observer, "mc1-l0-victim") {
		t.Fatal("Level 0 unexpectedly resurrected the crashed victim")
	}
	fmt.Println("LEVEL 0: public Create/Join/Shutdown/Members handled a simple crash; no higher-terminal ordering, no trigger")
}

// Level 1 adds timing pressure around a public UpdateNode and crash in a
// three-node cluster. Localhost delivery does not provide the selective
// reordering needed to put Dead(2) before a delayed Alive(2).
func mc1Level1(t *testing.T) {
	victim := mc1Create(t, mc1Config("mc1-l1-victim"))
	observerA := mc1Create(t, mc1Config("mc1-l1-observer-a"))
	observerB := mc1Create(t, mc1Config("mc1-l1-observer-b"))

	if _, err := observerA.Join([]string{victim.LocalNode().Address()}); err != nil {
		t.Fatalf("Level 1 observer A Join: %v", err)
	}
	if _, err := observerB.Join([]string{
		victim.LocalNode().Address(),
		observerA.LocalNode().Address(),
	}); err != nil {
		t.Fatalf("Level 1 observer B Join: %v", err)
	}
	mc1Wait(t, 2*time.Second, "Level 1 observers learning victim", func() bool {
		return mc1HasMember(observerA, "mc1-l1-victim") &&
			mc1HasMember(observerB, "mc1-l1-victim")
	})

	if err := victim.UpdateNode(time.Second); err != nil {
		t.Fatalf("Level 1 UpdateNode: %v", err)
	}
	// Timing assistance only: crash immediately after the incarnation-raising
	// alive broadcast is accepted for transmission.
	if err := victim.Shutdown(); err != nil {
		t.Fatalf("Level 1 victim Shutdown: %v", err)
	}
	mc1Wait(t, 2*time.Second, "Level 1 crash detection", func() bool {
		return !mc1HasMember(observerA, "mc1-l1-victim") &&
			!mc1HasMember(observerB, "mc1-l1-victim")
	})

	time.Sleep(200 * time.Millisecond)
	if mc1HasMember(observerA, "mc1-l1-victim") ||
		mc1HasMember(observerB, "mc1-l1-victim") {
		t.Fatal("Level 1 timing run unexpectedly resurrected the crashed victim")
	}
	fmt.Println("LEVEL 1: public UpdateNode + immediate Shutdown + sleeps did not trigger on localhost; selective packet ordering was not obtained")
}

func mc1TakeBroadcast(t *testing.T, m *Memberlist, want messageType) []byte {
	t.Helper()
	msgs := m.getBroadcasts(compoundOverhead, m.config.UDPBufferSize)
	if len(msgs) != 1 {
		t.Fatalf("%s: expected one membership broadcast, got %d", m.config.Name, len(msgs))
	}
	msg := append([]byte(nil), msgs[0]...)
	if len(msg) < 2 || messageType(msg[0]) != want {
		t.Fatalf("%s: expected message type %d, got %v", m.config.Name, want, msg)
	}
	// The reproduction explicitly delivers every retained copy below, so the
	// sender's bounded retransmit queue is exhausted at the chosen trace point.
	m.broadcasts.Reset()
	return msg
}

func mc1DeliverAlive(t *testing.T, m *Memberlist, msg []byte) {
	t.Helper()
	if len(msg) < 2 || messageType(msg[0]) != aliveMsg {
		t.Fatalf("not an alive broadcast: %v", msg)
	}
	m.handleAlive(msg[1:], &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 7946})
}

func mc1DeliverDead(t *testing.T, m *Memberlist, msg []byte) {
	t.Helper()
	if len(msg) < 2 || messageType(msg[0]) != deadMsg {
		t.Fatalf("not a dead broadcast: %v", msg)
	}
	m.handleDead(msg[1:], &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 7946})
}

// Level 2 instantiates the admissible terminalization steps from the
// counterexample. Unlike a hand-built alive packet, Alive(2) below is emitted
// by the real public UpdateNode API, held in the actual broadcast encoding,
// and delivered through the normal decoder after the real node has crashed.
func mc1Level2(t *testing.T) {
	events := &mc1Events{}

	isolated := func(name string) *Config {
		c := mc1Config(name)
		c.ProbeInterval = 0
		c.GossipInterval = 0
		c.PushPullInterval = 0
		return c
	}
	victim := mc1Create(t, isolated("mc1-l2-victim"))
	observerConfig := isolated("mc1-l2-observer")
	observerConfig.Events = events
	observer := mc1Create(t, observerConfig)
	accuser := mc1Create(t, isolated("mc1-l2-accuser"))

	// Each freshly created node queued its own Alive(1). Preserve the victim's
	// real packet and discard unrelated self-announcements.
	alive1 := mc1TakeBroadcast(t, victim, aliveMsg)
	observer.broadcasts.Reset()
	accuser.broadcasts.Reset()
	events.reset()

	mc1DeliverAlive(t, observer, alive1)
	mc1DeliverAlive(t, accuser, alive1)
	observer.broadcasts.Reset()
	accuser.broadcasts.Reset()
	events.reset()

	// Public UpdateNode advances the victim to incarnation 2 and emits the
	// exact legitimate alive packet that will be delayed.
	if err := victim.UpdateNode(0); err != nil {
		t.Fatalf("Level 2 victim UpdateNode: %v", err)
	}
	delayedAlive2 := mc1TakeBroadcast(t, victim, aliveMsg)
	mc1DeliverAlive(t, accuser, delayedAlive2)
	accuser.broadcasts.Reset()

	// A real crash after Alive(2) was emitted: Shutdown deliberately sends no
	// leave packet.
	if err := victim.Shutdown(); err != nil {
		t.Fatalf("Level 2 victim Shutdown: %v", err)
	}

	// These two local failure-detector outcomes instantiate the CE's
	// MCSuspicionExpire steps: State 11 gives observer Dead(1), while State 15
	// gives accuser Dead(2). deadNode creates the production broadcast.
	observer.deadNode(&dead{
		Incarnation: 1,
		Node:        "mc1-l2-victim",
		From:        "mc1-l2-observer",
	})
	observer.broadcasts.Reset()
	accuser.deadNode(&dead{
		Incarnation: 2,
		Node:        "mc1-l2-victim",
		From:        "mc1-l2-accuser",
	})
	dead2 := mc1TakeBroadcast(t, accuser, deadMsg)

	// State 17 delivers the higher terminal record to an already-dead
	// observer. Deliver several copies before Alive(2), modeling exhaustion of
	// the bounded retransmission budget. Every copy takes the same bad return.
	for i := 0; i < 4; i++ {
		mc1DeliverDead(t, observer, dead2)
	}

	observer.nodeLock.RLock()
	afterDead := observer.nodeMap["mc1-l2-victim"]
	gotState := afterDead.State
	gotInc := afterDead.Incarnation
	observer.nodeLock.RUnlock()
	if gotState != StateDead || gotInc != 1 {
		t.Fatalf("expected buggy retained Dead(1), got state=%v incarnation=%d", gotState, gotInc)
	}
	fmt.Printf("LEVEL 2: CE State 17 delivered Dead(2) four times to retained Dead(1); stored state=%v incarnation=%d\n", gotState, gotInc)

	// The packet was emitted before the terminal messages and the sender has
	// since crashed. Because the retained incarnation is stale, Alive(2)
	// passes aliveNode's <= guard and is exposed to real consumers.
	mc1DeliverAlive(t, observer, delayedAlive2)
	if !mc1HasMember(observer, "mc1-l2-victim") {
		t.Fatal("Members() did not expose the resurrected crashed victim")
	}
	joins, leaves := events.counts()
	if joins != 1 || leaves != 1 {
		t.Fatalf("expected one leave and one spurious rejoin, got joins=%d leaves=%d", joins, leaves)
	}
	fmt.Printf("BUG: delayed Alive(2) resurrected the crashed victim; Members() contains victim=true, NotifyJoin=%d, NotifyLeave=%d\n", joins, leaves)

	// With legal zero intervals, and with the accuser's bounded dead queue
	// exhausted before the delayed alive, no sync/probe/resend corrects it.
	time.Sleep(250 * time.Millisecond)
	if !mc1HasMember(observer, "mc1-l2-victim") {
		t.Fatal("a downstream mechanism corrected the resurrected record")
	}
	joinsAfter, leavesAfter := events.counts()
	if joinsAfter != 1 || leavesAfter != 1 {
		t.Fatalf("unexpected downstream events joins=%d leaves=%d", joinsAfter, leavesAfter)
	}
	fmt.Println("PERMANENCE: after 250ms the crashed victim remains in Members(); probe/gossip/push-pull are legally disabled and all Dead(2) copies preceded Alive(2)")
}

func TestBugMC1TerminalIncarnation(t *testing.T) {
	mc1Level0(t)
	mc1Level1(t)
	mc1Level2(t)
}
