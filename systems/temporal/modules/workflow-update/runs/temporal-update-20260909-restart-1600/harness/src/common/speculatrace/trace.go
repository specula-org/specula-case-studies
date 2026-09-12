package speculatrace

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"
)

// The observer is enabled only by a harness scenario in this instrumented tree.
// It never waits for a workflow lease, RPC, or persistence operation while locked.
var recorder struct {
	sync.Mutex
	file     *os.File
	workflow string
	updates  map[string]bool
	ordinal  uint64
	baseline bool
	err      error
}

func Open(path, workflow string, updates []string, config any) error {
	recorder.Lock()
	defer recorder.Unlock()
	if recorder.file != nil {
		return errors.New("trace already open")
	}
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	recorder.file, recorder.workflow, recorder.ordinal, recorder.err = f, workflow, 0, nil
	recorder.baseline = false
	recorder.updates = make(map[string]bool)
	for _, u := range updates {
		recorder.updates[u] = true
	}
	writeLocked(map[string]any{"tag": "config", "ts": time.Now().UTC().Format(time.RFC3339Nano), "config": config})
	return recorder.err
}

func Close() error {
	recorder.Lock()
	defer recorder.Unlock()
	if recorder.file == nil {
		return recorder.err
	}
	if err := recorder.file.Sync(); recorder.err == nil {
		recorder.err = err
	}
	if err := recorder.file.Close(); recorder.err == nil {
		recorder.err = err
	}
	recorder.file = nil
	return recorder.err
}

func Enabled(key string) bool {
	recorder.Lock()
	defer recorder.Unlock()
	return recorder.file != nil && (key == recorder.workflow || recorder.updates[key])
}

func ID(p any) string { return fmt.Sprintf("%p", p) }
func Error(err error) any {
	if err == nil {
		return nil
	}
	return map[string]any{"type": fmt.Sprintf("%T", err), "message": err.Error()}
}

func Emit(key, name string, state any) {
	recorder.Lock()
	defer recorder.Unlock()
	if recorder.file == nil || (key != recorder.workflow && !recorder.updates[key]) {
		return
	}
	tag := "trace"
	if strings.HasPrefix(name, "probe.") {
		tag = "evidence"
	} else {
		recorder.ordinal++
	}
	writeLocked(map[string]any{"tag": tag, "ts": time.Now().UTC().Format(time.RFC3339Nano), "ordinal": recorder.ordinal,
		"event": map[string]any{"name": name, "nid": "h1", "state": state}})
}

// Publication holds the observer across a single Future.Set and its snapshot.
// A waiter can wake normally, but its observation cannot precede this event.
func Publication(key, name string, set func(), snapshot func() any) {
	recorder.Lock()
	defer recorder.Unlock()
	set()
	if recorder.file == nil || !recorder.updates[key] {
		return
	}
	recorder.ordinal++
	writeLocked(map[string]any{"tag": "trace", "ts": time.Now().UTC().Format(time.RFC3339Nano), "ordinal": recorder.ordinal,
		"event": map[string]any{"name": name, "nid": "h1", "state": snapshot()}})
}

func writeLocked(value any) {
	if recorder.err != nil {
		return
	}
	recorder.err = json.NewEncoder(recorder.file).Encode(value)
}

func FirstBaseline() bool {
	recorder.Lock()
	defer recorder.Unlock()
	if recorder.baseline {
		return false
	}
	recorder.baseline = true
	return true
}
