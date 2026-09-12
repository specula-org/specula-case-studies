#!/usr/bin/env python3
import hashlib, json, os, pathlib, re, subprocess
H = pathlib.Path(__file__).resolve().parent
S = pathlib.Path(os.environ.get('TEMPORAL_SOURCE', '/home/ubuntu/temporal-investigation-20260909/parallel-20260911/source-nexus')).resolve()
PIN = '0c010ce5fe8c0180aa7573c72fe8fc87c6df7025'
assert subprocess.check_output(['git','-C',str(S),'rev-parse','HEAD'], text=True).strip() == PIN
manifest_path = H/'applied.json'
previous = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
out = {}
def original(path):
    return subprocess.check_output(['git','-C',str(S),'show',f'{PIN}:{path}'], text=True)
def put(path, content):
    p=S/path
    match=re.search(r'import \(\n(.*?)\n\)',content,re.S)
    if match:
        lines=[line.strip() for line in match[1].splitlines() if line.strip()]
        if all(re.fullmatch(r'(?:[\w.]+\s+)?"[^"]+"(?:\s*//.*)?',line) for line in lines):
            key=lambda line:re.search(r'"([^"]+)"',line)[1]
            standard=sorted([line for line in lines if '.' not in key(line).split('/')[0]],key=key)
            external=sorted([line for line in lines if '.' in key(line).split('/')[0]],key=key)
            block='import (\n'+'\n'.join('\t'+line for line in standard)
            if standard and external:block+='\n\n'
            block+='\n'.join('\t'+line for line in external)+'\n)'
            content=content[:match.start()]+block+content[match.end():]
    raw=content.encode()
    if p.exists():
        current=p.read_bytes()
        if current != raw:
            allowed=previous.get(path,{}).get('sha256')
            if hashlib.sha256(current).hexdigest()!=allowed:
                try: clean=original(path).encode()
                except subprocess.CalledProcessError: clean=None
                if current != clean: raise RuntimeError(f'Refusing to overwrite unrelated changes: {p}')
    p.parent.mkdir(parents=True,exist_ok=True)
    p.write_bytes(raw)
    out[path]={'sha256':hashlib.sha256(raw).hexdigest()}
    manifest_path.write_text(json.dumps({**previous, **out},indent=2)+'\n')
def patch(path, pairs, imports=True):
    s=original(path)
    if imports:
        s=s.replace('import (','import (\n "go.temporal.io/server/common/speculatrace"',1)
    for a,b in pairs:
        if s.count(a)!=1: raise RuntimeError(f'{path}: expected unique anchor {a[:100]!r}, count={s.count(a)}')
        s=s.replace(a,b,1)
    put(path,s)
def function(s, signature):
    start=s.index(signature)
    end=s.find('\nfunc ',start+len(signature))
    return start, len(s) if end<0 else end
def transform(path, signature, change, imports=False):
    s=(S/path).read_text() if path in out else original(path)
    if imports and '"go.temporal.io/server/common/speculatrace"' not in s:
        s=s.replace('import (','import (\n "go.temporal.io/server/common/speculatrace"',1)
    a,b=function(s,signature)
    chunk=s[a:b]
    new=change(chunk)
    assert new != chunk, (path,signature)
    # permit own intermediate output
    previous.update(out)
    put(path,s[:a]+new+s[b:])

patch('service/history/hsm/nexusoperations/workflow/commands.go',[
 ('return nexusoperations.ScheduledEventDefinition{}.Apply(root, event)', '''err := nexusoperations.ScheduledEventDefinition{}.Apply(root, event)
 if err == nil { root.SpeculaEmit("HandleScheduleCommand", map[string]any{"event": speculatrace.Proto(event), "capacity": ch.config.MaxConcurrentOperations(nsName)}) }
 return err'''),
 ('err = nexusoperations.CancelRequestedEventDefinition{}.Apply(ms.HSM(), event)', '''err = nexusoperations.CancelRequestedEventDefinition{}.Apply(ms.HSM(), event)
 if err == nil || errors.Is(err, hsm.ErrStateMachineNotFound) { ms.HSM().SpeculaEmit("HandleCancelCommand", map[string]any{"event": speculatrace.Proto(event), "apply_error": speculatrace.Error(err)}) }'''),
 ('if coll.Size() >= ch.config.MaxConcurrentOperations(nsName) {', '''if coll.Size() >= ch.config.MaxConcurrentOperations(nsName) {
  root.SpeculaEmit("HandleScheduleCommandLimit", map[string]any{"capacity": ch.config.MaxConcurrentOperations(nsName), "physical_count": coll.Size()})'''),
])

nx='service/history/hsm/nexusoperations/executors.go'
patch(nx,[
 ('args.namespaceFailoverVersion = event.Version\n\t\treturn nil','''args.namespaceFailoverVersion = event.Version
  node.SpeculaEmit("loadOperationArgs", map[string]any{"ref": speculatrace.Proto(ref.StateMachineRef), "task_id": ref.TaskID, "event": speculatrace.Proto(event), "request_id": args.requestID})
  return nil'''),
 ('result, callErr = e.startViaHTTP(callCtx, client, args, options)', '''speculaCall("executeInvocationTask", ref, map[string]any{"options": options, "budget_ns": int64(callTimeout), "scheduled_time": args.scheduledTime})
  result, callErr = e.startViaHTTP(callCtx, client, args, options)
  speculaCall("ReceiveStartResponse", ref, speculaStartResult(result, callErr))'''),
 ('callErr = handle.Cancel(callCtx, nexus.CancelOperationOptions{Header: header})','''speculaCall("executeCancelationTask", ref, map[string]any{"token": args.token, "request_id": args.requestID, "budget_ns": int64(callTimeout), "header": header})
  callErr = handle.Cancel(callCtx, nexus.CancelOperationOptions{Header: header})
  speculaCall("ReceiveCancelResponse", ref, map[string]any{"error": speculatrace.Error(callErr)})'''),
 ('emitMetrics = e.deferredOperationMetric(finalOp, callErr, node.NamespaceName(), node.WorkflowTypeName(), env.Now())', '''node.SpeculaEmit(speculaStartAction(finalOp, callErr), map[string]any{"ref": speculatrace.Proto(ref.StateMachineRef), "task_id": ref.TaskID, "result": speculaStartResult(result, callErr)})
  emitMetrics = e.deferredOperationMetric(finalOp, callErr, node.NamespaceName(), node.WorkflowTypeName(), env.Now())'''),
 ('emitOperationTimedOut(e.MetricsHandler, e.metricTagConfig(), op, node.NamespaceName(), node.WorkflowTypeName(), timeoutType.String(), env.Now())','''node.SpeculaEmit("executeOperationTimeout", map[string]any{"timeout_type": timeoutType.String()})
 emitOperationTimedOut(e.MetricsHandler, e.metricTagConfig(), op, node.NamespaceName(), node.WorkflowTypeName(), timeoutType.String(), env.Now())'''),
 ('args.payload = attrs.GetInput()\n\t\t}\n\t\treturn nil','''args.payload = attrs.GetInput()
  }
  n.SpeculaEmit("loadArgsForCancelation", map[string]any{"ref": speculatrace.Proto(ref.StateMachineRef), "task_id": ref.TaskID, "request_id": args.requestID, "token": args.token})
  return nil''')
])
for sig,event in [('func (e taskExecutor) executeBackoffTask(', 'executeBackoffTask'), ('func (e taskExecutor) executeCancelationBackoffTask(', 'executeCancelationBackoffTask')]:
    transform(nx,sig,lambda c,event=event: c.replace('return hsm.MachineTransition(', 'err := hsm.MachineTransition(',1).replace('\n\t})\n}',f'\n\t}})\n if err == nil {{ node.SpeculaEmit("{event}", map[string]any{{"type": task.Type(), "deadline": task.Deadline()}}) }}\n return err\n}}',1))
transform(nx,'func (e taskExecutor) saveCancelationResult(', lambda c:c.replace('return hsm.MachineTransition(n,','err := hsm.MachineTransition(n,',1).replace('\n\t\t})\n\t})','''
  })
  if err == nil { n.SpeculaEmit(speculaCancelAction(n), map[string]any{"ref": speculatrace.Proto(ref.StateMachineRef), "task_id": ref.TaskID, "error": speculatrace.Error(callErr)}) }
  return err
 })''',1))
for sig,event in [('func (e taskExecutor) executeInvocationTask(', 'executeInvocationTaskBelowMin'),('func (e taskExecutor) executeCancelationTask(', 'executeCancelationTaskBelowMin')]:
    transform(nx,sig,lambda c,event=event: c.replace('callErr = &operationTimeoutBelowMinError{timeoutType: timeoutType}',f'callErr = &operationTimeoutBelowMinError{{timeoutType: timeoutType}}\n speculaCall("{event}", ref, map[string]any{{"budget_ns": int64(callTimeout), "error": speculatrace.Error(callErr)}})',1))
patch('service/history/hsm/nexusoperations/completion.go',[
 ('emitMetrics = h.deferredCompletionMetric(operation, node.NamespaceName(), node.WorkflowTypeName(), opFailedError, emitScheduleToStart, env.Now())','''node.SpeculaEmit("CompletionHandlerHandle", map[string]any{"ref": speculatrace.Proto(ref.StateMachineRef), "request_id": requestID, "token": operationToken, "start_time": startTime, "error": speculatrace.Error(opFailedError)})
  emitMetrics = h.deferredCompletionMetric(operation, node.NamespaceName(), node.WorkflowTypeName(), opFailedError, emitScheduleToStart, env.Now())'''),
 ('// The initial version of the completion token did not include a request ID.', '''defer func() { speculaCall("CompletionHandlerReturnBoundary", ref, map[string]any{"request_id": requestID}) }()
 // The initial version of the completion token did not include a request ID.'''),
])
patch('service/history/workflow/task_generator.go',[
 ('AddNextStateMachineTimerTask(r.mutableState)\n\n\treturn nil','''AddNextStateMachineTimerTask(r.mutableState)
 r.mutableState.HSM().SpeculaEmit("GenerateDirtySubStateMachineTasks", nil)
 return nil''')
],False)
patch('service/history/workflow/mutable_state_impl.go',[
 ('ms.currentTransactionAddedStateMachineEventTypes = append(ms.currentTransactionAddedStateMachineEventTypes, t)\n\treturn event','''ms.currentTransactionAddedStateMachineEventTypes = append(ms.currentTransactionAddedStateMachineEventTypes, t)
 if speculatrace.Active(ms.executionInfo.NamespaceId) { speculatrace.Emit("HistoryEvent", "workflow-lock", ms.executionInfo.NamespaceId, ms.executionInfo.WorkflowId, ms.executionState.RunId, speculatrace.Proto(event)) }
 return event'''),

])
transform('service/history/workflow/mutable_state_impl.go','func (ms *MutableStateImpl) CloseTransactionAsMutation(',lambda c:c.replace('ms.checksum = result.checksum', 'ms.checksum = result.checksum\n ms.SpeculaEmit("CloseTransactionBoundary", map[string]any{"new_buffered_events": result.bufferEvents, "clear_buffered_events": result.clearBuffer, "workflow_events": result.workflowEventsSeq})',1))
patch('service/history/hsm/tree.go',[
 ('n.persistence.Data = serialized\n\tn.cache.dirty = true','''n.persistence.Data = serialized
 n.cache.dirty = true'''),
 ('\n\treturn nil\n}\n\n// A Collection of similarly typed sibling state machines.', '''
 n.SpeculaEmit("HSMTransition", map[string]any{"type": n.Key.Type, "transition_tasks": speculaTasks(output.Tasks)})
 return nil
}

// A Collection of similarly typed sibling state machines.'''),
 ('delete(n.cache.children, key)\n\treturn nil','''delete(n.cache.children, key)
 child.SpeculaEmit("HSMDelete", nil)
 return nil''')
],False)
patch('service/history/statemachine_environment.go',[
 ('if accessType == hsm.AccessRead {\n\t\treturn nil\n\t}', '''ms.HSM().SpeculaEmit("AccessMutationBoundary", map[string]any{"access_type": accessType, "task_id": ref.TaskID, "ref": speculatrace.Proto(ref.StateMachineRef)})
 if accessType == hsm.AccessRead { return nil }'''),
 ('\t\tif accessType == hsm.AccessWrite && accessed {\n\t\t\trelease(retErr)', '''if accessType == hsm.AccessWrite && accessed {
   release(retErr)
   speculatrace.Emit("AccessReturn", "persistence", ref.WorkflowKey.NamespaceID, ref.WorkflowKey.WorkflowID, ref.WorkflowKey.RunID, map[string]any{"error": speculatrace.Error(retErr), "ref": speculatrace.Proto(ref.StateMachineRef), "task_id": ref.TaskID})''')
])
patch('service/history/workflow/context.go',[
 ('c.MutableState = mutableState', 'c.MutableState = mutableState\n mutableState.HSM().SpeculaEmit("LoadMutableState", map[string]any{"range_id":shardContext.GetRangeID(),"shard_id":shardContext.GetShardID()})'),
 ('func (c *ContextImpl) Clear() {','''func (c *ContextImpl) Clear() {
 if c.MutableState != nil { speculatrace.Emit("CacheLoss", "recovery", c.workflowKey.NamespaceID, c.workflowKey.WorkflowID, c.workflowKey.RunID, nil) }'''),
])
patch('service/history/workflow/task_refresher.go',[],False)
transform('service/history/workflow/task_refresher.go','func (r *TaskRefresherImpl) Refresh(',lambda c:c.replace('\n\treturn nil\n}', '\n mutableState.HSM().SpeculaEmit("RefreshWorkflowTasks", nil)\n return nil\n}',1))
patch('service/history/timer_queue_task_executor_base.go',[
 ('\ttimers := ms.GetExecutionInfo().StateMachineTimers\n\tprocessedTimers := 0','''ms.HSM().SpeculaEmit("executeStateMachineTimerTask", map[string]any{"task": task})
 timers := ms.GetExecutionInfo().StateMachineTimers
 processedTimers := 0'''),
 ('t.logger.Info("Skipped state machine timer", tag.Error(err))','''t.logger.Info("Skipped state machine timer", tag.Error(err))
    ms.HSM().SpeculaEmit("SkipStaleTimer", map[string]any{"timer": speculatrace.Proto(timer), "deadline": group.Deadline.AsTime(), "error": speculatrace.Error(err)})'''),
 ('\treturn processedTimers, nil','''ms.HSM().SpeculaEmit("FinishStateMachineTimers", map[string]any{"processed_groups": processedTimers})
 return processedTimers, nil''')
])
patch('common/persistence/sql/execution.go',[
 ('\t// then update mutable state\n\treturn m.txExecuteShardLocked(ctx,','''speculatrace.Emit("AppendHistoryNodes", "persistence", request.UpdateWorkflowMutation.NamespaceID, request.UpdateWorkflowMutation.WorkflowID, request.UpdateWorkflowMutation.ExecutionState.RunId, map[string]any{"range_id": request.RangeID, "db_record_version": request.UpdateWorkflowMutation.DBRecordVersion, "appends": request.UpdateWorkflowNewEvents})
 // then update mutable state
 err := m.txExecuteShardLocked(ctx,'''),
 ('return m.updateWorkflowExecutionTx(ctx, tx, request)\n\t\t})','''return m.updateWorkflowExecutionTx(ctx, tx, request)
  })
 speculatrace.Emit("SQLCommitResult", "persistence", request.UpdateWorkflowMutation.NamespaceID, request.UpdateWorkflowMutation.WorkflowID, request.UpdateWorkflowMutation.ExecutionState.RunId, map[string]any{"range_id": request.RangeID, "db_record_version": request.UpdateWorkflowMutation.DBRecordVersion, "error": speculatrace.Error(err)})
 return err''')
])
patch('common/persistence/execution_manager.go',[
 ('\terr = m.persistence.UpdateWorkflowExecution(ctx, newRequest)','''if speculatrace.Active(updateMutation.ExecutionInfo.NamespaceId) {
  speculatrace.Emit("PersistenceWriteRequest", "persistence", updateMutation.ExecutionInfo.NamespaceId, updateMutation.ExecutionInfo.WorkflowId, updateMutation.ExecutionState.RunId, map[string]any{"range_id": request.RangeID, "db_record_version": updateMutation.DBRecordVersion, "execution_info": speculatrace.Proto(updateMutation.ExecutionInfo), "execution_state": speculatrace.Proto(updateMutation.ExecutionState), "new_buffered_events": updateMutation.NewBufferedEvents, "clear_buffered_events": updateMutation.ClearBufferedEvents, "events": request.UpdateWorkflowEvents, "tasks": speculaPhysicalTasks(updateMutation.Tasks)})
 }
 err = m.persistence.UpdateWorkflowExecution(ctx, newRequest)
 if speculatrace.Active(updateMutation.ExecutionInfo.NamespaceId) { m.speculaReadback(ctx, request, err) }'''),
 ('\treturn newResponse, respErr','''speculatrace.Emit("PersistenceReadback", "persistence", request.NamespaceID, request.WorkflowID, request.RunID, map[string]any{"readback_id":ctx.Value(speculaReadContextKey{}),"state": speculatrace.State(state), "db_record_version": response.DBRecordVersion, "error": speculatrace.Error(respErr), "shard_id": request.ShardID})
 return newResponse, respErr'''),
 ('\t\thistoryTasks = append(historyTasks, task)','''speculatrace.Emit("QueueRead", "persistence", task.GetNamespaceID(), task.GetWorkflowID(), task.GetRunID(), map[string]any{"readback_id":ctx.Value(speculaReadContextKey{}),"task": task, "category": request.TaskCategory.ID(), "task_id": task.GetTaskID(), "visibility_time": task.GetVisibilityTime()})
  historyTasks = append(historyTasks, task)''')
])
patch('service/history/workflow/transaction_impl.go',[
 ('\tif persistence.OperationPossiblySucceeded(err) {\n\t\tNotifyOnExecutionMutation(engine, archetypeID, currentWorkflowMutation)', '''speculatrace.Emit("NotifyOnExecutionMutation", "persistence", currentWorkflowMutation.ExecutionInfo.NamespaceId, currentWorkflowMutation.ExecutionInfo.WorkflowId, currentWorkflowMutation.ExecutionState.RunId, map[string]any{"error": speculatrace.Error(err), "possibly_succeeded": persistence.OperationPossiblySucceeded(err), "db_record_version": currentWorkflowMutation.DBRecordVersion})
 if persistence.OperationPossiblySucceeded(err) {
  NotifyOnExecutionMutation(engine, archetypeID, currentWorkflowMutation)''')
])
patch('service/history/queues/executable.go',[
 ('\te.state = ctasks.TaskStateAcked','''e.state = ctasks.TaskStateAcked
 speculatrace.Emit("QueueAck", "recovery", e.GetNamespaceID(), e.GetWorkflowID(), e.GetRunID(), map[string]any{"task": e.Task, "task_id": e.GetTaskID(), "invalid": e.invalidTask})''')
])
patch('common/persistence/faultinjection/store_fault_generator.go',[
 ('\t\tf := newFaultFromError(err, 1.0)','''if _, ok := err.(speculatrace.ExecuteAndTimeout); ok {
   f := newFault("ExecuteAndTimeout", 1.0, target.Method)
   return &f
  }
  f := newFaultFromError(err, 1.0)''')
])
patch('common/persistence/faultinjection/fault.go',[
 ('\tif f.execOp {\n\t\terr := op()','''speculatrace.Emit("PersistenceFault", "persistence", "", "", "", map[string]any{"execute_operation": f.execOp, "injected_error": speculatrace.Error(f.err)})
 if f.execOp {
  err := op()
  speculatrace.Emit("PersistenceFaultUnderlyingResult", "persistence", "", "", "", map[string]any{"error": speculatrace.Error(err)})''')
])

patch('tests/testcore/test_cluster.go',[
 ('options.ApplyDefaults(&defaults)','''options.ApplyDefaults(&defaults)
 if speculatrace.Enabled() { options.ConnectAttributes = map[string]string{"mode":"memory", "cache":"shared"} }''')
])
patch('service/history/workflow/workflow_task_state_machine.go',[
 ('return startedEvent, workflowTask, nil','m.ms.SpeculaEmit("StartWorkflowTask", nil)\n return startedEvent, workflowTask, nil')
],False)
transform('service/history/workflow/workflow_task_state_machine.go','func (m *workflowTaskStateMachine) AddWorkflowTaskCompletedEvent(',lambda c:c.replace('return event, nil','m.ms.SpeculaEmit("CompleteWorkflowTask", nil)\n return event, nil',1))
patch('common/persistence/shard_manager.go',[
 ('return m.shardStore.UpdateShard(ctx, internalRequest)','''err = m.shardStore.UpdateShard(ctx, internalRequest)
 event:="ShardUpdate"
 if err==nil && request.PreviousRangeID!=request.ShardInfo.GetRangeId(){event="ReacquireShard"}
 speculatrace.Emit(event, "recovery", "", "", "", map[string]any{"previous_range_id":request.PreviousRangeID,"range_id":request.ShardInfo.GetRangeId(),"shard_id":request.ShardInfo.GetShardId(),"error":speculatrace.Error(err)})
 return err''')
])
patch('service/history/shard/context_impl.go',[
 ('_ = s.transition(contextRequestLost{})','speculatrace.Emit("LoseShard", "recovery", "", "", "", map[string]any{"range_id": requestRangeID, "shard_id":s.GetShardID(), "error":speculatrace.Error(err)})\n _ = s.transition(contextRequestLost{})')
])
transform('service/history/hsm/nexusoperations/executors.go','func (e taskExecutor) saveResult(',lambda c:c.replace('if err != nil {\n\t\treturn err\n\t}\n\tif emitMetrics', 'if err != nil {\n speculaCall("StartSaveRejected", ref, map[string]any{"error":speculatrace.Error(err)})\n return err\n }\n if emitMetrics',1))

transform('service/history/queues/executable.go','func (e *executableImpl) Execute()',lambda c:c.replace('startTime := e.timeSource.Now()','''speculatrace.Emit("QueueExecute", "recovery", e.GetNamespaceID(),e.GetWorkflowID(),e.GetRunID(),map[string]any{"task":e.Task,"task_id":e.GetTaskID(),"reader_id":e.readerID,"attempt":e.attempt.Load()})
 defer func(){speculatrace.Emit("QueueExecutionResult", "recovery", e.GetNamespaceID(),e.GetWorkflowID(),e.GetRunID(),map[string]any{"task_id":e.GetTaskID(),"error":speculatrace.Error(retErr)})}()
 startTime := e.timeSource.Now()''',1))
transform('service/history/hsm/nexusoperations/completion.go','func (h *CompletionHandler) Handle(',lambda c:c.replace(') error {',') (retErr error) {',1).replace('map[string]any{"request_id": requestID}', 'map[string]any{"request_id": requestID,"error":speculatrace.Error(retErr)}',1))
# Copy observer modules and scenario tests after anchored source changes.
for p in sorted((H/'src').rglob('*.go')):
    put(str(p.relative_to(H/'src')),p.read_text())
manifest_path.write_text(json.dumps(out,indent=2)+'\n')
subprocess.run(['gofmt','-w',*[str(S/p) for p in out]],check=True)
for p in out: out[p]['sha256']=hashlib.sha256((S/p).read_bytes()).hexdigest()
manifest_path.write_text(json.dumps(out,indent=2)+'\n')
print(f'Applied {len(out)} trace files at {S}')
