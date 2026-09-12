package hqtrace

import (
	"encoding/json"
	"fmt"
	"os"
	"sync"
	"time"
)

type M = map[string]any

// Enabled gates the hooks installed by the serialized harness schedule.
var Enabled bool
var Owner = 1
var Task int
var Exec string
var Probes = map[string]func() any{}
var Extra = M{}
var Before func(string, M, M)
var After func(string, M, M)
var writer *os.File
var mu sync.Mutex
var seq int

func Open(path string) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	writer = f
	seq = 0
	Enabled = true
	return nil
}
func Close() error {
	mu.Lock()
	defer mu.Unlock()
	Enabled = false
	if writer == nil {
		return nil
	}
	err := writer.Sync()
	closeErr := writer.Close()
	writer = nil
	if err != nil {
		return err
	}
	return closeErr
}
func Emit(name string, args M, detail M) {
	if !Enabled {
		return
	}
	mu.Lock()
	defer mu.Unlock()
	if args == nil {
		args = M{}
	}
	if detail == nil {
		detail = M{}
	}
	if Before != nil {
		Before(name, args, detail)
	}
	raw := M{}
	for key, probe := range Probes {
		raw[key] = probe()
	}
	seq++
	record := M{"tag": "trace", "ts": time.Now().UTC().Format(time.RFC3339Nano), "seq": seq,
		"schema": 1, "provenance": "implementation", "event": name, "nid": fmt.Sprintf("s%d", Owner),
		"args": args, "raw": raw, "detail": detail, "context": M{"owner": Owner, "task": Task, "exec": Exec}, "extra": Extra}
	if err := json.NewEncoder(writer).Encode(record); err != nil {
		panic(err) //nolint:forbidigo // A failed observer write must abort the harness, never silently drop a trace event.
	}
	if After != nil {
		After(name, args, detail)
	}
}
func Current(name string, detail M) { Emit(name, M{"o": Owner}, detail) }
func Publication(name string, detail M) {
	if Task != 0 {
		Emit(name, M{"t": Task}, detail)
	}
}
func Execution(name string, detail M) {
	if Exec != "" {
		Emit(name, M{"e": Exec}, detail)
	}
}
func Ptr(v any) string { return fmt.Sprintf("%p", v) }
func Error(err error) string {
	if err == nil {
		return ""
	}
	return fmt.Sprintf("%T: %v", err, err)
}
