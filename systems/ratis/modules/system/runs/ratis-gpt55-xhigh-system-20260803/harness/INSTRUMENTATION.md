# Ratis Trace Harness Instrumentation

## Run

From `.specula-output`:

```bash
bash harness/run.sh
```

Override the source checkout with `SPECULA_SOURCE_DIR=/path/to/ratis-system`.
Traces are written to `.specula-output/traces/*.ndjson`.

## Files

- `harness/src/main/java/org/apache/ratis/server/impl/SpeculaTrace.java`: synchronized NDJSON emitter and Ratis-to-TLA ID/index mapping.
- `harness/src/test/java/org/apache/ratis/grpc/TestSpeculaTraceHarnessWithGrpc.java`: four JUnit scenarios.
- `harness/patches/instrumentation.patch`: patch applied by `harness/apply.sh`.

## Main Hooks

- `ServerState.java:142,143,239,249,251,403,419,426`: metadata shadowing, restart, election, optional persist events, purge, configuration promotion, commit update.
- `RaftServerImpl.java:663,927,1157,1468,1549,1682,1704,1737,1751`: leader transition, client append, read completion, config start, vote grant, persist failure, append inconsistency, physical append completion, append reply.
- `LeaderStateImpl.java:441,632,742,750,892,1080,1202,1214,1224,1228`: bootstrap index filtering, config entries, queued stepdown, follower catch-up, read-index hooks.
- `GrpcLogAppender.java:227,231,235,409,461,527,783,833`: reset, append send, timeout, append success response, snapshot stream/notify.
- `RaftLogBase.java:343`: successful direct purge from the persistent log path.
- `ServerImplUtils.java:154,159`: append composition and in-flight registration.
- `SnapshotInstallationHandler.java:209,240,379`: snapshot chunk 0, finalize, reload.
- `StateMachineUpdater.java:267,271` and `ReplyFlusher.java:144`: apply and reply visibility.

## Event Shaping

`SpeculaTrace.reset(tracePath, peers)` must run before cluster start. It writes a `tag=config` line and maps sorted Ratis peer IDs to `s1`, `s2`, `s3`.

The emitter compresses real Ratis log indexes to logical indexes because Ratis writes startup/config/no-op entries that are not in `EntryValue`. Default traces include client values `v1` and `v2`. Configuration events are disabled unless `-Dspecula.trace.config.events=true`; read events are disabled unless `-Dspecula.trace.read.events=true`; persist events are disabled unless `-Dspecula.trace.persist.events=true`.

Snapshot chunk/finalize/reload events intentionally emit an empty `state`. The current base snapshot actions model snapshot frontier changes but keep term/leader fields unchanged, while real Ratis recognizes the leader at chunk handling time. Capturing those fields causes false mismatches.

## Scenarios

- `normal-consensus-read.ndjson`: normal leader election, two writes, append/commit/apply.
- `leader-loss-restart.ndjson`: leader kill, re-election, old leader restart, catch-up.
- `grpc-reconnect-timeout.ndjson`: outbound leader RPC block, timeout/reconnect path, eventual client success.
- `snapshot-catchup.ndjson`: follower down, leader snapshot/purge, follower restart and snapshot catch-up.

## Validation Notes

All traces are real NDJSON from the instrumented JUnit scenarios; `run.sh` validates JSON shape and event counts.

The provided `Trace.tla` has `TraceSpec == TraceInit /\ [][TraceNext]_TraceVars` and `TraceMatched == <>(l > Len(TraceLog))`. Without a fairness condition, TLC may report a stuttering counterexample before consuming the whole trace. For diagnosis, use a temporary wrapper that adds `WF_TraceVars(TraceNext)` and disables the `VIEW`.

With that fair wrapper, the current traces validate as follows:

- `normal-consensus-read.ndjson`: passes.
- `snapshot-catchup.ndjson`: passes.
- `leader-loss-restart.ndjson`: stops at the second-election path. The current base `RaftServerImpl_requestVote_Grant` precondition does not model a higher-term vote replacing an old `votedFor`.
- `grpc-reconnect-timeout.ndjson`: stops after blocked AppendEntries when the live system steps into loss/re-election behavior. This is the same multi-term/stepdown modeling boundary, not a trace format failure.

## Adjusting

To add a field, update `SpeculaTrace.coreState`, `logState`, or the event-specific helper, then rerun `bash harness/run.sh`.

To add an event, add a public `SpeculaTrace` method that builds `event.name`, `nid`, `state`, and action parameters, then insert a call at the real post-state point in Ratis source.

To move a capture point, keep the event name unchanged and move only the `SpeculaTrace.*` call. Do not hand-write trace files; rerun the JUnit scenario to regenerate them.
