# Instrumentation specification: vsr-rs

Pinned source: `3ac0104a567092139534c9022205d02281a2da41`. Category A. This is a harness-generation handoff; the source has not been instrumented by this task. The schema below is implemented by `Trace.tla`, including mandatory full post-state equality. Use `Trace.tla`'s `Snapshot`, `ExportWire`, `ExportEnvelope`, and normalization functions as the executable schema.

## 1. Trace event schema

Store implementation traces in `../traces/` relative to `spec/`. Default: `../traces/trace.ndjson`; select a run with the `JSON` environment variable. Emit one JSON object per line with `tag: "trace"`. Other tagged logging may coexist; unknown `trace` events are rejected. Traces are globally ordered by the controlled caller/scheduler, not by unsynchronized timestamps.

The first tagged record is an `Init` header:

```json
{"tag":"trace","event":"Init","revision":"3ac0104a567092139534c9022205d02281a2da41","workload":"register-put-old-v1","replicas":[0,1,2],"clients":[3,4],"values":[0,1,2],"primaryTimeout":3,"state":"<full snapshot object described below>"}
```

The string placeholder above must be replaced with an object. Replica IDs must be exactly `0..N-1`, matching `Config::add_replica` (`lib.rs:90-93`). Use globally unique numeric client lifetime IDs disjoint from `0..N-1` (for example 3 and 4 in N=3). If raw application IDs overlap replica IDs, map the client namespace injectively into disjoint integers and preserve that mapping on every request/log/reply. This is endpoint naming only, not an additional restriction on the Rust ClientID contract. Header identities include the finite supply of new client lifetimes that may appear later. N, clients, values and timeout are derived from the header by `Trace.cfg` overrides. No arbitrary nonempty initial log is accepted: start from `Replica::new` / `Client::new` and record the history that established durable views and recovery obligations.

Each later record has mandatory `tag`, `event`, `state` (full **post**-state), and `applies` (ordered list; empty for actions without application calls). Depending on the event, also include the following fields; do not emit unused placeholder event arguments:

- Replica action: `node` (integer).
- Client action: `client` (the normalized lifetime identity).
- Incoming, released, lost, or replayed packet: `message` (normalized envelope).
- `ReplicaOnMessage` / `ReplicaOnIdle`: `branch`, computed from the **pre**-state as below.
- `ClientOnRequest`: `input` and returned `request` number.
- `ClientOnReply`: `accepted`, the actual boolean from `Client::on_reply` after the owner routes by `Reply.client_id`.

`applies` items are `{slot, entry, stateBefore, result, stateAfter}`. `slot` is one-based, `entry` is the full logical request entry, and order is the actual `commit_op` invocation order. They are accumulated during the handler and emitted with its post-state. There is **no separate interleavable Apply event**: one synchronous `&mut self` handler and its helper calls are atomic in the base model, as required by brief S1/S2.

### State fields at every event

The top-level `state` object has exactly these fields:

| Field | JSON representation | Captured state / TLA variable |
|---|---|---|
| `replicas` | N-element array in ID order | Per-replica projection below; `r[i]` |
| `durableViews` | N-element integer array | Caller-owned last completed durable view publication, `durableView` |
| `lives` | N-element array of `Running`, `Paused`, `Down` | Fault-controller state, `life` |
| `phases` | N-element array of `Persist`, `Release` | Caller shadow: after a handler/recover, Persist; after persist callback, Release |
| `incarnations` | N-element integer array, starts at 0 | Observer recovery epoch; increments once at each `recover`, not at crash |
| `clients` | Array of `{id, state}` for every header client identity | `Client` projection below |
| `retiredClients` | Array representing a set of identities | Permanently retired client lifetimes |
| `invocations` | Array representing a set of entries | Actual `ClientOnRequest` history, including retired clients; `requestInput` |
| `acceptedReplies` | Array representing a set of envelopes | Actual accepted client reply facts, `acceptedReplies` |
| `network` / `replyChannel` | Array of `{message, count}` with unique message keys, positive multiplicity | Independent controlled protocol/request and reply transport bags |
| `released` | Array representing a set of envelopes | Immutable authentic packet catalogue, including delivered/lost packets |
| `applications` | Array of `{replica, incarnation, entries}` with unique replica/incarnation keys | Actual applied-entry sequences retained across crashes, `appliedByIncarnation` |

Per-replica object (`lib.rs:427-474`; private access requires a feature-gated debug snapshot inside the library):

| Fields | Source and normalization |
|---|---|
| `id`, `status`, `view`, `lastNormal`, `commit`, `log` | `self_id`, `status`, `view_number`, `last_normal_view`, `commit_number`, `log` (429,431-436) |
| `acks` | Array of `{slot, replicas:[IDs]}` from `acks` (438); array and ID-list order ignored, no duplicated slots/IDs |
| `table` | Array of `{client, request, hasReply, reply}` from `client_table` (441). `reply=0` when `hasReply=false`; actual result otherwise. |
| `heard`, `waiting` | `heard_from_primary`, `idle_periods_waiting` (443,446), exact |
| `attempts`, `stable` | Capture raw `view_change_attempts`, `idle_periods_stable` (455,458). Trace normalizes attempts to `min(raw,10)` and stable to `min(raw,primaryTimeout)`, the source's only predicate-use thresholds (1291-1305). |
| `svc`, `dvcSent` | Set-array of `start_view_change_from`, `do_view_change_sent` (460,462) |
| `dvc` | Array of `{replica,last,log,commit}` from `do_view_change_from` (465); no op-number redundancy required because log length carries it |
| `catching`, `nonce` | `catching_up`, normalized `recovery_nonce` (468,470) |
| `responses` | Array of `{replica,view,hasState,log,commit}` from `recovery_responses` (472). Missing state has `hasState=false`, empty log, commit 0. |
| `out`, `replies` | Ordered arrays of all **unpublished** messages/replies, combining library buffers (473-474) and volatile caller staging as explained below |
| `app`, `applied`, `results` | Instrumented deterministic application value, actual per-incarnation full ordered entry sequence, and ordered returned values (1363-1365). Observer history must include every apply, including recovery reconstruction. |

Client `state` object inside each `{id,state}` row (`lib.rs:279-299`): `{view,next,pending,out}`. `next` is `next_request_number`. `pending` is `[]` or `[entry]`; `out` is the ordered unpublished client output, including caller staging. A retired identity remains in the snapshot, with pending/out cleared and its prior view/next retained. The owner must never issue a second outstanding request or reuse an identity after restart.

An entry is `{client,request,input}`. The reference application is a finite register initially 0. Input is `{kind:"Put",value:v}` or `{kind:"Get",value:0}`. Both return the **old/current** value; Put then assigns v, Get leaves the value unchanged. This deliberately order-sensitive workload implements the public `StateMachine` trait; it is not the shipped Store's output type or the existing accumulator workload. A different workload requires a matching application model rather than mapping away results or order.

### Message fields

Every envelope is `{src,dst,wire,incarnation,proof}`. `src` / `dst` are disjoint replica/client integers. `incarnation` is the sender replica's observer epoch at emission (0 for clients); `proof` is the sender's exact then-held prefix for PrepareOk, otherwise `[]`. These two fields are **not added to the Rust wire protocol** and are never incoming acceptance guards. The transport retains them with each authentic packet when delaying or duplicating it. Never relabel an old packet with its sender's current incarnation.

Every normalized `wire` has **all** fields:

```json
{"kind":"Commit","view":0,"opn":0,"commit":0,"entry":[],"log":[],"start":0,"last":0,"nonce":0,"hasState":false,"client":[],"request":0,"result":0}
```

Use the displayed defaults for fields not present in the Rust variant. `entry` is `[]` or `[entry]`; wire client is `[]` or `[clientID]`. This avoids JSON null/model-value ambiguity. `Trace.tla` converts optional fields into the internal `Nil` model value.

| Rust variant (`lib.rs`) | Non-default normalized fields and routing |
|---|---|
| Request (147-151) | `entry=[{client,request,input}]`; `src=client`; view remains 0 (client's routing view is not a wire field) |
| Prepare (157-166) | `view`, `opn=op_number`, `commit`, `entry=[...]` |
| PrepareOk (170-175) | `view`, `opn`; `src=replica_id`; retain whole prefix as envelope `proof` captured at 1381-1387 |
| Commit (179-182) | `view`, `commit` |
| GetState (188-192) | `view`, `opn`; `src=replica_id` |
| NewState (197-207) | `view`, `log` (suffix only), `start`, `opn=op_number_end`, `commit` |
| StartViewChange (211-214) | `view`; `src=replica_id` |
| DoViewChange (219-228) | `view`, `last`, `log`, `opn`, `commit`; `src=replica_id` |
| StartView (232-238) | `view`, `log`, `opn`, `commit` |
| Recovery (242-249) | `view`, `nonce`; `src=replica_id` |
| RecoveryResponse (255-262) | `view`, `nonce`, `hasState`; `log` / `commit` only when state exists; `src=replica_id` |
| Reply (126-130) | `kind="Reply"`, `view`, `client=[clientID]`, `request`, `result`; `dst=client` |

Authenticity includes sender identity and all wire fields. For variants carrying `replica_id`, retain and verify its agreement with the source; do not infer it from a currently selected primary. The library does not check a transport sender for Prepare, StartView, NewState, or Commit, and the model does not invent such a guard. RecoveryResponse's nonce belongs to the **recovering destination**, not its responding source. Maintain a per-replica mapping from each actual fresh nonce to its epoch; apply that same mapping to Recovery requests and their responses. Detect raw nonce reuse before normalization; do not make an invalid raw execution look fresh by allocating it another epoch.

## 2. Action-to-code mapping

Exactly one event type per **base transition**. The nested functional helpers are executed within their enclosing handler; they do not represent additional concurrent steps. `TraceReplicaOnMessage` and `TraceReplicaOnIdle` call the full base transitions and compare `branch`, ordered `applies`, and the entire post-state.

| Base action / event name | Code location | Precise trigger and event-specific fields |
|---|---|---|
| `ReplicaOnMessage` | `lib.rs:528-641` | Capture incoming envelope and pre-state branch before dispatch; emit **after** the selected handler returns, including all nested helper effects, before owner persistence. Fields: `node,message,branch,applies`. |
| `ReplicaOnIdle` | `lib.rs:1233-1285` | Capture pre-state idle branch; emit after one replica's idle call, before persistence. Fields: `node,branch,applies`. Independent replicas get separate events. |
| `PersistView` | Caller contract `lib.rs:14-18`; example `main.rs:570-579,701,749` | Emit after durable publication completes, or after verifying that the identical view is already durable, before any output publication. Fields: `node`; applies empty. Do not treat rename alone as proof of directory durability in the real example. |
| `ReleaseMessage` | `lib.rs:1468-1469`; example `main.rs:551-552` | Emit after **one** staged message is handed to the controlled transport. Capture exact pre-publication head as `message`, remove one from unpublished shadow, add one to network bag. Fields: `node,message`. |
| `ReleaseReply` | `lib.rs:1473-1474`; example `main.rs:554-559` | Same single-publication boundary for replies; add to independent reply bag. Fields: `node,message`. Even a local direct reply has a publication then a delivery event. |
| `Pause` | S1 controller; retained-state distinction in brief, library no-I/O contract `lib.rs:6-12` | Emit after suspending scheduling, leaving replica/application/pending outputs and durable state intact. `node`. |
| `Resume` | Same controller | Emit after making retained replica runnable; no constructor or replay. `node`. |
| `Crash` | Caller failure boundary `lib.rs:14-18`; simulator crash/restart boundary `simulator/lib.rs:694-711` | Emit after destroying replica/application and volatile owner staging, before any recovery constructor. Preserve durable view, released packet identities and prior factual histories. `node`. Down projection is the documented empty dummy; actual object is absent. |
| `Recover` | `lib.rs:511-524` | Emit after fresh empty application construction and `Replica::recover`, including its buffered Recovery broadcasts; before persist/publication. Advance epoch once. `node`. |
| `ClientOnRequest` | `lib.rs:312-326`; example `main.rs:733-734` | Emit after invocation returns, before draining. Capture returned `request`, `input`, and `client`; record invocation identity. |
| `ClientOnIdle` | `lib.rs:353-369` | Emit after one pending client's retry call has buffered all destination requests. `client`. Skip no-pending idle calls as semantic no-ops. |
| `ClientDrain` | `lib.rs:374-375`; example `main.rs:562-564` | Emit after a single client packet publication; `client,message`. |
| `ClientOnReply` | `lib.rs:334-347`; owner routing example `main.rs:719` | Emit after the owner selects matching client identity and invokes on_reply; `client,message,accepted`. State/result observation must include delayed, old-view, duplicate and stale replies. |
| `ClientRetire` | Owner obligation `lib.rs:29-31`; example disconnect `main.rs:736-737` | Emit after retiring the identity and destroying its pending/outgoing volatile client state. Preserve invocation/reply facts and old packets. New lifetime uses another previously unused ID. `client`. |
| `LoseMessage` | Controlled protocol/request transport; library caller delivery contract `lib.rs:6-12` | Emit after removing exactly one selected queued packet; `message`. Do not implement loss by altering packet contents. |
| `LoseReply` | Independent controlled reply transport, same contract | Emit after removing one queued reply; `message`. Do not inherit DST's always-lossless direct reply delivery as an assumption. |
| `ReplayMessage` | Controlled authentic duplication/delay transport | Emit after adding another occurrence of a previously released immutable packet, even from an earlier sender incarnation; `message`. |
| `ReplayReply` | Independent authentic reply transport | Emit after adding another occurrence of a previously released reply; `message`. |

Handler-to-helper coverage inside `ReplicaOnMessage`:

| Rust handler | Source blocks / base functional helper | Branch capture |
|---|---|---|
| Recovering dispatch filter | 530-535 / `OnMessage` | `ignore-recovering` for every non-RecoveryResponse packet |
| on_request | 646-693 / `OnRequest`, `AppendToLog`, `RegisterSelf` | `ignore-role-status`, `old-request`, `duplicate-request`, `append-request` |
| on_prepare | 701-730 plus 795-812 / `OnPrepare`, `AcceptFromPrimary`, `StateTransfer` | `old-view`, `catch-up-new-view`, `catch-up-same-view`, `ignore-role-status`, `state-transfer`, `append-prepare`, `normal` |
| on_commit | 776-784 plus 795-812 / `OnCommit` | Same accept/gap branch names; successful commit path is `normal` |
| on_prepare_ok | 737-767 / `OnPrepareOk` | `PrepareOk`; post-state checks exact ack sets, cumulative application and replies |
| on_get_state | 818-837 / `OnGetState` | `GetState`; no invented primary guard |
| on_new_state | 850-894 / `OnNewState`, distinct `OnNewStateTransfer` and `OnNewStateCatchUp` | `different-view`, `same-view-transfer`, `view-catch-up`, `ignore-status`; offset checks stay inside full base action |
| on_start_view_change | 906-921; 971-1037 / `OnStartViewChange`, `StartViewChange`, `MaybeSendDoViewChange`, `SendDoViewChange` | `StartViewChange` |
| on_do_view_change | 926-942; 1043-1080 / `OnDoViewChange`, `RecordDoViewChange` | `DoViewChange`; self-recording and new-primary replay stay atomic |
| on_start_view | 948-967 / `OnStartView` | `StartView` |
| on_recovery | 1131-1149 / `OnRecovery` | `Recovery` |
| on_recovery_response | 1159-1205 / `OnRecoveryResponse` | `RecoveryResponse`; quorum/nonce/latest-primary guards and silent-to-clients replay stay active |

Idle branches: `primary` (1235-1253), `recovering` (1255), `backup-or-transfer` (1256-1268), `view-change` (1270-1283). Capture the pre-state choice, not the status after a timeout or recovery/view-change completion.

Other helpers requiring internal capture but **no separate transition event**: append/client table (1310-1318); installation/cache reconstruction (1324-1344); ordered commit/application (1349-1376); ack prefix at `send_prepare_ok` (1381-1387); sender views and offsets at `send_get_state`, `send_start_view`, and `send_recovery` (1390-1396,1083-1089,1208-1214). The full post-state checks their final effects; `applies` preserves all application-call observations.

## 3. Special considerations

**Publication and source access.** Rust's `Vec::drain(..)` removes a batch into a borrowed iterator; the abstract output buffer is all still-unpublished volatile data, including the owner staging that holds that iterator/batch. Maintain an observer FIFO for each message/reply/client buffer. Do not report the private Vec's now-empty state as though all staged packets were already released. Transfer to staging is a representation-only operation; emit each actual publication separately. A whole process crash loses both library and owner staging, but never deletes already released network packets. Handler completion must be followed by a persistence event even when the view did not change. The model permits the owner to handle another event while old already-persisted outputs remain staged; it never permits a handler before the preceding persist obligation completes.

**Atomicity and histories.** Put an apply hook around the actual `StateMachine::apply` call at 1364; capture the entry/slot before it and the returned value/application state after it. Buffer these observations until the enclosing handler returns. Never interleave another replica handler between `commit_op` iterations merely because there are multiple apply hooks. Keep per-incarnation histories and accepted invocation/reply facts in the harness controller, which survives modeled replica crashes. These are observations, not an implementation-side oracle. The model computes canonical history/certificates independently and never asks the trace to supply a preferred canonical answer.

**Snapshots and no silent actions.** Every base transition has an explicit hook above; Trace has no silent fault, hidden timeout, arbitrary log installation, or fabricated packet step. Use a feature-gated helper for private fields, and a scheduler shadow for global transport/persistence/lifetime state. For an uncontrolled real TCP execution the full scheduler snapshot may not be available; instrument controlled library tests first. Do not replace required field checks with conditionally absent fields to accept such a trace.

**Failure budgets and scope.** The base trace replay itself permits authentic crash schedules outside the promised failure budget, so trace fidelity can still be inspected. A semantic invariant violation from such a run must be interpreted against its actual failure schedule; all supplied MC hunts enforce the brief's budget. No fsync omission, ID reuse, stale nonce, incompatible application initialization, or malformed peer frame is injected into the conforming core model. S4's component candidates remain separate review/test work.

**Serialization.** Preserve empty arrays, false booleans, and zero counts/numbers where the schema calls for them; do not use serde omission attributes. Sets/map rows must have unique keys; channel multiplicity uses positive counts. Logs and output buffers are sequences, not sets. Never drop old requests, replies, or historical incarnation records to shorten a trace. Preserve raw view/request/operation numbers exactly. The only numeric quotients are timer saturation and the injective nonce-epoch naming described above.

**Validation command.** From `spec/`, use a TLC jar plus CommunityModules supplying `IOUtils` and NDJSON support:

```sh
JSON=../traces/run.ndjson java -cp "$TLA_JAR:$COMMUNITY_JAR" tlc2.TLC -noGenerateSpecTE -config Trace.cfg Trace
```

`TraceMatched` is enabled. Fairness permits advancing matching events and prevents a gratuitous-stutter false failure; a mismatched first or later event still fails. Check both a real positive trace and copies with a changed commit/application result, changed message offset, and omitted transition. Synthetic checker fixtures in `checks/` only test parser/schema/non-vacuity; they are not implementation trace validation or evidence of protocol correctness.
