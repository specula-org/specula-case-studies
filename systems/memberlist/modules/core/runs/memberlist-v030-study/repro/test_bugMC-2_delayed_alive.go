package memberlist_test

import (
	"fmt"
	"log"
	"net"
	"sync"
	"testing"
	"time"

	memberlist "github.com/hashicorp/memberlist"
)

// delayingTransport is a timing-only wrapper. Once armed, it retains the next
// datagram that the real memberlist gossip loop emits instead of placing it on
// the wire. The test later sends those exact bytes to the original destination.
type delayingTransport struct {
	memberlist.NodeAwareTransport

	mu        sync.Mutex
	armed     bool
	held      []byte
	heldDest  memberlist.Address
	heldReady chan struct{}
}

func newDelayingTransport(inner memberlist.NodeAwareTransport) *delayingTransport {
	return &delayingTransport{
		NodeAwareTransport: inner,
		heldReady:          make(chan struct{}),
	}
}

func (d *delayingTransport) arm() {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.armed = true
}

func (d *delayingTransport) WriteTo(b []byte, addr string) (time.Time, error) {
	return d.WriteToAddress(b, memberlist.Address{Addr: addr})
}

func (d *delayingTransport) WriteToAddress(b []byte, addr memberlist.Address) (time.Time, error) {
	d.mu.Lock()
	if d.armed && d.held == nil {
		d.held = append([]byte(nil), b...)
		d.heldDest = addr
		d.armed = false
		close(d.heldReady)
		d.mu.Unlock()
		return time.Now(), nil
	}
	d.mu.Unlock()
	return d.NodeAwareTransport.WriteToAddress(b, addr)
}

func (d *delayingTransport) snapshot() ([]byte, memberlist.Address) {
	d.mu.Lock()
	defer d.mu.Unlock()
	return append([]byte(nil), d.held...), d.heldDest
}

func netTransport(t *testing.T, bindAddr string) *memberlist.NetTransport {
	t.Helper()
	tr, err := memberlist.NewNetTransport(&memberlist.NetTransportConfig{
		BindAddrs: []string{bindAddr},
		BindPort:  0,
		Logger:    log.Default(),
	})
	if err != nil {
		t.Fatalf("create transport on %s: %v", bindAddr, err)
	}
	return tr
}

func baseConfig(name string, transport memberlist.Transport) *memberlist.Config {
	c := memberlist.DefaultLocalConfig()
	c.Name = name
	c.Transport = transport
	c.BindPort = 0
	c.AdvertisePort = 0
	c.EnableCompression = false
	c.PushPullInterval = 0
	c.IndirectChecks = 0
	c.DisableTcpPings = true
	c.ProbeTimeout = 10 * time.Millisecond
	c.ProbeInterval = 50 * time.Millisecond
	c.SuspicionMult = 1
	c.SuspicionMaxTimeoutMult = 1
	c.GossipToTheDeadTime = 50 * time.Millisecond
	return c
}

func waitMember(t *testing.T, m *memberlist.Memberlist, name string, timeout time.Duration) *memberlist.Node {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		for _, n := range m.Members() {
			if n.Name == name {
				copy := *n
				copy.Addr = append(net.IP(nil), n.Addr...)
				return &copy
			}
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("%s did not expose member %s within %s", m.LocalNode().Name, name, timeout)
	return nil
}

func waitMemberAbsent(t *testing.T, m *memberlist.Memberlist, name string, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		found := false
		for _, n := range m.Members() {
			if n.Name == name {
				found = true
				break
			}
		}
		if !found {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("%s still exposes member %s after %s", m.LocalNode().Name, name, timeout)
}

func hasMember(m *memberlist.Memberlist, name string) bool {
	for _, n := range m.Members() {
		if n.Name == name {
			return true
		}
	}
	return false
}

func waitEvent(t *testing.T, events <-chan memberlist.NodeEvent, kind memberlist.NodeEventType, name string, timeout time.Duration) memberlist.NodeEvent {
	t.Helper()
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	for {
		select {
		case event := <-events:
			if event.Event == kind && event.Node.Name == name {
				return event
			}
		case <-timer.C:
			t.Fatalf("did not receive event kind=%d for %s within %s", kind, name, timeout)
		}
	}
}

func releaseDatagram(t *testing.T, payload []byte, destination string) {
	t.Helper()
	conn, err := net.Dial("udp", destination)
	if err != nil {
		t.Fatalf("dial observer UDP address: %v", err)
	}
	defer conn.Close()
	if _, err := conn.Write(payload); err != nil {
		t.Fatalf("release captured datagram: %v", err)
	}
}

func level0WithoutTimingControl(t *testing.T) {
	const (
		subjectName  = "level0-subject"
		observerName = "level0-observer"
	)

	events := make(chan memberlist.NodeEvent, 32)
	oldConfig := baseConfig(subjectName, netTransport(t, "127.0.0.1"))
	oldConfig.ProbeInterval = 0
	oldConfig.GossipInterval = 20 * time.Millisecond
	oldConfig.GossipNodes = 1
	oldSubject, err := memberlist.Create(oldConfig)
	if err != nil {
		t.Fatalf("level 0 create old subject: %v", err)
	}

	observerConfig := baseConfig(observerName, netTransport(t, "127.0.0.1"))
	observerConfig.GossipInterval = 0
	observerConfig.Events = &memberlist.ChannelEventDelegate{Ch: events}
	observer, err := memberlist.Create(observerConfig)
	if err != nil {
		_ = oldSubject.Shutdown()
		t.Fatalf("level 0 create observer: %v", err)
	}
	defer observer.Shutdown()

	if _, err := oldSubject.Join([]string{observer.LocalNode().Address()}); err != nil {
		_ = oldSubject.Shutdown()
		t.Fatalf("level 0 join: %v", err)
	}
	_ = waitMember(t, observer, subjectName, 2*time.Second)

	// With an ordinary loopback transport, pre-restart gossip is delivered
	// promptly. There is no black-box API that asks the network to retain one
	// selected UDP datagram through the failure-detection/reap interval.
	time.Sleep(100 * time.Millisecond)
	if err := oldSubject.Shutdown(); err != nil {
		t.Fatalf("level 0 shutdown old subject: %v", err)
	}
	waitEvent(t, events, memberlist.NodeLeave, subjectName, 3*time.Second)
	waitMemberAbsent(t, observer, subjectName, time.Second)
	time.Sleep(300 * time.Millisecond)

	restartConfig := baseConfig(subjectName, netTransport(t, "127.0.0.2"))
	restartConfig.ProbeInterval = 0
	restartConfig.GossipInterval = 0
	restarted, err := memberlist.Create(restartConfig)
	if err != nil {
		t.Fatalf("level 0 create restarted subject: %v", err)
	}
	defer restarted.Shutdown()

	time.Sleep(200 * time.Millisecond)
	if hasMember(observer, subjectName) {
		t.Fatal("level 0 unexpectedly retained or resurrected the old subject")
	}
	fmt.Printf("LEVEL=0 standard loopback Create/Join/Shutdown/Create: trigger_not_observed (no packet-delay control)\n")
}

func TestBugMC2DelayedPreRestartAlive(t *testing.T) {
	const (
		subjectName  = "subject"
		observerName = "observer"
	)

	level0WithoutTimingControl(t)

	events := make(chan memberlist.NodeEvent, 32)

	oldBase := netTransport(t, "127.0.0.1")
	delayed := newDelayingTransport(oldBase)
	oldConfig := baseConfig(subjectName, delayed)
	oldConfig.ProbeInterval = 0
	oldConfig.GossipInterval = time.Second
	oldConfig.GossipNodes = 1
	oldSubject, err := memberlist.Create(oldConfig)
	if err != nil {
		t.Fatalf("create old subject: %v", err)
	}

	observerConfig := baseConfig(observerName, netTransport(t, "127.0.0.1"))
	observerConfig.GossipInterval = 0
	observerConfig.Events = &memberlist.ChannelEventDelegate{Ch: events}
	observer, err := memberlist.Create(observerConfig)
	if err != nil {
		_ = oldSubject.Shutdown()
		t.Fatalf("create observer: %v", err)
	}
	defer observer.Shutdown()

	if _, err := oldSubject.Join([]string{observer.LocalNode().Address()}); err != nil {
		_ = oldSubject.Shutdown()
		t.Fatalf("join old subject to observer: %v", err)
	}
	initial := waitMember(t, observer, subjectName, 2*time.Second)
	oldAddress := initial.Address()

	// The subject's initial incarnation-1 Alive is still queued after Join.
	// Arm before the first one-second gossip tick and retain the real packet.
	delayed.arm()
	select {
	case <-delayed.heldReady:
	case <-time.After(3 * time.Second):
		_ = oldSubject.Shutdown()
		t.Fatal("old subject did not emit its queued Alive gossip")
	}
	held, heldDest := delayed.snapshot()
	if len(held) == 0 {
		_ = oldSubject.Shutdown()
		t.Fatal("captured gossip datagram is empty")
	}
	if heldDest.Addr != observer.LocalNode().Address() {
		_ = oldSubject.Shutdown()
		t.Fatalf("captured datagram destination=%s, want observer=%s", heldDest.Addr, observer.LocalNode().Address())
	}

	if err := oldSubject.Shutdown(); err != nil {
		t.Fatalf("shutdown old subject: %v", err)
	}

	// The real failure detector marks the old lifetime dead. Waiting well past
	// GossipToTheDeadTime and several probe-index wraps lets resetNodes reap it.
	waitEvent(t, events, memberlist.NodeLeave, subjectName, 3*time.Second)
	waitMemberAbsent(t, observer, subjectName, time.Second)
	time.Sleep(500 * time.Millisecond)

	restartConfig := baseConfig(subjectName, netTransport(t, "127.0.0.2"))
	restartConfig.ProbeInterval = 0
	restartConfig.GossipInterval = 0
	restarted, err := memberlist.Create(restartConfig)
	if err != nil {
		t.Fatalf("create restarted subject: %v", err)
	}
	defer restarted.Shutdown()
	currentAddress := restarted.LocalNode().Address()
	if currentAddress == oldAddress {
		t.Fatalf("restart did not change address: both lifetimes use %s", currentAddress)
	}

	// Release the exact pre-crash packet through the normal UDP decoder.
	releaseDatagram(t, held, observer.LocalNode().Address())
	join := waitEvent(t, events, memberlist.NodeJoin, subjectName, 2*time.Second)
	wrong := waitMember(t, observer, subjectName, time.Second)

	fmt.Printf("LEVEL=1 timing-only delayed datagram; public Create/Join/Shutdown/Create APIs\n")
	fmt.Printf("CAPTURED pre-restart gossip bytes=%d destination=%s old_address=%s\n", len(held), heldDest.Addr, oldAddress)
	fmt.Printf("RESTART current_process_address=%s\n", currentAddress)
	fmt.Printf("OBSERVER NotifyJoin name=%s accepted_address=%s\n", join.Node.Name, join.Node.Address())
	fmt.Printf("BUG Members() name=%s address=%s expected_current=%s\n", wrong.Name, wrong.Address(), currentAddress)

	if wrong.Address() != oldAddress {
		t.Fatalf("observer accepted address %s, want captured old address %s", wrong.Address(), oldAddress)
	}
	if wrong.Address() == currentAddress {
		t.Fatalf("observer unexpectedly learned the restarted process address %s", currentAddress)
	}

	// Prove the downstream mask actually fires: the normal probe/suspicion
	// machinery detects that the retired address is unreachable and removes it.
	waitEvent(t, events, memberlist.NodeLeave, subjectName, 3*time.Second)
	waitMemberAbsent(t, observer, subjectName, time.Second)
	fmt.Printf("MASK probe/suspicion emitted NotifyLeave and Members() removed stale address=%s\n", oldAddress)
}
