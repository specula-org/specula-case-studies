# sofa-jraft Bug Confirmation Checklist

This document lists all 25 bugs found during analysis of the sofa-jraft project, with code evidence and confirmation status for each.

**Discovery method abbreviations**: CA = Code Analysis, MC = Model Checking, TV = Trace Validation

---

## A. Protocol Safety (#1 - #5)

---

### Bug #1: handleRequestVoteRequest Non-atomic Vote Persistence

| Property | Value |
|----------|-------|
| File | `NodeImpl.java` |
| Lines | 1871-1874 (vote), 1343-1346 (stepDown) |
| Discovery | CA |
| MC Reproducible | Family 1 not triggered (400K traces), confirmed via architectural analysis |
| Existing Issue | #1241 (open), #1242 (test PR) |
| Confirmation Status | **Pending** |

**Bug Description**: `handleRequestVoteRequest` performs two disk writes when voting: `stepDown()` first writes `(term, empty)`, then `setVotedFor(candidate)` writes again. A crash between the two writes allows double-voting in the same term.

**Code Evidence**:

Vote path (NodeImpl.java:1871-1874):
```java
stepDown(request.getTerm(), false, new Status(RaftError.EVOTEFORCANDIDATE, ...));
// ↑ internally calls setTermAndVotedFor(term, emptyPeer) — disk write ①
this.votedId = candidateId.copy();
this.metaStorage.setVotedFor(candidateId);  // — disk write ②
```

Persistence in stepDown (NodeImpl.java:1343-1346):
```java
if (term > this.currTerm) {
    this.currTerm = term;
    this.votedId = PeerId.emptyPeer();
    this.metaStorage.setTermAndVotedFor(term, this.votedId);  // disk write ①
}
```

**Crash Scenario**: Write ① succeeds (term=T, votedFor=empty), crash occurs, after restart the node can vote for a different candidate at term=T.

**Note**: stepDown only writes to disk when `request.getTerm() > this.currTerm`. If terms are equal, there is only one write, no issue.

---

### Bug #2: electSelf() Sends RPC Before Persisting

| Property | Value |
|----------|-------|
| File | `NodeImpl.java` |
| Lines | 1190 (term++), 1228 (send RPC), 1231 (persist) |
| Discovery | CA |
| MC Reproducible | Same as Family 1, not triggered |
| Existing Issue | Related to #1241 |
| Confirmation Status | **Pending** |

**Bug Description**: `electSelf()` first increments the term in memory, sends RequestVote RPCs, and only persists last. Within the crash window, remote nodes have already voted but the local term is lost.

**Code Evidence** (NodeImpl.java:1190-1231):
```java
this.currTerm++;                           // line 1190: in-memory update
this.votedId = this.serverId.copy();       // line 1191: in-memory update
// ... unlock, getLastLogId, relock ...
for (final PeerId peer : this.conf.listPeers()) {
    // ...
    this.rpcService.requestVote(peer.getEndpoint(), done.request, done);  // line 1228: send RPC
}
this.metaStorage.setTermAndVotedFor(this.currTerm, this.serverId);  // line 1231: persist (last!)
```

**Crash Scenario**: After RPCs are sent but before persistence, crash occurs. Remote nodes received term=T RequestVote and voted, but local term rolls back on restart.

---

### Bug #3: setTermAndVotedFor() Return Value Ignored by 3 Callers

| Property | Value |
|----------|-------|
| File | `NodeImpl.java` |
| Lines | 1231, 1346, 1874 |
| Discovery | CA |
| MC Reproducible | No |
| Existing Issue | #96 (closed) |
| Confirmation Status | **Pending** |

**Bug Description**: `setTermAndVotedFor()` returns a boolean indicating whether persistence succeeded, but all 3 call sites ignore it.

**Code Evidence**:
```java
// line 845: initialization — checked ✓
if (!this.metaStorage.setTermAndVotedFor(1, new PeerId())) { ... }

// line 1231: electSelf — unchecked ✗
this.metaStorage.setTermAndVotedFor(this.currTerm, this.serverId);

// line 1346: stepDown — unchecked ✗
this.metaStorage.setTermAndVotedFor(term, this.votedId);

// line 1874: handleRequestVoteRequest — unchecked ✗
this.metaStorage.setVotedFor(candidateId);
```

**Impact**: After disk write failure, in-memory state is already modified (see Bug #5), and the node continues running. State becomes inconsistent after crash restart.

---

### Bug #4: Meta File Missing Silently Recovers to term=0

| Property | Value |
|----------|-------|
| File | `LocalRaftMetaStorage.java` |
| Lines | 89-104 (load), NodeImpl.java:605-616 (initMetaStorage) |
| Discovery | CA + MC |
| MC Reproducible | **Yes** — ElectionSafety violated (Family 5, 7402 traces) |
| Existing Issue | None |
| Confirmation Status | **Pending** |

**Bug Description**: `load()` returns `true` with default value `term=0` when the meta file does not exist. A node whose file is lost after running at a higher term will restart with term rolled back to 0.

**Code Evidence** — load() (LocalRaftMetaStorage.java:89-104):
```java
private boolean load() {
    final ProtoBufFile pbFile = newPbFile();
    try {
        final StablePBMeta meta = pbFile.load();
        if (meta != null) {
            this.term = meta.getTerm();
            return this.votedFor.parse(meta.getVotedfor());
        }
        return true;           // ← file exists but empty → term=0
    } catch (final FileNotFoundException e) {
        return true;           // ← file does not exist → term=0
    } catch (final IOException e) {
        LOG.error("Fail to load raft meta storage", e);
        return false;
    }
}
```

**Code Evidence** — initMetaStorage() (NodeImpl.java:605-616):
```java
this.currTerm = this.metaStorage.getTerm();       // directly adopted, no cross-validation
this.votedId = this.metaStorage.getVotedFor().copy();
```

**MC Counterexample**: Node votes at term=2 → meta file lost → restarts at term=0 → votes for a different candidate at term=2 → dual leader.

**Note**: File not existing at first startup is normal and indistinguishable from file loss after restart.

---

### Bug #5: In-memory State Updated Before Persistence, No Rollback

| Property | Value |
|----------|-------|
| File | `LocalRaftMetaStorage.java` |
| Lines | 184-189 |
| Discovery | CA |
| MC Reproducible | No |
| Existing Issue | Related to #96 |
| Confirmation Status | **Pending** |

**Bug Description**: `setTermAndVotedFor()` modifies in-memory fields first, then calls `save()`. If save fails, in-memory state is already polluted.

**Code Evidence** (LocalRaftMetaStorage.java:184-189):
```java
public boolean setTermAndVotedFor(final long term, final PeerId peerId) {
    checkState();
    this.votedFor = peerId;   // in-memory modified first
    this.term = term;         // in-memory modified first
    return save();            // disk may fail
}
```

**Impact**: Same root cause as Bug #3. After save failure, memory/disk are inconsistent, with a window before the onError() callback.

---

## B. Response Handler Inconsistency (#6 - #9)

---

### Bug #6: onInstallSnapshotReturned Missing Term Check

| Property | Value |
|----------|-------|
| File | `Replicator.java` |
| Lines | 711-763 |
| Discovery | CA |
| MC Reproducible | **Yes** — CommitIndexBoundInv violated (Family 2, 81 traces) |
| Existing Issue | None |
| Confirmation Status | **Pending** |

**Bug Description**: The only response handler among 4 that does not check for higher-term responses.

**Comparative Evidence**:

| Handler | Lines | Has term check? |
|---------|-------|:-----------:|
| `onHeartbeatReturned` | 1225-1238 | **Yes** |
| `onAppendEntriesReturned` (fail) | 1478-1494 | **Yes** |
| `onTimeoutNowReturned` | 1833-1839 | **Yes** |
| `onInstallSnapshotReturned` | 711-763 | **Missing** |

All three other handlers use the identical check pattern:
```java
if (response.getTerm() > r.options.getTerm()) {
    final NodeImpl node = r.options.getNode();
    r.notifyOnCaughtUp(RaftError.EPERM.getNumber(), true);
    r.destroy();
    node.increaseTermTo(response.getTerm(), new Status(RaftError.EHIGHERTERMRESPONSE, ...));
    return;
}
```

`onInstallSnapshotReturned` has no such code at all.

**Impact**: A stale leader receiving a higher-term InstallSnapshot response does not step down, continuing to accept client requests until the next heartbeat timeout.

---

### Bug #7: onAppendEntriesReturned Success Path Does Not Step Down on Term Mismatch

| Property | Value |
|----------|-------|
| File | `Replicator.java` |
| Lines | 1534-1541 |
| Discovery | CA |
| MC Reproducible | No (dead code) |
| Existing Issue | None |
| Confirmation Status | **Pending** |

**Bug Description**: The success path detects `response.getTerm() != r.options.getTerm()` but only does a Probe reset without calling `increaseTermTo()`.

**Code Evidence** — success path (Replicator.java:1534-1541):
```java
if (response.getTerm() != r.options.getTerm()) {
    r.resetInflights();
    r.setState(State.Probe);
    LOG.error("Fail, response term {} dismatch, expect term {}", ...);
    id.unlock();
    return false;   // ← only unlocks, does not step down
}
```

**Code Evidence** — failure path (Replicator.java:1478-1494):
```java
if (response.getTerm() > r.options.getTerm()) {
    // ... correctly calls increaseTermTo()
}
```

**Key Question**: Is this path reachable?
- When the follower returns `success=true`, `response.getTerm() <= request.getTerm()` (guaranteed by Raft protocol)
- Therefore, `success=true + response.getTerm() > leader.term` **cannot happen in normal Raft**
- This is essentially an **inconsistency in dead code**

---

### Bug #8: handlePreVoteRequest Missing ABA Check

| Property | Value |
|----------|-------|
| File | `NodeImpl.java` |
| Lines | 1760-1768 |
| Discovery | CA |
| MC Reproducible | No |
| Existing Issue | None |
| Confirmation Status | **Pending** |

**Bug Description**: After unlock → `getLastLogId(true)` → relock, currTerm change is not checked.

**Comparative Evidence**:

handlePreVoteRequest (NodeImpl.java:1760-1768) — **no ABA check**:
```java
doUnlock = false;
this.writeLock.unlock();
final LogId lastLogId = this.logManager.getLastLogId(true);
doUnlock = true;
this.writeLock.lock();
// ← no currTerm change check
final LogId requestLastLogId = new LogId(request.getLastLogIndex(), request.getLastLogTerm());
granted = requestLastLogId.compareTo(lastLogId) >= 0;
```

handleRequestVoteRequest (NodeImpl.java:1854-1865) — **has ABA check**:
```java
doUnlock = false;
this.writeLock.unlock();
final LogId lastLogId = this.logManager.getLastLogId(true);
doUnlock = true;
this.writeLock.lock();
// vote need ABA check after unlock&writeLock
if (request.getTerm() != this.currTerm) {
    LOG.warn("Node {} raise term {} when get lastLogId.", getNodeId(), this.currTerm);
    break;
}
```

**Impact**: PreVote is non-persistent and does not affect safety. Worst case: pre-vote granted based on stale context, causing one unnecessary election.

---

### Bug #9: handleRequestVoteRequest Missing Membership Check

| Property | Value |
|----------|-------|
| File | `NodeImpl.java` |
| Lines | 1836-1853 |
| Discovery | CA |
| MC Reproducible | No |
| Existing Issue | None |
| Confirmation Status | **Pending** |

**Bug Description**: `handlePreVoteRequest` checks whether the candidate is in the configuration; `handleRequestVoteRequest` does not.

**Comparative Evidence**:

handlePreVoteRequest (NodeImpl.java:1738-1741) — **has membership check**:
```java
if (!this.conf.contains(candidateId)) {
    LOG.warn("Node {} ignore PreVoteRequest from {} as it is not in conf <{}>.", ...);
    break;
}
```

handleRequestVoteRequest (NodeImpl.java:1836-1853) — **no membership check**, goes directly into term comparison.

**Impact**: A node removed from the cluster sending a RequestVote with a high term causes the leader to step down. Mitigated when PreVote is enabled (PreVote is rejected first), but directly affects availability when PreVote is disabled or bypassed.

**Possible Intentional Omission**: The Raft paper does not require a membership check for RequestVote, and PreVote already provides protection.

---

## C. Storage / Logging (#10 - #12)

---

### Bug #10: truncateSuffix Two deleteRange Calls Non-atomic

| Property | Value |
|----------|-------|
| File | `RocksDBLogStorage.java` |
| Lines | 627-631 |
| Discovery | CA |
| MC Reproducible | No |
| Existing Issue | None |
| Confirmation Status | **Pending** |

**Bug Description**: Two `deleteRange` calls on two RocksDB column families without `WriteBatch` wrapping.

**Code Evidence** (RocksDBLogStorage.java:627-631):
```java
this.db.deleteRange(this.defaultHandle, this.writeOptions,
    getKeyBytes(lastIndexKept + 1), getKeyBytes(lastLogIndex + 1));  // delete data CF
this.db.deleteRange(this.confHandle, this.writeOptions,
    getKeyBytes(lastIndexKept + 1), getKeyBytes(lastLogIndex + 1));  // delete conf CF
```

**Fix**: Wrap both operations in a `WriteBatch`:
```java
try (final WriteBatch batch = new WriteBatch()) {
    batch.deleteRange(this.defaultHandle, getKeyBytes(lastIndexKept + 1), getKeyBytes(lastLogIndex + 1));
    batch.deleteRange(this.confHandle, getKeyBytes(lastIndexKept + 1), getKeyBytes(lastLogIndex + 1));
    this.db.write(this.writeOptions, batch);
}
```

**Impact**: If crash occurs exactly between the two deleteRange calls, data CF is deleted but conf CF is not (or vice versa), causing column family inconsistency. Extremely low probability.

---

### Bug #11: checkConsistency() Format String %d Used for String

| Property | Value |
|----------|-------|
| File | `LogManagerImpl.java` |
| Lines | 1208-1210 |
| Discovery | CA |
| MC Reproducible | No |
| Existing Issue | None |
| Confirmation Status | **Pending** |

**Bug Description**: `%d` (integer placeholder) receives `toString()` (String type), throwing `IllegalFormatConversionException` at runtime.

**Code Evidence** (LogManagerImpl.java:1208-1210):
```java
return new Status(RaftError.EIO,
    "There's a gap between snapshot={%d, %d} and log=[%d, %d] ",
    this.lastSnapshotId.toString(),   // ← String, not int!
    this.lastSnapshotId.getTerm(),
    this.firstLogIndex,
    this.lastLogIndex);
```

**Trigger Condition**: `lastSnapshotId.getIndex() < firstLogIndex - 1` (gap between snapshot and log), called during `NodeImpl.init()` at startup.

**Impact**: The diagnostic code meant to report error details instead throws its own exception, masking the original error. The Status constructor uses `String.format()`, which performs runtime type checking.

**Fix**: `toString()` → `getIndex()`, or `%d` → `%s`.

---

### Bug #12: getEntry() Accesses Storage After Lock Release

| Property | Value |
|----------|-------|
| File | `LogManagerImpl.java` |
| Lines | 771-797 |
| Discovery | CA |
| MC Reproducible | No |
| Existing Issue | None |
| Confirmation Status | **Pending** |

**Bug Description**: `getEntry()` checks the index range under `readLock`, releases the lock, then accesses `logStorage.getEntry(index)`. Concurrent `truncatePrefix` can cause null → reportError → node shutdown.

**Code Evidence** (LogManagerImpl.java:771-797):
```java
public LogEntry getEntry(final long index) {
    this.readLock.lock();
    try {
        if (index > this.lastLogIndex || index < this.firstLogIndex) { return null; }
        final LogEntry entry = getEntryFromMemory(index);
        if (entry != null) { return entry; }
    } finally {
        this.readLock.unlock();     // ← lock released
    }
    // ↓ accessing storage without lock
    final LogEntry entry = this.logStorage.getEntry(index);
    if (entry == null) {
        reportError(RaftError.EIO.getNumber(),   // ← false-positive corruption report
            "Corrupted entry at index=%d, not found", index);
    }
    return entry;
}
```

**Reachability Analysis**:
1. All write operations in LogManager are executed through a Disruptor single-thread consumer
2. `truncatePrefix` is asynchronous, through the Disruptor queue
3. RocksDB has its own lock protection
4. After returning null, there is graceful handling

**Conclusion**: The threading model actually prevents this race condition; it exists in theory but would not trigger in practice.

---

## D. Concurrency / Timers (#13 - #15)

---

### Bug #13: BallotBox.describe() StampedLock Optimistic Read Order Error

| Property | Value |
|----------|-------|
| File | `BallotBox.java` |
| Lines | 273-298 |
| Discovery | CA |
| MC Reproducible | No |
| Existing Issue | None |
| Confirmation Status | **Pending** |

**Bug Description**: The correct StampedLock optimistic read pattern is `tryOptimisticRead → read → validate`; here `validate` is called before `read`.

**Code Evidence** — describe() (BallotBox.java:274-281):
```java
long stamp = this.stampedLock.tryOptimisticRead();    // 1. Acquire stamp
if (this.stampedLock.validate(stamp)) {                // 2. Validate (should be after read!)
    _lastCommittedIndex = this.lastCommittedIndex;     // 3. Read (should be before validate!)
    _pendingIndex = this.pendingIndex;
    _pendingMetaQueueSize = this.pendingMetaQueue.size();
}
```

**Comparison** — getLastCommittedIndex() (BallotBox.java:69-81) (correct implementation):
```java
long stamp = this.stampedLock.tryOptimisticRead();
long optimisticVal = this.lastCommittedIndex;          // read first
if (this.stampedLock.validate(stamp)) {                // validate after
    return optimisticVal;
}
```

**Impact**: `describe()` is only used for diagnostic/monitoring output; does not affect Raft protocol safety. Worst case: inconsistent monitoring values.

---

### Bug #14: startHeartbeatTimer Called After ThreadId Lock Release

| Property | Value |
|----------|-------|
| File | `Replicator.java` |
| Lines | 1249-1251 |
| Discovery | CA |
| MC Reproducible | No |
| Existing Issue | None |
| Confirmation Status | **Pending** |

**Bug Description**: In one path of `onHeartbeatReturned()`, `sendProbeRequest()` releases the ThreadId lock, after which `startHeartbeatTimer()` is called without lock protection.

**Code Evidence** (Replicator.java:1249-1251):
```java
doUnlock = false;
r.sendProbeRequest();          // internally releases ThreadId lock
r.startHeartbeatTimer(startTimeMs);  // ← operates on timer without lock
```

**Comparison**: In the normal path (line 1263), `startHeartbeatTimer()` is called under lock protection (in the finally block with doUnlock=true, lock not yet released).

**Impact**: After lock release, another thread may have already destroyed this Replicator, leading to operations on a destroyed object. In practice, the race window is extremely small due to the relatively long heartbeat interval.

---

### Bug #15: Heartbeat Timer Not Cancelled Before Rescheduling

| Property | Value |
|----------|-------|
| File | `Replicator.java` |
| Lines | 1221, 1251, 1263 |
| Discovery | CA |
| MC Reproducible | No |
| Existing Issue | None |
| Confirmation Status | **Pending** |

**Bug Description**: Multiple code paths call `startHeartbeatTimer()` without first cancelling the previous timer, potentially causing multiple timers to fire simultaneously.

**Code Paths**:
- line 1221: RPC failure path
- line 1251: heartbeat failure + probe path
- line 1263: normal path

**Impact**: The ThreadId lock prevents concurrent execution, so this only wastes resources (extra heartbeats) without causing data inconsistency.

---

## E. Error Handling / Logic (#16 - #19)

---

### Bug #16: passByStatus() Returns true on ERROR State + null done

| Property | Value |
|----------|-------|
| File | `FSMCallerImpl.java` |
| Lines | 773-782 |
| Discovery | CA |
| MC Reproducible | No |
| Existing Issue | None |
| Confirmation Status | **Pending** |

**Bug Description**: When FSMCaller is in an error state and `done == null`, the method returns `true` (allow continuation) instead of `false`.

**Code Evidence** (FSMCallerImpl.java:773-782):
```java
private boolean passByStatus(final Closure done) {
    final Status status = this.error.getStatus();
    if (!status.isOk()) {
        if (done != null) {
            done.run(new Status(RaftError.EINVAL, "FSMCaller is in bad status=`%s`", status));
            return false;       // done != null → correctly returns false
        }
        // done == null → falls through the if block
    }
    return true;                // ← error state + done==null → returns true (BUG)
}
```

**Correct Logic**: Regardless of whether done is null, error state should return false.

**Impact**: In practice, callers typically pass non-null `done`, so this path is rarely triggered.

---

### Bug #17: onCaughtUp ABA Check Uses && Instead of ||

| Property | Value |
|----------|-------|
| File | `NodeImpl.java` |
| Lines | 2245 |
| Discovery | CA |
| MC Reproducible | No |
| Existing Issue | None |
| Confirmation Status | **Pending** |

**Bug Description**: The ABA check condition uses `&&`, but semantically it should be `||`.

**Code Evidence** (NodeImpl.java:2245):
```java
// check current_term and state to avoid ABA problem
if (term != this.currTerm && this.state != State.STATE_LEADER) {
    // ↑ current: term changed AND not leader → return
    // should be: term changed OR not leader → return
    return;
}
```

**Analysis**:
- If `term != currTerm` (term changed) but the node is still leader → current code does not return, continues processing
- But being leader after a term change is impossible in Raft (term change requires stepDown)
- Therefore `&&` and `||` are behaviorally equivalent under Raft invariants

**Conclusion**: Code intent is unclear, but actual behavior is equivalent under Raft invariant guarantees.

---

### Bug #18: onApply User Code Exception Prevents lastAppliedIndex Advancement

| Property | Value |
|----------|-------|
| File | `FSMCallerImpl.java` |
| Lines | 593-607 |
| Discovery | CA |
| MC Reproducible | No |
| Existing Issue | None |
| Confirmation Status | **Pending** |

**Bug Description**: If the user-implemented `fsm.onApply()` throws an uncaught exception, `lastAppliedIndex` is not advanced, and subsequent COMMITTED events re-apply the same batch.

**Code Evidence** (FSMCallerImpl.java:593-607):
```java
private void doApplyTasks(final IteratorImpl iterImpl) {
    final IteratorWrapper iter = new IteratorWrapper(iterImpl);
    try {
        this.fsm.onApply(iter);    // ← user code may throw exception
    } finally {
        // only records metrics, does not advance lastAppliedIndex
    }
    if (iter.hasNext()) {
        LOG.error("Iterator is still valid, did you return before iterator reached the end?");
    }
    iter.next();
}
```

**Impact**: This is a user code quality issue, not a Raft protocol bug. The framework not defending against user exceptions is a design choice.

---

### Bug #19: Dual Leader Detection Term Bump

| Property | Value |
|----------|-------|
| File | `NodeImpl.java` |
| Lines | 1998-2008 |
| Discovery | CA |
| MC Reproducible | No |
| Existing Issue | None |
| Confirmation Status | **Pending** |

**Bug Description**: When a follower detects two leaders in the same term, it proactively calls `stepDown(term + 1)`, which may cause unnecessary term inflation.

**Code Evidence** (NodeImpl.java:1998-2008):
```java
if (!serverId.equals(this.leaderId)) {
    LOG.error("Another peer {} declares that it is the leader at term {} which was occupied by leader {}.",
        serverId, this.currTerm, this.leaderId);
    // Increase the term by 1 and make both leaders step down to minimize the
    // loss of split brain
    stepDown(request.getTerm() + 1, false, new Status(RaftError.ELEADERCONFLICT,
        "More than one leader in the same term."));
    return AppendEntriesResponse.newBuilder()
        .setSuccess(false)
        .setTerm(request.getTerm() + 1)
        .build();
}
```

**Analysis**: This is a defensive extension beyond the Raft paper. In normal Raft, two leaders should not exist in the same term; this code handles an abnormal scenario. The `term+1` is intended to force both leaders to step down.

**Impact**: In pathological scenarios with network partitions/duplicate messages, it may cause unnecessary term inflation, but does not affect safety. This is more of a **design choice** than a bug.

---

## F. Configuration Change (#20)

---

### Bug #20: ConfigSafety Violation

| Property | Value |
|----------|-------|
| File | (TLA+ spec level) |
| Lines | base.tla:1066-1071 (invariant definition) |
| Discovery | MC (pending verification) |
| MC Reproducible | **Pending verification** — marked as MC-5 test case in modeling brief |
| Existing Issue | None |
| Confirmation Status | **Pending** |

**Bug Description**: The configuration change protocol can violate safety under specific sequences — the leader's log simultaneously contains multiple uncommitted configuration change entries.

**TLA+ Invariant Definition** (base.tla:1066-1071):
```tla
ConfigSafety ==
    \A s \in Server :
        state[s] = Leader =>
            LET configIndices == {idx \in (commitIndex[s]+1)..LastLogIndex(s) :
                                    log[s][idx].type = ConfigEntry}
            IN Cardinality(configIndices) <= 1
```

**Code-level Concerns**:
- BallotBox.java:127-132 comment: "not well proved right now" — regarding commit-all-preceding optimization
- ConfigurationManager does not distinguish committed vs uncommitted configurations

**Current Status**: MC-5 test case is marked as "pending verification" in the modeling brief; no TLC output has confirmed a violation yet.

---

## G. Existing Issue Confirmations (#21 - #25)

---

### Bug #21: #1241 — Non-atomic Vote Persistence

| Property | Value |
|----------|-------|
| GitHub Issue | #1241 (open) |
| Our Confirmation | Code Analysis confirmed (Finding N-1), MC Family 1 not triggered but confirmed via architectural analysis |
| Confirmation Status | **Pending** |

**Correspondence**: Same issue as our Bug #1. Issue #1241 describes the two-write problem between `stepDown()` and `setVotedFor()`.

---

### Bug #22: #1242 — Test Case PR for #1241

| Property | Value |
|----------|-------|
| GitHub PR | #1242 (open) |
| Our Confirmation | Analysis confirms test logic is correct |
| Confirmation Status | **Pending** |

**Note**: This is the companion test PR for #1241, not an independent bug.

---

### Bug #23: #96 — RaftMetaStorage Error Return Value Not Handled

| Property | Value |
|----------|-------|
| GitHub Issue | #96 (closed) |
| Our Confirmation | Code Analysis confirmed 3 call sites (Finding N-4) |
| Confirmation Status | **Pending** |

**Correspondence**: Same root cause as our Bug #3 and #5.

---

### Bug #24: #1195 — FSMCallerImpl.done() Causes Duplicate Task Apply

| Property | Value |
|----------|-------|
| GitHub Issue | #1195 (open) |
| Our Confirmation | Noted in Code Analysis (related to Finding F-1) |
| Confirmation Status | **Pending** |

**Correspondence**: Related to but not identical with Bug #18. #1195 focuses on duplicate apply caused by `done()` callback; Bug #18 focuses on duplicate apply caused by user exception.

---

### Bug #25: #1092 — commitIndex < snapshotIndex After Restart

| Property | Value |
|----------|-------|
| GitHub Issue | #1092 (closed) |
| Our Confirmation | Similar state observable in MC Family 5 traces |
| Confirmation Status | **Pending** |

**Correspondence**: Related to Bug #4 (meta file loss → term=0). Meta file loss after restart can cause commitIndex and snapshotIndex inconsistency.

---

## Appendix: Statistical Summary

| Category | Bug Numbers | Count |
|----------|-------------|-------|
| A. Protocol Safety | #1-#5 | 5 |
| B. Response Handler | #6-#9 | 4 |
| C. Storage/Logging | #10-#12 | 3 |
| D. Concurrency/Timers | #13-#15 | 3 |
| E. Error Handling/Logic | #16-#19 | 4 |
| F. Configuration Change | #20 | 1 |
| G. Existing Issues | #21-#25 | 5 |
| **Total** | | **25** |

| Discovery Method | Count |
|-----------------|-------|
| Code Analysis | 19 |
| MC Reproduced | 2 (#4, #6) |
| MC Pending Verification | 1 (#20) |
| Existing Issue Confirmations | 5 |

| Recommended Action | Count |
|-------------------|-------|
| Tier 1 PR | 5 (#6, #8, #9, #10, #11) |
| Tier 2 PR | 3 (#13, #16, others) |
| Issue | 3 (#4, #14, #20) |
| Not recommended | 6 (#7, #12, #15, #17, #18, #19) |
| Existing Issues | 5 (#21-#25) |
