package persistence

import (
 "context"
 "math"
 "fmt"
 "time"
 "go.temporal.io/server/common/speculatrace"
 "go.temporal.io/server/service/history/tasks"
)

func speculaPhysicalTasks(grouped map[tasks.Category][]tasks.Task) []any {
 out := make([]any, 0)
 for category, group := range grouped {
  for _, task := range group { out=append(out, map[string]any{"category": category.ID(), "task": task}) }
 }
 return out
}

func (m *executionManagerImpl) speculaReadback(_ context.Context, request *UpdateWorkflowExecutionRequest, writeErr error) {
 mutation := request.UpdateWorkflowMutation
 ns, wf, run := mutation.ExecutionInfo.NamespaceId, mutation.ExecutionInfo.WorkflowId, mutation.ExecutionState.RunId
 ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
 readID:=fmt.Sprintf("%s/%d/%d",wf,mutation.DBRecordVersion,time.Now().UnixNano())
 ctx=context.WithValue(ctx,speculaReadContextKey{},readID)
 defer cancel()
 result, err := m.GetWorkflowExecution(ctx, &GetWorkflowExecutionRequest{ShardID: request.ShardID, NamespaceID: ns, WorkflowID: wf, RunID: run, ArchetypeID: request.ArchetypeID})
 observation := map[string]any{"readback_id":readID,"range_id": request.RangeID, "expected_new_version": mutation.DBRecordVersion,
  "write_error": speculatrace.Error(writeErr), "read_error": speculatrace.Error(err), "shard_id": request.ShardID}
 if err == nil {
  observation["state"] = speculatrace.State(result.State)
  observation["db_record_version"] = result.DBRecordVersion
 }
 queue := make([]any, 0)
 for _, category := range []tasks.Category{tasks.CategoryOutbound,tasks.CategoryTimer} {
  upper := tasks.NewImmediateKey(math.MaxInt64)
  if category == tasks.CategoryTimer { upper = tasks.NewKey(time.Now().Add(365*24*time.Hour), 0) }
  req := &GetHistoryTasksRequest{ShardID: request.ShardID, TaskCategory: category, InclusiveMinTaskKey: tasks.MinimumKey, ExclusiveMaxTaskKey: upper, BatchSize: 1000}
  for {
   response, readErr := m.GetHistoryTasks(ctx,req)
   if readErr != nil { observation["queue_error"] = speculatrace.Error(readErr); break }
   for _, task := range response.Tasks {
    if task.GetNamespaceID()==ns && task.GetWorkflowID()==wf && task.GetRunID()==run {
     queue=append(queue,map[string]any{"category": category.ID(), "task_id": task.GetTaskID(), "visibility_time": task.GetVisibilityTime(), "task": task})
    }
   }
   if len(response.NextPageToken)==0 { break }
   req.NextPageToken=response.NextPageToken
  }
 }
 observation["queue_rows"] = queue
 speculatrace.Emit("UpdateWorkflowExecution", "persistence", ns,wf,run,observation)
}

type speculaReadContextKey struct{}
