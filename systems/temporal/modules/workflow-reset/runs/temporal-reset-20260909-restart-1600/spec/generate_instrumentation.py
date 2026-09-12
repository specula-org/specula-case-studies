from pathlib import Path
import json
O=Path(__file__).parent;A=json.loads((O/'action-manifest.json').read_text())
triggers={
'StartWorkflowExecution':'After creation parameters are allocated and current-execution lock acquired; before shard Create submission.',
'ResetWorkflowExecution':'At frontend/history request entry after normalization of explicit base, finish boundary and reapply exclusions; before base lease.',
'GetWorkflowLease_Base':'After acquisition and LoadMutableState, including the actual stored version/frontier; emit NotFound on failed load.',
'GetCurrentWorkflowRunID':'After GetCurrentExecution returns and the short current lookup lock is released; distinguish NotFound from transient error.',
'GetWorkflowLease_Current':'After concrete current lease/load, or the no-current branch; capture actual CreateRequestId.',
'Invoke_Deduplicate':'Immediately after comparing the current CreateRequestId to the external Reset RequestId, before UUID allocation.',
'Invoke_NewRunID':'Immediately after uuid.New; never manufacture a UUID from the external request ID.',
'ResetWorkflow_UpdateResetRunID':'After volatile base link/current termination preparation and findStartRequestID selection; before fork. Current termination is still uncommitted.',
'ForkHistoryBranch':'After durable fork registration succeeds, before Rebuild; record original and returned tokens and ancestor intervals.',
'Rebuild':'After history-prefix read/rebuild, Start/callback identity assignment and reset WFT preparation; before eligible suffix replay. Capture error instead of a success marker on missing history.',
'ReadHistoryBranch':'After the relevant branch range is read, before applying its events. The trace projection currently treats the finite range as one batch; paginate hook must preserve the full range and errors.',
'ReapplyEvents':'After each individual original event is examined/applied/skipped or rejected; do not collapse a batch. Capture accepted-without-request skips and Update collision error.',
'ReapplyEventsFromBranch_NextRun':'After inspecting the last event of the full range for a CAN successor.',
'GetNextEventIDBranchToken':'After successor load/capture and release of any temporary successor lease, before reading that branch.',
'ScheduleWorkflowTask':'After reapplication/post-reset operations and scheduling succeed; before choosing persistence mode.',
'AppendHistoryNodes_Current':'After appending current termination history, before base/new history or metadata. This is a separate event and interleaving point.',
'AppendHistoryNodes':'After appending the candidate history (or bypass no-event preparation), before metadata. If current termination history exists, AppendHistoryNodes_Current must precede it.',
'PersistenceAppendTimeout':'At the history append timeout return, before any metadata transaction is attempted; capture actual retained append and preserve the retryable AppendHistoryTimeout classification.',
'AssertNotCurrentExecution':'Cassandra only: after assertNotCurrentExecution read; before constructing/executing the conditional metadata batch.',
'CommitWorkflowExecution':'At the durable SQL transaction commit / Cassandra applied=true CAS boundary, before the caller receives its result. Record actual prior current, expected versions and both RangeIDs.',
'RejectWorkflowExecution':'After a real conditional transaction failure with readback showing no metadata commit. Ownership mismatch and current/version mismatch must be distinguished.',
'PersistenceDefiniteRejection':'At the injected definitely-uncommitted ResourceExhausted return before metadata commit; assert injection fired.',
'PersistenceUncertainReturn':'When persistence returns an uncertain result and the caller stops tracking that I/O; capture whether metadata already committed or remains pending. Do not infer rollback from a timeout.',
'PersistenceReturn':'At normal success/definite-failure delivery through shard handleWriteError and the transaction wrapper; release the per-call slot.',
'Invoke_ReturnSuccess':'After handler response construction, before deferred lease release. Distinct from frontend/client receipt.',
'ReleaseWorkflowLease_Success':'After deferred successful cache release; preserve any independently mutated newly created run.',
'ReceiveResetResponse':'At the actual public client receipt. Despite the action name, also used for Start response receipt in setup.',
'LoseResetResponse':'At a verified test transport hook that discards a successful response; record the hidden real RunId in evidence.',
'ReplayResetRequest':'At a client replay of the exact same normalized request after success or a nonretryable error. Capture identical external RequestId/base/finish/exclusion fields.',
'ReleaseWorkflowLease_Error':'After cache Clear/unlock on error and error classification. InternalUpdateCollision is returned to the client, not automatically retried as Unavailable.',
'RetryResetWorkflowExecution':'At actual whole-handler retry/reentry with the same public request; before reacquiring base. Record prior response/error and current readback for the immediate-retry monitor.',
'CrashHistoryService':'At controlled process loss, capturing durable readback after restart separately from pre-crash volatile state. CloseShard alone is a distinct, weaker test and must be labeled.',
'AcquireShard':'After tracked I/O drains, durable RangeID advances and shard serves again. Query durable ownership to verify fencing.',
'ExpireResetRequest':'After the real History RPC deadline expires before another persistence call is admitted; preserve the expired request and error until cache release. Pending writes use their existing uncertain/append-timeout events.',
'DeleteWorkflowExecution_AcquireIO':'After shard I/O semaphore acquisition for deletion stages 1-3; keep it held across current-row deletion until mutable-state deletion finishes.',
'ReadTransientFailure':'At injected non-NotFound read/fork failure; capture original error and fail the attempt, rather than terminating CAN traversal successfully.',
'AddWorkflowTaskStartedEvent':'After the next WorkflowTaskStarted event commits, separately from workflow creation and Update completion; expose the exact valid reset prefix boundary.',
'AddWorkflowExecutionUpdateAcceptedEvent':'At successful accepted-with-request Update metadata commit on the source run; preserve ID and payload class.',
'AddWorkflowExecutionUpdateCompletedEvent':'At successful Update completion metadata commit; the next WFT start is a separate AddWorkflowTaskStartedEvent transition.',
'AddWorkflowExecutionSignaled':'At a successful, fresh public Signal metadata commit; use unique signal request IDs in supported fixtures.',
'ContinueAsNew':'At the atomic current/new-run metadata commit of supported CAN; record both histories and the terminal source CAN event.',
'CompleteWorkflowExecution':'At successful worker completion metadata commit; completion payload and task internals are abstracted.',
'DeleteWorkflowExecution':'At successful public Delete response, after termination/enqueue; this does not imply mutable-state/history deletion.',
'DeleteExecutionTask':'After close-transfer dependency is acknowledged and the deletion worker holds the run lease, before staged persistence deletion.',
'DeleteCurrentWorkflowExecution':'After exact-RunId current deletion returns; capture the actual current pointer, including no-op on another current.',
'DeleteWorkflowMutableState':'After mutable-state removal, before branch deletion; retain the cached branch token for subsequent stages.',
'GetHistoryTreeContainingBranch':'After snapshotting all branch registrations/references and computing deletion ranges, before the delete transaction/batch.',
'DeleteHistoryBranch_SQL':'After the atomic SQL branch-row/range deletion commit.',
'DeleteHistoryBranch_CassandraRow':'At the observed application of branch-row deletion in the logged batch; this can precede or follow range removal.',
'DeleteHistoryBranch_CassandraRanges':'At observed range removal in that logged batch; finish the batch only after both effects are observed.',
'HistoryScannerAge':'When the branch age actually crosses the configured scanner threshold. Record elapsed time and threshold in sidecar evidence.',
'HistoryScavengerVerify':'After DescribeMutableState returns NotFound/NamespaceNotFound for an age-eligible branch, before branch reference capture. Temporary errors must not emit this event.'}
for n in ['UpdateWorkflowExecution_BypassCurrent','CreateWorkflowExecution_BrandNew','UpdateWorkflowExecution_WithNew','ConflictResolveWorkflowExecution','CreateWorkflowExecution_Start']:
    triggers[n]='After per-call shard I/O admission and RangeID/request snapshot assignment, before datastore history append. Record the exact selected mode and all expected current/record versions. '+('For Start, use service/history/api/startworkflow/api.go:210 and workflow/transaction_impl.go:53-94.' if n.endswith('_Start') else '')
t='''# Instrumentation specification: temporal-reset

## 1. Trace event schema

Category A linear NDJSON. Store implementation traces in `../traces/` relative to this directory. `Trace.tla` defaults to `../traces/trace.ndjson`; set `JSON=/absolute/or/relative/file.ndjson` to select a run. Every represented action has exactly one event type, with identical spelling. There are no silent actions.

The first tagged event is `Bootstrap`:

```json
{"tag":"temporal-reset","event":"Bootstrap","config":{"revision":"0c010ce5fe8c0180aa7573c72fe8fc87c6df7025","backend":"SQL","ioConcurrency":1,"historyLimit":16,"startMapPresent":true,"scannerAfterRequestDeadline":true,"runs":["a","b","c"],"ops":["p"],"resetIDs":["reset1"],"startIDs":["start1"],"updateIDs":["u1","u2"],"payloads":["x","y"]},"state":{"db":"REPLACE WITH FULL RECORD","op":"REPLACE WITH FULL MAP","pending":"REPLACE WITH FULL MAP","rt":"REPLACE WITH FULL RECORD","audit":"REPLACE WITH FULL RECORD","deletion":"REPLACE WITH FULL MAP","used":[]}}
```

This is a schema illustration, not a runnable trace. Replace every placeholder with the records specified below. The target namespace/workflow must initially have no execution or history branch. Start the trace before supported setup. `TraceInit` calls the base Init and checks the complete initial snapshot; it will not accept an arbitrary preloaded state. Preprocessing collects all IDs appearing anywhere in the execution into config; it must not reorder or invent transitions.

Subsequent events have exactly `tag`, `event`, `args`, and `state`. `args` uses the names in the action table, including arrays for `ex`. Additional debug metadata belongs in an untagged sidecar; it is not a silently ignored state field. All state records are **required** at every tagged event. `ValidatePostState` compares their full decoded values, including unchanged fields. Missing, extra or mismatched fields fail validation. JSON objects encode record/maps; arrays encode sequences or the explicitly declared sets; booleans remain booleans, IDs are strings, integers remain exact (no floating-point roundtrip). The reserved `none` value is not a real ID.

### State fields and implementation sources

| Snapshot path | Required content / implementation mapping |
|---|---|
| `db.current`, `db.range` | `GetCurrentExecution.RunID` and persisted shard `RangeId`, observed at the relevant storage boundary. Missing current is `none`. Never derive current from a returned candidate ID. |
| `db.runs[r]` | Exactly `exists,status,ver,n,create,start,requestIds,callback,link,can,base,cut,resetReq`. `exists` from execution-row readback; `status` maps RUNNING/COMPLETED/CONTINUED_AS_NEW/TERMINATED; `ver` is DBRecordVersion; `n` is the normalized committed NextEventId frontier. `create` = ExecutionState.CreateRequestId. `start`/`requestIds` = the Start entry selected from RequestIds, with absence preserved for legacy-map fixture. `callback` = addCompletionCallbacks' actual source request ID. `link` = ExecutionInfo.ResetRunId. `can` comes from the terminal CAN event. `base/cut/resetReq` are provenance shadow fields attached to the observed committed reset; resetReq must come from its actual originating API request, never CreateRequestId. |
| `db.hist[r]` | Physically persisted branch event sequence, including uncommitted appended tails, with each normalized event containing `origin,number,kind,id,payload,hasRequest,next,version`. Use original source provenance for reapplied events, even though their local event IDs change. Preserve real-to-normalized event/batch maps in the sidecar. |
| `db.cells[r]`, `db.nodes`, `db.branches` | Ordered physical references `[branch,index]`, the **set** of present physical cells, and **set** of registered history branches. Fork ancestors become shared cells. Collect branch-table data independently of mutable state/reset links. A registered fork may have no candidate execution. |
| `op[p]` | Exact EmptyOp shape in base.tla: `pc,kind,req,base,cut,exclude,candidate,seen,bv,cv,baseN,curN,create,callback,originalToken,prefixToken,localLink,terminate,scan,end,index,batch,input,prefix,built,expected,reapplied,updateIds,visited,frontier,err,result,immediate,adminEpoch,dedup`. Values come from request/local variables, leased snapshots and event processing. `exclude/updateIds` are sets; other event/frontier fields are ordered sequences. `pc` is the action-boundary shadow, not an implementation field. `expected` is an independently filtered source-range oracle; do not fill it from the rebuilt result. |
| `pending[r]` | Exact EmptyWrite shape: `state,mode,owner,epoch,base,seen,bv,cv,curN,create,req,cut,terminate,events,prefix,expected,reapplied,prechecked,reply,result,immediate,adminEpoch`. Storage request snapshot plus actual commit/reject/result-delivery observations. Modes are base/create/same/distinct/start. States are empty/submitted/current-appended/precheck/ready/committed/rejected. `reply` is waiting/returned/lost. This record can outlive its RPC and process. |
| `rt` | `state` acquired/acquiring/stopped; `leases` per-run holder p/q/none/deletion; `currentLock` holder or none; `io` **set** of tracked candidate writes. Observe actual I/O acquisition/release and workflow cache locks, including error clearing and shard reacquisition. |
| `deletion[r]` | `stage,epoch,plan,aged,scanner`. Stages are none/queued/admit/current/mutable/plan/delete/row-first/ranges-first/done/orphan. `plan` is a **set** of physical cells derived from the actual reference-snapshot deletion ranges, not from the final surviving state. |
| `used` | **Set** of all allocated run symbols, including failed attempts; never silently reuse a symbol after failure. |
| `audit` | `acks,receipts,commits,deleted,wanted,terminal` are **sets**; `admin` is a per-request interference-count map; `retryBad,availableBad,reapplyBad` are boolean observation monitors. Build acks and receipts independently at their respective boundaries. Commit records contain run/mode/epoch/durableEpoch/seen/prior/base. Ack records contain request/run/base/kind; receipt records contain request/run. Monitors are derived by independent test assertions over captured identities/history and must not be hardcoded false. They are not additional implementation state. |

`StartMapPresent` is true in every shipped configuration. False is a legacy-record diagnostic abstraction, not a supported Start path at this revision; do not use false for implementation trace acceptance. The fallback helper is encoded but legacy initial records are outside this empty-bootstrap suite. The model projects RequestIds to its Start entry because that is the only map lookup in findStartRequestID; unrelated entries may be kept in the evidence sidecar. Do not erase a Start entry that exists or choose a callback ID based only on comments/helper names.

### Capture discipline

Instrument a controlled test environment with a single sequence-numbered observer. Capture locals/leases while held and storage mutations at their real commit boundaries. Maintain a recorder shadow from **observed** operations, and independently compare it with quiescent direct durable readback after each fault/reload/recovery checkpoint. A readback taken after unrelated mutations is not a snapshot of the earlier event. Coordinate pauses so each tagged snapshot represents one actual linearization of the abstract variables; do not globally hold the current lock across Reset or otherwise remove the race being tested.

Database hooks must distinguish “committed but returned timeout” from “not yet committed at timeout.” A hook placed only outside executionManager cannot establish that. Use SQL transaction commit observation and a separately gated return, or an equivalent backend-specific durable observer. Capture copied request arguments before the call. An ExecuteAndTimeout injection must include evidence that the underlying write ran and a durable readback/restart control. Runtime diagnostic logs from the analysis phase lack these snapshots and are not valid inputs without new instrumentation.

## 2. Action-to-code mapping

Every row requires the complete post-state above. Parameter names are the exact `args` keys. Source paths are relative to the pinned checkout. Entry `Bootstrap` has no base action: it validates base Init before setup.

| Base action = trace event | Args | Code location | Emit point |
|---|---|---|---|
'''
for a in A:
    assert a['name'] in triggers,a['name']
    t+=f"| `{a['name']}` | `{a['args'] or '(none)'}` | `{a['source']}` | {triggers[a['name']]} |\n"
t+='''
## 3. Special considerations and handoff execution

- Preserve supported Start/CAN/Delete setup. For missing current, create an older retained run and a newer current, delete the newer via the public API, and wait for actual current-row removal. Public Delete acknowledgement alone is insufficient. Keep original physical histories for before/after comparison.
- Preserve the three persistence modes in separate fixtures: base=current, base!=current, and missing current. Exact request replay must include both delivered success and deliberately discarded success, plus callback source/readback controls. The known T-1 behavior is allowed by the implementation model even when its contract invariant fails.
- Two active operation IDs are needed for competing requests. SQL I/O capacity two must be explicitly configured for a competing write inside another persistence call. Slot-one schedules should pause between base and Create calls. Cassandra is always slot one; old-owner remote completion is still separately modeled.
- Candidate source history must include surviving CAN chains, repeated Update ID with distinct payloads, distinct-ID controls, exclusions, and a prefix containing an Update entry. Capture admission/acceptance request presence and completion separately. `scannerAfterRequestDeadline` must reflect the configured scanner age versus the History RPC deadline; standard configs use the default 60-day scanner age after the ordinary 30-second History call deadline. With true, age crossing of a candidate requires its attempt to finish/expire first. The short-age sensitivity cfg explicitly disables that relation. The initial environment producers do not yet support direct admitted-then-accepted history or buffered termination-time reapplication; extend those producers before accepting such traces. Never bypass a missing precondition or delete a post-state check to force a match.
- SQL branch deletion is one commit; Cassandra row/range visibility can differ. If the available Cassandra fixture cannot observe those internal boundaries, add a datastore/server/proxy observer. Do not emit invented intermediate snapshots merely from the batch return. SQL trace acceptance does not validate Cassandra.
- `HistoryScannerAge` requires the actual configured age threshold and elapsed time. Default 60-day behavior cannot be inferred from an immediate test hook. If accelerating the threshold, report the setting and model request-deadline interactions. An orphan scanner observation alone does not prove an acknowledged run lost history.
- The trace checks abstract event semantics, not payload serialization, history batch transaction-ID ordering, all Start conflict policies, legacy zero-record-version CAS, worker tasks, activities, child delivery or replication. Preserve those as explicit limitations in reports. CR-3 remains a separate public-handler investigation; do not close it because this model omits child state.
- `Trace.cfg` actively checks TraceMatched with weak fairness of event consumption. A malformed snapshot or unmatched event must fail. No Trace invariant is weakened to accept the known retry/Update defects; the full base action still executes. The known contract monitors are enabled in hunts, while trace checks core/structural consistency.

Run from this directory using the available jars:

```bash
JSON=../traces/trace.ndjson java -XX:+UseParallelGC -Xmx2g \\
  -cp /home/ubuntu/Specula-incremental-dataset-20260815/tools/tla2tools.jar:/home/ubuntu/Specula-incremental-dataset-20260815/tools/CommunityModules-deps.jar \\
  tlc2.TLC -workers 1 -config Trace.cfg Trace
```

For independent environments, supply compatible TLC and CommunityModules jars on the classpath. `validation/` fixtures are explicitly synthetic model-generated plumbing checks; they are not implementation traces. Real traces and test/fault sidecars remain a required next-phase handoff. Record the exact server revision, DB/plugin/config, fault command, observed injected boundary, process versus shard restart, public request/response IDs, durable current/base links, complete normalized history and final worker completion/rejection.
'''
(O/'instrumentation-spec.md').write_text(t)
