# Instrumentation mapping: vsr-rs

Pinned source: `3ac0104a567092139534c9022205d02281a2da41`. Category A. Read with `base.tla`, `Trace.tla`, and `brief-coverage.md`. This is a harness handoff, not a claim that implementation traces have already been collected.

## 1. Trace event schema

Write one globally ordered NDJSON file under `../traces/` (sibling of `spec/`). Default is `../traces/trace.ndjson`; `JSON` in the TLC process environment overrides it. Every protocol event has `"tag":"trace"`. Other tags may carry diagnostics and are filtered out; never give a required protocol event a different tag. No event timestamps or independent threads are used to infer order.

Use a controlled owner that serializes individual handler calls, timer callbacks, client calls, crashes, restarts, network drops, and duplications. Capture immediately after **each** call, including ignored-message and no-op calls. Do not wait until the end of a simulator tick or delivery batch. Instrument the harness/scheduler to interpose at those boundaries (`simulator/lib.rs:711-719,907-927`); replies must enter the same tracked fault network rather than bypass it (`950-961`). This does not make the stock simulator's existing oracle sound.

### Bootstrap

First tagged line has these metadata fields and the complete snapshot described below:

```json
{"tag":"trace","event":"Init","schema":1,"system":"vsr-rs","revision":"3ac0104a567092139534c9022205d02281a2da41","category":"A","application":"integer-sum","servers":[0,1,2],"clientIds":["c0"],"operations":[1,2],"primaryTimeout":2,"replicas":[],"clients":[],"network":[],"outputs":[]}
```

The snippet illustrates metadata only: **replace** its empty `replicas` and `clients` with all replica and client snapshot rows. A complete executable bootstrap example is in `validation/trace-positive.ndjson` after generation-time validation.

The actual schema uses `clientIds` for metadata IDs and `clients` for snapshot rows (to avoid a duplicate JSON key). `Trace.tla` derives membership, client set, operation domain, and timeout from the first line. `servers` must be the ordered array `[0,...,N-1]`, with `N >= 2`. `clientIds` is a duplicate-free array of fresh identity labels, excluding the empty-string sentinel. `operations` contains every integer operation in the run, without duplicates. All processes start fresh through `Replica::new` and `Client::new`, view 0, empty volatile state. Later restarts are explicit `Crash` then `Recover`; warm starts without complete preceding history are not accepted by this trace model.

### Common snapshot: mandatory on every tagged event

| JSON field | Type / meaning | Validation |
|---|---|---|
| `replicas` | Array of exactly N rows `{id,live,durableView,incarnation,usedNonces,state}` | All rows and all state fields compared, not only the current node |
| `clients` | Array `{id,state:{view,next,pending}}` for every client | Full `clients` function; pending is `[]` or `[request]` |
| `network` | Array of full canonical messages currently in transit, repeating identical entries for multiplicity | Compared as a multiset; array order irrelevant |
| `outputs` | Full canonical newly drained outputs from this event | Compared as a sequence; messages first, then replies, each in actual drain order |

Replica row fields `live`, `durableView`, `incarnation`, and `usedNonces` are owner snapshots. `incarnation` starts at 0 and increments at each recovery construction. `usedNonces` is an array representing the set of all prior/current recovery tokens for that identity. During a down interval, the destroyed replica has no Rust object: serialize the documented canonical `NewReplica` empty state, while retaining the actual durable view and nonce/identity history. This is an explicit absence representation, not a claim about readable memory after destruction.

`state` has **exactly** these fields; serialize all values, including false, zero, empty arrays and absent-map encodings:

| JSON state field | Rust source field / capture | TLA+ field |
|---|---|---|
| `status` | `Replica.status` (`431`), strings `Normal`, `StateTransfer`, `ViewChange`, `Recovering` | `replicas[i].status` |
| `view`, `lastNormal` | `view_number`, `last_normal_view` (`432-434`) | `view`, `lastNormal` |
| `commit`, `log` | `commit_number`, full `log` (`435-436`); each log entry is `{client,number,op}` (`118-122`) | `commit`, `log` |
| `acks` | `acks` (`438`) as `[{key:op_number,value:[replica_ids]}]` | finite op-to-set map |
| `table` | `client_table` (`441`), map-array values `{number,hasReply,result}` (`398-400`) | finite client table |
| `heard`, `waiting` | `heard_from_primary`, `idle_periods_waiting` (`443,446`) | same meaning |
| `attempts`, `stable` | `view_change_attempts`, `idle_periods_stable` (`455,458`) | exact integer counts |
| `svc`, `dvcSent` | `start_view_change_from`, `do_view_change_sent` (`460,462`) | set array; Boolean |
| `dvc` | `do_view_change_from` (`465`), map-array values `{lastNormal,log,commit}` (`406-410`) | exact report map |
| `catching` | `catching_up` (`468`) | Boolean |
| `nonce`, `responses` | `recovery_nonce`, `recovery_responses` (`470-472`); response values `{view,hasState,log,commit}` (`415-418`) | nonce and report map |
| `app` | Actual integer-accumulator state, inspected through `state_machine()` (`1463`) | application result |
| `applied` | Observer recording the full request at every actual `commit_op` call (`1363-1365`), in order; reset when the application is destroyed | independent per-incarnation execution history |
| `out` | `[]` after both `drain_messages` and `drain_replies` | empty stable outbox; drained payloads are checked in `outputs` |

These are private fields: implement a test-only snapshot helper inside the library module, or use a test-instrumented isolated source copy. Do not reconstruct protocol state by running the TLA+ transition logic in the harness. Record `applied` at actual `commit_op`, before/after actual application as needed, with full request identity; this observer does not decide what the implementation commits. The base ghost `committedHistory` and `replyHistory` are rebuilt by the checker and need no JSON fields.

Maps always use `[{"key":...,"value":...}]`, including `[]` for empty. Numeric keys remain JSON numbers, client keys remain identity strings. Duplicate map keys/set elements are rejected. For `table`, Rust `None` maps to `{hasReply:false,result:0}`; `Some(x)` maps to `{hasReply:true,result:x}`. For recovery state `None`, use `{hasState:false,log:[],commit:0}`. Do not omit optional payload fields.

### Application and identity normalization

The baseline specializes `StateMachine` (`lib.rs:53-60`) to a deterministic integer accumulator: initial value 0; `apply(op)` adds the integer operation and returns the new total. Use this actual Rust state machine in the trace harness. The default operation domain is `{1,2}`. Arbitrary kvstore outputs are not equivalent to this specialization; do not relabel real kvstore values or results to force a match. Validating that application would require an explicit operation/state/result refinement and corresponding spec change.

Map each fresh Rust client ID bijectively to a stable nonempty string (`"c0"`, `"c1"`, ...), preserving identity in every request, log entry, table key, and reply. Reuse must map to the same label, not a fresh label. Predeclare the participating identities in `clientIds`. This model has no client-crash action: use a new, initially idle client identity for a restarted client and record that harness choice.

Replica IDs, view numbers, request numbers, timer counts, and op positions keep their actual integer values. Replica IDs cannot be renamed arbitrarily because they determine primary order. Large u64 recovery nonces may be normalized to small integers by a **per-replica, whole-trace bijection** preserving equality, including old in-flight responses. Recovery requests use the requester's namespace (`src`); responses use the recovering recipient's namespace (`dst`). Repeated raw nonce values must repeat their canonical value, so a freshness violation fails `Recover`; never allocate a new label on every observed restart. Raw clock-policy defects remain EX-NONCE handoffs, not baseline protocol counterexamples.

### Canonical messages

Every message includes all fields of `base!Message`:

```json
{"kind":"Commit","src":0,"dst":1,"view":0,"opnum":0,"commit":1,"start":0,"lastNormal":0,"nonce":0,"hasState":false,"log":[],"request":{"client":"","number":0,"op":0},"result":0}
```

All unused fields use those canonical defaults. Only the fields in the following table override defaults. Preserve full log entries, never just lengths or operation values.

| Kind | Native source | Additional fields |
|---|---|---|
| Request | `147-151` | `request={client_id,request_number,op}`; `src` is that client |
| Prepare | `157-166` | `view`, `opnum`, `request`, `commit` |
| PrepareOk | `170-175` | `view`, `opnum`; `src=replica_id` |
| Commit | `179-182` | `view`, `commit` |
| GetState | `188-192` | `view`, `opnum`; `src=replica_id` |
| NewState | `197-206` | `view`, suffix `log`, `start`, ending `opnum`, `commit` |
| StartViewChange | `211-214` | `view`; `src=replica_id` |
| DoViewChange | `219-228` | `view`, `lastNormal`, full `log`, `opnum`, `commit`; `src=replica_id` |
| StartView | `232-238` | `view`, full `log`, `opnum`, `commit` |
| Recovery | `242-249` | `view`, `nonce`; `src=replica_id` |
| RecoveryResponse | `255-261` | `view`, `nonce`, `hasState`; if state exists, full `log`, `commit`; `src=replica_id` |
| Reply | `126-131` | `view`, `request.client`, `request.number`, `result`; recover `request.op` from the harness's original issued-request registry; `dst=client`, `src=replying replica` |

`src`/`dst` are authentic harness delivery metadata; do not add a new sender guard to Rust. Where `replica_id` is in the payload, the controlled harness must preserve its genuine producer identity. Fabricated sender IDs, arbitrary input bytes, forged responses, and Byzantine peers are outside this model. Message equality includes every canonical field.

### Event-specific fields

Each event also has `tag`, `event`, and exactly the applicable input descriptor:

| Events | Required input fields |
|---|---|
| `OnRequest`, `OnPrepare`, `OnPrepareOk`, `OnCommit`, `OnGetState`, `OnNewState`, `OnStartViewChange`, `OnDoViewChange`, `OnStartView`, `OnRecovery`, `OnRecoveryResponse` | `node`, `message` (exact consumed canonical message) |
| `OnIdle`, `Crash` | `node` |
| `Recover` | `node`, `nonce` (canonical input) |
| `ClientOnRequest` | `client`, `op` |
| `ClientOnIdle` | `client` |
| `ClientOnReply` | `client`, `message` (exact consumed reply) |
| `Lose`, `Duplicate` | `message` |

Every one includes the complete post-snapshot. `Lose` removes exactly one copy; `Duplicate` adds exactly one copy. Both emit `outputs:[]`. Network messages may remain destined for down nodes; no silent discard is permitted. Log explicit loss when the actual transport drops them.

## 2. Action-to-code mapping

All replica-handler events use this boundary: save the input envelope, call `Replica::on_message` **once**, persist `view_number` under the declared conforming caller contract, drain both output queues, enqueue drained outputs in the tracked network, then snapshot before any other handler/timer/delivery executes. Do not emit nested events for synchronous helper calls. Global recovery rejection (`530-536`) is still recorded under the incoming variant's event name. The replica was called even though the specialized handler did not run.

| Base action / event | Source location | Trigger and branch notes |
|---|---|---|
| `OnRequest` | `lib.rs:528-544,646-694` | After full dispatch; captures ignored backup/non-normal/old request, cached replay, or new append/self-ack/broadcast. No added self-quorum evaluation. |
| `OnPrepare` | `lib.rs:545-559,701-730,795-812` | After dispatch including acceptance side effects; gap, append, and duplicate helper branches remain distinct. Snapshot `heard` even after rejection. |
| `OnPrepareOk` | `lib.rs:560-566,737-767` | After ack insertion and any whole-prefix commit/reply/ack cleanup; duplicate sender does not count twice. |
| `OnCommit` | `lib.rs:567-572,776-784` | After acceptance, transfer initiation, or commit; no partial commit on an over-log heartbeat. |
| `OnGetState` | `lib.rs:573-579,818-837` | After reply construction or ignore; do not add a primary-role requirement. |
| `OnNewState` | `lib.rs:580-594,842-893` | After all suffix appends/install, commit, Normal transition and ack; same-view transfer and catching-up have different guards/reset behavior. |
| `OnStartViewChange` | `lib.rs:595-600,906-921` | After adoption/reply/ignore, sender insertion and any synchronous DVC contribution. |
| `OnDoViewChange` | `lib.rs:601-616,926-942,1043-1080` | After report overwrite and possible whole view installation, commit/reply, enter-normal, self-ack initialization and StartView broadcast. Capture selected reports through resulting state/outputs; do not add an extra transition. |
| `OnStartView` | `lib.rs:617-625,948-967` | After install, commit, enter-normal, ack reset and PrepareOk; equal-view replay outside ViewChange is ignored. |
| `OnRecovery` | `lib.rs:626-632,1131-1149` | After higher-view change or Normal response; a newer persisted view does not also get a response. |
| `OnRecoveryResponse` | `lib.rs:633-639,1159-1205` | After nonce/status checks, sender overwrite, max-view/primary filtering, and possible recovery completion. No implicit PrepareOk. |
| `OnIdle` | `lib.rs:1233-1285` | After one replica idle call and all ordered retries/timer effects; includes primary, backup, transfer, ViewChange and Recovering branches. Exact counts, not a synthetic timeout jump. |
| `ClientOnRequest` | `lib.rs:311-326,374-375` | After request-number allocation, pending update, and client drain. Enforce caller's single outstanding request precondition (`274-277`); outputs go to learned-view primary. |
| `ClientOnIdle` | `lib.rs:353-370,374-375` | After one client idle call and drain; retry broadcasts to all IDs. Empty pending still produces an explicit no-op event if called. |
| `ClientOnReply` | `lib.rs:334-347` | After one delivered reply; snapshot view even when no pending request matched. Reply is consumed from tracked network. |
| `Crash` | Caller destruction; contract `lib.rs:14-21`; reference scheduler `simulator/lib.rs:695-704` | After destroying the actual replica/application; retain independently persisted view. Pending tracked network survives unless separately lost. No call to `Replica::new` for that old identity. |
| `Recover` | `lib.rs:511-524,1208-1214`; caller reference `simulator/lib.rs:695-704` | After actual `Replica::recover(id,config,fresh_sm,durable_view,nonce)`, drain and enqueue recovery requests, increment incarnation and record nonce. Capture supplied durable view/nonce rather than recomputing from peers. |
| `Lose` | Owner delivery policy, `lib.rs:10-12`; simulator scheduler `simulator/lib.rs:907-927` | After one explicit queue loss, before another event; applies equally to replies. |
| `Duplicate` | Same owner boundary | After adding a copy of an already present authentic queue entry; no new payload is invented. |
| `Init` (initial predicate) | `lib.rs:292-300,478-503` | After all fresh constructors, before any callback, with durable initial view 0 and empty network. |

Pure helper operators such as `InstallLogState`, `CommitUpTo`, `RecordDoViewChange`, `StartViewChange`, `CatchUpWithView`, and the three `OnPrepare*` branches execute inside the one owner call. They have no separate trace events because the implementation exposes no interleaving point inside them. `OnMessage` is only a disjunction of the eleven variant actions, not another event.

## 3. Special considerations

- **Separate output vectors:** Rust has independent `outbox` and `replies` (`473-474`). Preserve each vector's order; normalize `outputs` to protocol messages followed by replies. This imposes no cross-vector delivery order because `network` is a multiset. Persist before either class is released. `base!CanonicalOutput` performs the same normalization.
- **Application observation:** capture actual application state/result and full execution history. Never set `app` from `Sum(log)` in the harness; that would make `AppliedPrefix` and result checks circular.
- **Assertions:** authentic sends supply consistent full/suffix lengths. Do not suppress `on_message` (`609,623`), `on_new_state` (`853,871,887`), or `install_log` (`1325`) assertion failures. The model checks shape/bounds; overlapping-entry equality is an invariant consequence, not an invented acceptance guard.
- **Timing and persistence:** an atomic model step combines a handler with successful durable-view publication and output release. Successful owner calls are observed at that boundary. Real socket stalls, interrupted directory publication, startup read/parse fallback, and wall-clock allocation policy require their separate integration tests. The model does not simulate these failures.
- **No silent replay actions:** every callback and environment mutation has an explicit event. An omitted state-changing/interdependent event (such as the tested Prepare), wrong full request, changed timer count, false reply result, or unmatched output causes replay failure when subsequent captured state exposes the mismatch. Omitted observational no-op callbacks and an unrecorded terminal suffix may be undetectable: `TraceMatched` proves consumption of the supplied file, not independent capture completeness. Preserve a harness event count/completion record outside this replay contract when auditing capture completeness. Fix capture timing or model/source correspondence; do not remove fields or replace post-state validation with a stub.
- **Bounds:** trace replay uses no MC counters/symmetry/buffer pruning. It follows every event under the baseline assumptions. `TraceMatched` is enabled in `Trace.cfg`; replay fairness only consumes an enabled next event and is unrelated to client-progress fairness.
- **Scope:** no simulator reproduction was performed during spec generation, so no simulator regression seed is asserted. If downstream confirmation reproduces a bug in the simulator, add the required integration regression in `tests` and record seed plus pinned commit per `AGENTS.md`.

Run from this directory with a TLC jar and the CommunityModules dependencies jar on the classpath:

```sh
JSON=../traces/trace.ndjson java -XX:+UseParallelGC -Xmx2g -cp "$TLA_TOOLS_JAR:$COMMUNITY_MODULES_JAR" tlc2.TLC -workers 1 -config Trace.cfg Trace.tla
```

The generation-time positive/negative fixtures in `validation/` are synthetic validator tests, not implementation traces. See `validation.md` for exact results and commands.
