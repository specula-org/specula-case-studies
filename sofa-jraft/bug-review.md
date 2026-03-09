# sofa-jraft Bug Review Document

This document covers all noteworthy bugs found through code analysis and model checking, organized into three tiers by submission priority. Each bug includes complete code evidence, impact analysis, and suggested fixes.

---

## Tier 1: Strongly Recommended for PR

These bugs satisfy "clear code inconsistency + zero-risk fix + immediately reviewable."

---

### T1-1. `onInstallSnapshotReturned` Missing Term Check

| Property | Value |
|----------|-------|
| File | `Replicator.java` |
| Location | `onInstallSnapshotReturned()` (line 711-763) |
| Category | Family 2 — Response Handler Inconsistency |
| MC Verification | `CommitIndexBoundInv` violation (with out-of-order message model) |

**Problem Description**

Three of four response handlers call `increaseTermTo()` to make the leader step down when receiving a higher-term response; `onInstallSnapshotReturned` is the only one missing this check.

**Comparative Evidence**

`onHeartbeatReturned` (line 1225-1238) — **has check**:
```java
if (response.getTerm() > r.options.getTerm()) {
    final NodeImpl node = r.options.getNode();
    r.notifyOnCaughtUp(RaftError.EPERM.getNumber(), true);
    r.destroy();
    node.increaseTermTo(response.getTerm(), new Status(RaftError.EHIGHERTERMRESPONSE,
        "Leader receives higher term heartbeat_response from peer:%s", ...));
    return;
}
```

`onAppendEntriesReturned` failure path (line 1478-1494) — **has check**:
```java
if (response.getTerm() > r.options.getTerm()) {
    final NodeImpl node = r.options.getNode();
    r.notifyOnCaughtUp(RaftError.EPERM.getNumber(), true);
    r.destroy();
    node.increaseTermTo(response.getTerm(), ...);
    return false;
}
```

`onTimeoutNowReturned` (line 1833-1839) — **has check**:
```java
if (response.getTerm() > r.options.getTerm()) {
    final NodeImpl node = r.options.getNode();
    r.notifyOnCaughtUp(RaftError.EPERM.getNumber(), true);
    r.destroy();
    node.increaseTermTo(response.getTerm(), ...);
    return;
}
```

`onInstallSnapshotReturned` (line 711-763) — **missing**:
```java
// Success path directly updates nextIndex with no term check at all
r.nextIndex = request.getMeta().getLastIncludedIndex() + 1;
sb.append(" success=true");
LOG.info(sb.toString());
```

| Handler | Has term check? |
|---------|:-----------:|
| `onHeartbeatReturned` | **Yes** (line 1225) |
| `onAppendEntriesReturned` (fail) | **Yes** (line 1478) |
| `onTimeoutNowReturned` | **Yes** (line 1833) |
| `onInstallSnapshotReturned` | **Missing** |

**Impact**

When a stale leader receives an InstallSnapshot response from a follower that has moved to a higher term, it does not step down. The leader continues running with the old term until the next heartbeat or AppendEntries timeout discovers the stale term. During this window, the leader continues accepting client requests and replicating logs.

**Suggested Fix**

Insert before the success path inside the do-while block of `onInstallSnapshotReturned`:

```java
if (response.getTerm() > r.options.getTerm()) {
    sb.append(" fail, greater term ").append(response.getTerm())
      .append(" expect term ").append(r.options.getTerm());
    LOG.info(sb.toString());
    final NodeImpl node = r.options.getNode();
    r.notifyOnCaughtUp(RaftError.EPERM.getNumber(), true);
    r.destroy();
    node.increaseTermTo(response.getTerm(), new Status(RaftError.EHIGHERTERMRESPONSE,
        "Leader receives higher term install_snapshot_response from peer:%s, group:%s",
        r.options.getPeerId(), r.options.getGroupId()));
    return false;
}
```

**Fix Risk**: Very low. Pure additive change; code pattern is 100% copied from the other three handlers.

---

### T1-2. `handlePreVoteRequest` Missing ABA Check

| Property | Value |
|----------|-------|
| File | `NodeImpl.java` |
| Location | `handlePreVoteRequest()` (line 1760-1768) |
| Category | Concurrency Safety — Inconsistent unlock-relock pattern |

**Problem Description**

Both `handlePreVoteRequest` and `handleRequestVoteRequest` use the unlock → call `getLastLogId(true)` → relock pattern. `handleRequestVoteRequest` checks whether `currTerm` changed during the unlock period (ABA check); `handlePreVoteRequest` omits this check.

**Comparative Evidence**

`handlePreVoteRequest` (line 1760-1768) — **no ABA check**:
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

`handleRequestVoteRequest` (line 1854-1865) — **has ABA check**:
```java
doUnlock = false;
this.writeLock.unlock();

final LogId lastLogId = this.logManager.getLastLogId(true);

doUnlock = true;
this.writeLock.lock();
// vote need ABA check after unlock&writeLock   ← comment explicitly states ABA check is needed
if (request.getTerm() != this.currTerm) {
    LOG.warn("Node {} raise term {} when get lastLogId.", getNodeId(), this.currTerm);
    break;
}
```

**Impact**

If the node's term changes during the unlock period (e.g., receiving a higher-term message), `handlePreVoteRequest` makes its pre-vote decision based on stale context after relocking. This may lead to unnecessary elections or granting pre-votes to candidates that should not receive them.

**Suggested Fix**

Add after relock in `handlePreVoteRequest` (after line 1767):
```java
if (request.getTerm() != this.currTerm) {
    LOG.warn("Node {} raise term {} when get lastLogId in PreVote.", getNodeId(), this.currTerm);
    break;
}
```

**Fix Risk**: Very low. Three lines of code, pattern directly copied from `handleRequestVoteRequest`.

---

### T1-3. `checkConsistency()` Format String Type Error

| Property | Value |
|----------|-------|
| File | `LogManagerImpl.java` |
| Location | `checkConsistency()` (line 1208-1210) |
| Category | Runtime Exception — format string bug |

**Problem Description**

The format string uses `%d` (integer placeholder), but the first argument passed is `toString()` (String type), which throws `IllegalFormatConversionException` at runtime.

**Code Evidence** (line 1208-1210):
```java
return new Status(RaftError.EIO,
    "There's a gap between snapshot={%d, %d} and log=[%d, %d] ",
    this.lastSnapshotId.toString(),   // ← String, not int
    this.lastSnapshotId.getTerm(),
    this.firstLogIndex,
    this.lastLogIndex);
```

**Impact**

When a gap exists between snapshot and log (an abnormal state that needs diagnosis), the code meant to report error details instead throws `IllegalFormatConversionException`, masking the original error message.

**Suggested Fix**

```java
// Option A: fix the format specifier
"There's a gap between snapshot={%s, %d} and log=[%d, %d] ",
// Option B: fix the argument (more precise)
this.lastSnapshotId.getIndex(),  // use getIndex() instead of toString()
```

**Fix Risk**: Zero. A single-character change.

---

### T1-4. `handleRequestVoteRequest` Missing Membership Check

| Property | Value |
|----------|-------|
| File | `NodeImpl.java` |
| Location | `handleRequestVoteRequest()` (line 1836-1853) |
| Category | Missing defensive check |

**Problem Description**

`handlePreVoteRequest` checks whether the candidate is in the current configuration; `handleRequestVoteRequest` does not. A node that has been removed from the cluster can send a high-term `RequestVoteRequest`, forcing the receiver to `stepDown()`.

**Comparative Evidence**

`handlePreVoteRequest` (line 1738-1741) — **has membership check**:
```java
if (!this.conf.contains(candidateId)) {
    LOG.warn("Node {} ignore PreVoteRequest from {} as it is not in conf <{}>.",
        getNodeId(), request.getServerId(), this.conf);
    break;
}
```

`handleRequestVoteRequest` (line 1836-1853) — **no membership check**:
```java
do {
    // Goes directly into term comparison without conf.contains check
    if (request.getTerm() >= this.currTerm) {
        if (request.getTerm() > this.currTerm) {
            stepDown(request.getTerm(), false, ...);  // ← unconditional step down
        }
    } else {
        break;
    }
```

**Impact**

A node removed from the cluster (e.g., an old node replaced during rolling upgrade) sending a RequestVote with a high term causes the current leader to step down, triggering unnecessary election disruption. This is mitigated when PreVote is enabled (PreVote would be rejected first), but if PreVote is disabled or bypassed, it directly affects cluster availability.

**Suggested Fix**

Add at the beginning of the do-while block in `handleRequestVoteRequest` (after line 1837):
```java
if (!this.conf.contains(candidateId)) {
    LOG.warn("Node {} ignore RequestVoteRequest from {} as it is not in conf <{}>.",
        getNodeId(), request.getServerId(), this.conf);
    break;
}
```

**Fix Risk**: Very low. Copied from the identical pattern in `handlePreVoteRequest`.

---

### T1-5. `BallotBox.describe()` StampedLock Optimistic Read Order Error

| Property | Value |
|----------|-------|
| File | `BallotBox.java` |
| Location | `describe()` (line 277-281) |
| Category | Concurrency — StampedLock misuse |

**Problem Description**

The correct pattern for StampedLock optimistic read is: acquire stamp → read variables → validate. Here, validate is called before read.

**Code Evidence** (line 277-281):
```java
long stamp = this.stampedLock.tryOptimisticRead();         // 1. Acquire stamp
if (this.stampedLock.validate(stamp)) {                     // 2. Validate ← should be after read
    _lastCommittedIndex = this.lastCommittedIndex;          // 3. Read ← should be before validate
    _pendingIndex = this.pendingIndex;
    _pendingMetaQueueSize = this.pendingMetaQueue.size();
} else {
    stamp = this.stampedLock.readLock();
    // ... fallback path
}
```

**Correct Implementation**:
```java
long stamp = this.stampedLock.tryOptimisticRead();         // 1. Acquire stamp
_lastCommittedIndex = this.lastCommittedIndex;              // 2. Read
_pendingIndex = this.pendingIndex;
_pendingMetaQueueSize = this.pendingMetaQueue.size();
if (!this.stampedLock.validate(stamp)) {                    // 3. Validate
    stamp = this.stampedLock.readLock();
    try {
        _lastCommittedIndex = this.lastCommittedIndex;
        _pendingIndex = this.pendingIndex;
        _pendingMetaQueueSize = this.pendingMetaQueue.size();
    } finally {
        this.stampedLock.unlockRead(stamp);
    }
}
```

**Impact**

`describe()` is a diagnostic/monitoring method. If a concurrent write occurs between validate and read, the three fields may come from different states, causing inconsistent monitoring output. Does not affect Raft protocol safety.

**Fix Risk**: Very low. Only reorders code without changing any logic. This is a classic anti-pattern from Java concurrency textbooks.

---

## Tier 2: Can Submit PR, Slightly Less Convincing

---

### T2-1. `truncateSuffix` Two `deleteRange` Calls Not in WriteBatch

| Property | Value |
|----------|-------|
| File | `RocksDBLogStorage.java` |
| Location | `truncateSuffix()` (line 627-630) |
| Category | Storage Consistency — Non-atomic operation |

**Problem Description**

`truncateSuffix` executes `deleteRange` on two RocksDB column families (default and conf) separately without wrapping them in a `WriteBatch`. A crash between the two operations leads to column family inconsistency.

**Code Evidence** (line 625-630):
```java
long lastLogIndex = getLastLogIndex();
this.db.deleteRange(this.defaultHandle, this.writeOptions,
    getKeyBytes(lastIndexKept + 1), getKeyBytes(lastLogIndex + 1));  // delete data
this.db.deleteRange(this.confHandle, this.writeOptions,
    getKeyBytes(lastIndexKept + 1), getKeyBytes(lastLogIndex + 1));  // delete conf
```

**Impact**

If the first `deleteRange` succeeds but the node crashes before the second, entries are deleted from the data column family but corresponding configuration entries in the conf column family remain. This only triggers when the crash hits at precisely the right moment.

**Suggested Fix**

```java
try (final WriteBatch batch = new WriteBatch()) {
    batch.deleteRange(this.defaultHandle,
        getKeyBytes(lastIndexKept + 1), getKeyBytes(lastLogIndex + 1));
    batch.deleteRange(this.confHandle,
        getKeyBytes(lastIndexKept + 1), getKeyBytes(lastLogIndex + 1));
    this.db.write(this.writeOptions, batch);
}
```

**Fix Risk**: Low. `WriteBatch` is the standard atomic operation primitive in RocksDB. No public interface changes.

**Weakness**: Maintainers may argue that the probability of a crash occurring exactly between the two `deleteRange` calls is extremely low.

---

### T2-2. `passByStatus()` Logic Inversion

| Property | Value |
|----------|-------|
| File | `FSMCallerImpl.java` |
| Location | `passByStatus()` (line 773-782) |
| Category | Error Handling — Logic error |

**Problem Description**

When FSMCaller is in an error state (`!status.isOk()`) and `done == null`, the method returns `true` (continue execution) instead of `false` (block execution).

**Code Evidence** (line 773-782):
```java
private boolean passByStatus(final Closure done) {
    final Status status = this.error.getStatus();
    if (!status.isOk()) {
        if (done != null) {
            done.run(new Status(RaftError.EINVAL, "FSMCaller is in bad status=`%s`", status));
            return false;       // done != null → correctly returns false
        }
        // done == null → falls through the if block to return true below ← BUG
    }
    return true;                // ← error state + done==null should not return true
}
```

**Suggested Fix**

```java
private boolean passByStatus(final Closure done) {
    final Status status = this.error.getStatus();
    if (!status.isOk()) {
        if (done != null) {
            done.run(new Status(RaftError.EINVAL, "FSMCaller is in bad status=`%s`", status));
        }
        return false;  // regardless of whether done is null, error state should return false
    }
    return true;
}
```

**Impact**

In practice, callers typically pass non-null `done`, so this path is rarely triggered. However, the logic is clearly wrong: an FSMCaller in error state should not allow any operation to continue.

**Fix Risk**: Very low. Only moves the position of `return false`.

**Weakness**: Maintainers may argue "all actual callers pass done, so there's no real impact."

---

## Tier 3: Recommend Filing as Issue for Discussion

---

### T3-1. Meta File Missing Silently Recovers to term=0

| Property | Value |
|----------|-------|
| File | `LocalRaftMetaStorage.java` |
| Location | `load()` (line 89-104) |
| Category | Family 5 — Crash Recovery Safety |
| MC Verification | `ElectionSafety` violation (TLC found in 7402 traces) |

**Problem Description**

`load()` returns `true` with default values `term=0, votedFor=null` when the meta file does not exist. `NodeImpl` does not cross-validate meta and log during startup. If a node that previously ran at term=5 loses its meta file, it restarts at term=0, allowing it to vote again in a term where it already voted.

**Code Evidence** — `load()` (line 89-104):
```java
private boolean load() {
    final ProtoBufFile pbFile = newPbFile();
    try {
        final StablePBMeta meta = pbFile.load();
        if (meta != null) {
            this.term = meta.getTerm();
            return this.votedFor.parse(meta.getVotedfor());
        }
        return true;                          // ← file exists but content is null → default term=0
    } catch (final FileNotFoundException e) {
        return true;                          // ← file does not exist → default term=0
    } catch (final IOException e) {
        LOG.error("Fail to load raft meta storage", e);
        return false;                         // ← file corrupted → refuse to start
    }
}
```

**Code Evidence** — `initMetaStorage()` (line 605-616):
```java
private boolean initMetaStorage() {
    this.metaStorage = this.serviceFactory.createRaftMetaStorage(...);
    if (!this.metaStorage.init(opts)) {
        return false;
    }
    this.currTerm = this.metaStorage.getTerm();       // directly adopted, no cross-validation
    this.votedId = this.metaStorage.getVotedFor().copy();
    return true;
}
```

**TLC Counterexample Summary**

39-step trace: node s1 votes at term=2 for s2 → CorruptedCrash resets s1's term to 0 → s1 restarts and votes for s3 (term=2) → both s2 and s3 achieve quorum → two leaders exist simultaneously at term=2.

**Defensive Layers in the Real System**

1. **PreVote mechanism** (present in code but not modeled in TLA+): a node with term=0 would have its PreVote rejected by the cluster
2. **Heartbeat recovery**: the leader will pull the term=0 node to the current term via heartbeat within ~500ms
3. **Atomic file writes**: `ProtoBufFile.save()` uses write-to-tmp + rename pattern, making file loss extremely unlikely

**Why File as Issue Rather Than PR**

The fix requires design decisions:
- Option A: Add `lastLogTerm > metaTerm` validation in `initMetaStorage()` → requires ensuring log manager is already initialized
- Option B: `load()` returns `false` when the file does not exist → would affect first startup of brand new nodes
- Option C: Add meta file checksum → involves serialization format changes

**Suggested Issue Content**

Title: `Meta file missing is silently treated as term=0 without cross-validation against log`

Key points:
- `load()` returns `true` on `FileNotFoundException`, defaulting to term=0
- `initMetaStorage()` does not validate meta term against the term of the last log entry
- Suggest adding at startup: if log is non-empty but meta term=0, refuse to start or infer minimum safe term from log

---

### T3-2. `getEntry()` Accesses Storage After Lock Release, Null Misreported as Corruption

| Property | Value |
|----------|-------|
| File | `LogManagerImpl.java` |
| Location | `getEntry()` (line 771-797) |
| Category | Concurrency Safety + Error Handling |

**Problem Description**

`getEntry()` checks the index range and in-memory cache under `readLock`, then releases the lock to access `logStorage.getEntry(index)`. Between lock release and storage read, a concurrent `truncatePrefix` may delete that entry. The resulting null is reported by `reportError` as a fatal I/O error, triggering node shutdown.

**Code Evidence** (line 771-797):
```java
public LogEntry getEntry(final long index) {
    this.readLock.lock();
    try {
        if (index > this.lastLogIndex || index < this.firstLogIndex) {
            return null;                                          // range check (under lock)
        }
        final LogEntry entry = getEntryFromMemory(index);
        if (entry != null) {
            return entry;                                         // memory hit (under lock)
        }
    } finally {
        this.readLock.unlock();                                   // ← lock released
    }
    // ↓ accessing storage without lock: truncatePrefix may have deleted this entry
    final LogEntry entry = this.logStorage.getEntry(index);
    if (entry == null) {
        reportError(RaftError.EIO.getNumber(),                    // ← false-positive corruption report
            "Corrupted entry at index=%d, not found", index);
    }
    return entry;
}
```

**Impact**

Under high concurrency (snapshot + log replication happening simultaneously), a concurrent `truncatePrefix` could cause `getEntry()` to return null → `reportError` → node shutdown. This is a false-positive fatal error that may cause unnecessary node restarts.

**Why File as Issue Rather Than PR**

The fix involves trade-offs:
- Option A: Extend lock scope (include storage read) → may affect performance
- Option B: Re-acquire lock on null to re-check index range, distinguishing "real corruption" from "race condition deletion" → increases code complexity
- Option C: Downgrade `reportError` to `LOG.warn` → may mask real corruption

**Suggested Issue Content**

Title: `getEntry() may false-positive report corruption due to race with truncatePrefix`

Key points:
- Range check is under readLock, storage read is outside the lock
- Concurrent truncatePrefix can cause null → reportError → node shutdown
- Suggest adding a secondary range check on null to distinguish between race conditions and real corruption

---

### T3-3. `onAppendEntriesReturned` Success Path Does Not Step Down on Term Mismatch

| Property | Value |
|----------|-------|
| File | `Replicator.java` |
| Location | `onAppendEntriesReturned()` (line 1534-1541) |
| Category | Family 2 — Response Handler Inconsistency |

**Problem Description**

The success path detects `response.getTerm() != r.options.getTerm()` but only does a Probe reset and unlock, without calling `increaseTermTo()` to step down. The failure path (line 1478-1494) handles this correctly.

**Code Evidence** — success path (line 1534-1541):
```java
// success
if (response.getTerm() != r.options.getTerm()) {
    r.resetInflights();
    r.setState(State.Probe);
    LOG.error("Fail, response term {} dismatch, expect term {}", response.getTerm(),
            r.options.getTerm());
    id.unlock();
    return false;   // ← only unlocks, does not step down
}
```

**Code Evidence** — failure path (line 1478-1494):
```java
if (response.getTerm() > r.options.getTerm()) {
    final NodeImpl node = r.options.getNode();
    r.notifyOnCaughtUp(RaftError.EPERM.getNumber(), true);
    r.destroy();
    node.increaseTermTo(response.getTerm(), ...);   // ← correctly steps down
    return false;
}
```

**Why File as Issue Rather Than PR**

This code path is **unreachable in practice**:
- When the follower processes an `AppendEntriesRequest`, if `request.getTerm() < currentTerm`, it returns `success=false`
- If `request.getTerm() >= currentTerm`, the follower first steps down to the request's term, then processes it
- Therefore, a `success=true` response will never have `response.getTerm()` higher than the leader's term

Maintainers will likely respond: "This is dead code, no fix needed." It's best to file as an issue to let maintainers confirm whether this path is indeed unreachable.

**Suggested Issue Content**

Title: `onAppendEntriesReturned success path does not call increaseTermTo on term mismatch`

Key points:
- Failure path correctly calls `increaseTermTo()`, success path only does a Probe reset
- Question: Is this path reachable? If the follower always returns `<= leader's term` when `success=true`, then this path is dead code
- Even so, suggest adding a defensive `increaseTermTo()` call for consistency

---

### T3-4. `startHeartbeatTimer()` Called After ThreadId Lock Release

| Property | Value |
|----------|-------|
| File | `Replicator.java` |
| Location | `onHeartbeatReturned()` (line ~1251) |
| Category | Concurrency Safety — Data race |

**Problem Description**

In `onHeartbeatReturned()`, `sendProbeRequest()` releases the ThreadId lock, after which `startHeartbeatTimer()` is called without lock protection. After the lock is released, another thread may have already destroyed this Replicator.

**Code Path**:
```
r.sendProbeRequest()     // internally unlocks ThreadId
r.startHeartbeatTimer()  // operates on heartbeatTimer field without lock
```

**Why File as Issue Rather Than PR**

The fix requires adjusting the lock acquisition scope. `sendProbeRequest()` releases the lock for good reason (to avoid network operations under lock). Moving `startHeartbeatTimer()` before `sendProbeRequest()` requires ensuring no deadlock occurs and that the timer start does not depend on probe results. This needs maintainer evaluation.

---

## Appendix: Complete Bug Classification Summary

| Bug | Tier | Action | Core Evidence Type | Fix LOC |
|-----|------|--------|-------------------|---------|
| T1-1: InstallSnapshot missing term check | 1 | **PR** | Side-by-side comparison of 4 handlers | ~10 |
| T1-2: PreVote missing ABA check | 1 | **PR** | Side-by-side comparison of 2 methods | ~3 |
| T1-3: checkConsistency %d→%s | 1 | **PR** | Format specifier type mismatch | 1 |
| T1-4: RequestVote missing membership check | 1 | **PR** | Side-by-side comparison of 2 methods | ~5 |
| T1-5: StampedLock optimistic read order | 1 | **PR** | Standard anti-pattern | ~5 |
| T2-1: truncateSuffix non-atomic delete | 2 | **PR** | Missing RocksDB WriteBatch | ~5 |
| T2-2: passByStatus logic inversion | 2 | **PR** | Control flow analysis | 1 |
| T3-1: Meta term=0 without cross-validation | 3 | **Issue** | TLC counterexample + code path | Design discussion |
| T3-2: getEntry race false-positive corruption | 3 | **Issue** | Lock analysis + race scenario | Design discussion |
| T3-3: AppendEntries success path no step down | 3 | **Issue** | Unreachable path discussion | Design discussion |
| T3-4: Heartbeat timer called without lock | 3 | **Issue** | Concurrency analysis | Design discussion |
