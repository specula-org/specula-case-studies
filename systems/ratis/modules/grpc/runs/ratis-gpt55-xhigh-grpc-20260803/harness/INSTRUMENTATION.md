# ratis-grpc Trace Harness

This harness instruments the real Apache Ratis gRPC replication path and writes
one NDJSON trace per JUnit scenario.  The target `Trace.tla` filters
`tag = "ratis-grpc"`, so emitted protocol events use that tag.  The first line
in each file is a `tag = "config"` scenario marker.

## Apply and Run

From `.specula-output`:

```bash
bash harness/run.sh
```

Environment overrides:

- `SPECULA_RATIS_GRPC_ARTIFACT`: artifact checkout, default
  `/home/ubuntu/specula-ratis-issue123-20260803/sources/ratis-grpc`
- `SPECULA_TRACE_DIR`: output trace directory, default `.specula-output/traces`
- `SPECULA_RUN_TLC=1`: also run optional TLC replay smoke checks

`harness/apply.sh` replays `harness/patches/instrumentation.patch`, then copies:

- `harness/src/main/java/org/apache/ratis/specula/RatisGrpcTrace.java`
- `harness/src/test/java/org/apache/ratis/grpc/TestSpeculaGrpcTraceHarness.java`

## Scenarios

- `normal-append.ndjson`: three-node gRPC AppendEntries replication.
- `timeout-restart.ndjson`: follower write blocking, append timeout, appender restart, and stream reset/cancel paths.
- `snapshot-staging-peer.ndjson`: one-node leader, forced snapshot, two staging peers, snapshot install, catch-up check, and config application.

## Instrumentation Points

- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:212`: local append stream cancellation during reset.
- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:243`: stream reset event selection.
- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:265`: snapshot trigger and staging snapshot attempt.
- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:401`: stream readiness while waiting for gRPC onReady.
- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:454`: stream reconnect after observer creation.
- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:457`: append data, heartbeat, and append-after-snapshot sends.
- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:506`: append timeout after pending removal.
- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:600`: leader-side append reply handling.
- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:765`: install-snapshot reply handling.
- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:850`: snapshot stream-name mapping.
- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:859`: chunked snapshot send.
- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:878`: snapshot installed after sender completion.
- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcServerProtocolService.java:196`: weak server-side append stream cancellation.
- `ratis-grpc/src/main/java/org/apache/ratis/grpc/util/StreamObserverWithTimeout.java:90`: snapshot backpressure wait.
- `ratis-grpc/src/main/java/org/apache/ratis/grpc/util/StreamObserverWithTimeout.java:118`: resource-exhausted timeout.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/RaftServerImpl.java:1691`: follower-side inconsistency and snapshot-in-progress replies.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/RaftServerImpl.java:1735`: follower-side success replies.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderStateImpl.java:548`: staging peer creation.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderStateImpl.java:728`: appender restart.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderStateImpl.java:891`: stale staging progress check.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderStateImpl.java:898`: caught-up staging progress check.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderStateImpl.java:904`: old-new configuration application.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderStateImpl.java:1045`: leader commit-index advance.

## Changing Events

- Add or rename an event in `RatisGrpcTrace.java`, then update the call site and
  `known_events` in `harness/run.sh`.
- Add a field by extending the event-specific `fields` map or `state` map in
  `RatisGrpcTrace.java`.
- Move a capture point only after checking whether `Trace.tla` validates primed
  post-state or pre-state for that action.
- Rebuild with `bash harness/run.sh`; the script reapplies the patch, compiles,
  runs tests, validates NDJSON, and reports line counts.

## Validation Notes for Phase 3

Generated traces are real implementation traces.  They are not hand-written and
timestamps come from the running JVM.

`harness/Trace.harness.cfg` uses JSON string node constants:

```tla
Server = {"L", "F1", "F2"}
LeaderNode = "L"
```

The original `Trace.cfg` uses model values and small bounds intended for model
checking, so it does not replay these real traces directly.

Current TLC replay reaches implementation events, but `Trace.tla` can still
fail `TraceMatched` because `TraceSilentEnqueueSuccessReply` and
`TraceSilentEnqueueInconsistencyReply` may repeatedly enqueue extra replies on
branches where explicit `FollowerAppendSuccess` or
`FollowerAppendInconsistency` events already appear.  Phase 3 should either
guard silent enqueue actions so they fire only when the trace lacks the explicit
follower reply event, or run an existential/single-path trace replay mode.

Currently uncovered optional events in the generated tests:

- `CompactLeaderLog`: no direct leader compaction event observed before the
  snapshot-install path starts.
- `FollowerSnapshotInProgress`: current snapshot installation did not overlap
  with a follower AppendEntries rejection.
- `ReceiveSuccessWithoutRequest`: no late success reply after request removal in
  these deterministic scenarios.
- `ReceiveInconsistencyWithoutRequest`: no late inconsistency reply after
  request removal in these deterministic scenarios.
- `ResourceExhausted`: requires holding snapshot backpressure past
  `StreamObserverWithTimeout` timeout.
- `SnapshotAlreadyInstalled`: depends on follower returning
  `ALREADY_INSTALLED`; current snapshot scenario returns `SNAPSHOT_INSTALLED`.
- `SnapshotUnavailableOrExpired`: requires unavailable or expired leader
  snapshot state.
- `StreamErrorReset`: current fault injection triggers completion/cancel reset,
  not gRPC error reset.
- `TriggerSnapshot`: staging peers emit the more specific
  `SnapshotAttemptForStagingPeer`.
