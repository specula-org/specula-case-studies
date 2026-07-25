# braft_3 Trace Harness — Instrumentation Guide

Phase 3 reference: what is instrumented, where to find each emit site after
`apply.sh`, and how to extend the harness when trace validation surfaces a
mismatch.

## 1. Layout

```
harness/
├── src/
│   ├── trace_logger.h           ← copied to artifact/braft/src/braft/
│   ├── trace_logger.cpp         ← copied to artifact/braft/src/braft/
│   ├── test_bug_repro.cpp       ← copied to artifact/braft/test/
│   └── test_trace_smoke.cpp     ← copied to artifact/braft/test/
├── patches/
│   └── instrumentation.patch    ← applied to CMakeLists / node.{cpp,h} /
│                                  replicator.cpp / ballot_box.{cpp,h} /
│                                  snapshot_executor.cpp
├── apply.sh                     ← reset tree, copy src/, apply patch
├── clean.sh                     ← revert artifact to upstream
├── run.sh                       ← apply → cmake → build → run scenarios
└── INSTRUMENTATION.md           ← this file
```

`run.sh` produces three trace files under `../traces/`:

| Trace file | Test | Purpose |
|---|---|---|
| `smoke_elect_replicate.ndjson` | `TraceSmokeTest.ElectAndReplicate` | 3-node cluster: PreVote/Elect/AppendEntries/Commit |
| `smoke_leader_lease.ndjson`     | `TraceSmokeTest.LeaderLeaseValid`   | 3-node + leader lease enabled — `CheckLeaderLease` fires |
| `bug_force_commit.ndjson`       | `BugReproTest.ForceCommitViaConfigChange` | 4-node cluster — exercises `AdvanceCommitIndex` corner + `TakeSnapshot` |

## 2. Compile-time gate

The instrumentation is guarded by `BRAFT_ENABLE_TRACE` (set by CMake option
`WITH_BRAFT_TRACE=ON`).  Without it the emit calls compile to no-ops, so the
shipped library and the instrumented library produce byte-identical binaries
when `WITH_BRAFT_TRACE=OFF`.

Runtime is gated by two gflags exposed in `trace_logger.cpp`:

```
--raft_trace_enabled   (default: false)
--raft_trace_file      (default: "")
```

Both must be set for events to be emitted.  Tests pick these up from the
`RAFT_TRACE_FILE` environment variable in `SetUp()`.

## 3. Per-action instrumentation map

Line numbers below refer to the *instrumented* artifact tree after
`apply.sh` (the patch shifts lines slightly).

| Spec action | File | After-patch line(s) | Capture |
|---|---|---|---|
| `PreVote`                       | node.cpp     | inside `pre_vote()`,        after `_pre_vote_ctx.init`  | full |
| `HandlePreVoteRequest`          | node.cpp     | end of `handle_pre_vote_request`                       | full + msg{from,to,term,granted,rejectedByLease,disrupted} |
| `HandlePreVoteResponse`         | node.cpp     | step-down branch AND main branch of `handle_pre_vote_response` | full + msg{from,to,granted,disrupted} |
| `BecomeCandidate`               | node.cpp     | `elect_self()` after `_voted_id = _server_id;`         | full |
| `CompletePersistTerm`           | node.cpp     | `elect_self()` after `set_term_and_votedfor` (both branches) AND `handle_request_vote_request` grant path | full (no msg) |
| `HandleRequestVoteRequest`      | node.cpp     | end of `handle_request_vote_request`                    | full + msg{from,to,term,granted,rejectedByLease,disrupted} |
| `HandleRequestVoteResponse`     | node.cpp     | step-down branch AND main branch of `handle_request_vote_response` | full + msg{from,to,term,granted} |
| `BecomeLeader`                  | node.cpp     | `become_leader()` after `_leader_lease.on_leader_start(...)` | full |
| `WitnessStepDownReactive`       | node.cpp     | `check_witness()` after `step_down(...)`                | full |
| `CheckLeaderLease`              | node.cpp     | end of `handle_stepdown_timeout()`                      | full (sets state.leaderLeaseValid) |
| `HandleAppendEntriesRequest`    | node.cpp     | three paths in `handle_append_entries_request`: term-mismatch reject, empty-entries (heartbeat), append (replicate) | full + msg{from,to,term,prevLogIndex?,prevLogTerm?,entriesSize?,commitIndex,success?} — heartbeats omit `prevLogIndex` |
| `HandleInstallSnapshotRequest`  | node.cpp     | `handle_install_snapshot_request` before forwarding to executor | full + msg{from,to,term,lastIncludedIndex,lastIncludedTerm} |
| `AdvanceCommitIndex`            | ballot_box.cpp | `BallotBox::commit_at` after the `_last_committed_index.store(...)` | commit (term + role + commitIndex) |
| `SendHeartbeat`                 | replicator.cpp | `_send_empty_entries(is_heartbeat=true)` before `stub.append_entries(...)` | weak + msg{from,to,term,commitIndex} |
| `SendReplicateEntries`          | replicator.cpp | `_send_entries` before `stub.append_entries(...)`     | weak + msg{from,to,term,prevLogIndex,prevLogTerm,entriesSize,commitIndex} |
| `SendInstallSnapshot`           | replicator.cpp | `_install_snapshot` after `_install_snapshot_in_fly = cntl->call_id();` | weak + msg{from,to,term,lastIncludedIndex,lastIncludedTerm} |
| `HandleHeartbeatResponse`       | replicator.cpp | `_on_heartbeat_returned` after `_start_heartbeat_timer(...)` | weak + msg{from,to,term} |
| `HandleReplicateResponse`       | replicator.cpp | both failure and success branches of `_on_rpc_returned` | weak + msg{from,to,term,success,matchIndex,entriesSize} |
| `HandleInstallSnapshotResponse` | replicator.cpp | `_on_install_snapshot_returned` after success/failure resolved | weak + msg{from,to,term,success,lastIncludedIndex} |
| `TakeSnapshot`                  | snapshot_executor.cpp | `on_snapshot_save_done` after `_log_manager->set_snapshot(...)` | full (under `_node->_mutex`) |
| `OnSnapshotLoadDone`            | snapshot_executor.cpp | `on_snapshot_load_done` after the success branch     | full (under `_node->_mutex`) |

Capture levels — what `TraceState` writes for each:

| Level | Fields | Validator in Trace.tla |
|---|---|---|
| **full** (`TraceState::capture`) | term, role, votedFor, commitIndex, lastLogIndex, lastLogTerm, nodeRole, virtualFirstLog, physicalFirstLog, installingSnapshot, leaderLeaseValid, followerLease | `ValidatePostState` |
| **weak** (`TraceState::capture_weak`) | term, role (rest defaulted) | `ValidatePostStateWeak` — used for replicator-bthread events that don't hold `NodeImpl::_mutex` |
| **commit** (`TraceState::capture_commit`) | term, role, commitIndex | `ValidatePostStateCommit` — used for `AdvanceCommitIndex` |

## 4. Server-ID mapping

`TraceServerMap` assigns short IDs (`s1`, `s2`, ...) in registration order.
The first call is `trace_init()` from `NodeImpl::init()`, which registers
`self` first then every peer in `_conf.conf`.  Because peers come from a
`std::set<PeerId>`, the order is the natural sort order of the underlying
`std::string` form (ip:port:idx).  Each test pins the ports so the order is
stable across runs:

* 3-node smoke: ports 5306-5308 → s1, s2, s3
* 3-node lease smoke: ports 5316-5318 → s1, s2, s3
* 4-node bug-force-commit: ports 5006-5009 → s1, s2, s3, s4

The TraceWriter is opened on the FIRST `trace_init` call only — every node in
the same process appends to the same file under a mutex.

## 5. Known mismatches between trace and `Trace.cfg`

These are NOT format issues — the trace is well-formed.  Phase 3 must
reconcile them before model checking.

### 5.1 Model-value vs. JSON-string

`spec/Trace.cfg` declares constants with model-value syntax:

```
s1 = s1
Server = {s1, s2, s3}
Follower = Follower
...
```

The trace's `nid`, `role`, `votedFor`, `msg.from`, `msg.to` are JSON strings.
TLC compares them as ordinary strings.  As soon as `Trace.tla` evaluates
`TraceServer \subseteq Server`, the assumption fails because `"s1" /= s1`
(model value).

**Fix** (Phase 3): change `Trace.cfg` constants to string literals:

```
s1 = "s1"
s2 = "s2"
s3 = "s3"
Server = {"s1", "s2", "s3"}

Nil         = "Nil"
Follower    = "Follower"
Candidate   = "Candidate"
Leader      = "Leader"
Voter       = "Voter"
Witness     = "Witness"
ValueEntry  = "ValueEntry"
ConfigEntry = "ConfigEntry"

PreVoteRequest          = "PreVoteRequest"
PreVoteResponse         = "PreVoteResponse"
RequestVoteRequest      = "RequestVoteRequest"
RequestVoteResponse     = "RequestVoteResponse"
AppendEntriesRequest    = "AppendEntriesRequest"
AppendEntriesResponse   = "AppendEntriesResponse"
InstallSnapshotRequest  = "InstallSnapshotRequest"
InstallSnapshotResponse = "InstallSnapshotResponse"
TimeoutNowRequest       = "TimeoutNowRequest"
```

(I verified this end-to-end: with the string config, `Trace.tla` parses
through the ASSUME block and starts replaying events.)

### 5.2 4-node trace vs. 3-node `Server`

`bug_force_commit.ndjson` runs a 4-node cluster (s1–s4) but `Trace.cfg` only
declares `Server = {s1, s2, s3}`.  Either extend the config to `{s1,s2,s3,s4}`
for that trace, or rewrite `BugReproTest.ForceCommitViaConfigChange` as a
3-node scenario.  The smoke traces are 3-node and ready to validate.

## 6. Events not yet covered by any scenario

| Spec action | Why not exercised | How to add |
|---|---|---|
| `SendInstallSnapshot`              | Snapshot install only triggers when a follower lags past the leader's first_log_index.  Requires snapshot_interval_s < test_duration AND a paused follower. | New `TraceSmokeTest.SnapshotInstall`: start cluster, pause s3, apply N entries, take a snapshot (`leader->snapshot()`), then resume s3.  Replicator should fall back to `_install_snapshot()`. |
| `HandleInstallSnapshotRequest`     | same as above (receiver side) | same scenario |
| `HandleInstallSnapshotResponse`    | same as above | same scenario |
| `OnSnapshotLoadDone`               | same as above | same scenario |
| `WitnessStepDownReactive`          | Requires a node to be configured with `options.witness = true`.  None of the current scenarios do that. | New scenario using `Configuration::parse_from("ip:port:0:witness,...")` style. |

The trace spec covers the missing events via `SilentTransitionCopyToLoad`,
`SilentSnapshotRenameBegin`, `SilentSnapshotRenameComplete`, etc., so basic
validation can proceed even before these scenarios are added; coverage of the
related bug families just stays weaker.

## 7. How to make adjustments

### 7.1 Add a new field to an event

1. Append `.msg_field("key", value)` to the relevant `TraceEvent(...)` block in
   `node.cpp` / `replicator.cpp` / `ballot_box.cpp` / `snapshot_executor.cpp`.
   The builder accepts `int64_t`, `bool`, and `std::string`.
2. If the new field is a state field rather than a message field, add it to
   `struct TraceState` and `TraceState::capture()` in `trace_logger.h/.cpp`,
   then emit it in `TraceEvent::emit()`.
3. Regenerate the patch: `cd artifact/braft && git diff -- … >
   harness/patches/instrumentation.patch`.

### 7.2 Move a capture point (before → after)

Each emit site is in the source file as a `BRAFT_TRACE_IF_ENABLED(...)`
block.  Cut and paste the block to the new location, then regenerate the
patch.

### 7.3 Add a new event type

There is no per-event class — `TraceEvent("EventName")` is sufficient.  Add a
new emit block at the trigger point and (in Phase 3) add the corresponding
`<Action>IfLogged` wrapper in `Trace.tla`.

### 7.4 Rebuild and re-collect traces

```
cd .specula-output
bash harness/clean.sh                 # revert artifact
bash harness/apply.sh                 # re-apply patch + source
bash harness/run.sh                   # build + run + collect
```

Total runtime is ~3 minutes (build dominates).  Subsequent `run.sh` calls
reuse the build directory and finish in <30s.

## 8. Quirks

* `TraceWriter::open` is idempotent on subsequent calls so multi-node tests
  in the same process all share one trace file.  Closing is handled by the
  process exit.
* Replicator-thread events (`SendHeartbeat`, `SendReplicateEntries`,
  `Handle*Response`, `SendInstallSnapshot`) use **weak** state capture
  (term + role only).  They cannot read `NodeImpl::_mutex`-protected state
  without re-acquiring the lock — and Phase 2's spec marks them
  `ValidatePostStateWeak` for exactly that reason.  Do NOT promote them to
  full capture without first ensuring the lock can be held safely.
* `BallotBox::commit_at` runs under `_mutex` (its own, not the node's).  It
  knows the leader's `term` only via `set_trace_context()`, called from
  `become_leader()`.  If you instrument code that calls `commit_at` on a
  non-leader (rare in braft), `_trace_term` may be stale — the trace will
  still validate because `ValidatePostStateCommit` re-establishes term from
  the event.
* `OnSnapshotLoadDone` and `TakeSnapshot` re-acquire `_node->_mutex` to
  capture state.  This is safe because both run on the FSM caller thread,
  not under any other node lock.
