// Package tla_trace emits NDJSON trace events from instrumented CometBFT code
// for TLA+ trace validation against the round-3 spec (cometbft_3).
//
// The package is shimmed into the artifact via the harness apply script. It
// is intentionally dependency-free (only standard library) so it can be
// dropped into any sub-package without import-cycle pain.
package tla_trace

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"sync"
	"sync/atomic"
	"time"
)

// Event is the on-wire shape of an instrumented action.
type Event struct {
	Name  string                 `json:"name"`
	Nid   string                 `json:"nid"`
	State map[string]interface{} `json:"state,omitempty"`
	Msg   map[string]interface{} `json:"msg,omitempty"`
	Peer  map[string]interface{} `json:"peer,omitempty"`
}

type envelope struct {
	Tag   string `json:"tag"`
	TS    int64  `json:"ts"`
	Event Event  `json:"event"`
}

type configEnvelope struct {
	Tag    string                 `json:"tag"`
	TS     int64                  `json:"ts"`
	Config map[string]interface{} `json:"config"`
}

var (
	mu       sync.Mutex
	file     *os.File
	enc      *json.Encoder
	disabled atomic.Bool

	peerMu        sync.RWMutex
	byzPeers      = map[string]struct{}{}
)

// Init opens the trace file. Subsequent emits write to it.
// If path is empty or open fails, tracing is disabled silently.
func Init(path string) error {
	mu.Lock()
	defer mu.Unlock()
	if path == "" {
		disabled.Store(true)
		return nil
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0644)
	if err != nil {
		disabled.Store(true)
		return err
	}
	file = f
	enc = json.NewEncoder(f)
	disabled.Store(false)
	return nil
}

// InitFromEnv looks at TLA_TRACE_FILE; falls back to TRACE_FILE.
// When neither is set, tracing remains disabled.
func InitFromEnv() {
	for _, k := range []string{"TLA_TRACE_FILE", "TRACE_FILE"} {
		if p := os.Getenv(k); p != "" {
			_ = Init(p)
			return
		}
	}
	disabled.Store(true)
}

// Close flushes and closes the trace file.
func Close() {
	mu.Lock()
	defer mu.Unlock()
	if file != nil {
		_ = file.Sync()
		_ = file.Close()
		file = nil
		enc = nil
	}
	disabled.Store(true)
}

// IsEnabled reports whether emit calls will do work.
func IsEnabled() bool {
	return !disabled.Load()
}

func tsNow() int64 { return time.Now().UnixNano() }

// EmitConfig writes the leading config record. Should be called once after
// Init, before any Event.
func EmitConfig(cfg map[string]interface{}) {
	if !IsEnabled() {
		return
	}
	mu.Lock()
	defer mu.Unlock()
	if enc == nil {
		return
	}
	_ = enc.Encode(configEnvelope{Tag: "config", TS: tsNow(), Config: cfg})
}

// Emit writes one event line.
func Emit(ev Event) {
	if !IsEnabled() {
		return
	}
	mu.Lock()
	defer mu.Unlock()
	if enc == nil {
		return
	}
	_ = enc.Encode(envelope{Tag: "trace", TS: tsNow(), Event: ev})
}

// EmitState is a convenience for state-only events.
func EmitState(name, nid string, state map[string]interface{}) {
	Emit(Event{Name: name, Nid: nid, State: state})
}

// EmitMsg is a convenience for events that take a message field.
func EmitMsg(name, nid string, state, msg map[string]interface{}) {
	Emit(Event{Name: name, Nid: nid, State: state, Msg: msg})
}

// EmitPeer is a convenience for events that take a peer field.
func EmitPeer(name, nid string, state, peer map[string]interface{}) {
	Emit(Event{Name: name, Nid: nid, State: state, Peer: peer})
}

// ----- Byzantine peer registration --------------------------------------------

// MarkPeerByz lets a test harness flag a peer as Byzantine. Action wrappers
// consult IsPeerByz to decide between honest and Byz event variants.
func MarkPeerByz(id string) {
	peerMu.Lock()
	defer peerMu.Unlock()
	byzPeers[id] = struct{}{}
}

// ClearByzPeers wipes the Byzantine registry (for clean test setup).
func ClearByzPeers() {
	peerMu.Lock()
	defer peerMu.Unlock()
	byzPeers = map[string]struct{}{}
}

// IsPeerByz returns true iff MarkPeerByz was called for id.
func IsPeerByz(id string) bool {
	peerMu.RLock()
	defer peerMu.RUnlock()
	_, ok := byzPeers[id]
	return ok
}

// ----- helpers for encoding implementation values ---------------------------

// HexOrNil hex-encodes a byte slice, returning "nil" if empty. Useful for
// validator addresses and block hashes that get mapped to s1/v1 in
// post-processing.
func HexOrNil(b []byte) string {
	if len(b) == 0 {
		return "nil"
	}
	return hex.EncodeToString(b)
}

// FmtPeer returns the canonical string for a peer ID.
func FmtPeer(id interface{}) string {
	if id == nil {
		return "nil"
	}
	return fmt.Sprint(id)
}
