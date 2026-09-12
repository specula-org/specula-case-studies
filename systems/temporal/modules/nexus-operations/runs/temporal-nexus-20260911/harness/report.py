#!/usr/bin/env python3
import collections,hashlib,json,pathlib,re,subprocess
H=pathlib.Path(__file__).resolve().parent
S=pathlib.Path('/home/ubuntu/temporal-investigation-20260909/parallel-20260911/source-nexus')
T=H.parent/'traces'
audit=json.loads((H/'evidence'/'trace-audit.json').read_text())
results=json.loads((H/'evidence'/'collection-results.json').read_text())
rows={p.stem:[json.loads(x) for x in p.read_text().splitlines()] for p in T.glob('*.ndjson')}

def refs(name,events):
 return ', '.join(f'`{r["event"]}` #{r["sequence"]}' for r in rows[name] if r['event'] in events)

def readbacks(name):
 return '; '.join(f'{r["raw"]["label"]}: #{r["sequence"]}' for r in rows[name] if r['event']=='ObservationReadback')

def fault(name):
 r=next(r for r in rows[name] if r['event']=='UpdateWorkflowExecution' and r['raw']['write_error'])
 x=r['raw']
 return f'#{r["sequence"]}: requested DB version {x["expected_new_version"]}, actual readback {x["db_record_version"]}, returned `{x["write_error"]["type"]}`'

count=sum(x['rows'] for x in audit['scenarios'].values())
parts=['''# temporal-nexus harness evidence

**Phase status: INCOMPLETE.** Real-source instrumentation, collection, observer-integrity checks, and the requested output scripts exist. The raw observations have **not** been joined into the complete semantic `post` schema required by the supplied Trace. No implementation trace has passed strict TLC replay. The failed format gate is preserved; it is not a Temporal counterexample.

## Pin, route, configuration

`temporalio/temporal@0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`, originally clean checkout. Workflow-owned legacy HSM Nexus operations only. Each schedule runs in a fresh dedicated single-cluster Temporal onebox with actual frontend/history/matching services and real SQL/SQLite persistence. Effective values are read before starting the recorder: CHASM workflow operations=false, rollout=0, transition history=true, cancel-ACK events=true, outbound batch size=100, capacity=1, request timeout=10s, minimum request timeout=1.5s. The controlled endpoint uses the actual configured frontend HTTP callback URL. The recorded endpoint request carries that resolved URL and independently decoded completion reference.

The pinned default is **SQLite `mode=memory, cache=private`**, contrary to the earlier handoff's shared-cache description. The harness explicitly sets `mode=memory, cache=shared` in the test persistence fixture and asserts the effective connection attributes. The initial private-cache run is retained under `evidence/initial-private-cache/` and is excluded from the final recordings. Temporal's SQLite connection pool shares the actual SQL connection; these tests exercise database transactions and shard/cache lifecycle inside one process. They do not test persistence after process exit or another persistence backend.

Request IDs, operation tokens, parent/child initial references, attempt counters, physical TaskIDs, DBRecordVersion, RangeID, task-generation clocks, timestamps and history attributes remain raw. Each final header records the test executable SHA-256. Retry initial/max intervals are both 100ms; actual jittered retry times remain in the observations. No affine time normalization or deadline rounding has been claimed.

## Executed checks

''',f'- {len(results)} focused real functional schedules: all returned 0 and reached their scenario completion marker. {count} raw NDJSON receipts in `../traces/` at this audit.\n',
'''- Existing legacy HSM workflow controls: synchronous completion, completion before start response, prestart cancellation, and S2C/S2S/STC timeouts all passed. Existing `tests/nexus_api_test.go` Start/Cancel outcome matrix passed.
- `go test -tags test_dep -p 4 ./service/history/hsm/nexusoperations/... -count=1 -json` passed both packages.
- The repository's `make lint-code-fast GOLANGCI_LINT_BASE_REV=HEAD GOLANGCI_LINT_FIX=false` passed with 0 lint issues; the final Make target, including its vet check, returned 0 ([log](evidence/lint-final.log)).
- Raw integrity audit checks real timestamps, consecutive receipts, configuration, complete controlled endpoint counts, outgoing/received request identity, decoded initial ref, cancel token, DB readback, persisted HSM/timer equality against the write input, physical queue readback, callback commit observations, and per-scenario required code boundaries.
- Nine deliberately corrupted-observation controls were rejected: wire RequestID, initial reference, missing persisted timer, queue mismatch, DB mismatch, Accepted inserted immediately after definite noncommit, removed receipt, unmatched suffix, and empty recording. These are **observer-audit controls**, not nine passing TLC negative tests. They live only under `evidence/negative-controls/`.
- `bash harness/run.sh` completed collection and checks, then returned **2** at its strict-replay gate. It is reproducible collection with an explicit incomplete validation result, not a successfully completed Phase 2.5 validation.

Exact invocations, binary hashes, per-schedule return codes and trace/log paths: [collection-results.json](evidence/collection-results.json). Observer results: [trace-audit.json](evidence/trace-audit.json), [negative-controls.json](evidence/negative-controls.json). End-to-end output: [run.log](evidence/run.log). TLC commands and exits: [validation-results.json](evidence/validation-results.json).

## Priority questions: implementation evidence

The following are executed code/SQL observations. They are neither model-checking discoveries nor completed formal trace reconfirmations.

| Question | Checked paths and result | Remaining boundary |
|---|---|---|
| Q1 completion/start/cancel/timeout overlap | Healthy and early successful callbacks, duplicate rejection, buffered completion while a normal WFT is Started, synchronous Failed/Canceled outcomes. Early callback deletes the node before the start result can save; the late save is rejected. | Complete semantic transaction/callback join, invalid reference delivery schedules, and exhaustive overlap exploration remain open. |
| Q2 accepted start plus lost response/local write | Accepted response-loss retry uses the same request identity; the controlled endpoint records a dedup hit and one accepted effect. Start-result definite noncommit retries the original task; ExecuteAndTimeout preserves Started/token after reload. | The endpoint's stable dedup/token behavior is an explicit fixture contract. No exactly-once claim for arbitrary remote endpoints. |
| Q3 cancel durability and ACK semantics | Deferred cancel intent is committed before returning Async; the endpoint ACK does not complete the operation. Cancel retry/refusal and local below-min budget paths execute. The existing missing-STC behavior is reproduced with actual DB readback and refresh compensation. | Additional cancellation/completion/timeout interleavings and complete child-reference projection remain open. |
| Q4 stale tasks/timers and recovery | Start retry/backoff, child cancel retry/backoff, stale S2S timer skip after Started, explicit refresh, shard reacquisition, and real post-reload HSM/timer observations. | Controlled duplicate outbound copies, old generation physical wakes and conditional stale writes are not covered. |
| Q5 local commit/notifications/visible outcome | Callback definite failure and ExecuteAndTimeout have independent SQL/readback/error/notification/caller evidence. The definite failure is masked by a successful frontend-to-history retry; ExecuteAndTimeout returns a caller timeout despite a committed completion. | No complete publication/ownership semantic ledger; workflow closure and uncertain writes that later commit after the first read are not explored. |

### Fault receipts
''']
for name in ['response_loss','start_definite_failure','start_execute_timeout','definite_failure','execute_timeout']:
 parts.append(f'\n**{name}** — [raw recording](../traces/{name}.ndjson), [test log](evidence/{name}.log).\n\n')
 if name!='response_loss':parts.append(fault(name)+'.\n\n')
 parts.append(refs(name,{'EndpointAccept','LoseResponse','FaultSelected','PersistenceFault','PersistenceFaultUnderlyingResult','LoseShard','ReacquireShard','ReceiveCompletionReply','ScenarioEnd'})+'.\n\n')
 parts.append('Independent observations: '+readbacks(name)+'.\n')
parts.append('''
### Prior source observations retained

`deferred_cancel` records the cancel child while the operation is still Scheduled, then Started and cancel ACK. After the 2s STC deadline, committed state is still Started with no persisted timer groups; ordinary shard close/readback preserves that absence. Explicit `RefreshWorkflowTasks` reconstructs the timer and the real timer executor times out the operation. This is fresh implementation reconfirmation of the handoff's B1, not formal discovery.

`timeout_capacity` records a TimedOut node retained in the database and a subsequent real schedule command rejected for capacity. `sync_capacity` is the control: two sequential synchronous completions both succeed under capacity=1 and leave no HSM operation node. This is fresh implementation reconfirmation of the handoff's B2. Describe/public history are accompanied by raw database node observations.

## Strict replay and observation gaps

1. The skill mandates `tag="trace"`; supplied `Trace.tla` selects `tag="temporal-nexus"`. The recorder follows the skill. The inputs were preserved; no permissive tag/header wrapper was substituted.
2. The recordings contain raw protobuf receipts (including nulls and full-sized raw IDs), not the required `Init/config/post/args/provenance/evidence` stream. The unchanged validator actually fails first on `unsupported JSON value null`. This is an **unfinished harness schema/projection step**, not a model or implementation violation. All complete semantic `post` states, bijective alias tables, task-ticket ownership, causal joins, normalized time, and completeness attestation remain to be implemented. The JSON reader also requires representable bounded integers; raw nanosecond values cannot simply be copied into TLC values.
3. A separate diagnostic extracts the actual bootstrap WFT status from the DB readback before schedule. It is **Started**; `base.Init` initializes `d.wft="Idle"`. The diagnostic rejects that chosen bootstrap (see [bootstrap-boundary-check.log](evidence/bootstrap-boundary-check.log) and its exact [observation](evidence/bootstrap/observation.json)). This does not prove every possible initialization is impossible. Align the trace bootstrap and the model with actual normal WFT scheduling/commit boundaries; do not overwrite the observed WFT state.
4. WFT bookkeeping and commands share transactions. A signal can also create its own DB commit before WFT start. Raw `CompleteWorkflowTask` and `HandleScheduleCommand` receipts cannot simply be emitted as two independent model transactions. `CloseTransactionBoundary` retains the true grouping. Logical timer executors run before the framework removes the processed timer **group**; a per-logical-timer semantic consumption ledger must be justified against that grouping.
5. The request-targeted **definite** fault here runs before the underlying store, so it has no SQL history-append receipt. The model's DefiniteFailure path requires an Appended phase. Either model that reachable pre-store boundary or add a separately identified post-append fault schedule. The harness does not invent an append or falsely call this an executed post-append failure.
6. A cancel request carries an operation token on the protocol call. The captured request ID is a loaded local correlation value; do not claim it was independently present on the cancel wire. Outbound and callback identities must be joined from their respective actual observations.
7. The independent task-store readback includes physical rows already delivered/acknowledged but not range-cleaned. `queue_rows` is intentionally not renamed to the model's available `queue`. Use task IDs, queue reads, execution/ack receipts and generation clocks to construct and check that projection.
8. `ValidatePostState` is not a stub: the supplied Trace compares every decoded semantic state field, and every wrapper invokes it. **None of those complete implementation post-state checks has passed.** No check was removed, no silent action was enabled, and no model action was run to manufacture observations.

## Coverage gaps

''')
parts.append(f'{len(audit["observed_spec_event_names"])}/59 spec event **names** occur in raw observations. This is a code-boundary count, not action replay coverage.\n\n')
missing=audit['unobserved_spec_event_names']
reasons={
 'AdvanceTime':'Real clock samples are retained, but no semantics-preserving affine time join has been implemented.',
 'CloseWorkflowExecution':'Focused schedules keep the workflow open for final readback; closure is outside this batch.',
 'CompletionHandlerReject':'Rejection is visible in handler-return and caller-response receipts; final same-run fallback classification is not encoded as this wrapper.',
 'ConditionalWriteRejected':'No targeted stale RangeID/DBRecordVersion conditional write was injected.',
 'DiscardLateResponse':'Response loss is injected; an expired request receiving a later response was not scheduled.',
 'DropStaleOutboundTask':'Raw execution/rejection receipts exist, but this canonical drop action is not joined.',
 'DropStaleWake':'An old-generation physical wake schedule is not exercised.',
 'DuplicateOutboundTask':'Ordinary retries occur; independently duplicated delivery tickets are not injected.',
 'LoseCompletionReply':'No callback-response loss after server return is injected.',
 'RejectStaleCall':'Early completion produces a real StartSaveRejected receipt; no canonical call ordinal/state join is emitted.',
 'RequestDeadlineExceeded':'The accepted response-loss fault returns a transport error immediately; it is not a real request deadline expiry.',
}
for name in missing:parts.append(f'- `{name}`: {reasons.get(name,"Not covered in this batch.")}\n')
parts.append('''
Full event counts and raw receipt types are in `evidence/trace-audit.json`. Source capture points are in `evidence/instrumentation-points.txt`.

## Retained failed/intermediate attempts

The initial private-cache smoke run is separate. The first queue readback used a nonzero TaskID in a scheduled-category upper bound; this was corrected and final recordings contain no queue read errors. Initial lints found formatting/assertion conventions and panic-based capture handling; final instrumentation records capture failure and fails test cleanup instead. A prior intermediate collection used an executable built before the last two scenario branches were added; those artifacts are archived and are not the final `traces/` files. Final audit requires each named scenario's actual boundary to appear, and records executable hashes.

The requested full semantic join and successful strict replay remain outstanding. These raw receipts and source hooks are the handoff for completing that work; they must not be presented as finished trace validation.
''')
(H/'EVIDENCE.md').write_text(''.join(parts))
manifest=json.loads((H/'applied.json').read_text())
metadata={'source_revision':subprocess.check_output(['git','-C',str(S),'rev-parse','HEAD'],text=True).strip(),
 'source_changes':manifest,
 'input_sha256':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in (H.parent/'spec').glob('*') if p.is_file() and p.name in ['base.tla','Trace.tla','Trace.cfg','instrumentation-spec.md']},
 'binaries':sorted({r['binary_sha256'] for r in results}),
 'raw_trace_sha256':{name:record['sha256'] for name,record in audit['scenarios'].items()}}
(H/'evidence'/'manifest.json').write_text(json.dumps(metadata,indent=2)+'\n')
print(f'Wrote EVIDENCE.md and manifest for {len(results)} schedules, {count} raw receipts.')
