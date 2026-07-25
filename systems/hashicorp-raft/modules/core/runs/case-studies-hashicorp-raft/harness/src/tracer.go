package main

import (
	"encoding/json"
	"os"
	"sync"
	"time"

	"github.com/hashicorp/raft"
)

// traceLine is a single line in the NDJSON trace output.
type traceLine struct {
	Timestamp time.Time       `json:"ts"`
	Tag       string          `json:"tag"`
	Event     *raft.TraceEvent `json:"event,omitempty"`
	Config    *traceConfig    `json:"config,omitempty"`
}

// traceConfig captures cluster configuration metadata.
type traceConfig struct {
	Servers          []string `json:"servers"`
	HeartbeatTimeout string   `json:"heartbeatTimeout"`
	ElectionTimeout  string   `json:"electionTimeout"`
	PreVoteDisabled  bool     `json:"preVoteDisabled"`
}

// NDJSONTracer implements raft.TraceLogger and writes events as NDJSON.
type NDJSONTracer struct {
	mu     sync.Mutex
	enc    *json.Encoder
	closer *os.File
}

// NewNDJSONTracer creates a tracer that writes to the given file path.
func NewNDJSONTracer(path string) (*NDJSONTracer, error) {
	f, err := os.Create(path)
	if err != nil {
		return nil, err
	}
	return &NDJSONTracer{
		enc:    json.NewEncoder(f),
		closer: f,
	}, nil
}

// TraceEvent implements raft.TraceLogger.
func (t *NDJSONTracer) TraceEvent(event raft.TraceEvent) {
	t.mu.Lock()
	defer t.mu.Unlock()
	_ = t.enc.Encode(traceLine{
		Timestamp: time.Now(),
		Tag:       "trace",
		Event:     &event,
	})
}

// WriteConfig writes the cluster configuration as a config line.
func (t *NDJSONTracer) WriteConfig(cfg traceConfig) {
	t.mu.Lock()
	defer t.mu.Unlock()
	_ = t.enc.Encode(traceLine{
		Timestamp: time.Now(),
		Tag:       "config",
		Config:    &cfg,
	})
}

// Close flushes and closes the output file.
func (t *NDJSONTracer) Close() error {
	return t.closer.Close()
}
