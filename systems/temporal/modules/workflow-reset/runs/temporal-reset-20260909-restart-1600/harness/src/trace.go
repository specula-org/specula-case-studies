package resettrace

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"slices"
	"sync"
	"time"
)

type Fields = map[string]any

type Recorder struct {
	mu         sync.Mutex
	emitMu     sync.Mutex
	file       *os.File
	workflow   string
	runs       map[string]bool
	tokens     map[string][]byte
	snapshot   func() (any, error)
	traceError error
	fault      func(string, Fields) error
}

var registry = struct {
	sync.Mutex
	records map[string]*Recorder
}{records: map[string]*Recorder{}}

func Open(workflow, path string) (*Recorder, error) {
	f, err := os.Create(path)
	if err != nil {
		return nil, err
	}
	r := &Recorder{file: f, workflow: workflow, runs: map[string]bool{}, tokens: map[string][]byte{}}
	registry.Lock()
	registry.records[workflow] = r
	registry.Unlock()
	return r, nil
}
func Lookup(workflow string) *Recorder {
	registry.Lock()
	defer registry.Unlock()
	return registry.records[workflow]
}
func (r *Recorder) Close() error {
	registry.Lock()
	delete(registry.records, r.workflow)
	registry.Unlock()
	r.emitMu.Lock()
	defer r.emitMu.Unlock()
	if err := r.file.Sync(); err != nil {
		return err
	}
	return errors.Join(r.file.Close(), r.traceError)
}
func Run(workflow, run string) {
	if r := Lookup(workflow); r != nil && run != "" {
		r.mu.Lock()
		r.runs[run] = true
		r.mu.Unlock()
	}
}
func Token(workflow, run string, token []byte) {
	if r := Lookup(workflow); r != nil {
		r.mu.Lock()
		r.runs[run] = true
		r.tokens[run] = append([]byte(nil), token...)
		r.mu.Unlock()
	}
}
func Runs(workflow string) ([]string, map[string][]byte) {
	r := Lookup(workflow)
	if r == nil {
		return nil, nil
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	ids := []string{}
	tokens := map[string][]byte{}
	for id := range r.runs {
		ids = append(ids, id)
	}
	for id, t := range r.tokens {
		tokens[id] = append([]byte(nil), t...)
	}
	return ids, tokens
}
func Bind(workflow string, snapshot func() (any, error)) {
	if r := Lookup(workflow); r != nil {
		r.mu.Lock()
		r.snapshot = snapshot
		r.mu.Unlock()
	}
}
func Emit(workflow, name string, data Fields) {
	r := Lookup(workflow)
	if r == nil {
		return
	}
	r.emitMu.Lock()
	defer r.emitMu.Unlock()
	r.emitLocked(name, data)
}

func (r *Recorder) emitLocked(name string, data Fields) {
	r.mu.Lock()
	snap := r.snapshot
	r.mu.Unlock()
	var db any
	if snap != nil {
		var err error
		db, err = snap()
		if err != nil {
			r.traceError = errors.Join(r.traceError, err)
		}
	}
	row := Fields{"ts": time.Now().UTC().Format(time.RFC3339Nano), "name": name, "nid": "s1", "data": data, "durable": db}
	if err := json.NewEncoder(r.file).Encode(row); err != nil {
		r.traceError = errors.Join(r.traceError, fmt.Errorf("reset trace write: %w", err))
	}
}
func (r *Recorder) SetFault(f func(string, Fields) error) { r.mu.Lock(); r.fault = f; r.mu.Unlock() }
func Fault(workflow, point string, data Fields) error {
	r := Lookup(workflow)
	if r == nil {
		return nil
	}
	r.mu.Lock()
	f := r.fault
	r.mu.Unlock()
	if f == nil {
		return nil
	}
	return f(point, data)
}
func Error(err error) string {
	if err == nil {
		return ""
	}
	return fmt.Sprintf("%T: %v", err, err)
}

type writeKey struct{}
type Write struct {
	Workflow string
	Method   string
	Request  any
}

func WithWrite(ctx context.Context, workflow, method string, request any) context.Context {
	if Lookup(workflow) == nil {
		return ctx
	}
	return context.WithValue(ctx, writeKey{}, Write{workflow, method, request})
}
func TransactionIssued(ctx context.Context, operation string) {
	w, ok := ctx.Value(writeKey{}).(Write)
	if ok && w.Method == operation {
		Emit(w.Workflow, "IssueMetadata", Fields{"method": operation})
	}
}

func Transaction(ctx context.Context, operation string, err error) error {
	w, ok := ctx.Value(writeKey{}).(Write)
	if !ok || w.Method != operation {
		return nil
	}
	Emit(w.Workflow, "SQLTransaction", Fields{"method": operation, "request": w.Request, "error": Error(err)})
	if err == nil {
		return Fault(w.Workflow, "after-commit", Fields{"method": operation, "request": w.Request})
	}
	return nil
}
func BeforeMetadata(ctx context.Context) error {
	w, ok := ctx.Value(writeKey{}).(Write)
	if !ok {
		return nil
	}
	return Fault(w.Workflow, "before-metadata", Fields{"method": w.Method, "request": w.Request})
}
func Snapshot(v any) any {
	if s, ok := v.(interface{ ResetTraceSnapshot() any }); ok {
		return s.ResetTraceSnapshot()
	}
	return nil
}
func ContextEvent(ctx context.Context, name string, data Fields) {
	if w, ok := ctx.Value(writeKey{}).(Write); ok {
		Emit(w.Workflow, name, data)
	}
}

func All(name string, data Fields) {
	registry.Lock()
	workflows := []string{}
	for wf := range registry.records {
		workflows = append(workflows, wf)
	}
	registry.Unlock()
	for _, wf := range workflows {
		Emit(wf, name, data)
	}
}

// ObserveAll keeps the real datastore mutation and its snapshot in one observer
// interval, preventing another event from seeing the commit before its record.
func ObserveAll(name string, data Fields, operation func() error) error {
	registry.Lock()
	workflows := make([]string, 0, len(registry.records))
	for workflow := range registry.records {
		workflows = append(workflows, workflow)
	}
	slices.Sort(workflows)
	recorders := make([]*Recorder, 0, len(workflows))
	for _, workflow := range workflows {
		recorders = append(recorders, registry.records[workflow])
	}
	registry.Unlock()
	for _, recorder := range recorders {
		recorder.emitMu.Lock()
	}
	defer func() {
		for i := len(recorders) - 1; i >= 0; i-- {
			recorders[i].emitMu.Unlock()
		}
	}()
	if err := operation(); err != nil {
		return err
	}
	for _, recorder := range recorders {
		recorder.emitLocked(name, data)
	}
	return nil
}
