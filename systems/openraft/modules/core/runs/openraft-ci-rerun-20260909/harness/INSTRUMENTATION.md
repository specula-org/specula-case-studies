# OpenRaft trace harness

## Scope and category

OpenRaft is a Category A distributed/message-passing system. The harness uses
one mutex-protected NDJSON writer per scenario, emits real Unix-epoch nanosecond
timestamps, and flushes every event. It is test-only behind
`cfg(all(test, feature = "specula-trace"))`; normal library builds are unchanged.

The first batch deliberately starts from a source-level state equivalent to
`base.Init` and covers three strict-replay actions plus one incremental
initialize/elect ordering assertion. It does not fabricate
storage, replication, apply, or recovery events merely to increase coverage.

## Applied files and capture points

After `bash harness/apply.sh`, the source checkout contains:

| Event | Applied location | Capture point |
|---|---|---|
| `HandleElectionTimeout` | `openraft/src/engine/engine_impl.rs:234` | After `elect()` has installed the candidate vote, accepted vote IO, `SendVote`, and candidate role. |
| `EngineHandleVoteRequest` | `openraft/src/engine/engine_impl.rs:337` | After `update_vote()` succeeds. Lease, log, and ordered-vote rejections do not emit. |
| `SnapshotHandlerTriggerSnapshot` | `openraft/src/engine/handler/snapshot_handler/mod.rs:45` | After `building_snapshot=true` and the real state-machine build command is queued. A duplicate trigger does not emit. |
| Trace runtime | `openraft/src/tla_trace.rs` | Full common-state serializer plus mutex writer. |
| Scenarios | `openraft/src/engine/specula_trace_scenarios.rs` | Four focused tests using the actual `Engine`, `SendVote` command, vote handler, initialize path, and snapshot handler. |

The runtime maps focused-test OpenRaft IDs `0,1,2` to TLA+ IDs `1,2,3` and
implements the exact `base.tla::VoteRank` formula. Voter lists are sorted.
The scenario tests are marked `#[ignore]` so ordinary feature-enabled library
regressions do not require `SPECULA_TRACE_FILE`; `run.sh` selects them with
`--ignored --exact` and fails if a scenario is not actually executed.

## State capture and shadows

For the covered paths, vote, role, accepted/submitted/flushed log IO,
commit/apply/snapshot/purge cursors, and committed/effective membership are read
from `RaftState` at the post-state capture point. The remaining fields are
trace-only initial shadows because none of the three covered actions changes
them: persistent vote, durable IO, read state, replication session, recovery
PC, snapshot worker/install PC, request state, and client completion.

Do not reuse those initial shadows when adding a storage/network/worker action.
Update the shadow next to the successful real operation first, then capture it.
In particular, preserve the distinct instrumentation-spec boundaries
`submit -> durable callback -> LocalIO` and
`snapshot accepted -> worker install -> core notification -> durable purge`.

`Trace.tla::ValidatePostState` is strong (not `TRUE`) and checks every emitted
common field. All three generated traces have passed this validator, including
`TraceMatched` and the configured invariants.

## Scenarios and observed event coverage

| Trace | Real behavior exercised | Events |
|---|---|---|
| `election_remote_grants.ndjson` | Node 0 campaigns; nodes 1 and 2 consume the actual `SendVote` request and grant it. | 3 |
| `competing_candidates.ndjson` | Two same-term candidates race; the lower advanced ballot is rejected without a trace event, while node 2 grants the higher ballot. | 3 |
| `snapshot_trigger.ndjson` | The first snapshot request queues a build; a duplicate request hits the in-progress guard and emits nothing. | 1 |
| `initialize_then_election.ndjson` | `Engine::initialize()` queues only the membership append and emits no modeled event; a later manual election produces the normal timeout trace event. | 1 |

Instrumented event-type coverage is 3/3:
`HandleElectionTimeout`, `EngineHandleVoteRequest`, and
`SnapshotHandlerTriggerSnapshot` each occur in at least one collected trace.

The following specification actions are not yet instrumented in this first
batch and therefore are not claimed as validated:

- Election/runtime IO: `RaftCoreRunCommandSaveVote`,
  `RaftCoreHandleLocalIO`, `RaftCoreReleaseVoteResponse`,
  `EngineHandleVoteResponse`.
- Append/replication/apply: `LeaderHandlerLeaderAppendEntries`,
  `RaftCoreRunCommandAppendEntries`, `LogStoreCompleteAppend`,
  `ReplicationHandlerSendReplicate`, `EngineHandleAppendEntries`,
  `RaftCoreReleaseRPCResponse`, `ReplicationHandlerUpdateProgress`,
  `RaftCoreRunCommandSaveCommittedAndApply`, `SMWorkerApply`,
  `ApplyResponderComplete`.
- Membership: `ManagementApiStartMembership`, `CoreChangeMembership`,
  `ManagementApiFlattenJoint`.
- Snapshot/purge beyond trigger: `SMWorkerBuildSnapshotStart`,
  `EngineOnBuildingSnapshotDone`, `LogHandlerSchedulePolicyBasedPurge`,
  `LogHandlerPurgeLog`, `RaftCoreRunCommandPurgeLog`,
  `ReplicationCoreSendSnapshot`, `FollowingHandlerInstallFullSnapshot`,
  `SMWorkerInstallSnapshot`, `RaftCoreHandleInstallSnapshotNotification`.
- Heartbeat/read/clock: `LeaderHandlerSendHeartbeat`, `HeartbeatWorkerDoRun`,
  `EngineHandleHeartbeatRequest`, `RaftCoreHandleHeartbeatProgress`,
  `RaftCoreHandleEnsureLinearizableRead`, `RaftCoreSendReadIndexRequest`,
  `EngineHandleReadIndexRequest`, `RaftCoreHandleReadIndexResponse`,
  `LinearizerTryAwaitReady`, `AdvanceClock`.
- Fault/recovery: `LoseMessage`, `Crash`, `RestartLoadState`,
  `StorageHelperRestoreFromSnapshot`, `StorageHelperReapplyCommitted`,
  `StorageHelperFinishRecovery`, `EngineStartupRestoreLeader`,
  `EngineStartupFollowing`.

## Adjusting the instrumentation

- Add a field: edit `harness/src/tla_trace.rs::state_json()` (common state) or
  the `serde_json::json!` details object at the action hook. Add the matching
  structural check to `harness/verify_traces.py`.
- Add an event type: place the emit immediately after the real successful
  transition, add its exact Trace.tla name to `EXPECTED_EVENTS`, and create a
  focused real-code scenario that reaches it. Rejected/no-op branches must not
  emit state-changing action names.
- Move a capture point: move the emit together with its state/shadow update.
  Never hold the trace mutex across a storage, network, or state-machine await.
- Add persistent or async paths: extend `TraceRuntime` with per-node shadows and
  mutate them only after the corresponding real future/callback succeeds.
- Change tests: edit `harness/src/specula_trace_scenarios.rs`; this copied file
  is the source of truth, not the generated copy under `openraft/src/`.

Rebuild, regenerate, structurally check, and replay every trace with:

```bash
cd .specula-output
bash harness/run.sh
```

`run.sh` is bounded by timeouts, applies the pinned-source patch idempotently,
runs each scenario in its own test process/file, checks all captured fields and
instrumented event coverage, then runs TLC against `spec/Trace.tla` and
`spec/Trace.cfg` for every trace.
