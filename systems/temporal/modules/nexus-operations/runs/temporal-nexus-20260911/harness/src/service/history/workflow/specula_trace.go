package workflow

import (
 "fmt"
 "go.temporal.io/server/common/speculatrace"
 "go.temporal.io/server/service/history/hsm"
)

func (ms *MutableStateImpl) SpeculaEmit(event string, args any) {
 key := ms.GetWorkflowKey()
 if !speculatrace.Active(key.NamespaceID) { return }
 outputs := make([]any, 0)
 log, err := ms.HSM().OpLog()
 if err != nil { speculatrace.Fail(err); return }
 for _, op := range log {
  raw := map[string]any{"path": op.Path()}
  switch op := op.(type) {
  case hsm.TransitionOperation:
   raw["kind"] = "transition"
   raw["count"] = op.Output.TransitionCount
   ts := make([]any, 0, len(op.Output.Tasks))
   for _, task := range op.Output.Tasks {
    ts = append(ts, map[string]any{"type": task.Type(), "deadline": task.Deadline(), "destination": task.Destination(), "data": task})
   }
   raw["tasks"] = ts
  case hsm.DeleteOperation:
   raw["kind"] = "delete"
  default:
   speculatrace.Fail(fmt.Errorf("unexpected operation log entry %T",op))
   return
  }
  outputs = append(outputs, raw)
 }
 source:="workflow-lock"
 if event=="LoadMutableState" || event=="RefreshWorkflowTasks" {source="recovery"}
 speculatrace.Emit(event, source, key.NamespaceID, key.WorkflowID, key.RunID, map[string]any{
  "args": args, "state": speculatrace.State(ms.CloneToProto()), "history_builder": ms.hBuilder.SpeculaSnapshot(),
  "db_record_version": ms.dbRecordVersion, "task_outputs": outputs, "insert_tasks": speculaInserted(ms),
  "workflow_running": ms.IsWorkflowExecutionRunning(), "pending_wft": ms.HasPendingWorkflowTask(),
  "started_wft": ms.HasStartedWorkflowTask(),
 })
}

func speculaInserted(ms *MutableStateImpl) []any {
 result := make([]any, 0)
 for category, tasks := range ms.InsertTasks {
  for _, task := range tasks { result = append(result, map[string]any{"category": category.ID(), "task": task}) }
 }
 return result
}
