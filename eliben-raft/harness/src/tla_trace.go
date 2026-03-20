// TLA+ trace emission module for eliben/raft.
//
// Emits NDJSON trace events for trace validation against Trace.tla.
// Thread-safe: protected by traceMu. Lock ordering: cm.mu -> traceMu.
package raft

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"time"
)

var (
	traceFile *os.File
	traceMu   sync.Mutex
)

// InitTrace opens a trace file for writing. Call once per test scenario.
func InitTrace(path string) error {
	traceMu.Lock()
	defer traceMu.Unlock()
	if traceFile != nil {
		traceFile.Close()
	}
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return err
	}
	var err error
	traceFile, err = os.Create(path)
	return err
}

// CloseTrace flushes and closes the trace file.
func CloseTrace() {
	traceMu.Lock()
	defer traceMu.Unlock()
	if traceFile != nil {
		traceFile.Close()
		traceFile = nil
	}
}

// traceEmitRaw writes one NDJSON line with the given fields.
// Adds a real nanosecond timestamp.
func traceEmitRaw(fields map[string]any) {
	traceMu.Lock()
	defer traceMu.Unlock()
	if traceFile == nil {
		return
	}
	fields["ts"] = time.Now().UnixNano()
	data, err := json.Marshal(fields)
	if err != nil {
		return
	}
	traceFile.Write(data)
	traceFile.Write([]byte("\n"))
}

// traceEvent emits a trace event with common server state fields.
// MUST be called while cm.mu is held (reads cm fields).
func (cm *ConsensusModule) traceEvent(event string, extra map[string]any) {
	fields := map[string]any{
		"event": event,
		"node":  cm.id,
		"term":  cm.currentTerm,
		"role":  cm.state.String(),
	}
	for k, v := range extra {
		fields[k] = v
	}
	traceEmitRaw(fields)
}

// traceFilePath returns the full path for a trace file, using RAFT_TRACE_DIR
// env var if set, otherwise the current directory.
func traceFilePath(name string) string {
	dir := os.Getenv("RAFT_TRACE_DIR")
	if dir == "" {
		dir = "."
	}
	return filepath.Join(dir, name)
}
