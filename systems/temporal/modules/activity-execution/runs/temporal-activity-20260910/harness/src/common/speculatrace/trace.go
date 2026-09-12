package speculatrace

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime/debug"
	"sync"
	"time"

	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
)

const Revision = "0c010ce5fe8c0180aa7573c72fe8fc87c6df7025"

type Fields = map[string]any

var recorder struct {
	sync.Mutex
	err                                error
	file                               *os.File
	namespace, workflow, run, artifact string
	seq                                int64
	fault                              string
}

// Start scopes observations to one real Run. Encoding is synchronous under the
// source lock; the writer mutex never spans a protocol operation or database IO.
func Start(root, scenario, ns, wf string, config Fields) error {
	recorder.Lock()
	defer recorder.Unlock()
	if recorder.file != nil {
		return errors.New("trace already active")
	}
	if err := os.MkdirAll(filepath.Join(root, "raw"), 0700); err != nil {
		return err
	}
	path := filepath.Join(root, "raw", scenario+".jsonl")
	f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	recorder.file = f
	recorder.namespace = ns
	recorder.workflow = wf
	recorder.run = ""
	recorder.seq = 0
	recorder.err = nil
	pendingFinish = map[string]Fields{}
	pendingClear = map[string]Fields{}
	recorder.artifact = "harness/evidence/raw/" + scenario + ".jsonl"
	recorder.fault = ""
	config["sourceRevision"] = Revision
	config["patchSHA256"] = os.Getenv("SPECULA_PATCH_SHA256")
	config["binarySHA256"] = os.Getenv("SPECULA_BINARY_SHA256")
	if b, ok := debug.ReadBuildInfo(); ok {
		config["buildInfo"] = b.String()
	}
	return json.NewEncoder(f).Encode(Fields{"tag": "config", "ts": time.Now().UTC().Format(time.RFC3339Nano), "config": config})
}
func SetRun(run string) { recorder.Lock(); defer recorder.Unlock(); recorder.run = run }
func Active(wf string) bool {
	recorder.Lock()
	defer recorder.Unlock()
	return recorder.file != nil && recorder.workflow == wf
}
func ActiveAny() bool { recorder.Lock(); defer recorder.Unlock(); return recorder.file != nil }
func Stop() error {
	recorder.Lock()
	defer recorder.Unlock()
	if recorder.file == nil {
		return nil
	}
	err := errors.Join(recorder.err, recorder.file.Sync())
	cerr := recorder.file.Close()
	recorder.file = nil
	if err != nil {
		return err
	}
	return cerr
}
func Proto(p proto.Message) json.RawMessage {
	if p == nil {
		return json.RawMessage("null")
	}
	b, err := (protojson.MarshalOptions{UseProtoNames: true, EmitUnpopulated: true}).Marshal(p)
	if err != nil {
		recordError(err)
		return json.RawMessage("null")
	}
	return b
}
func Freeze(v any) json.RawMessage {
	b, err := json.Marshal(v)
	if err != nil {
		recordError(err)
		return json.RawMessage("null")
	}
	return b
}
func Error(err error) any {
	if err == nil {
		return nil
	}
	return Fields{"type": fmt.Sprintf("%T", err), "message": err.Error()}
}
func Emit(wf, name string, observation Fields) {
	recorder.Lock()
	defer recorder.Unlock()
	if recorder.file == nil || (wf != "" && wf != recorder.workflow) {
		return
	}
	recorder.seq++
	line := Fields{"tag": "trace", "schemaVersion": 1, "seq": recorder.seq, "ts": time.Now().UTC().Format(time.RFC3339Nano),
		"event": name, "nid": "s1", "args": Fields{}, "state": Fields{}, "observation": observation,
		"identity": Fields{"namespaceId": recorder.namespace, "workflowId": recorder.workflow, "runId": recorder.run},
		"evidence": Fields{"sourceRevision": Revision, "basis": "implementation", "complete": false,
			"ordering": "source-lock-and-call-order; cross-layer projection incomplete", "artifact": recorder.artifact}}
	if err := json.NewEncoder(recorder.file).Encode(line); err != nil {
		recorder.err = errors.Join(recorder.err, err)
	}
}
func ArmFault(wf, kind string) {
	recorder.Lock()
	defer recorder.Unlock()
	if recorder.file == nil || recorder.workflow != wf || recorder.fault != "" {
		recorder.err = errors.Join(recorder.err, errors.New("invalid fault arm"))
		return
	}
	recorder.fault = kind
	if kind == "DelayedTimeout" {
		delayed.ready = make(chan struct{})
		delayed.done = make(chan struct{})
	}
}
func TakeFault(wf string) string {
	recorder.Lock()
	defer recorder.Unlock()
	if recorder.file == nil || recorder.workflow != wf {
		return ""
	}
	f := recorder.fault
	recorder.fault = ""
	return f
}

var delayed struct{ ready, done chan struct{} }

func WaitDelayed()         { recorder.Lock(); c := delayed.ready; recorder.Unlock(); <-c }
func ReleaseDelayed()      { recorder.Lock(); defer recorder.Unlock(); close(delayed.ready) }
func MarkDelayedFinished() { recorder.Lock(); defer recorder.Unlock(); close(delayed.done) }
func DelayedFinished() bool {
	recorder.Lock()
	c := delayed.done
	recorder.Unlock()
	select {
	case <-c:
		return true
	default:
		return false
	}
}
func TakeSpecificFault(wf, kind string) bool {
	recorder.Lock()
	defer recorder.Unlock()
	if recorder.file == nil || recorder.workflow != wf || recorder.fault != kind {
		return false
	}
	recorder.fault = ""
	return true
}

func recordError(err error) {
	recorder.Lock()
	defer recorder.Unlock()
	recorder.err = errors.Join(recorder.err, err)
}
func CaptureError(wf string, err error) {
	if err != nil && Active(wf) {
		recordError(err)
	}
}

var pendingFinish = map[string]Fields{}
var pendingClear = map[string]Fields{}

func MarkRejectedClose(wf string, fields Fields) {
	recorder.Lock()
	defer recorder.Unlock()
	if recorder.file != nil && recorder.workflow == wf {
		pendingClear[wf] = fields
	}
}

func TakeClear(wf string) (string, Fields) {
	recorder.Lock()
	defer recorder.Unlock()
	if fields, ok := pendingClear[wf]; ok {
		delete(pendingClear, wf)
		fields["cacheInvalid"] = true
		return "HandleCommandCompleteWorkflowRejected", fields
	}
	return "ClearWorkflowCache", Fields{"cacheInvalid": true}
}

func MarkUpdateReturn(wf string, err error) {
	recorder.Lock()
	defer recorder.Unlock()
	if recorder.file != nil && recorder.workflow == wf {
		pendingFinish[wf] = Fields{"error": Error(err), "boundary": "lease-release"}
	}
}
func TakeFinish(wf string) (Fields, bool) {
	recorder.Lock()
	defer recorder.Unlock()
	f, ok := pendingFinish[wf]
	delete(pendingFinish, wf)
	return f, ok
}
