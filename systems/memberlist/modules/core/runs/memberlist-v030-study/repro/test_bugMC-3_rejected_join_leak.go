// Level 0 (pure black-box) reproduction for MC-3.
//
// Run from the memberlist source worktree:
//
//	timeout 2m go run /absolute/path/to/repro/test_bugMC-3_rejected_join_leak.go
//
// The program uses only exported memberlist configuration, constructors,
// Join, Members, LocalNode, and delegate interfaces. It does not inject state,
// forge protocol messages, call internals, or patch source.
package main

import (
	"errors"
	"fmt"
	"net"
	"os"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/hashicorp/memberlist"
)

var errRejected = errors.New("n1 policy rejects cluster merge")

type rejectingMergeDelegate struct {
	calls atomic.Int32
}

func (d *rejectingMergeDelegate) NotifyMerge(peers []*memberlist.Node) error {
	d.calls.Add(1)
	return errRejected
}

type eventRecorder struct {
	mu    sync.Mutex
	joins []string
}

func (r *eventRecorder) NotifyJoin(n *memberlist.Node) {
	r.mu.Lock()
	r.joins = append(r.joins, n.Name)
	r.mu.Unlock()
}

func (*eventRecorder) NotifyLeave(*memberlist.Node)  {}
func (*eventRecorder) NotifyUpdate(*memberlist.Node) {}

func (r *eventRecorder) sawJoin(name string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, got := range r.joins {
		if got == name {
			return true
		}
	}
	return false
}

func config(name string, events memberlist.EventDelegate, merge memberlist.MergeDelegate) *memberlist.Config {
	c := memberlist.DefaultLocalConfig()
	c.Name = name
	c.BindAddr = "127.0.0.1"
	c.BindPort = 0
	c.AdvertiseAddr = "127.0.0.1"
	c.AdvertisePort = 0
	c.Events = events
	c.Merge = merge
	c.PushPullInterval = 0 // isolate propagation to normal UDP gossip
	c.LogOutput = os.Stdout
	return c
}

func address(m *memberlist.Memberlist) string {
	n := m.LocalNode()
	return net.JoinHostPort(n.Addr.String(), fmt.Sprint(n.Port))
}

func create(name string, events memberlist.EventDelegate, merge memberlist.MergeDelegate) (*memberlist.Memberlist, error) {
	return memberlist.Create(config(name, events, merge))
}

func shutdownAll(nodes ...*memberlist.Memberlist) {
	for i := len(nodes) - 1; i >= 0; i-- {
		if nodes[i] != nil {
			_ = nodes[i].Shutdown()
		}
	}
}

func view(m *memberlist.Memberlist) string {
	nodes := m.Members()
	parts := make([]string, 0, len(nodes))
	for _, n := range nodes {
		parts = append(parts, fmt.Sprintf("%s:%s", n.Name, stateName(n.State)))
	}
	sort.Strings(parts)
	return strings.Join(parts, ",")
}

func stateName(state memberlist.NodeStateType) string {
	switch state {
	case memberlist.StateAlive:
		return "Alive"
	case memberlist.StateSuspect:
		return "Suspect"
	case memberlist.StateDead:
		return "Dead"
	case memberlist.StateLeft:
		return "Left"
	default:
		return fmt.Sprintf("Unknown(%d)", state)
	}
}

func hasAlive(m *memberlist.Memberlist, name string) bool {
	for _, n := range m.Members() {
		if n.Name == name && n.State == memberlist.StateAlive {
			return true
		}
	}
	return false
}

func waitFor(deadline time.Duration, condition func() bool) bool {
	until := time.Now().Add(deadline)
	for time.Now().Before(until) {
		if condition() {
			return true
		}
		time.Sleep(10 * time.Millisecond)
	}
	return condition()
}

func main() {
	fmt.Println("LEVEL=0 public APIs and normal gossip; no timing hooks, injection, or source patch")

	n1Events := &eventRecorder{}
	n3Events := &eventRecorder{}
	reject := &rejectingMergeDelegate{}

	n1, err := create("n1-rejector", n1Events, reject)
	if err != nil {
		fmt.Printf("SETUP_ERROR create n1: %v\n", err)
		os.Exit(2)
	}
	n2, err := create("n2-initiator", nil, nil)
	if err != nil {
		shutdownAll(n1)
		fmt.Printf("SETUP_ERROR create n2: %v\n", err)
		os.Exit(2)
	}
	n3, err := create("n3-observer", n3Events, nil)
	if err != nil {
		shutdownAll(n1, n2)
		fmt.Printf("SETUP_ERROR create n3: %v\n", err)
		os.Exit(2)
	}
	defer shutdownAll(n1, n2, n3)

	// Establish a normal n2/n3 cluster before the rejected cross-cluster join.
	initialSuccess, initialErr := n2.Join([]string{address(n3)})
	if initialErr != nil || initialSuccess != 1 {
		fmt.Printf("SETUP_ERROR n2->n3 join success=%d error=%v\n", initialSuccess, initialErr)
		os.Exit(2)
	}
	if !waitFor(3*time.Second, func() bool {
		return hasAlive(n2, "n3-observer") && hasAlive(n3, "n2-initiator")
	}) {
		fmt.Printf("SETUP_ERROR n2/n3 did not converge n2=[%s] n3=[%s]\n", view(n2), view(n3))
		os.Exit(2)
	}
	fmt.Printf("PRECONDITION n2=[%s] n3=[%s]\n", view(n2), view(n3))

	// n1 rejects n2's offered cluster. The defect lets n2 independently
	// accept n1's already-sent response and report Join success.
	joinSuccess, joinErr := n2.Join([]string{address(n1)})
	rejected := waitFor(time.Second, func() bool { return reject.calls.Load() > 0 })
	fmt.Printf("RESPONDER_REJECTED=%t delegate_calls=%d\n", rejected, reject.calls.Load())
	fmt.Printf("INITIATOR_JOIN_RETURN success=%d error=%v\n", joinSuccess, joinErr)
	fmt.Printf("INITIATOR_VIEW n2=[%s]\n", view(n2))

	// With periodic TCP anti-entropy disabled, observe the queued Alive record
	// arriving at the pre-existing third member through ordinary gossip.
	thirdSawEvent := waitFor(5*time.Second, func() bool {
		return n3Events.sawJoin("n1-rejector")
	})
	thirdHasAlive := hasAlive(n3, "n1-rejector")
	fmt.Printf("THIRD_NODE_EVENT observer=n3 NotifyJoin(n1)=%t\n", thirdSawEvent)
	fmt.Printf("THIRD_NODE_VIEW n3=[%s] contains_n1_alive=%t\n", view(n3), thirdHasAlive)

	// Wait across multiple default-local gossip rounds and at least one probe
	// round. A transient observation would disappear or cease being Alive.
	time.Sleep(1500 * time.Millisecond)
	persistentAtN2 := hasAlive(n2, "n1-rejector")
	persistentAtN3 := hasAlive(n3, "n1-rejector")
	fmt.Printf("AFTER_SETTLE n1=[%s] n2=[%s] n3=[%s]\n", view(n1), view(n2), view(n3))
	fmt.Printf("PERSISTENT initiator_has_n1_alive=%t third_has_n1_alive=%t\n", persistentAtN2, persistentAtN3)

	triggered := rejected &&
		joinSuccess == 1 &&
		joinErr == nil &&
		thirdSawEvent &&
		thirdHasAlive &&
		persistentAtN2 &&
		persistentAtN3
	if !triggered {
		fmt.Println("BUG_NOT_TRIGGERED")
		os.Exit(1)
	}

	fmt.Println("BUG_TRIGGERED: responder rejected the join, but Join returned success and n1's Alive state reached and persisted at n3")
	fmt.Println("EXPECTED: responder rejection is returned to the initiator, and rejected response state is not committed or gossiped")
}
