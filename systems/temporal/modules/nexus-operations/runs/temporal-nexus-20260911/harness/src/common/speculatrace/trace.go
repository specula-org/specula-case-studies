package speculatrace

import (
 "encoding/json"
 "errors"
 "fmt"
 "os"
 "reflect"
 "sync"
 "time"

 persistencespb "go.temporal.io/server/api/persistence/v1"
 "google.golang.org/protobuf/encoding/protojson"
 "google.golang.org/protobuf/proto"
)

const Revision = "0c010ce5fe8c0180aa7573c72fe8fc87c6df7025"

type Record struct {
 Tag string `json:"tag"`
 TS string `json:"ts"`
 Sequence uint64 `json:"sequence"`
 Event string `json:"event"`
 Source string `json:"source"`
 Namespace string `json:"namespace"`
 Workflow string `json:"workflow"`
 Run string `json:"run"`
 Raw any `json:"raw"`
}

var recorder struct {
 sync.Mutex
 file *os.File
 namespace string
 sequence uint64
 failure error
}

func Enabled() bool { return os.Getenv("SPECULA_TRACE_FILE") != "" }

func Start(namespace string, config any) error {
 if !Enabled() { return nil }
 recorder.Lock()
 defer recorder.Unlock()
 if recorder.file != nil { return errors.New("trace recorder already open") }
 f, err := os.OpenFile(os.Getenv("SPECULA_TRACE_FILE"), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
 if err != nil { return err }
 recorder.file, recorder.namespace, recorder.sequence = f, namespace, 0
 recorder.failure=nil
 return encodeLocked("Init", "configuration", namespace, "", "", config)
}

func Close() error {
 recorder.Lock()
 defer recorder.Unlock()
 if recorder.file == nil { return nil }
 err := recorder.file.Sync()
 closeErr := recorder.file.Close()
 recorder.file = nil
 return errors.Join(recorder.failure,err,closeErr)
}

func Active(namespace string) bool {
 if !Enabled() { return false }
 recorder.Lock()
 defer recorder.Unlock()
 return recorder.file != nil && (namespace == "" || namespace == recorder.namespace)
}

func Emit(event, source, namespace, workflow, run string, raw any) {
 if !Enabled() { return }
 recorder.Lock()
 defer recorder.Unlock()
 if recorder.file == nil || (namespace != "" && namespace != recorder.namespace) { return }
 if err := encodeLocked(event, source, namespace, workflow, run, raw); err != nil {
  recorder.failure=errors.Join(recorder.failure,fmt.Errorf("trace observation lost: %w", err))
 }
}

func encodeLocked(event, source, namespace, workflow, run string, raw any) error {
 recorder.sequence++
 return json.NewEncoder(recorder.file).Encode(Record{
  Tag: "trace", TS: time.Now().UTC().Format(time.RFC3339Nano), Sequence: recorder.sequence,
  Event: event, Source: source, Namespace: namespace, Workflow: workflow, Run: run, Raw: raw,
 })
}

func Proto(message proto.Message) json.RawMessage {
 data, err := (protojson.MarshalOptions{UseProtoNames: true, EmitUnpopulated: true}).Marshal(message)
 if err != nil { Fail(err); return json.RawMessage(`{"capture_error":"protobuf marshal failed"}`) }
 return data
}

func Error(err error) any {
 if err == nil || (reflect.ValueOf(err).Kind() == reflect.Pointer && reflect.ValueOf(err).IsNil()) { return nil }
 return map[string]any{"type": fmt.Sprintf("%T", err), "message": err.Error()}
}

func State(state *persistencespb.WorkflowMutableState) any {
 decoded := map[string]any{}
 for id, n := range state.GetExecutionInfo().GetSubStateMachinesByType()["nexusoperations.Operation"].GetMachinesById() {
  op := &persistencespb.NexusOperationInfo{}
  if err := proto.Unmarshal(n.Data, op); err != nil { Fail(err); return map[string]any{"capture_error":Error(err)} }
  children := map[string]any{}
  for cid, c := range n.Children["nexusoperations.Cancelation"].GetMachinesById() {
   info := &persistencespb.NexusOperationCancellationInfo{}
   if err := proto.Unmarshal(c.Data, info); err != nil { Fail(err); return map[string]any{"capture_error":Error(err)} }
   children[cid] = map[string]any{"info": Proto(info), "node": Proto(c)}
  }
  decoded[id] = map[string]any{"info": Proto(op), "node": Proto(n), "children": children}
 }
 return map[string]any{"mutable_state": Proto(state), "operations": decoded}
}

// ExecuteAndTimeout requests the existing persistence fault, scoped by the test injector.
type ExecuteAndTimeout struct{}
func (ExecuteAndTimeout) Error() string { return "Specula targeted ExecuteAndTimeout" }

func Fail(err error) {
 recorder.Lock()
 defer recorder.Unlock()
 if recorder.file!=nil {recorder.failure=errors.Join(recorder.failure,err)}
}
