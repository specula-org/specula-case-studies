# Instrumentation specification: openraft

This document is the handoff contract for producing NDJSON accepted by
`Trace.tla`. Instrument the pinned source at
`15f927e1358d41ffc1297516f781029dbf8ca86a` (incrementally updated from
old source input `0f4e195474e4a902b391b99497bdbb3535b89749`). Emit only successful state-changing
paths; rejected requests that do not execute the corresponding base action must
not emit that action's event.

## 1. Trace event schema

Every line is one JSON object:

```json
{
  "tag": "trace",
  "timestamp": 1234,
  "event": {
    "name": "<exact action name from section 2>",
    "nid": 1,
    "state": { "<common post-state fields>": "..." },
    "details": { "<action-specific fields>": "..." }
  }
}
```

`nid` values must be dense integers `1..N`. Timestamp is diagnostic only; file
order is the authoritative Category A event order. Emit under one process-wide
trace mutex after the state transition and snapshot capture so independently
running heartbeat, replication, callback, snapshot, and state-machine tasks
produce a total order consistent with their observed post-state.

### Common post-state

Every event must include all of these `event.state` fields. This is deliberate:
`Trace.tla::ValidatePostState` is strong and never falls back to `TRUE`.

```json
{
  "online": true,
  "role": "Follower|Candidate|Leader|Down",
  "recovery_stage": "Running|RecoverLoad|RecoverSnapshot|RecoverReplay|RecoverReady",
  "recovery_ready": true,
  "vote": {"term": 1, "leader": 1, "committed": true},
  "persistent_vote": {"term": 1, "leader": 1, "committed": true},
  "accepted_vote": 11,
  "accepted_log": 3,
  "submitted_vote": 11,
  "submitted_log": 3,
  "durable_vote": 11,
  "durable_log": 3,
  "flushed_vote": 11,
  "flushed_log": 3,
  "cluster_committed": 3,
  "local_committed": 3,
  "persisted_committed": 3,
  "apply_submitted": 3,
  "sm_applied": 3,
  "committed_membership": {"log": 0, "old_voters": [1,2,3], "new_voters": [1,2,3], "joint": false, "request_id": 0},
  "effective_membership": {"log": 0, "old_voters": [1,2,3], "new_voters": [1,2,3], "joint": false, "request_id": 0},
  "candidate_granted": [1,2],
  "match_index": [3,3,2],
  "replication_session": {"term": 1, "leader": 1, "membership_log": 0},
  "clock": 2,
  "clock_acks": [1,2],
  "lease_until": 3,
  "read": {
    "phase": "Idle|WaitQuorum|WaitApply|Done",
    "policy": "ReadIndex|LeaseRead",
    "required": 3,
    "floor": 3,
    "session": {"term": 1, "leader": 1, "membership_log": 0},
    "membership": {"log": 0, "old_voters": [1,2,3], "new_voters": [1,2,3], "joint": false, "request_id": 0},
    "acks": [1,2],
    "read_id": 1
  },
  "read_epoch": 1,
  "last_read_observed": 3,
  "last_read_required": 3,
  "build_phase": "Idle|Queued|Running",
  "build_target": 3,
  "build_membership": {"log": 0, "old_voters": [1,2,3], "new_voters": [1,2,3], "joint": false, "request_id": 0},
  "snapshot_meta_last": 3,
  "snapshot_meta_membership": {"log": 0, "old_voters": [1,2,3], "new_voters": [1,2,3], "joint": false, "request_id": 0},
  "snapshot_accepted": 3,
  "snapshot_submitted": 3,
  "snapshot_flushed": 3,
  "snapshot_last": 3,
  "snapshot_membership": {"log": 0, "old_voters": [1,2,3], "new_voters": [1,2,3], "joint": false, "request_id": 0},
  "install_done": false,
  "purge_upto": 3,
  "purge_command": 3,
  "durable_purged": 3,
  "client_completed": 3
}
```

### State-field mapping

| Trace field | Implementation source | Notes |
|---|---|---|
| `role`, `vote`, effective/committed membership | `RaftCore.engine.state` (`openraft/src/raft_state/mod.rs`) | Convert `ServerState`; preserve advanced `(term,node_id,committed)` vote identity. |
| `accepted_*`, `submitted_*`, `flushed_*`, cluster/local commit, apply/snapshot cursors, `purge_upto` | `RaftCore.engine.state.io_state` and `RaftState` | Encode IO vote component with the exact `VoteRank` formula in `base.tla`; log `None` as `0`. |
| `persistent_vote`, `persisted_committed`, `snapshot_last`, `snapshot_membership`, `durable_purged` | successful storage calls and startup reads | Maintain a tracer shadow updated only after the storage future succeeds. Do not infer durable state from Engine acceptance. |
| `durable_vote`, `durable_log` | `IOFlushed::io_completed(Ok)` at `openraft/src/storage/callback.rs:80-115`, plus successful synchronous `save_vote` | Maintain a monotone tracer shadow before the LocalIO event is consumed. In the new source, the callback writes a watch slot and `openraft/src/raft/mod.rs:315-359` forwards the latest value to the core. |
| `sm_applied`, applied membership/snapshot | `sm::Worker` after state-machine calls return | Snapshot values come from the installed/built `SnapshotMeta`; apply comes from `ApplyResult.last_applied`. |
| `match_index`, `replication_session`, `clock_acks`, `lease_until` | `Leader.progress`, `Leader.clock_progress`, `ReplicationSessionId` | For non-leaders emit zero match indices and empty acks. Compress `Instant` values to monotone logical `clock` ticks under the trace mutex. |
| `candidate_granted` | Engine `Candidate` quorum grant state | Emit the granted node IDs for the current candidate, or an empty array otherwise. |
| `read*` | tracer object keyed by read ID around `handle_ensure_linearizable_read` and `Linearizer` | The spawned quorum future owns captured vote/membership; keep it after later Engine session changes. |
| `recovery_*`, `online`, `build_phase`, `build_target`, `install_done`, `purge_command` | narrow tracer shadows at the boundaries below | These make async program-counter boundaries observable; they do not alter protocol execution. |
| `client_completed` | `ApplyResponder::send` (`openraft/src/storage/v2/apply_responder.rs:55-59`) | Monotone highest completed normal-entry index; exclude blank/membership entries. |

`request_id = 0` and membership `request_id = 0` mean the TLA+ sentinels
`NoRequest`. Voter arrays are sets semantically; sort them only for stable output.

### Reusable detail records

- `session`: `{"term":n,"leader":n,"membership_log":n}`.
- `io`: `{"vote":<VoteRank>,"log":n}`.
- `entry`: `{"term":n,"leader":n,"index":n,"kind":"Normal|Blank|Membership","value":"opaque-value","request_id":0,"membership":<membership-record>}`. For non-normal entries `value` is ignored; for non-membership entries the membership object may be the initial membership.
- Network identity: `src`, `dst`, `idx`, `read_id`, `session`. These fields must identify the exact pre-state message consumed by a receive/loss event.
- Response identity: `node`, `peer`, `required_vote`, `required_log`, `read_id`; add `kind: "Append|Heartbeat|ReadIndex"` for the generic RPC release event.
- Request post-state: `request: {"phase":...,"owner":n,"goal":[...],"retain":bool,"log":n}`.

## 2. Action-to-code mapping

`Common` below means the complete post-state above. `Entry`, `Message`,
`Response`, and `Request` mean the reusable detail records just defined.

| # | Spec action / exact event name | Code location | Trigger point | Details in addition to Common | Notes |
|---:|---|---|---|---|---|
| 1 | `HandleElectionTimeout` | `openraft/src/core/raft_core.rs:1633-1685`; `openraft/src/engine/engine_impl.rs:214-230` | After `engine.elect()` has updated candidate vote/accepted IO and queued self-vote persistence | none | Emit only when election actually fires, not on tick rejection. |
| 2 | `EngineHandleVoteRequest` | `openraft/src/engine/engine_impl.rs:286-336` | After successful `update_vote`, before queued commands run | `candidate` | Do not emit lease/log/vote rejections. |
| 3 | `RaftCoreRunCommandSaveVote` | `openraft/src/core/raft_core.rs:1864-1887` | After `save_vote()` succeeds and notifications are enqueued | none | Update persistent/durable tracer shadows before capture. |
| 4 | `RaftCoreHandleLocalIO` | `openraft/src/core/raft_core.rs:1540-1558` | After `try_flush(io_id)` | `io` | One event per consumed LocalIO notification. |
| 5 | `RaftCoreReleaseVoteResponse` | `openraft/src/core/raft_core.rs:970-993`; `openraft/src/engine/handler/vote_handler/mod.rs:80-87` | Immediately after the satisfied vote responder sends | Response | Preserve the required IOId from enqueue time. |
| 6 | `EngineHandleVoteResponse` | `openraft/src/engine/engine_impl.rs:339-363`; `openraft/src/engine/handler/vote_handler/mod.rs:162-218` | After quorum calls `establish_leader()` and leader no-op append returns | `entry_index`, Entry | Emit only the quorum-establishing response; entry is the generated blank no-op. |
| 7 | `LeaderHandlerLeaderAppendEntries` | `openraft/src/engine/handler/leader_handler/mod.rs:43-95`; `openraft/src/core/raft_core.rs:497-523` | After accepted IO/effective membership updates and command enqueue | `value`, `entry_index`, Entry | This event is for normal client entries; membership has its own actions. |
| 8 | `RaftCoreRunCommandAppendEntries` | `openraft/src/core/raft_core.rs:1837-1862` | Immediately after `log_progress.submit(io_id)` at line 1859 and before awaiting `log_store.append` | none | This placement preserves submit → durable completion. |
| 9 | `LogStoreCompleteAppend` | `openraft/src/storage/callback.rs:80-115`; `openraft/src/raft/mod.rs:315-359` | On `io_completed(Ok)` after durable append updates the watch slot, before LocalIO is handled | `entry_index`, Entry | Update persistent-log and durable-IO shadows first. `Trace.tla` models the forwarder as a constrained internal step because the forwarder does not own the full common state snapshot. |
| 10 | `ReplicationHandlerSendReplicate` | `openraft/src/engine/handler/replication_handler/mod.rs:303-340`; `openraft/src/core/raft_core.rs:1931-1934` | When a log replication request is handed to the per-peer stream/network | `target` | Correlate the subsequent request using session and index. |
| 11 | `EngineHandleAppendEntries` | `openraft/src/engine/engine_impl.rs:401-458`; `openraft/src/engine/handler/following_handler/mod.rs:145-212`; `openraft/src/core/raft_core.rs:1286-1296` | After successful accept/truncate/append/effective-membership/leader-commit updates, before commands run | Message + Entry + `entry_index` | Do not emit `RejectAppendEntries` paths. |
| 12 | `RaftCoreReleaseRPCResponse` | `openraft/src/core/raft_core.rs:970-993`; `openraft/src/engine/command.rs:314-335` | Immediately after a satisfied Append/Heartbeat/ReadIndex response sends | Response + `kind` | Required IOId must be the one captured when queued. |
| 13 | `ReplicationHandlerUpdateProgress` | `openraft/src/core/raft_core.rs:1561-1570`; `openraft/src/engine/handler/replication_handler/mod.rs:150-201,248-283` | After session check and progress/commit updates; also emit stale deliveries after the ignore decision | Message | For stale delivery, Common must show unchanged match/commit. |
| 14 | `RaftCoreRunCommandSaveCommittedAndApply` | `openraft/src/engine/engine_impl.rs:670-705`; `openraft/src/core/raft_core.rs:1928-1937` | After `save_committed` returns and apply command is submitted | none | The command is capped at `min(log_progress.submitted, apply_progress.accepted)`; emit `persisted_committed` unchanged when storage uses the optional no-op implementation. |
| 15 | `SMWorkerApply` | `openraft/src/core/sm/worker.rs:149-156,177-233`; `openraft/src/core/raft_core.rs:1624-1626` | After SM apply succeeds and core consumes the `Apply` notification | `entry_index`, Entry; Request for membership | Split batches into one trace event per applied entry in index order. |
| 16 | `ApplyResponderComplete` | `openraft/src/storage/v2/apply_responder.rs:55-59` | Immediately after the normal-entry responder sends | Response | Update `client_completed` first. |
| 17 | `ManagementApiStartMembership` | `openraft/src/raft/api/management.rs:61-88` | After assigning a trace request ID, immediately before first `call_core` | `request_id`, `goal`, `retain`, Request | Request IDs are dense `1..2` per focused trace. |
| 18 | `CoreChangeMembership` | `openraft/src/raft_state/membership_state/change_handler.rs:31-58`; `openraft/src/membership/membership.rs:292-330`; `openraft/src/core/raft_core.rs:465-482`; `openraft/src/engine/handler/leader_handler/mod.rs:53-95` | After the first coherent membership entry is appended/effective and streams rebuild | `request_id`, `entry_index`, Entry, Request | Emit only successful `ensure_committed`/membership validation. |
| 19 | `ManagementApiFlattenJoint` | `openraft/src/raft/api/management.rs:98-124`; `openraft/src/membership/membership.rs:315-345` | After the second empty-change call appends its entry/effective membership | `request_id`, `entry_index`, Entry, Request | Retain the original caller ID/retain flag while reading the then-current membership. |
| 20 | `SnapshotHandlerTriggerSnapshot` | `openraft/src/engine/handler/snapshot_handler/mod.rs:28-43`; `openraft/src/core/raft_core.rs:720-747` | After `building_snapshot=true` and command enqueue | none | Do not emit rejected triggers while a build is active. |
| 21 | `SMWorkerBuildSnapshotStart` | `openraft/src/core/sm/worker.rs:236-269` | After a builder is acquired and its consistent applied/membership view is captured, before spawned build | none | Set build target/membership in tracer shadow. |
| 22 | `EngineOnBuildingSnapshotDone` | `openraft/src/engine/engine_impl.rs:524-565` | After core handles `BuildSnapshotDone`, updates monotone snapshot metadata/progress | none | Older completion after newer install must not regress fields. |
| 23 | `LogHandlerSchedulePolicyBasedPurge` | `openraft/src/engine/handler/log_handler/mod.rs:51-68,70-113` | After `purge_upto` advances | none | Do not emit no-op policy checks. |
| 24 | `LogHandlerPurgeLog` | `openraft/src/engine/handler/log_handler/mod.rs:29-49` | After in-memory `st.purge_log` and `Command::PurgeLog` enqueue | none | This is not durable purge completion. |
| 25 | `RaftCoreRunCommandPurgeLog` | `openraft/src/core/raft_core.rs:1889-1892`; `openraft/src/engine/command.rs:256,290-323` | After conditioned storage `purge()` succeeds and durable purged cursor updates | none | Snapshot condition must already be satisfied. |
| 26 | `ReplicationCoreSendSnapshot` | `openraft/src/replication/mod.rs:682-759` | Immediately before the snapshot RPC is awaited | `target` | Details use the snapshot last-log index and session used by that stream. |
| 27 | `FollowingHandlerInstallFullSnapshot` | `openraft/src/engine/handler/following_handler/mod.rs:249-302`; `openraft/src/engine/engine_impl.rs:460-490` | After accepted snapshot metadata/membership/progress and purge command enqueue, before worker install | Message | Use `idx=snapshot.meta.last_log_id.index`; Entry is absent (`Nil` in spec). |
| 28 | `SMWorkerInstallSnapshot` | `openraft/src/core/sm/worker.rs:124-139`; `openraft/src/core/raft_core.rs:1954-1973` | After `install_snapshot` succeeds and worker response is sent, before core consumes it | none | Update durable snapshot and SM shadows; set `install_done=true`. |
| 29 | `RaftCoreHandleInstallSnapshotNotification` | `openraft/src/core/raft_core.rs:1591-1622` | After log/apply/snapshot `try_flush` updates | none | Clear install-pending tracer state after capture. |
| 30 | `LeaderHandlerSendHeartbeat` | `openraft/src/engine/handler/leader_handler/mod.rs:98-104`; `openraft/src/core/raft_core.rs:1765-1803` | After per-peer heartbeat events are broadcast to watch channels | none | Snapshot the exact session before workers run. |
| 31 | `HeartbeatWorkerDoRun` | `openraft/src/core/heartbeat/worker.rs:72-107` | Immediately before `network.append_entries` for the consumed watch event | `target` | The worker's recorded send time becomes `sentAt`. |
| 32 | `EngineHandleHeartbeatRequest` | `openraft/src/core/heartbeat/worker.rs:94-156`; `openraft/src/engine/engine_impl.rs:401-438` | On receiver after successful empty AppendEntries handling and response queueing | Message | Use response IOFlushed gating even with no log payload. |
| 33 | `RaftCoreHandleHeartbeatProgress` | `openraft/src/core/raft_core.rs:1573-1588`; `openraft/src/engine/handler/replication_handler/mod.rs:115-148` | After session check and optional clock-progress/lease update | Message | Emit stale ignored notifications with unchanged clock state. |
| 34 | `RaftCoreHandleEnsureLinearizableRead` | `openraft/src/core/raft_core.rs:267-317`; `openraft/src/engine/handler/leader_handler/mod.rs:106-117` | After capturing read log, applied, vote, membership and self grant; for lease, after lease test succeeds | `policy` (`ReadIndex` or `LeaseRead`) | Failed/forwarded reads do not emit this success-path event. |
| 35 | `RaftCoreSendReadIndexRequest` | `openraft/src/core/raft_core.rs:319-377` | Immediately before each spawned empty AppendEntries RPC | `target` | Read ID/session come from the captured read tracer object. |
| 36 | `EngineHandleReadIndexRequest` | `openraft/src/core/raft_core.rs:335-370`; `openraft/src/engine/engine_impl.rs:401-438` | Receiver after successful empty AppendEntries handling/response queue | Message | Same durability gate as heartbeat/replication. |
| 37 | `RaftCoreHandleReadIndexResponse` | `openraft/src/core/raft_core.rs:379-427` | After inserting target in the spawned future's captured grant set and any quorum completion | Message | Do not substitute current Engine membership/session for the captured values. |
| 38 | `LinearizerTryAwaitReady` | `openraft/src/raft/linearizable_read/linearizer.rs:99-135`; `openraft/src/raft/linearizable_read/linearize_state.rs:67-77` | On the successful branch after observed applied reaches read log ID | none | Timeout-not-ready is not this action. |
| 39 | `AdvanceClock` | trace runtime helper around ticks/monotonic `Instant` | After incrementing the compressed logical clock at an observed timeout/lease boundary | none | Emit `nid` as the node whose timer event caused advancement. |
| 40 | `LoseMessage` | harness network fault injector | At the point the selected RPC/request/response is dropped | Message + `kind` string | External fault action; never fabricate a receive event for the same message. |
| 41 | `Crash` | harness process/task fault injector | Immediately after marking node unavailable, before restart reads | none | Flush trace output before terminating the target task/process. |
| 42 | `RestartLoadState` | `openraft/src/storage/helper.rs:87-118,150-223` | After durable vote/log/optional commit are loaded and IO state constructed, before snapshot restore | none | For a true process restart, persist tracer durable shadows in the harness controller. |
| 43 | `StorageHelperRestoreFromSnapshot` | `openraft/src/storage/helper.rs:225-255` | After newer persistent snapshot installation succeeds (or after the explicit no-newer-snapshot decision) | none | Emit once per recovery attempt so replay stage is observable. |
| 44 | `StorageHelperReapplyCommitted` | `openraft/src/storage/helper.rs:123-148,258-275`; continue through `reapply_committed` | After each entry is re-applied | none | Instrument inside the chunk loop and emit one event per index. |
| 45 | `StorageHelperFinishRecovery` | `openraft/src/storage/helper.rs:145-150,202-223` | Immediately before returning the fully recovered `RaftState` to core startup | none | `recovery_ready=true`, stage `RecoverReady`. |
| 46 | `EngineStartupRestoreLeader` | `openraft/src/engine/engine_impl.rs:145-159`; `openraft/src/engine/handler/vote_handler/mod.rs:162-218` | After `update_internal_server_state` completes the persisted self-leader branch | none | Must occur after helper finish, never as a silent pre-replay step. |
| 47 | `EngineStartupFollowing` | `openraft/src/engine/engine_impl.rs:162-174` | After follower/learner startup state assignment | none | Emit learners as `Follower` for this baseline abstraction. |

## 3. Special considerations

### Capture timing and locks

- Do not hold the trace mutex across storage/network/state-machine awaits. Make
  the protocol change, obtain the minimal state locks/read guards, copy the
  snapshot, then acquire the trace mutex only to allocate logical clock/read/
  request IDs and append one line.
- Events 8→9→4 intentionally distinguish submit, durable completion, and core
  LocalIO handling. Combining them would make `DurableBeforeAck` untestable.
- Events 27→28→29→25 intentionally distinguish accepted snapshot metadata,
  worker persistence, core notification, and durable log purge.

### Trace-only shadows

`durableIO`, durable snapshot/purge metadata, recovery/build/install PCs,
request/read IDs, and `client_completed` need narrow tracing shadows because no
single OpenRaft object owns all of them. Shadows must be observational: update
them next to the real successful operation, never use them to gate production
control flow. Model-only proof history (`leaderHistory`, `voteSupport`,
`committedLog`, and `staleSessionEffect`) is reconstructed by TLA+ actions and
must not be injected into the trace.

### Batches and rejected paths

- Split append/apply/replay batches into per-index trace events in increasing
  order. The base model deliberately exposes each durable/apply boundary.
- Rejected vote, append, membership, snapshot, read, and trigger attempts are
  not state-changing base actions. Record them in a diagnostic log if useful,
  but not as `tag:"trace"` events with the action names above.
- A stale replication/heartbeat notification *is* a modeled action because it
  consumes an asynchronous message while leaving guarded state unchanged.

### Bootstrap and configuration

Focused traces should start from a fresh three-node cluster before the first
election. `TraceInit` then matches `base.Init`. Use at most two membership
request IDs per trace. `Trace.cfg` derives node count, maximum term/index/clock,
and payload values from the trace and defaults to `PersistCommitted = TRUE`.
For optional-commit recovery traces, use a copied config with
`PersistCommitted = FALSE`; do not relabel the default contract.

Trace files belong in the sibling `traces/` directory. The default is
`../traces/trace.ndjson`; set `IOEnv.JSON`/environment `JSON` to select an
individual trace during validation.
