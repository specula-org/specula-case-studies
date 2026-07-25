package blocksync

import (
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/cometbft/cometbft/libs/log"
	tlatrace "github.com/cometbft/cometbft/libs/tla_trace"
	"github.com/cometbft/cometbft/p2p"
)

// TestScenarioBlockPoolBasic drives the BlockPool through a small height
// range (1..4) that fits inside the TLA+ spec's MaxFetchHeight bound.
//
// Three honest peers plus one Byzantine peer all advertising heights inside
// [1, 4]. We drive blocks until the pool pops up to height 4.
//
// Exercises: SetPeerRange, ByzPeerAdvertiseRange, HonestPeerDeliverBlock,
// ByzPeerDeliverBlock, AdvancePoolHeight.
func TestScenarioBlockPoolBasic(t *testing.T) {
	defer tlatrace.ClearByzPeers()

	start := int64(1)
	target := int64(4)

	peerInfo := []struct {
		id     p2p.ID
		base   int64
		height int64
		byz    bool
	}{
		{"p1", 1, 4, false},
		{"p2", 1, 4, false},
		{"p3", 1, 4, false},
		{"byz", 1, 4, true},
	}
	peers := make(testPeers, len(peerInfo))
	for _, info := range peerInfo {
		peers[info.id] = &testPeer{
			id:        info.id,
			base:      info.base,
			height:    info.height,
			inputChan: make(chan inputData, 10),
		}
		if info.byz {
			tlatrace.MarkPeerByz(string(info.id))
		}
	}

	requestsCh := make(chan BlockRequest)
	errorsCh := make(chan peerError)
	pool := NewBlockPool(start, requestsCh, errorsCh)
	pool.SetLogger(log.TestingLogger())
	require.NoError(t, pool.Start())
	t.Cleanup(func() { _ = pool.Stop() })

	peers.start()
	defer peers.stop()

	// Introduce each peer — triggers SetPeerRange / ByzPeerAdvertiseRange.
	go func() {
		for _, peer := range peers {
			pool.SetPeerRange(peer.id, peer.base, peer.height)
		}
	}()

	// Goroutine pulls blocks (triggers AdvancePoolHeight via PopRequest).
	go func() {
		for {
			if !pool.IsRunning() {
				return
			}
			first, second, _ := pool.PeekTwoBlocks()
			if first != nil && second != nil {
				pool.PopRequest()
			} else {
				time.Sleep(50 * time.Millisecond)
			}
		}
	}()

	timeout := time.After(15 * time.Second)
	tick := time.NewTicker(50 * time.Millisecond)
	defer tick.Stop()
	for {
		select {
		case err := <-errorsCh:
			t.Logf("peer error: %v", err)
		case request := <-requestsCh:
			t.Logf("request height=%d peer=%s pool=%d", request.Height, request.PeerID, pool.Height())
			peers[request.PeerID].inputChan <- inputData{t, pool, request}
		case <-tick.C:
			if pool.Height() >= target {
				return
			}
		case <-timeout:
			t.Fatalf("timed out (pool height: %d)", pool.Height())
		}
	}
}

// TestScenarioBlockPoolBan exercises the "base > height" branch of
// SetPeerRange that bans the peer — the trace records bannedCount > 0.
func TestScenarioBlockPoolBan(t *testing.T) {
	defer tlatrace.ClearByzPeers()

	requestsCh := make(chan BlockRequest, 50)
	errorsCh := make(chan peerError, 50)
	pool := NewBlockPool(1, requestsCh, errorsCh)
	pool.SetLogger(log.TestingLogger())
	require.NoError(t, pool.Start())
	t.Cleanup(func() { _ = pool.Stop() })

	go func() {
		for {
			select {
			case <-requestsCh:
			case <-errorsCh:
			case <-time.After(1 * time.Second):
				return
			}
		}
	}()

	pool.SetPeerRange("p1", 1, 4)
	pool.SetPeerRange("p2", 1, 4)
	// Misbehaving peer reports base > height — banned.
	pool.SetPeerRange("p3", 9, 4)
	// Banned peer reintroducing itself — silently dropped, no bump in bannedCount.
	pool.SetPeerRange("p3", 1, 4)

	time.Sleep(50 * time.Millisecond)
}
