// Package tlatrace is a lightweight NDJSON trace emitter used by the
// Specula harness to record real keeper-level state transitions for TLA+
// trace validation. It is enabled when the BABYLON_TLA_TRACE_FILE env
// variable points to a writable file. When disabled, Emit is a no-op.
//
// Trace line envelope (one JSON object per line):
//
//	{"tag":"trace","ts":"<unix-nano>","event":{"name":"<Action>",
//	    "module":"<mod>","fp":"<fp>","validator":"<v>",
//	    "msg":{...},"state":{...}}}
//
// Trace.tla filters on tag=="trace"; lines without it are silently dropped.
package tlatrace

import (
	"encoding/json"
	"os"
	"strconv"
	"sync"
	"time"
)

var (
	mu       sync.Mutex
	out      *os.File
	enabled  bool
	fpMap    = map[string]string{}
	valMap   = map[string]string{}
	hashMap  = map[string]string{}
	fpNext   int
	valNext  int
	hashNext int
)

// MaxAbstractHashes bounds the number of distinct hashes we'll ever map.
// Trace.cfg currently declares BlockHashes = {h1, h2, h3}; bumping this
// requires also updating the cfg.
const MaxAbstractHashes = 3

// Init opens the trace file (path from BABYLON_TLA_TRACE_FILE). Safe to
// call multiple times; only the first call has effect. If env is unset
// or the path is empty, tracing stays disabled and Emit becomes a no-op.
func Init() {
	mu.Lock()
	defer mu.Unlock()
	if out != nil {
		return
	}
	path := os.Getenv("BABYLON_TLA_TRACE_FILE")
	if path == "" {
		return
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	if err != nil {
		return
	}
	out = f
	enabled = true
}

// Close flushes and closes the trace file.
func Close() {
	mu.Lock()
	defer mu.Unlock()
	if out != nil {
		_ = out.Sync()
		_ = out.Close()
		out = nil
		enabled = false
	}
}

// SetServerMap clears and seeds the static FP / validator mappings.
// Useful at the start of each scenario.
func Reset() {
	mu.Lock()
	defer mu.Unlock()
	fpMap = map[string]string{}
	valMap = map[string]string{}
	hashMap = map[string]string{}
	fpNext = 0
	valNext = 0
	hashNext = 0
}

// Fp returns the canonical fp1..fpN tag for an implementation FP key.
// Stable across the run; assigns ids in first-seen order.
func Fp(impl string) string {
	if impl == "" {
		return "fp0"
	}
	mu.Lock()
	defer mu.Unlock()
	if id, ok := fpMap[impl]; ok {
		return id
	}
	fpNext++
	id := "fp" + strconv.Itoa(fpNext)
	fpMap[impl] = id
	return id
}

// Hash returns an abstract block-hash tag (h1..hMaxAbstractHashes) for an
// implementation hash hex string.  Stable across the run; rotates round-robin
// after MaxAbstractHashes to avoid blowing the model bound, which is fine for
// trace validation because the spec only compares hashes for equality.
//
// Empty / nil-like values map to "NilHash" (matches Trace.cfg).
func Hash(impl string) string {
	if impl == "" || impl == "0" {
		return "NilHash"
	}
	mu.Lock()
	defer mu.Unlock()
	if id, ok := hashMap[impl]; ok {
		return id
	}
	hashNext++
	idx := ((hashNext - 1) % MaxAbstractHashes) + 1
	id := "h" + strconv.Itoa(idx)
	hashMap[impl] = id
	return id
}

// Val returns the canonical v1..vN tag for an implementation validator addr.
func Val(impl string) string {
	if impl == "" {
		return "v0"
	}
	mu.Lock()
	defer mu.Unlock()
	if id, ok := valMap[impl]; ok {
		return id
	}
	valNext++
	id := "v" + strconv.Itoa(valNext)
	valMap[impl] = id
	return id
}

// Enabled reports whether tracing is on.
func Enabled() bool {
	mu.Lock()
	defer mu.Unlock()
	return enabled
}

// Event is the inner record carried in the trace envelope.
type Event struct {
	Name      string                 `json:"name"`
	Module    string                 `json:"module,omitempty"`
	Fp        string                 `json:"fp,omitempty"`
	Validator string                 `json:"validator,omitempty"`
	Msg       map[string]interface{} `json:"msg,omitempty"`
	State     map[string]interface{} `json:"state,omitempty"`
}

type envelope struct {
	Tag   string `json:"tag"`
	Ts    string `json:"ts"`
	Event Event  `json:"event"`
}

// Emit writes one NDJSON trace line. Safe to call before Init (no-op).
func Emit(ev Event) {
	mu.Lock()
	defer mu.Unlock()
	if !enabled || out == nil {
		return
	}
	rec := envelope{
		Tag:   "trace",
		Ts:    strconv.FormatInt(time.Now().UnixNano(), 10),
		Event: ev,
	}
	b, err := json.Marshal(&rec)
	if err != nil {
		return
	}
	b = append(b, '\n')
	_, _ = out.Write(b)
}

// EmitConfig writes one NDJSON config line (first line of trace).
// Used to describe constants (validators / fps / sizes) so Trace.tla
// can override CONSTANTS instead of hardcoding.
func EmitConfig(cfg map[string]interface{}) {
	mu.Lock()
	defer mu.Unlock()
	if !enabled || out == nil {
		return
	}
	rec := struct {
		Tag    string                 `json:"tag"`
		Ts     string                 `json:"ts"`
		Config map[string]interface{} `json:"config"`
	}{
		Tag:    "config",
		Ts:     strconv.FormatInt(time.Now().UnixNano(), 10),
		Config: cfg,
	}
	b, err := json.Marshal(&rec)
	if err != nil {
		return
	}
	b = append(b, '\n')
	_, _ = out.Write(b)
}

// init auto-opens the trace file on first import when env is set.
// Tests can also call Init explicitly.
func init() { Init() }
