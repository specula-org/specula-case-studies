package tests

import (
 "context"
 "errors"
 "net/http"
 "os"
 "sync"
 "sync/atomic"
 "time"

 "github.com/nexus-rpc/sdk-go/nexus"
 commandpb "go.temporal.io/api/command/v1"
 commonpb "go.temporal.io/api/common/v1"
 enumspb "go.temporal.io/api/enums/v1"
 historypb "go.temporal.io/api/history/v1"
 "go.temporal.io/api/serviceerror"
 taskqueuepb "go.temporal.io/api/taskqueue/v1"
 "go.temporal.io/api/workflowservice/v1"
 "go.temporal.io/sdk/client"
 "go.temporal.io/server/api/adminservice/v1"
 persistencespb "go.temporal.io/server/api/persistence/v1"
 "go.temporal.io/server/chasm"
 "go.temporal.io/server/common/config"
 commonnexus "go.temporal.io/server/common/nexus"
 "go.temporal.io/server/common/nexus/nexusrpc"
 "go.temporal.io/server/common/nexus/nexustest"
 "go.temporal.io/server/common/persistence"
 "go.temporal.io/server/common/rpc/httpfaults"
 "go.temporal.io/server/common/speculatrace"
 "go.temporal.io/server/common/testing/await"
 "go.temporal.io/server/service/history/hsm/nexusoperations"
 "go.temporal.io/server/tests/testcore"
 "google.golang.org/protobuf/types/known/durationpb"
)

// This extends the existing Nexus functional suite and its real onebox/SQL fixture.
func (s *NexusWorkflowTestSuite) TestSpeculaTrace(chasmEnabled bool) {
 s.Require().False(chasmEnabled)
 mode := os.Getenv("SPECULA_SCENARIO")
 if mode == "" { s.T().Skip("run via harness/run.sh") }
 switch mode {
 case "healthy_async","early_callback","response_loss","definite_failure","execute_timeout","deferred_cancel","healthy_timeout","timeout_capacity","sync_capacity","start_retry","sync_failed","sync_canceled","buffered_callback","below_min","start_refused","cancel_retry","cancel_refused","start_definite_failure","start_execute_timeout","cancel_below_min","stale_timer":
 default:s.T().Fatal("unknown trace scenario: "+mode)
 }
 var armed, faultFired atomic.Bool
 var faultCount atomic.Int32
 opts := []testcore.TestOption{testcore.WithDedicatedCluster(),
  testcore.WithDynamicConfig(nexusoperations.MaxConcurrentOperations,1),
  testcore.WithDynamicConfig(nexusoperations.RetryPolicyInitialInterval,100*time.Millisecond),
  testcore.WithDynamicConfig(nexusoperations.RetryPolicyMaximumInterval,100*time.Millisecond),
 }
 if mode == "definite_failure" || mode == "execute_timeout" || mode == "start_definite_failure" || mode == "start_execute_timeout" {
  opts=append(opts,testcore.WithPersistenceFaultInjection(&config.FaultInjection{Injector:func(target config.FaultInjectionTarget) error {
   if target.Method!="UpdateWorkflowExecution" || !armed.Load() { return nil }
   req, ok := target.Request.(*persistence.InternalUpdateWorkflowExecutionRequest)
   if !ok { return nil }
   // Arm at a controlled start response or callback boundary, with no active worker.
   if !faultFired.CompareAndSwap(false,true) { return nil }
   faultCount.Add(1)
   speculatrace.Emit("FaultSelected", "persistence",req.UpdateWorkflowMutation.NamespaceID,req.UpdateWorkflowMutation.WorkflowID,req.UpdateWorkflowMutation.ExecutionState.RunId,map[string]any{"mode":mode,"db_record_version":req.UpdateWorkflowMutation.DBRecordVersion,"range_id":req.RangeID})
   if mode=="execute_timeout" || mode=="start_execute_timeout" { return speculatrace.ExecuteAndTimeout{} }
   return &serviceerror.ResourceExhausted{Cause:enumspb.RESOURCE_EXHAUSTED_CAUSE_SYSTEM_OVERLOADED,Scope:enumspb.RESOURCE_EXHAUSTED_SCOPE_SYSTEM,Message:"Specula definite pre-store failure"}
  }}))
 }
 env := s.newTestEnv(false,opts...)
 effective := env.SpeculaConfig()
 s.Require().Equal("sqlite",effective["backend"])
 s.Require().Equal(map[string]string{"cache":"shared","mode":"memory"},effective["connect_attributes"])
 s.Require().Equal(false,effective["chasmWorkflowOperations"])
 s.Require().Equal(0,effective["chasmRollout"])
 s.Require().Equal(true,effective["transitionHistory"])
 s.Require().Equal(true,effective["cancelAckEvents"])
 s.Require().Positive(effective["outboundBatchSize"].(int))
 effective["scenario"]=mode
 s.Require().NoError(speculatrace.Start(env.NamespaceID().String(),effective))
 s.T().Cleanup(func(){s.Require().NoError(speculatrace.Close())})
 ctx := s.Context()
 taskQueue := testcore.RandomizeStr("specula-nexus")
 accepted := make(chan nexus.StartOperationOptions,8)
 release := make(chan struct{})
 var releaseOnce sync.Once
 releaseStart := func(){releaseOnce.Do(func(){close(release)})}
 defer releaseStart()
 var endpointMu sync.Mutex
 endpointLedger := map[string]string{}
 var startCount, cancelCount atomic.Int32
 var endpointStart time.Time
 handler := nexustest.Handler{
  OnStartOperation:func(ctx context.Context,_, operation string,_ *nexus.LazyValue,o nexus.StartOperationOptions)(nexus.HandlerStartOperationResult[any],error){
   call := startCount.Add(1)
   if (mode=="start_definite_failure" || mode=="start_execute_timeout") && call==1 {armed.Store(true)}
   if mode=="start_refused" {
    speculatrace.Emit("EndpointStartFailure","endpoint","","","",map[string]any{"options":o,"result":"Refused"})
    select {case accepted<-o:case <-ctx.Done():return nil,ctx.Err()}
    return nil,nexus.NewHandlerErrorf(nexus.HandlerErrorTypeBadRequest,"controlled start refusal")
   }
   if mode=="start_retry" && call==1 {
    speculatrace.Emit("EndpointStartFailure","endpoint","","","",map[string]any{"options":o,"result":"Retryable"})
    return nil,nexus.NewHandlerErrorf(nexus.HandlerErrorTypeUnavailable,"controlled preaccept retry")
   }
   endpointMu.Lock()
   token,dedup := endpointLedger[o.RequestID]
   if !dedup { token="accepted-"+o.RequestID; endpointLedger[o.RequestID]=token; endpointStart=time.Now().UTC() }
   start := endpointStart
   endpointMu.Unlock()
   resultMode := "Async"
   if mode=="sync_capacity" || mode=="sync_failed" || mode=="sync_canceled" {resultMode="Succeeded"}
   if mode=="sync_failed" {resultMode="Failed"}
   if mode=="sync_canceled" {resultMode="Canceled"}
   speculatrace.Emit("EndpointAccept","endpoint","","","",map[string]any{"callback_ref":speculaDecodeCallback(o.CallbackHeader.Get(commonnexus.CallbackTokenHeader)),"options":o,"token":token,"mode":resultMode,"dedup":dedup,"accepted_at":start,"operation":operation,"call":call})
   select {case accepted<-o:case <-ctx.Done():return nil,ctx.Err()}
   if mode=="early_callback" || mode=="deferred_cancel" {
    select {case <-release:case <-ctx.Done():return nil,ctx.Err()}
   }
   if mode=="sync_capacity" {return &nexus.HandlerStartOperationResultSync[any]{Value:"ok"},nil}
   if mode=="sync_failed" {return nil,nexus.NewOperationFailedErrorf("controlled synchronous failure")}
   if mode=="sync_canceled" {return nil,nexus.NewOperationCanceledErrorf("controlled synchronous cancellation")}
   return &nexus.HandlerStartOperationResultAsync{OperationToken:token},nil
  },
  OnCancelOperation:func(_ context.Context,_,_ string,token string,_ nexus.CancelOperationOptions)error {
   attempt:=cancelCount.Add(1)
   if mode=="cancel_retry" && attempt==1 {
    speculatrace.Emit("EndpointCancelFailure","endpoint","","","",map[string]any{"token":token,"result":"Retryable"})
    return nexus.NewHandlerErrorf(nexus.HandlerErrorTypeUnavailable,"controlled cancel retry")
   }
   if mode=="cancel_refused" {
    speculatrace.Emit("EndpointCancelFailure","endpoint","","","",map[string]any{"token":token,"result":"Refused"})
    return nexus.NewHandlerErrorf(nexus.HandlerErrorTypeBadRequest,"controlled cancel refusal")
   }
   speculatrace.Emit("EndpointCancelAck","endpoint","","","",map[string]any{"token":token,"terminal_callback":false})
   return nil
  },
 }
 endpoint:=env.createRandomExternalNexusServer(ctx,s.T(),handler)
 var responseLost atomic.Bool
 if mode=="response_loss" {
  env.InjectHTTPResponseFault(func(_ context.Context,request *http.Request,response *http.Response,err error)*httpfaults.Outcome {
   if err!=nil || response==nil || response.StatusCode!=http.StatusCreated || !responseLost.CompareAndSwap(false,true) {return nil}
   speculatrace.Emit("LoseResponse","transport","","","",map[string]any{"url":request.URL.String(),"request_header":request.Header,"status":response.StatusCode,"response_header":response.Header})
   return &httpfaults.Outcome{Error:errors.New("Specula accepted-start response loss")}
  })
 }
 run,err:=env.SdkClient().ExecuteWorkflow(ctx,client.StartWorkflowOptions{TaskQueue:taskQueue,WorkflowTaskTimeout:30*time.Second},"specula-nexus-workflow")
 s.Require().NoError(err)
 execution:=&commonpb.WorkflowExecution{WorkflowId:run.GetID(),RunId:run.GetRunID()}
 emit:=func(event,source string,raw any){speculatrace.Emit(event,source,env.NamespaceID().String(),run.GetID(),run.GetRunID(),raw)}
 history:=func()[]*historypb.HistoryEvent{return env.GetHistory(env.Namespace().String(),execution)}
 readback:=func(label string)*persistencespb.WorkflowMutableState {
  r,err:=env.AdminClient().DescribeMutableState(ctx,&adminservice.DescribeMutableStateRequest{Namespace:env.Namespace().String(),Execution:execution,Archetype:chasm.WorkflowArchetype})
  s.Require().NoError(err)
  events:=history()
  rawEvents:=make([]any,0,len(events))
  for _,e:=range events{rawEvents=append(rawEvents,speculatrace.Proto(e))}
  emit("ObservationReadback","recovery",map[string]any{"label":label,"database":speculatrace.State(r.DatabaseMutableState),"history":rawEvents})
  return r.DatabaseMutableState
 }
 poll:=func()*workflowservice.PollWorkflowTaskQueueResponse {
  r,err:=env.FrontendClient().PollWorkflowTaskQueue(ctx,&workflowservice.PollWorkflowTaskQueueRequest{Namespace:env.Namespace().String(),TaskQueue:&taskqueuepb.TaskQueue{Name:taskQueue},Identity:"specula"})
  s.Require().NoError(err)
  s.Require().NotEmpty(r.TaskToken)
  return r
 }
 completeWFT:=func(task *workflowservice.PollWorkflowTaskQueueResponse, commands ...*commandpb.Command)error {
  _,err:=env.FrontendClient().RespondWorkflowTaskCompleted(ctx,&workflowservice.RespondWorkflowTaskCompletedRequest{TaskToken:task.TaskToken,Identity:"specula",Commands:commands})
  return err
 }
 s2c:=time.Duration(0)
 if mode=="below_min" {s2c=100*time.Millisecond}
 s2s:=time.Duration(0)
 if mode=="stale_timer" {s2s=2*time.Second}
 stc:=time.Duration(0)
 if mode=="deferred_cancel" || mode=="timeout_capacity" || mode=="healthy_timeout" || mode=="cancel_below_min" {stc=2*time.Second}
 if mode=="stale_timer" {stc=3*time.Second}
 schedule:=func()*commandpb.Command{return &commandpb.Command{CommandType:enumspb.COMMAND_TYPE_SCHEDULE_NEXUS_OPERATION,Attributes:&commandpb.Command_ScheduleNexusOperationCommandAttributes{ScheduleNexusOperationCommandAttributes:&commandpb.ScheduleNexusOperationCommandAttributes{Endpoint:endpoint,Service:"service",Operation:"operation",Input:testcore.MustToPayload(s.T(),"input"),ScheduleToCloseTimeout:durationpb.New(s2c),ScheduleToStartTimeout:durationpb.New(s2s),StartToCloseTimeout:durationpb.New(stc)}}}}
 bootstrap:=poll()
 readback("bootstrap-before-schedule")
 s.Require().NoError(completeWFT(bootstrap,schedule()))
 if mode=="below_min" {
  await.RequireTrue(s.T(), func()bool{for _,e:=range history(){if e.EventType==enumspb.EVENT_TYPE_NEXUS_OPERATION_TIMED_OUT{return true}};return false},10*time.Second,20*time.Millisecond)
  s.Require().Zero(startCount.Load())
  env.CloseShard(env.NamespaceID().String(),run.GetID())
  readback("below-min-no-wire-final")
  emit("ScenarioEnd","test",map[string]any{"start_calls":0,"cancel_calls":0,"fault_count":0,"response_loss":false})
  return
 }
 var remoteOpts nexus.StartOperationOptions
 select {case remoteOpts=<-accepted:case <-ctx.Done():s.T().Fatal(ctx.Err())}
 waitEvent:=func(kind enumspb.EventType){await.RequireTrue(s.T(), func()bool{for _,e:=range history(){if e.EventType==kind{return true}};return false},20*time.Second,20*time.Millisecond)}
 callback:=func()error {
  endpointMu.Lock();token:=endpointLedger[remoteOpts.RequestID];started:=endpointStart;endpointMu.Unlock()
  options:=nexusrpc.CompleteOperationOptions{OperationToken:token,StartTime:started,Result:testcore.MustToPayload(s.T(),"result"),Header:nexus.Header{commonnexus.CallbackTokenHeader:remoteOpts.CallbackHeader.Get(commonnexus.CallbackTokenHeader)}}
  emit("SendCompletionCallback","transport",map[string]any{"url":remoteOpts.CallbackURL,"options":options})
  err:=s.sendNexusCompletionRequest(ctx,remoteOpts.CallbackURL,options)
  emit("ReceiveCompletionReply","transport",map[string]any{"error":speculatrace.Error(err),"request_id":remoteOpts.RequestID,"token":token})
  return err
 }
 endpointComplete:=func(){emit("EndpointComplete","endpoint",map[string]any{"request_id":remoteOpts.RequestID,"result":"Succeeded"})}
 switch mode {
 case "early_callback":
  endpointComplete()
  s.Require().NoError(callback())
  releaseStart()
  waitEvent(enumspb.EVENT_TYPE_NEXUS_OPERATION_COMPLETED)
  s.Require().Error(callback())
 case "cancel_retry", "cancel_refused", "cancel_below_min":
  waitEvent(enumspb.EVENT_TYPE_NEXUS_OPERATION_STARTED)
  if mode=="cancel_below_min" {
   timer:=time.NewTimer(800*time.Millisecond);defer timer.Stop()
   select{case <-timer.C:case <-ctx.Done():s.T().Fatal(ctx.Err())}
  }
  task:=poll()
  var scheduledID int64
  for _,e:=range history(){if e.EventType==enumspb.EVENT_TYPE_NEXUS_OPERATION_SCHEDULED{scheduledID=e.EventId}}
  s.Require().NoError(completeWFT(task,&commandpb.Command{CommandType:enumspb.COMMAND_TYPE_REQUEST_CANCEL_NEXUS_OPERATION,Attributes:&commandpb.Command_RequestCancelNexusOperationCommandAttributes{RequestCancelNexusOperationCommandAttributes:&commandpb.RequestCancelNexusOperationCommandAttributes{ScheduledEventId:scheduledID}}}))
  kind:=enumspb.EVENT_TYPE_NEXUS_OPERATION_CANCEL_REQUEST_COMPLETED
  if mode=="cancel_refused" || mode=="cancel_below_min"{kind=enumspb.EVENT_TYPE_NEXUS_OPERATION_CANCEL_REQUEST_FAILED}
  waitEvent(kind)
  endpointComplete()
  s.Require().NoError(callback())
  waitEvent(enumspb.EVENT_TYPE_NEXUS_OPERATION_COMPLETED)
 case "deferred_cancel":
  // A real signal and normal WFT create a cancel command while Start is outstanding.
  s.Require().NoError(env.SdkClient().SignalWorkflow(ctx,run.GetID(),run.GetRunID(),"cancel",nil))
  task:=poll()
  var scheduledID int64
  for _,e:=range history(){if e.EventType==enumspb.EVENT_TYPE_NEXUS_OPERATION_SCHEDULED {scheduledID=e.EventId}}
  s.Require().NotZero(scheduledID)
  s.Require().NoError(completeWFT(task,&commandpb.Command{CommandType:enumspb.COMMAND_TYPE_REQUEST_CANCEL_NEXUS_OPERATION,Attributes:&commandpb.Command_RequestCancelNexusOperationCommandAttributes{RequestCancelNexusOperationCommandAttributes:&commandpb.RequestCancelNexusOperationCommandAttributes{ScheduledEventId:scheduledID}}}))
  before:=readback("cancel-committed-before-start-response")
  s.Require().Len(before.ExecutionInfo.SubStateMachinesByType[nexusoperations.OperationMachineType].MachinesById,1)
  releaseStart()
  waitEvent(enumspb.EVENT_TYPE_NEXUS_OPERATION_CANCEL_REQUEST_COMPLETED)
  endpointMu.Lock();deadline:=endpointStart.Add(stc+100*time.Millisecond);endpointMu.Unlock()
  timer:=time.NewTimer(time.Until(deadline));defer timer.Stop()
  select {case <-timer.C:case <-ctx.Done():s.T().Fatal(ctx.Err())}
  db:=readback("past-start-to-close")
  s.Require().Empty(db.ExecutionInfo.StateMachineTimers)
  env.CloseShard(env.NamespaceID().String(),run.GetID())
  db=readback("after-shard-close")
  s.Require().Empty(db.ExecutionInfo.StateMachineTimers)
  _,err=env.AdminClient().RefreshWorkflowTasks(ctx,&adminservice.RefreshWorkflowTasksRequest{NamespaceId:env.NamespaceID().String(),Execution:execution})
  s.Require().NoError(err)
  waitEvent(enumspb.EVENT_TYPE_NEXUS_OPERATION_TIMED_OUT)
  s.Require().EqualValues(1,cancelCount.Load())
 case "timeout_capacity", "healthy_timeout":
  waitEvent(enumspb.EVENT_TYPE_NEXUS_OPERATION_TIMED_OUT)
  db:=readback("timeout-committed")
  s.Require().Len(db.ExecutionInfo.SubStateMachinesByType[nexusoperations.OperationMachineType].MachinesById,1)
  if mode=="timeout_capacity" {
   task:=poll()
   err=completeWFT(task,schedule())
   emit("CommandCallerResult","transport",map[string]any{"error":speculatrace.Error(err)})
   waitEvent(enumspb.EVENT_TYPE_WORKFLOW_TASK_FAILED)
   found:=false
   for _,e:=range history(){if e.GetWorkflowTaskFailedEventAttributes().GetCause()==enumspb.WORKFLOW_TASK_FAILED_CAUSE_PENDING_NEXUS_OPERATIONS_LIMIT_EXCEEDED{found=true}}
   s.Require().True(found)
  }
 case "sync_capacity":
  waitEvent(enumspb.EVENT_TYPE_NEXUS_OPERATION_COMPLETED)
  task:=poll()
  s.Require().NoError(completeWFT(task,schedule()))
  await.RequireTrue(s.T(), func()bool{n:=0;for _,e:=range history(){if e.EventType==enumspb.EVENT_TYPE_NEXUS_OPERATION_COMPLETED{n++}};return n==2},20*time.Second,20*time.Millisecond)
  s.Require().Empty(readback("two-sync-completions").ExecutionInfo.SubStateMachinesByType)
 case "sync_failed", "sync_canceled", "start_refused":
  kind:=enumspb.EVENT_TYPE_NEXUS_OPERATION_FAILED
  if mode=="sync_canceled" {kind=enumspb.EVENT_TYPE_NEXUS_OPERATION_CANCELED}
  waitEvent(kind)
 default:
  waitEvent(enumspb.EVENT_TYPE_NEXUS_OPERATION_STARTED)
  if mode=="start_definite_failure" || mode=="start_execute_timeout" {
   armed.Store(false)
   s.Require().True(faultFired.Load())
   s.Require().EqualValues(1,faultCount.Load())
   env.CloseShard(env.NamespaceID().String(),run.GetID())
   db:=readback("start-persistence-fault-after-shard-close")
   s.Require().Len(db.ExecutionInfo.SubStateMachinesByType[nexusoperations.OperationMachineType].MachinesById,1)
   if mode=="start_definite_failure"{s.Require().GreaterOrEqual(startCount.Load(),int32(2))}
   endpointMu.Lock();s.Require().Len(endpointLedger,1);endpointMu.Unlock()
  }
  if mode=="response_loss" {s.Require().True(responseLost.Load());s.Require().GreaterOrEqual(startCount.Load(),int32(2));endpointMu.Lock();s.Require().Len(endpointLedger,1);endpointMu.Unlock()}
  if mode=="stale_timer" {
   timer:=time.NewTimer(2100*time.Millisecond);defer timer.Stop()
   select{case <-timer.C:case <-ctx.Done():s.T().Fatal(ctx.Err())}
   db:=readback("stale-schedule-to-start-timer-processed")
   s.Require().NotEmpty(db.ExecutionInfo.StateMachineTimers)
  }
  var bufferingTask *workflowservice.PollWorkflowTaskQueueResponse
  if mode=="buffered_callback"{bufferingTask=poll()}
  before:=readback("before-completion")
  endpointComplete()
  if mode=="definite_failure" || mode=="execute_timeout" {
   armed.Store(true)
   _=callback()
   armed.Store(false)
   s.Require().True(faultFired.Load())
   s.Require().EqualValues(1,faultCount.Load())
   env.CloseShard(env.NamespaceID().String(),run.GetID())
   after:=readback("fault-readback-after-shard-close")
   if mode=="execute_timeout" {
    s.Require().Empty(after.ExecutionInfo.SubStateMachinesByType)
   } else {
    // gRPC retry may have committed the same callback after the definite failure;
    // the immediate write-side DB readback in the raw trace preserves noncommit.
    emit("FaultFinalObservation","recovery",map[string]any{"before":speculatrace.State(before),"after":speculatrace.State(after)})
   }
   if len(after.ExecutionInfo.SubStateMachinesByType)>0 {s.Require().NoError(callback())}
  } else {s.Require().NoError(callback())}
  if bufferingTask!=nil {
   db:=readback("callback-buffered-while-wft-started")
   s.Require().NotEmpty(db.BufferedEvents)
   s.Require().NoError(completeWFT(bufferingTask))
  }
  waitEvent(enumspb.EVENT_TYPE_NEXUS_OPERATION_COMPLETED)
  s.Require().Error(callback())
 }
 env.CloseShard(env.NamespaceID().String(),run.GetID())
 readback("final-after-shard-close")
 emit("ScenarioEnd","test",map[string]any{"start_calls":startCount.Load(),"cancel_calls":cancelCount.Load(),"fault_count":faultCount.Load(),"response_loss":responseLost.Load()})
}

func speculaDecodeCallback(token string) any {
 decoded,err:=commonnexus.DecodeCallbackToken(token)
 if err!=nil{panic(err)}
 ref,err:=(&commonnexus.CallbackTokenGenerator{}).DecodeCompletion(decoded)
 if err!=nil{panic(err)}
 return speculatrace.Proto(ref)
}
