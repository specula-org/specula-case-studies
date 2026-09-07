# vsr-rs instrumentation mapping

Revision: `3ac0104a567092139534c9022205d02281a2da41`. Category A, one globally ordered NDJSON stream. This is the Phase 4 handoff; this task does not patch Rust or claim to have validated implementation traces. Source paths below are relative to `source/`. Trace files belong in `../traces/` relative to `spec/`; `Trace.tla` defaults to `../traces/trace.ndjson`, with the `JSON` environment variable overriding it.

## 1. Trace event schema

Each relevant record has `tag: "trace"`, `event`, event-specific input fields, and a **required full post-state** `post`. Start with an `Init` record containing `config` and the initialized post-state. All following records correspond one-to-one to the actions listed below. Non-`trace` diagnostics may coexist in the stream. No field in a captured state snapshot is optional. Unsupported fields must be diagnosed by the harness, not silently omitted. `Trace.cfg` enables `TraceMatched` and structural/durability checks; the replay intentionally permits matching the known integration defect through its client-visible consequences.

The Init configuration is:

```json
{"revision":"3ac0104a567092139534c9022205d02281a2da41","servers":[0,1,2],"clients":[100,101],"values":["A","AA","B"],"primary_timeout":3,"failure_budget":1,"integration_mode":false,"full_value":"AA","prefix_value":"A"}
```

Trace clients are integers outside the replica-ID range (for example 100,101). Map actual unique client IDs bijectively over the whole trace, and use -1 only for the neutral no-entry sentinel. This keeps TLC values type-comparable; MC configs independently use symmetric client model values. Request numbers start at **0**; never offset request numbers when log positions are converted from zero-based Rust indexing to one-based op numbers. Model only one outstanding operation per client, stable client identities and one key (`k`). Values can be literal small strings or a documented equality-preserving dictionary. For the EOF experiment, map the proven original long ASCII value to `AA`, its observed nonempty prefix to `A`, and retain raw bytes separately.

A log entry is `{"client":100,"request":0,"op":{"kind":"Put","value":"AA"}}`; Get uses `{"kind":"Get","value":"nil"}`. `nil` represents Store's `None`, not the string value "nil"; exclude that string from modeled stored values. Put returns `nil`; Get returns the current value or `nil`.

Every normalized message contains **all** these fields:

```json
{"kind":"Commit","src":0,"dst":1,"view":0,"opnum":0,"commit":0,"entry":{"client":-1,"request":-1,"op":{"kind":"Get","value":"nil"}},"log":[],"start":0,"lastNormal":0,"nonce":0,"hasState":false,"result":"nil"}
```

| Message kind | Non-default fields copied from implementation |
|---|---|
| Request | client source ID, destination, entry. `view=0` because the Request has no view field; destination reflects Client.view. |
| Prepare | sender/destination, view, opnum, commit, complete entry including the received operation |
| PrepareOk | `src=replica_id`, destination, view, opnum |
| Commit | sender/destination, view, commit |
| GetState | `src=replica_id`, destination, view, opnum |
| NewState | sender/destination, view, start=`op_number_start`, opnum=`op_number_end`, suffix log, commit |
| StartViewChange | `src=replica_id`, destination, view |
| DoViewChange | `src=replica_id`, destination, view, lastNormal, full log, opnum, commit |
| StartView | sender/destination, view, full log, opnum, commit |
| Recovery | `src=replica_id`, destination, view, nonce |
| RecoveryResponse | `src=replica_id`, destination, view, nonce, hasState; log/commit only for Some(state), otherwise empty/0 |
| Reply | sender and client destination, view, result; `entry.client`/`entry.request` only; `entry.op` is the neutral Get/nil sentinel, because Reply carries no original operation |

`src` on messages lacking a sender payload comes from the actual sender wrapper/connection provenance. It is not a new base-handler guard. Preserve immutable payload snapshots on queueing; do not reread the sender's current view/log when delivering delayed messages. DVC and RecoveryResponse map rows retain the normalized message that supplied that map value. Fields not stored by the library (destination, recovery nonce on map values) are shadow metadata attached at reception, not inferred from current state.

Every `post` object has the following fields, compared by `Trace!ValidatePostState` after **every** event:

| JSON field | Normalization / actual capture |
|---|---|
| `replicas` | Array of `{id, durable, owner, incarnation, state}` for every configured replica. A coordinated observer keeps the most recent snapshot for unchanged nodes. |
| `clients` | Array of `{id, view, next, pending, entry}` for every client; lib.rs:280-300,311-370. Retain the last pending entry after completion as observer metadata; `pending=false` controls validity. |
| `network` | Array/set projection of queued abstract envelopes, including published replies not yet delivered to Client::on_reply. Equal envelopes are coalesced; different log/view/commit snapshots remain distinct. |
| `frames` | Array of `{id,sent,stage,admitted}` for integration Prepare.Put frames. Full `sent` stays immutable. Stage is queued/partial/eof/complete/admitted/lost. Before admission, `admitted=sent`; after EOF admission it is the actual shortened message. |
| `nextFrame` | Next monotonically allocated sender-frame ID (initially 0); increment only on PublishOutput of an integration Prepare.Put. |
| `phase`, `healthySet` | Harness schedule metadata: faults/stable, and the fixed healthy set. Normal safety traces stay faults with all members in healthySet. |
| `invocations` | Array of original log-entry-shaped invocation records, captured at Client::on_request; never copied from received Prepare. |
| `responses` | Array of `{client,request,result}` for accepted pending completions only, recorded after Client::on_reply returns true; retain all historical completions. |
| `happensBefore` | Array of `[[earlierClient,earlierRequest],[laterClient,laterRequest]]`; at each invocation add edges from every already completed request. |
| `committedHistory` | Set projection of all past `{pos,entry,result,view}` application executions, including before process crashes. Capture from actual commit_op/apply hooks. Deduplicate equal records only. |

`state` contains every field below; exact spellings are consumed by `NormReplica`:

| Fields | Capture and mapping |
|---|---|
| `status`, `view`, `lastNormal` | status(), view_number(), private last_normal_view; Normal/ViewChange/StateTransfer/Recovering. Down is a harness process state. |
| `log`, `commit` | Complete `log()` entries and commit_number(); no op-count-only approximation. |
| `acks` | Array `{opnum,from:[replica IDs]}` from acks BTreeMap/BTreeSet, lib.rs:437-438. |
| `table` | Array `{client,request,hasReply,result}` from client_table, lib.rs:395-400,439-441. `hasReply` distinguishes no cached reply from cached `None` (whose result is `nil`). |
| `heard`, `waiting`, `attempts`, `stable` | heard_from_primary, idle_periods_waiting, view_change_attempts, idle_periods_stable. Capture actual integers; normalization caps attempts at 10 and stable at PrimaryTimeout. |
| `svc`, `dvcSent`, `dvc`, `catching` | start_view_change_from set, do_view_change_sent flag, per-sender DVC rows, catching_up; lib.rs:459-468. |
| `nonce`, `responses` | Fresh recovery attempt nonce and current recovery response map as normalized message rows; lib.rs:469-472. Remap actual fresh nonce to that replica's monotonically increasing incarnation (first=1). All delayed messages retain the original remapping. |
| `messages`, `replies` | Full pending output **sequences**, preserving per-queue order; lib.rs:473-474,1467-1474. See owner boundary below when Drain moves ownership to caller buffers. |
| `app` | Store value for the modeled key, or nil; main.rs:48-62. Do not infer this by replaying the current log, since install_log preserves the existing application. |
| `executed` | Per-incarnation sequence `{pos,entry,result,view}` independently observed inside actual commit_op (1362-1377). Reset on crash/recover, retain globally in committedHistory. Capture operation before apply, result after apply, view of that execution. |

`owner` is ready/persist/publish/down. A synchronous Replica::on_message/on_idle returns into persist even if view did not change; PersistView then moves to publish or ready, and draining the last output moves to ready. `durable` is the last successful persistent view, retained after crash. `incarnation` is the monotonically increasing fresh-nonce mapping, retained across process resets. The base-only error/install/historyViolation/publicationViolation fields are derived assertion/obligation observers, not invented implementation fields; no source snapshot claims to measure them.

## 2. Action-to-code mapping

The event name equals the base action name. Every row additionally requires the complete `post` snapshot above. `node` is the receiving/acting replica. For received messages, `message` is the exact normalized incoming envelope and `keep` says an equal envelope remains deliverable (duplicate multiplicity). Message handler instrumentation runs immediately after the **outer** `Replica::on_message` call returns, before persistence. Internal helper calls update the same event's state and output; they are not separate action events.

| Base action / event | Source and exact trigger | Inputs / branch selection |
|---|---|---|
| Init | lib.rs:292-300,478-501; after all new replicas/clients are initialized, before any call | config and initialized post. Start from cold view 0; restarting traces must include the preceding crash/recover events. |
| RecoveringDrop | lib.rs:530-536; after early return | node,message,keep; pre-status Recovering and non-RecoveryResponse |
| OnRequest | lib.rs:646-693; after on_message returns | node,message,keep; includes ignored, stale, cached duplicate and new request branches in original order |
| OnPrepareRejected | lib.rs:708-710,795-812 | node,message,keep; pre-state not exact-view Normal backup; capture catch-up and heard side effects even though Prepare is rejected |
| OnPrepareGap | lib.rs:712-714,898-900 | node,message,keep; accepted Prepare, opnum > old log length + 1 |
| OnPrepareAppend | lib.rs:716-730 | node,message,keep; accepted Prepare, opnum = old log length + 1; capture app, table, commit and ack output |
| OnPrepareDuplicate | lib.rs:720-730 | node,message,keep; accepted Prepare, opnum <= old length; retain old operation even if retransmission differs |
| OnPrepareOk | lib.rs:737-768 | node,message,keep; capture full updated ack sets and every prefix commit/reply, including early-return map updates |
| OnCommit | lib.rs:776-812 | node,message,keep; includes rejected/catch-up, state-transfer gap, and commit branches |
| OnGetState | lib.rs:818-837 | node,message,keep; emitted suffix starts at the requested op number; handler does not require receiver to be primary |
| OnNewStateTransfer | lib.rs:842-874,893 | node,message,keep; pre-status StateTransfer, including stale/unhelpful response; append only non-overlap |
| OnNewStateCatchUp | lib.rs:875-889,893 | node,message,keep; pre-status ViewChange and catching=true; replacement starts at local commit |
| OnNewStateIgnored | lib.rs:850-855,891 | node,message,keep; other non-recovering pre-statuses; heard may still change |
| OnStartViewChange | lib.rs:906-921,971-1037 | node,message,keep; capture inline start_view_change, sender-set update, maybe_send_do_view_change and potential self DVC quorum completion |
| OnDoViewChange | lib.rs:926-943,1043-1090 | node,message,keep; allow DVC quorum excluding self; record arrival replacement and BTreeMap tie order; capture all inline installation/commits/replies/StartViews |
| OnStartView | lib.rs:623-624,948-967 | node,message,keep; capture install and application preservation; same-view replay after leaving ViewChange is ignored |
| OnRecovery | lib.rs:1131-1149 | node,message,keep; higher request view starts a view change and returns without response; otherwise only Normal responds |
| OnRecoveryResponse | lib.rs:1159-1205 | node,message,keep; map insertion before checking quorum/floor/primary; capture actual arrival overwrite even when it decreases the currently stored maximum |
| OnIdle | lib.rs:1233-1305 | node; exactly one idle-period call, after return; preserve Commit-before-Prepare order, retries, backoff and inline view selection |
| PersistView | lib.rs:14-21; main.rs:570-584,749 | node; after successful view durability (or the explicit same-view no-op), before output release. Failure exits/crashes instead. |
| PublishOutput | lib.rs:1467-1474; main.rs:551-559 | node; immediately after releasing **one** message or reply. Publish all messages before replies. Emit one event per item, not one batch event. |
| Crash | lib.rs:14-18,505-523; harness process-stop point | node; after process state and unpublished owner buffers are lost. Already published abstract traffic remains; integration queued sender frames become lost and partial transmitted bodies become eof. |
| Recover | lib.rs:511-524; main.rs:690-701 | node; after Replica::recover returns with newly initialized Store and recovery output, before PersistView. Record durable floor and fresh nonce mapping. |
| LoseMessage | lib.rs:6-12; harness transport discard point | message; after removing one final equal envelope. Replies can be lost as well as protocol messages. |
| DiscardUnavailable | harness transport delivery to down endpoint; main.rs:370-379 | message; after dropping because destination is down, including stable permanently unavailable minority |
| RunSenderBeginPartial | main.rs:383-386; test transport observation during unchanged write_all | frame ID; only known Prepare.Put FullValue with actual emitted nonempty final-token prefix. Do not infer this event from a generic socket error. |
| RunSenderComplete | main.rs:383-386,401-404 | frame ID; completed encoded body/newline is admitted unchanged by receiver. Fragmentation is represented by earlier partial then complete, or directly complete. |
| RunPeerAcceptorEOF | main.rs:401-404,247-254 | frame ID; after clean EOF yields a valid unterminated line and decode succeeds; requires earlier partial plus sender crash. Record actual admitted prefix. |
| RunPeerAcceptorReadError | main.rs:401 map_while(Result::ok) | frame ID; after partial input ends with read error/reset and no message dispatch; mark lost. |
| ClientOnRequest | lib.rs:311-326; main.rs:729-734,562-565 | client,op; original invocation and its one client-outbox message enter abstract transport. Stable client transport may delay delivery arbitrarily. |
| ClientOnIdle | lib.rs:353-370; main.rs:742-745,562-565 | client; after actual retry broadcast of the original outstanding call; no event when pending is None |
| ClientOnReply | lib.rs:334-347; main.rs:528-539 | message,keep; immediately after client accepts/rejects result, capturing learned view even for stale reply. Record original pending identity and result at completion. |
| Stabilize | harness fault-schedule boundary, brief Scenario 5 | healthy array; fix nonfailed endpoints and forbid further injected crashes/losses/duplicates. For the MC timing subcase, tick every healthy replica once per round, draining all network/owner work between environment events. No library state is rewritten. |

Pure helpers (`InstallLog`, `CommitUpTo`, `RecordDoViewChange`, `EnterNormal`, `StateTransfer`, `CatchUpWithView`, etc.) run inside these synchronous handler actions. Their source hooks contribute to the outer event; they must not emit extra tagged transition events. Their output/application changes **must** appear in that event's post-state. Distinct externally observable Prepare and NewState control paths have separate wrappers; deterministic branches within the other synchronous handlers are fully evaluated rather than bypassed.

## 3. Special considerations

1. **Global ordering and shadow state.** Prefer a deterministic test owner/transport around real Replica/Client instances for core traces. It can capture private fields through test-only accessors in lib.rs. For separate kvstore processes, use a collector with per-process order and send-before-receive edges, and preserve original client invocation/response order. Do not timestamp-sort racy snapshots into a purported total order. Capture each atomic owner state at its return; a collector may fill unchanged-node snapshots from their last event. If a linear order is ambiguous, produce separate compatible orderings or use a coordinated harness. There are no silent base actions to excuse missing boundaries.
2. **Drain ownership.** Rust drain_messages/drain_replies can transfer all items into an owner-local vector. Until each item is actually released, keep it in the observer's pending sequence, in the exact order. Crash discards both Replica outbox and owner-local unpublished remainder. PersistView has to precede the first release. Tests that flush everything atomically cannot exercise Scenario 4; add hooks between individual items.
3. **Application evidence.** At commit_op capture the entry before `apply`, result afterwards and the new commit_number. Update local executed and global committedHistory from those actual observations. Never derive Store state or cached reply from a newly installed log. InstallLog intentionally preserves prior application state and may preserve matching old replies (lib.rs:1324-1345).
4. **Messages and duplicates.** The abstract network is a content set. Normalize concrete equal outstanding copies together, using keep=true if another equal copy remains after a delivery. keep=false consumes the last one. Drop of a non-last equal copy has no abstract state change and is an untagged diagnostic; loss of the last has LoseMessage. Captured logs and response-map snapshots are full contents, not lengths or maxima.
5. **Sender provenance.** The integration model is restricted to the existing `evidence/frame-regression/append.rs` witness. Keep raw encoder output, transmitted/received prefix, byte lengths, hashes, no-newline evidence, child/process IDs and exact source revision in an untagged sidecar. Require received bytes to be a strict nonempty-final-value prefix of unchanged encode output. A partial sender write by itself does not imply clean EOF; distinguish actual clean EOF from reset/read error. Full newline-less body at EOF is content-preserving; its abstraction is RunSenderComplete. Clean interruption before a syntactically valid prefix and unsupported frame variants are ordinary loss/out of this refinement, not arbitrary mutation.
6. **Publication vs delivery.** Published core messages are immutable snapshots permitted to outlive the sender. In IntegrationMode, Prepare.Put publication first queues a sender frame; a sender crash loses unstarted frames, but already transmitted bytes can still be decoded at EOF. The core abstraction allows published buffers to survive because callers may hand them to an independent transport. Do not treat every kvstore sender queue as crash-durable. For non-Prepare integration traffic this is a core content-preserving transport abstraction; concrete process-buffer loss is represented with explicit loss events before stabilization.
7. **Client scope.** Client state/outbox is a stable harness environment separate from replica recovery. Core ClientOnRequest/ClientOnIdle collapse the corresponding client-outbox transfer into the invocation/retry event; there is no client persistence obligation. Delayed client delivery is still free. For kvstore continuation, keep the client-owning connection/process alive, or use a distinct new client ID after reconnection. Crashing client-owner output queues and connection-reply failure mechanisms require further integration refinement and are not claimed covered here.
8. **Bootstrap and values.** Begin from all-new view-0 replicas and fresh clients. Include the pre-crash prefix for rolling recovery tests; do not invent an unconstrained TraceInit matching any supplied state. Supported operation vocabulary is single-key Put/Get. A trace with unsupported fields/operations must be reported as outside this abstraction. N=2 may be traced with FailureBudget=0; it is not a one-crash liveness claim.
9. **Replay checks.** Run from spec with `JSON=../traces/<file>.ndjson` and TLC plus CommunityModules-deps.jar on the Java classpath. TraceMatched must remain enabled; otherwise a stuck cursor can look successful. Generation's synthetic positive/negative fixtures in validation are only engine tests, not implementation conformance evidence.
