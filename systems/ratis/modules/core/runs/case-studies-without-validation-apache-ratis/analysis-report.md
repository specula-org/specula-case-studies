# Apache Ratis Code Analysis Report

## 1. Investigation Scope & Method

### Code Analyzed
- **Repository**: `https://github.com/apache/ratis.git` (Java)
- **Module**: `ratis-server/src/main/java/` — 73 Java files, ~19,130 lines of Raft core logic (excluding tests)
- **Key Files Analyzed Line-by-Line**:
  - `RaftServerImpl.java` (1942 lines) — Main server orchestrator
  - `LeaderStateImpl.java` (1331 lines) — Leader logic, replication, commitment
  - `ServerState.java` (524 lines) — Persistent state (term, votedFor)
  - `LeaderElection.java` (625 lines) — Pre-vote and election protocol
  - `SegmentedRaftLog.java` (621 lines) — Production log implementation
  - `SegmentedRaftLogWorker.java` (753 lines) — Background I/O worker
  - `SegmentedRaftLogCache.java` (764 lines) — In-memory log cache
  - `LogAppenderBase.java` (287 lines) — Log replication base
  - `LogAppenderDefault.java` (215 lines) — Default replication implementation
  - `SnapshotInstallationHandler.java` (403 lines) — Snapshot chunk handling
  - `SnapshotManager.java` (208 lines) — Snapshot persistence
  - `ConfigurationManager.java` (118 lines) — Membership configuration
  - `FollowerState.java` (184 lines) — Follower timeout tracking
  - `RoleInfo.java` (205 lines) — Role transition management
  - `RaftLogBase.java` (471 lines) — Abstract log base class
  - `LogSegment.java` (507 lines) — Segment file management

### Methods Used
1. **Static code analysis**: Line-by-line reading of all 16 core files listed above
2. **Git history mining**: Searched for commits with keywords: fix, bug, race, deadlock, safety, correctness, data loss, stale, inconsistent
3. **JIRA issue verification**: Searched Apache JIRA (issues.apache.org/jira/browse/RATIS) for bugs by category — 44 open bugs, 50 critical/blocker bugs, 14 race conditions, 8 data loss issues, 9 split-brain issues found
4. **GitHub PR review**: Examined 28 open PRs, focused on correctness-relevant ones
5. **Bug-fix commit deep-dive**: Examined full diffs of 12 critical bug-fix commits

---

## 2. Codebase Overview

### Architecture Summary
Apache Ratis is a Java implementation of the Raft consensus protocol, designed as a library for building replicated state machines. It supports multiple Raft groups per server via `RaftServerProxy` managing multiple `RaftServerImpl` divisions.

**Core Components:**
- `RaftServerImpl` — Main orchestrator implementing both client and server protocols
- `ServerState` — Manages persistent state (term, votedFor, log, snapshots)
- `LeaderStateImpl` — Leader-specific operations with an `EventProcessor` thread
- `LeaderElection` — Two-phase election (Pre-Vote + Election) via `ExecutorService`
- `SegmentedRaftLog` — Disk-backed log with segments, cache, and async worker
- `StateMachineUpdater` — Applies committed entries to the state machine
- `SnapshotInstallationHandler` — Handles incoming snapshot installations
- `ConfigurationManager` — Tracks membership configuration history

### Concurrency Model
Apache Ratis uses a multi-threaded architecture:

| Thread | Purpose |
|--------|---------|
| RPC handler threads | Accept incoming requests (via gRPC/Netty) |
| `EventProcessor` (single daemon) | Processes commit updates, step-downs, staging checks in `LeaderStateImpl` |
| `LogAppender` daemon threads | Per-follower replication threads |
| `SegmentedRaftLogWorker` | Background I/O for log operations |
| `StateMachineUpdater` | Sequential entry application |
| `FollowerState` daemon | Election timeout monitoring |
| `LeaderElection` thread | Vote collection via `ExecutorCompletionService` |

**Synchronization Primitives:**
- `synchronized(server)` — Coarse server-level lock for critical sections
- `ReentrantReadWriteLock` (fair) — Log read/write operations
- `AtomicLong`/`AtomicReference` — Term, leader ID, follower indices
- `BlockingQueue` — EventProcessor queue (capacity = 3, one per event type)
- `CompletableFuture` — Async RPC and cross-thread coordination
- `volatile` — `votedFor`, `lastRpcTime`, `openSegment`

### Key Implementation Deviations from Raft Paper
1. **Pre-Vote protocol**: Implements the Ongaro dissertation Pre-Vote extension to prevent disruptions from partitioned servers
2. **Leader lease**: Partial implementation via `LeaderLease.java` (PR #383 still open)
3. **Priority-based elections**: Higher-priority peers can abort elections by a single rejection
4. **Follower gap throttling**: Can stall commit index when any follower falls behind by more than a configurable threshold
5. **Async log persistence**: Supports `unsafeFlush` and `asyncFlush` modes that trade durability for performance

---

## 3. Code Analysis Findings

### Finding 1: Snapshot State Updated Before Chunk Validation (Developer-Acknowledged)
- **Location**: `SnapshotInstallationHandler.java:217-224`
- **Description**: The TODO at line 217 explicitly states: "We should only update State with installed snapshot once the request is done." The code calls `state.installSnapshot(request)` before validating chunk ordering at lines 220-224:
  ```java
  //TODO: We should only update State with installed snapshot once the request is done.
  state.installSnapshot(request);
  final int expectedChunkIndex = nextChunkIndex.getAndIncrement();
  if (expectedChunkIndex != snapshotChunkRequest.getRequestIndex()) {
      throw new IOException("Unexpected request chunk index...");
  }
  ```
  An out-of-order chunk writes data to disk before the exception is thrown, potentially corrupting the snapshot.
- **Verification status**: Developer-acknowledged (explicit TODO)
- **Severity**: High

### Finding 2: Non-Atomic Snapshot Directory Rename (Crash Window)
- **Location**: `SnapshotManager.java:172-207`
- **Description**: The `rename` method performs a three-step non-atomic sequence: (1) move existing `stateMachineDir` to a temp name, (2) move new snapshot dir to `stateMachineDir`, (3) delete old dir. A crash between steps 1 and 2 leaves no snapshot directory. Worse, if step 1 fails, the fallback is `FileUtils.deleteFully(stateMachineDir)` — if this succeeds but step 2 then fails, all snapshot data is lost.
  ```java
  // Step 1: Move existing dir
  moved = FileUtils.move(stateMachineDir, TMP + StringUtils.currentDateTime());
  // Step 2: Move new dir in place — crash between 1 and 2 = missing snapshot
  FileUtils.move(tmpDir, stateMachineDir);
  ```
- **Verification status**: Confirmed code inconsistency
- **Severity**: High

### Finding 3: Log Truncation Cache-Disk Ordering Gap
- **Location**: `SegmentedRaftLog.java:369-379`
- **Description**: The cache is truncated synchronously but disk truncation is done asynchronously via a worker task:
  ```java
  SegmentedRaftLogCache.TruncationSegments ts = cache.truncate(index);
  if (ts != null) {
      Task task = fileLogWorker.truncate(ts, index);
      return task.getFuture();
  }
  ```
  If the process crashes between cache truncation and disk truncation, recovery reloads entries from disk that were logically truncated, potentially re-introducing entries that conflicted with the leader's log.
- **Verification status**: Confirmed code inconsistency. Raft's retry semantics mean the leader will re-send truncation, but there is a window of inconsistency.
- **Severity**: High

### Finding 4: `updateIncreasingly` Sets-Then-Checks (Latent Atomicity Bug)
- **Location**: `RaftLogIndex.java:66-76`
- **Description**: The method uses `getAndSet(newIndex)` unconditionally, then checks the precondition. If the assertion fails, the index has already been modified:
  ```java
  public boolean updateIncreasingly(long newIndex, Consumer<Object> log) {
      final long old = index.getAndSet(newIndex);  // SET first
      Preconditions.assertTrue(old <= newIndex, ...); // CHECK after
  }
  ```
  Despite being documented as "thread safe" (line 31), two concurrent calls could corrupt the index. In practice, callers hold the log write lock, making this safe — but the method's contract is misleading.
- **Verification status**: Confirmed latent bug, mitigated by external locking
- **Severity**: High (latent)

### Finding 5: Async Flush Race on `lastWrittenIndex`
- **Location**: `SegmentedRaftLogWorker.java:402-410`
- **Description**: In `asyncFlushOutStream`, the callback captures `lastWrittenIndex` by reading the field at callback execution time, not at submission time. Between flush initiation and callback execution, the worker thread may advance `lastWrittenIndex` further, causing the callback to update the flush index beyond what was actually force-synced:
  ```java
  out.asyncFlush(flushExecutor)
      .thenCombine(stateMachineFlush, (async, sm) -> async)
      .whenComplete((v, e) -> {
          updateFlushedIndexIncreasingly(lastWrittenIndex); // reads field at callback time
      });
  ```
- **Verification status**: Confirmed race condition
- **Severity**: High (when async flush is enabled)

### Finding 6: `syncWithSnapshot` Data Race and Dangling Futures
- **Location**: `SegmentedRaftLogWorker.java:261-267`
- **Description**: `syncWithSnapshot()` clears the worker queue, overwrites `lastWrittenIndex` and `flushIndex`, and resets `pendingFlushNum` — all without synchronization with the worker thread:
  ```java
  void syncWithSnapshot(long lastSnapshotIndex) {
      queue.clear();
      lastWrittenIndex = lastSnapshotIndex;  // plain field, not volatile
      flushIndex.setUnconditionally(lastSnapshotIndex, infoIndexChange);
      pendingFlushNum = 0;  // plain field, not volatile
  }
  ```
  In-flight tasks whose futures are never completed will hang forever. `lastWrittenIndex` and `pendingFlushNum` are plain (non-volatile) fields subject to stale reads.
- **Verification status**: Confirmed race condition
- **Severity**: High

### Finding 7: Worker Thread Permanent Failure After Single I/O Error
- **Location**: `SegmentedRaftLogWorker.java:302-357`
- **Description**: Once a single I/O error occurs, `logIOException` is set and every subsequent task is failed. The worker never recovers — a transient disk error permanently kills the log worker.
- **Verification status**: Confirmed design issue (deliberate fail-fast, but no recovery)
- **Severity**: High (availability)

### Finding 8: Read Lock Can Be Disabled, Voiding Thread Safety
- **Location**: `SegmentedRaftLog.java:224-227`
- **Description**: When `readLockEnabled` is false, `readLock()` returns null, removing all synchronization for read operations:
  ```java
  public AutoCloseableLock readLock() {
      return readLockEnabled ? super.readLock() : null;
  }
  ```
  This enables concurrent truncation/append to produce torn reads. The `getSegment()` method in `SegmentedRaftLogCache` does not hold any lock and could see a segment in an inconsistent intermediate state.
- **Verification status**: Confirmed design decision with safety implications
- **Severity**: High (when disabled)

### Finding 9: Log Appending and Snapshot Installation Race (Developer-Acknowledged)
- **Location**: `SnapshotInstallationHandler.java:306-310`
- **Description**: Comments explicitly acknowledge the race:
  ```java
  // There is another appendLog thread appending raft entries, which returns inconsistency
  // entries with nextIndex and commitIndex to the leader when install snapshot in progress.
  ```
  While a snapshot is being installed, the follower still responds to AppendEntries RPCs with INCONSISTENCY, causing the leader to decrement the follower's `nextIndex`. When the snapshot completes, the leader's tracked state may be inconsistent with the follower's actual state.
- **Verification status**: Developer-acknowledged
- **Severity**: Medium

### Finding 10: Non-Atomic `getPrevious()` and Buffer Fill in LogAppender
- **Location**: `LogAppenderBase.java:226, 237`
- **Description**: `follower.getNextIndex()` is called twice without synchronization — once for `getPrevious()` and once for the buffer-fill loop. If `nextIndex` changes between calls (from a concurrent INCONSISTENCY response), `previous` would be stale relative to the entries actually buffered, violating `prevLogIndex == entries[0].index - 1`.
- **Verification status**: Confirmed code inconsistency
- **Severity**: Medium

### Finding 11: TOCTOU Race in Follower Election Timeout
- **Location**: `FollowerState.java:136-167`
- **Description**: `updateLastRpcTime` is NOT synchronized on the server object, but the timeout check in `roleChangeChecking` IS synchronized. A heartbeat can arrive between the timeout check and `changeToCandidate()`:
  ```java
  void updateLastRpcTime(UpdateType type) {
      lastRpcTime = Timestamp.currentTime(); // No server lock needed
  }
  ```
  The election will likely fail (other followers have fresh heartbeats) and the server reverts to follower — harmless but wasteful.
- **Verification status**: Confirmed race condition (benign)
- **Severity**: Low

### Finding 12: STEP_DOWN Event Deduplication Drops Newer Term
- **Location**: `LeaderStateImpl.java:126-134, 154, 706`
- **Description**: Events compare equal based solely on type. If a STEP_DOWN event for term 5 is queued and then term 7 arrives, the newer event is silently dropped. The processor steps down with term 5 instead.
- **Verification status**: Confirmed code inconsistency (not a safety violation since any higher term suffices)
- **Severity**: Low

### Finding 13: Slow Follower Throttling Can Stall Entire Cluster
- **Location**: `LeaderStateImpl.java:893-901`
- **Description**: When `followerMaxGapThreshold` is configured and any single follower falls behind by more than the threshold, the commit index is suppressed to the slowest follower's match index, stalling all client requests:
  ```java
  if (gapThreshold != -1 && (majority - min) > gapThreshold) {
      majority = min;  // suppress to slowest follower
  }
  ```
- **Verification status**: Confirmed design decision
- **Severity**: Medium (availability)

### Finding 14: `reloadStateMachine` While Holding Server Lock
- **Location**: `SnapshotInstallationHandler.java:227-229`
- **Description**: `state.reloadStateMachine(lastIncluded)` is called within `synchronized(server)`. Reloading the state machine is potentially long-running, blocking all server operations.
- **Verification status**: Confirmed robustness issue
- **Severity**: Medium (availability)

### Finding 15: Shared Non-Thread-Safe `MessageDigest`
- **Location**: `SnapshotManager.java:65`
- **Description**: `MessageDigest digester` is an instance field with no synchronization. Concurrent snapshot installations would corrupt digest state. Protected by external server lock, but the class itself doesn't document this requirement.
- **Verification status**: Confirmed robustness issue
- **Severity**: Medium

### Finding 16: Non-Volatile `lastWrittenIndex` and `pendingFlushNum`
- **Location**: `SegmentedRaftLogWorker.java:164, 166`
- **Description**: Both fields are plain (non-volatile) longs accessed from multiple threads (worker thread, sync callback, `syncWithSnapshot`). Cross-thread reads may see stale values.
- **Verification status**: Confirmed code inconsistency
- **Severity**: Medium

### Finding 17: `updateCommitIndex` Uses `tryWriteLock` with Silent Failure
- **Location**: `RaftLogBase.java:123, 137-141`
- **Description**: If the write lock cannot be acquired within 1 second, `updateCommitIndex` silently returns false. Under sustained lock contention, commit index updates stall indefinitely.
- **Verification status**: Confirmed (introduced by RATIS-2234 fix). Trade-off between deadlock prevention and commit stall.
- **Severity**: Medium

### Finding 18: Pending Requests Window During Leader Stop
- **Location**: `LeaderStateImpl.java:434-461`
- **Description**: Between `isStopped.compareAndSet(false, true)` and `sendNotLeaderResponses`, new requests could be added to `pendingRequests` via `addPendingRequest` (which doesn't check `isStopped`). These requests would never be completed.
- **Verification status**: Confirmed narrow race window, mitigated by client timeouts
- **Severity**: Low

### Finding 19: Configuration Manager Never Cleans Up Old Configurations
- **Location**: `ConfigurationManager.java:117`
- **Description**: TODO: "remove Configuration entries after they are committed." The `NavigableMap<Long, RaftConfigurationImpl>` grows unboundedly over time.
- **Verification status**: Developer-acknowledged (TODO)
- **Severity**: Low (memory leak)

### Finding 20: Snapshot Request Ordering Not Validated in SnapshotManager
- **Location**: `SnapshotManager.java:114-115`
- **Description**: TODO: "Make sure that subsequent requests for the same installSnapshot are coming in order, and are not lost when whole request cycle is done." The `installSnapshot()` method does not validate `requestId` or `requestIndex`.
- **Verification status**: Developer-acknowledged (TODO)
- **Severity**: Medium

### Correctly Implemented (Verified Not-Bugs)

1. **Commit safety (Section 5.4.2)**: The leader correctly only commits entries from its own term (`RaftLogBase.java:131-135`). Verified correct.
2. **Joint consensus majority**: Correctly uses min-of-two-majorities for transitional configs (`LeaderStateImpl.java:882-887`). Verified correct.
3. **Startup no-op entry**: New leaders append a configuration entry at their term to enable commitment of previous-term entries (`LeaderStateImpl.java:293-317`). Verified correct.
4. **Pre-Vote implementation**: Correctly uses current term without incrementing (`ServerState.java:236-237`). Verified correct.
5. **Vote uniqueness**: Cannot vote for two different candidates in the same term (`VoteContext.java:78-84`). Verified correct.
6. **Metadata persistence atomicity**: Term and votedFor are written together atomically via `AtomicFileOutputStream` (`RaftStorageMetadataFileImpl`). Verified correct.
7. **Sleep deviation detection**: GC pause detection prevents false elections (`FollowerState.java:148-154`). Verified correct.

---

## 4. GitHub Issues & PRs Verification

### Issue Tracking Note
Apache Ratis uses **Apache JIRA** (issues.apache.org/jira/browse/RATIS), not GitHub Issues. GitHub Issues are disabled on the repository.

### 4.1 Confirmed Bugs (with verification from git history)

| JIRA | Summary | Status | Component | Root Cause |
|------|---------|--------|-----------|------------|
| RATIS-2345 | Leader stepDown deadlock | Fixed (2025-10) | LeaderStateImpl | `changeToFollowerAndPersistMetadata().join()` blocked indefinitely |
| RATIS-2234 | Lock race: heartbeat vs append log | Fixed (2025-01) | RaftLogBase | `updateCommitIndex()` acquired write lock unconditionally, blocking appends |
| RATIS-2044 | ReadIndex loss from data race | Fixed (2024-03) | ReadIndexHeartbeats | Race between `add()` and `failAll()` in `AppendEntriesListeners` |
| RATIS-1995 | Data loss on re-format | Fixed (2025-05) | LeaderElection | Empty-log servers could vote, allowing data-less leader election |
| RATIS-1927 | Data race in ReadRequests | Fixed (2023-11) | ReadRequests | Non-atomic compound operations on `ConcurrentSkipListMap` |
| RATIS-1751 | Race: LeaderStateImpl vs ServerState | Fixed (2022-12) | LeaderStateImpl | `voterLists` cached from senders became inconsistent with configuration |
| RATIS-2162 | Deadlock closing leaderState | Fixed (2024-09) | LeaderStateImpl/RoleInfo | LogAppender tried to acquire server lock while shutdown held it |
| RATIS-981 | Stale leader in split-brain | Fixed (2020-07) | LeaderStateImpl | No mechanism to detect loss of majority heartbeat contact |
| RATIS-1256 | Leader updateCommit used old index | Fixed (2020-12) | LeaderStateImpl | `updateCommit()` iterated entries up to OLD committed index |
| RATIS-2350 | readAfterWrite bugs | Fixed (2025-11) | ReadRequests/LeaderStateImpl | Multiple bugs in read index tracking and write cache |
| RATIS-2183 | Stale snapshot request | Fixed (2024-11) | SnapshotInstallationHandler | No way to detect outdated snapshot chunks |
| RATIS-1691 | Deadlock in server shutdown | Fixed (2022-08) | RaftServerProxy | Executor shutdown ordering circular dependency |

### 4.2 Open Bugs of Interest (from JIRA)

| JIRA | Summary | Priority | Category |
|------|---------|----------|----------|
| RATIS-2300 | New Leader Repeatedly Times Out Sending RPCs to Old Leader | Open | Leader transition |
| RATIS-2306 | Initial raft group not recovered if server stopped immediately after start | Open | Recovery |
| RATIS-2175 | RaftLogTruncateTests failed due to concurrency | Open | Log truncation race |
| RATIS-2309 | OM down due to CompletionException | Open | Error handling |
| RATIS-535 | Race condition in creating log | Open | Log creation |
| RATIS-2082 | RaftPeers equal should also check address | Open | Peer identity |
| RATIS-1368 | Three NPEs in Raft Server Impl | Open | Null safety |
| RATIS-1305 | Leader stuck in infinite install snapshot cycle | Critical | Snapshot |
| RATIS-1241 | Leader unable to append to recovering follower when logs purged | Critical | Log purge |
| RATIS-804 | Race condition between cache evict and load in LogSegment | Critical | Cache |
| RATIS-797 | Ratis segment file corruption after server restart | Critical | Persistence |
| RATIS-2172 | RaftServer may lose FollowerState | Critical | State management |

### 4.3 Design Defects / Limitations

| JIRA/PR | Summary | Status |
|---------|---------|--------|
| RATIS-1273 / PR #383 | Fix split brain by leader lease | Open since 2020 — discussed and approved but never merged |
| RATIS-998 / PR #144 | shouldWithholdVotes() for higher term | Open since 2020 — correctness debate in PR comments |
| RATIS-1879 | Handle RaftLog corruption when unsafe flush enabled | Open — acknowledged unsafe flush risk |

### 4.4 Open PRs of Interest

| PR # | Title | Status | Relevance |
|------|-------|--------|-----------|
| #383 | Fix split brain by leader lease | Open (2020-12) | Core safety: stale leader reads |
| #144 | shouldWithholdVotes() for higher term | Open (2020-07) | Election correctness |
| #1339 | Don't keep failed requests in RetryCache | Open (2026-02) | Active discussion about idempotency semantics |
| #1262 | Safer initialization of TransactionContext#logIndexFuture | Open (2025-05) | Concurrency safety |
| #470 | Fix server impl NPEs | Open (2021-04) | Null safety |
| #411 | Fixes problems with large snapshots | Open (2021-01) | Snapshot robustness |

---

## 5. Historical Bug Patterns

### Bug Hotspot Files

| File | Bug-Fix Commits | Key Bug Types |
|------|----------------|---------------|
| `RaftServerImpl.java` | 8 | Role transitions, state management, NPEs |
| `LeaderStateImpl.java` | 3+ | Races with ServerState, deadlocks, commit index |
| `SegmentedRaftLogCache.java` | 2+ | NPEs, cache eviction races |
| `SnapshotInstallationHandler.java` | 2+ | Stale requests, chunk ordering |
| `ReadRequests.java` | 2 | Data races, readAfterWrite |
| `ReadIndexHeartbeats.java` | 1 | ReadIndex loss from race |

### Recurring Bug Types

| Bug Type | Count | Examples |
|----------|-------|---------|
| **Race conditions** | 14+ (JIRA) | RATIS-1751, 2044, 1927, 804, 535, 2282, 2278, 1699 |
| **Deadlocks** | 3 | RATIS-2345, 2162, 1691 |
| **Snapshot issues** | 5+ | RATIS-1305, 987, 1577, 2183, snapshot chunk ordering |
| **Log corruption/gaps** | 4+ | RATIS-815, 797, 1887, 1194 |
| **NPEs/null safety** | 5+ | RATIS-1300, 1292, 1368, 522 |
| **Split-brain/stale leader** | 3 | RATIS-981, 1273, 1418 |
| **Data loss** | 2 | RATIS-1995, unsafe flush |

### Most Refactored Areas
1. **Log appender system** — Multiple redesigns (RATIS-1208, 1200), race fixes (RATIS-2234, 2282)
2. **Read/linearizable read** — Three separate bug fixes (RATIS-2044, 1927, 2350)
3. **Snapshot installation** — Ongoing issues (RATIS-987, 1305, 1577, 2183)
4. **Role transition/shutdown** — Three deadlock fixes (RATIS-2345, 2162, 1691)

---

## 6. Summary

### What We Found

#### New Findings from Code Analysis (not previously reported)
1. **Non-atomic snapshot directory rename** with crash window that can lose all snapshot data (Finding 2)
2. **Cache-disk ordering gap during log truncation** that can re-introduce conflicting entries on crash recovery (Finding 3)
3. **`updateIncreasingly` sets-then-checks** — a latent atomicity bug in a class documented as "thread safe" (Finding 4)
4. **`syncWithSnapshot` data race** — writes non-volatile fields from non-worker thread, dangling futures (Finding 6)
5. **Async flush race on `lastWrittenIndex`** — callback reads field at wrong time (Finding 5)
6. **Non-atomic `getPrevious()`/buffer-fill** in log appender — `nextIndex` read twice without lock (Finding 10)
7. **`reloadStateMachine` blocks server** — holds server lock during potentially long operation (Finding 14)
8. **Shared non-thread-safe `MessageDigest`** — relies on undocumented external locking (Finding 15)

#### Confirmed Open Bugs (from JIRA verification)
- 44 open bugs total, 12 Critical/Blocker open bugs
- Notable: RATIS-2300 (leader timeout to old leader), RATIS-2306 (group recovery failure), RATIS-1305 (infinite snapshot cycle), RATIS-804 (cache evict race)

#### Developer-Acknowledged Issues (TODOs)
1. Snapshot state updated before chunk validation (SnapshotInstallationHandler:217)
2. Snapshot request ordering not validated (SnapshotManager:114-115)
3. Configuration entries never cleaned up after commit (ConfigurationManager:117)
4. Committed index not persisted for faster recovery (SegmentedRaftLog:258)
5. Cache eviction blocking not implemented (SegmentedRaftLog:335)
6. Retry policy incomplete (LogAppenderDefault:93)

### What We Excluded (False Positives)

1. **Term/votedFor persistence atomicity**: Initially suspicious because `updateCurrentTerm` modifies in-memory state but returns a flag for the caller to persist. Verified that `AtomicFileOutputStream` writes term and votedFor atomically, and the caller always persists within the `synchronized(server)` block before sending any reply. **Not a bug.**

2. **Candidate self-vote + incoming RequestVote overlap**: Both `initElection` and `requestVote` synchronize on the server object, preventing concurrent execution. `VoteContext.checkTerm` correctly rejects if `votedFor != null && !votedFor.equals(candidateId)`. **Not a bug.**

3. **`changeToLeader` discards election shutdown future**: Initially concerning because the future is not awaited. Verified that `changeToLeader` is called FROM the election thread itself, so shutting down the election reference and continuing in the same thread is safe. **Not a bug.**

4. **Election timeout fires right after heartbeat**: The TOCTOU race in `FollowerState.roleChangeChecking` is real but benign — the election will fail because other followers have fresh heartbeats, and the server reverts to follower. **Race exists but is harmless.**

5. **STEP_DOWN event deduplication**: Dropping a newer term in the event queue is technically a race but not a safety violation — stepping down to any higher term is sufficient. **Not a safety bug.**

### Recommended TLA+ Modeling Directions

Based on ALL findings, the top 5 areas for formal verification:

#### 1. Log Truncation and Crash Recovery
**Why**: Finding 3 (cache-disk truncation gap) and RATIS-797 (segment corruption after restart) reveal that the separation of cache and disk state during truncation creates a crash window. The Raft log matching property could be violated if recovery reloads truncated entries.
**Invariants to check**: Log matching property after crash/recovery, monotonicity of committed entries
**Guiding bugs**: RATIS-797, RATIS-815, RATIS-1887, RATIS-1194

#### 2. Snapshot Installation Protocol
**Why**: Findings 1, 2, 9, and 20 all relate to snapshot installation. The protocol has acknowledged ordering issues, a non-atomic rename with data loss potential, races with concurrent AppendEntries, and state updates before validation. RATIS-1305 (infinite snapshot cycle) is still open.
**Invariants to check**: Snapshot atomicity, no state corruption from partial installs, convergence (no infinite loops)
**Guiding bugs**: RATIS-1305, RATIS-987, RATIS-1577, RATIS-2183

#### 3. Read Index / Linearizable Read
**Why**: Three separate bug fixes (RATIS-2044, RATIS-1927, RATIS-2350) in the linearizable read path suggest this is an error-prone area. The interaction between ReadIndex, heartbeat confirmation, leader step-down, and state machine application has subtle races.
**Invariants to check**: Linearizability — every read returns a value that was committed at the time the read was initiated
**Guiding bugs**: RATIS-2044, RATIS-1927, RATIS-2350, RATIS-2392

#### 4. Leader Election with Pre-Vote and Priority
**Why**: The election system has Pre-Vote, priority-based rejections, leader stickiness checks, and data loss prevention (RATIS-1995). The interaction between these mechanisms is complex. PR #144 (shouldWithholdVotes) has been open for 6 years with unresolved correctness debate.
**Invariants to check**: Election safety (at most one leader per term), liveness (elections eventually succeed), no data loss from empty-log voters
**Guiding bugs**: RATIS-1995, RATIS-998, RATIS-1446, RATIS-758

#### 5. Commit Index Advancement and Flush Coordination
**Why**: Findings 4, 5, 6, and 17 reveal issues in how the commit index interacts with the flush index. The `updateIncreasingly` atomicity bug, the async flush race, and the `tryWriteLock` silent failure all affect whether committed entries are truly durable.
**Invariants to check**: Committed entries are durable (persisted before acknowledgment), commit index monotonicity, no phantom commits
**Guiding bugs**: RATIS-1256, RATIS-2234, RATIS-1879
