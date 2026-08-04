# ratis-server Trace Harness

This harness instruments the real Apache Ratis `ratis-server` module and runs
JUnit scenarios that emit Specula NDJSON traces for `Trace.tla`.

## Files

- `src/main/java/org/apache/ratis/server/impl/SpeculaTrace.java`: synchronized
  NDJSON writer and weak state snapshot helper.
- `src/test/java/org/apache/ratis/SpeculaTraceHarnessTest.java`: four concrete
  scenarios using `MiniRaftClusterWithSimulatedRpc`.
- `patches/instrumentation.patch`: production-source instrumentation patch for
  existing Ratis files only.
- `apply.sh`: copies harness Java files into the source tree and applies the
  production patch idempotently.
- `run.sh`: applies instrumentation, runs Maven tests, checks NDJSON, and runs
  quick TLC trace validation.

Run from `.specula-output`:

```bash
bash harness/run.sh
```

Useful overrides:

```bash
SPECULA_SOURCE_DIR=/path/to/ratis-server bash harness/run.sh
SPECULA_TRACE_DIR=/tmp/ratis-traces bash harness/run.sh
SPECULA_TLC_STRICT=1 bash harness/run.sh
```

## Instrumentation Points

Election and voting:

- `ServerState.initElection(Phase.ELECTION)` emits
  `ServerState.initElection.ELECTION` after `persistMetadata()`.
- `LeaderElection.submitRequests` emits `LeaderElection.submitRequestVote`
  before each real election vote RPC submission.
- `LeaderElection.logAndReturn` emits `LeaderElection.waitForResults.pass`
  when the election phase passes.
- `RaftServerImpl.requestVote` emits
  `ServerProtoUtils.setVoteReplyLastEntryKind`,
  and `RaftServerImpl.requestVote.grant` for successful election votes. It does
  not emit ordinary reject events because concurrent startup elections can
  reorder reject handling against local `initElection` events in a single-file
  trace.

Append, durability, and commit:

- `SegmentedRaftLog.appendEntry` emits
  `RaftLogBase.appendEntry.cacheAndQueue` for leader-local appends, including
  `kind=normal|config` and the added peer for configuration entries.
- `SegmentedRaftLogWorker.WriteLog.execute` emits
  `SegmentedRaftLogWorker.WriteLog.execute` for leader-local writes.
- `SegmentedRaftLogWorker.flushIfNecessary` emits flush start, complete, and
  async failure events for leader-local flushes.
- `RaftLogBase.appendMetadata` emits `RaftLogBase.appendMetadata`.
- `LeaderStateImpl.updateCommit` emits `LeaderStateImpl.updateCommit` after
  the committed index advances.
- `LogAppenderDefault.sendAppendEntriesWithRetries` emits send and reply
  timestamp events around the real AppendEntries RPC.
- `RaftServerImpl.appendEntriesAsync` emits reject-snapshot and success events.

Snapshots, reads, leases, and configuration:

- `SnapshotInstallationHandler` emits chunk append, final publish, notification
  start, and notification completion events.
- `RaftServerImpl.sendReadIndexAsync` emits follower ReadIndex forwarding and
  failure attempts.
- `LeaderStateImpl.getReadIndex`, `getAndSetLeaseEnabled`, and `hasLease`
  emit lease fast-path and lease-state events.
- `LeaderStateImpl.startSetConfiguration`, `applyOldNewConf`,
  `configAck`, and `commitOldNewConf` emit configuration-change progress.
- `RaftServerImpl.appendEntriesAsync` emits
  `ServerState.updateConfiguration.beforeAppendDurable` when a follower applies
  a config entry mentioning `s3` before append durability completes. These
  events capture membership state only, since commit/flush state can interleave
  with metadata-log durability.

## Trace Shape

Every trace line is either:

```json
{"tag":"config","ts":"...","config":{"servers":["s1","s2","s3"]}}
{"tag":"trace","ts":"...","event":{"name":"...","nid":"s1"}}
```

`SpeculaTrace` maps Ratis peer IDs to the TLA constants `s1`, `s2`, and `s3`.
It drops events whose `index` or `msg.index` exceeds `specula.trace.maxIndex`
which defaults to `8`, matching `Trace.cfg`.

The writer also suppresses `LeaderElection.submitRequestVote` and
`LeaderStateImpl.sendAppendEntries` records. The production code is still
instrumented at those points, but this `Trace.tla` replays those actions through
`SilentSubmitRequestVote` and `SilentSendAppendEntries` immediately before the
corresponding handler event.

Follower-side cache/queue records are suppressed because
`RaftServerImpl.appendEntries.success` models follower log enqueue. Follower
worker write/flush records are buffered until the matching append success event,
then emitted without state fields so the trace still observes durable-log
progress without racing the RPC handler.

The state capture is intentionally weak and event-specific. Ordinary server
events record public, low-risk fields: `term`, `role`, `leaderId`, `votedFor`,
`currentConf`, `commitIndex`, `flushIndex`, and `snapshotIndex` when available.
Leader WAL events record only log indexes, append-reply timestamp events and
follower worker events record empty state, and follower configuration-update
events record only membership/server identity state. The helper does not add new
production accessors for private durable log internals, lease freshness,
metadata commit index, durable configuration, in-flight snapshot index, or
ReadIndex result shadows.

`MiniRaftClusterWithSimulatedRpc` does not implement
`RaftServerAsynchronousProtocol`, so the follower ReadIndex scenario records the
real `RaftServerImpl.sendReadIndexAsync` forwarding attempt and asserts the
controlled unsupported-async exception. The leader-side linearizable read in the
same scenario remains a successful real read path.

## Adjusting For Phase 3

If `Trace.tla` rejects a trace because a post-state field is too strong or is
captured before the modeled transition, adjust one of these first:

- Move the `SpeculaTrace.emit(...)` call to immediately after the real state
  mutation modeled by the TLA action.
- Remove or specialize a state field in `SpeculaTrace.captureState` or
  `captureLogState` if the implementation field is not the same abstraction as
  the TLA variable.
- Add a narrowly scoped shadow in `SpeculaTrace` only when the real field is
  private and no public accessor matches the trace spec.
- Keep ordinary validation traces free of fault-only event names such as
  `SegmentedRaftLogWorker.asyncFlushOutStream.completeLateOrFailed`,
  `RaftServerImpl.appendEntries.acceptDuringSnapshotFault`,
  `LeaderStateImpl.commitConfigWithoutOldMajorityFault`, and `LoseMessage`.

After changes:

```bash
cd /home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-server-20260803/ratis-server/.specula-output
bash harness/run.sh
```
