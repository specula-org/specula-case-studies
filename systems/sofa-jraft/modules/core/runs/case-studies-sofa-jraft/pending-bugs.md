# sofa-jraft Pending Bugs

Bugs confirmed in review but requiring further testing/reproduction before recording to tracker.

Test file: `jraft-core/src/test/java/com/alipay/sofa/jraft/core/PendingBugTest.java`

Run: `mvn test -pl jraft-core -Dtest=PendingBugTest -DfailIfNoTests=false`

---

## Reproduction Test Report: Invasiveness & Realism Analysis

### PB-2: testPB2_metaFileLossResetsTerm

**Invasive operations:** NONE
- Uses public `TestCluster` APIs (`start`, `stop`, `waitLeader`, `getFollowers`)
- Filesystem operations: `File.delete()` on the meta file — simulates disk corruption / accidental deletion
- Casts `Node` to `NodeImpl` only for `getCurrentTerm()` logging (not for the bug assertion itself)

**Real-world triggering:**
- Disk corruption (sector failure, filesystem error) can silently destroy the meta file
- Accidental deletion during operations (human error, misconfigured cleanup script)
- Cloud environments: ephemeral storage loss after VM migration/restart
- This is a **highly realistic** scenario — no artificial conditions needed

**Verdict:** Zero invasiveness. The test reproduces exactly what happens in production.

### PB-3: testPB3_onApplyExceptionStallsPipeline

**Invasive operations:**
- Custom `StateMachineAdapter` subclass that throws `RuntimeException` for a specific payload
- Direct `RaftGroupService` + `RpcServer` construction (same pattern as `TestCluster.start()`)
- Cast `Node` to `NodeImpl` for `getCurrentTerm()` logging only

**Real-world triggering:**
- `StateMachine.onApply()` is the intended user extension point — users implement their own FSM
- Any uncaught exception in user FSM code triggers this: `NullPointerException`, `ClassCastException`, deserialization error, schema mismatch, data corruption
- The test simulates a persistent exception (same entry always fails) — this is what happens when the log entry data itself is the problem (e.g., corrupt protobuf, unexpected message type)
- A transient exception (like an OOM that resolves) would self-heal via retry, but the closures are still lost

**Verdict:** Minimal invasiveness. Custom `StateMachine` is the standard user extension point. This is the exact scenario a user with a buggy FSM implementation would hit.

### PB-1: electSelf() RPC-before-persist (NOT TESTED)

**Why not tested:**
- Non-invasive testing requires proving that Netty I/O thread flushes bytes to the kernel TCP socket before the calling thread reaches `setTermAndVotedFor()` at line 1231
- This would require: packet capture (tcpdump), Netty debug logging, or injecting a delay before line 1231
- `NodeOptions` does not expose `RaftMetaStorage` as a pluggable component, so injecting a slow meta storage requires modifying `NodeImpl` source — HIGH invasiveness
- The code ordering violation (send at 1228, persist at 1231) is confirmed by static analysis; only the network delivery timing is unverified

---

## PB-1: electSelf() sends RPCs before persisting term+votedFor

| Field | Value |
|-------|-------|
| File | `NodeImpl.java` |
| Lines | 1190 (term++), 1228 (send RPC), 1231 (persist) |
| Discovery | Code Analysis |
| Status | **Test PASSED** — bug confirmed via `PendingBugTest#testPB1_electSelfSendsRpcBeforePersist` |

### Description

`electSelf()` increments term in memory (line 1190), sends RequestVote RPCs to all peers (line 1228), and only then persists `(term, votedFor)` to disk (line 1231). Raft requires persist-before-send.

### Test result

Test `PendingBugTest#testPB1_electSelfSendsRpcBeforePersist` **PASSED**:
```
=== PB-1: Initial leader=10.131.161.49:5004 term=1 ===
=== PB-1: Stopping leader 10.131.161.49:5004 to trigger election ===
java.lang.RuntimeException: PB-1: Simulated crash before persisting term=2
=== PB-1: Node0 crashed on persist at term=2 ===
=== PB-1: Observer term before=1, after=2 ===
=== PB-1: BUG CONFIRMED — observer received RequestVote (term updated to 2) before node0's persistence at term 2 ===
```

Method: Inject a `CrashingMetaStorage` via `NodeOptions.setServiceFactory()` (official SPI extension point) that throws `RuntimeException` in `setTermAndVotedFor()`, simulating a crash between RPC send and persistence. The observer node's term advanced from 1 to 2, proving the RequestVote RPC was delivered before persistence.

---

## PB-2: Meta file loss silently resets term to 0

| Field | Value |
|-------|-------|
| File | `LocalRaftMetaStorage.java` |
| Lines | 89-104 (load), NodeImpl.java:605-616 (initMetaStorage) |
| Discovery | Code Analysis + MC |
| Severity | **Medium** (robustness issue, not a design oversight — see note) |
| Status | **Test PASSED** — bug confirmed via `PendingBugTest#testPB2_metaFileLossResetsTerm` |

### Description

`load()` returns `true` with default `term=0` when the meta file is missing (`FileNotFoundException`) or empty (`meta == null`). A node that previously ran at term=5, if its meta file is lost, restarts with term=0 and can vote again in already-decided terms. `initMetaStorage()` does not cross-validate meta term against the log.

### Severity note

The `catch (FileNotFoundException)` is **intentional** — it handles first-time startup when the meta file doesn't yet exist (same pattern in braft C++ upstream: `errno == ENOENT → ret = 0`). The issue is that this same code path is also triggered by post-startup file loss, which is a low-probability event (disk corruption, accidental deletion). The fix (cross-validate against log term, or log a warning) is near-zero cost, so this is more of a robustness improvement than a critical safety violation.

### MC result (from previous session)

Family 5 configuration reported ElectionSafety violation in 7402 traces. Counterexample: s1 votes at term=2 → meta file lost → restarts at term=0 → votes for different candidate at term=2 → dual leader.

### Reproduction plan

- [ ] Re-run TLC with MC_family5.cfg and capture the full counterexample trace
- [ ] Verify the counterexample shows the expected CorruptedCrash → term reset → double vote sequence
- [ ] Document the exact state trace

### Test result

Test `PendingBugTest#testPB2_metaFileLossResetsTerm` **PASSED**:
```
=== PB-2: Victim 10.131.161.49:5003 has term=1 before stop ===
=== PB-2: Deleted meta file at .../meta/raft_meta ===
=== PB-2: Node restarted successfully with deleted meta file ===
=== PB-2: BUG CONFIRMED — node started with term=0, no cross-validation ===
```
The node restarted successfully (`start()` returned `true`) despite the meta file being absent, proving `LocalRaftMetaStorage.load()` silently returns `true` with `term=0`.

---

## PB-3: User FSM exception in onApply permanently stalls apply pipeline

| Field | Value |
|-------|-------|
| File | `FSMCallerImpl.java` |
| Lines | 593-608 (doApplyTasks), 520-576 (doCommitted) |
| Discovery | Code Analysis |
| Status | **Test PASSED** — bug confirmed via `PendingBugTest#testPB3_onApplyExceptionStallsPipeline` |

### Description

If `fsm.onApply(iter)` throws an uncaught exception:

1. Exception propagates out of `doApplyTasks` (no catch, only finally for metrics)
2. Exception propagates out of `doCommitted` — **`setLastApplied` at line 572 is skipped**
3. Exception reaches Disruptor's `LogExceptionHandler` which only logs it (line 63-64), no recovery
4. `closureQueue` has already been drained by `popClosureUntil` (line 534) — closures are gone
5. Next `doCommitted` call: `lastAppliedIndex` unchanged, still < `committedIndex`, creates new iterator from same index
6. Same entries are re-applied → same exception → **infinite loop**

The node stays alive (Disruptor keeps running) but the FSM is permanently stuck, never advancing `lastAppliedIndex`.

### Reproduction plan

- [x] Write a test with a custom StateMachine whose `onApply()` throws RuntimeException on a specific log entry
- [x] Submit entries via the leader, observe that `lastAppliedIndex` stops advancing
- [x] Verify the Disruptor error log shows repeated exceptions for the same index
- [x] Confirm the node does not crash but FSM is permanently stalled

### Test result

Test `PendingBugTest#testPB3_onApplyExceptionStallsPipeline` **PASSED**:
```
=== PB-3: Last successful apply index: 3 ===
=== PB-3: Exception count: 2 ===
=== PB-3: Applied index after extra tasks: 3 ===
=== PB-3: Extra tasks completed: false ===
=== PB-3: Extra tasks applied ok: false ===
=== PB-3: Total exception count: 3 ===
=== PB-3: BUG CONFIRMED — apply pipeline stalled, repeated exceptions ===
```
Key observations:
- Exception fires 3 times for the same poisoned entry (retried on each `doCommitted` call)
- `lastAppliedIndex` stuck at 3, never advances
- Extra entries submitted after the crash are never applied, callbacks never fire
- Node stays alive but FSM is permanently stalled
