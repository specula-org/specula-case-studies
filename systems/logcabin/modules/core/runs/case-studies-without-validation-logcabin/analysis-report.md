# LogCabin Raft Implementation — Code Analysis Report

## 1. Investigation Scope & Method

### Code Analyzed
- **Repository**: [logcabin/logcabin](https://github.com/logcabin/logcabin) (C++)
- **Primary author**: Diego Ongaro (Raft protocol designer)
- **Raft core files** (5,240 LOC):
  - `Server/RaftConsensus.cc` (3,037 lines) — main consensus logic
  - `Server/RaftConsensus.h` (1,725 lines) — class definitions, state variables
  - `Server/RaftConsensusInvariants.cc` (306 lines) — runtime invariant checking
  - `Server/RaftService.cc` (110 lines) — RPC dispatcher
  - `Server/RaftService.h` (62 lines) — RPC service interface
- **Supporting files** analyzed:
  - `Server/StateMachine.cc` (837 lines) — state machine application layer, snapshot management
  - `Storage/SegmentedLog.cc` (1,370 lines) — primary persistent log backend
  - `Storage/SnapshotFile.cc` (264 lines) — snapshot I/O
  - `Protocol/Raft.proto` (339 lines) — Raft RPC message definitions

### Methods Used
1. **Static code analysis**: Line-by-line reading of all core files
2. **Git history archaeology**: Mining 107+ commits to `RaftConsensus.cc` for bug-fix patterns
3. **GitHub issue verification**: Reading full discussions of 48 bug-labeled issues + 30 keyword searches
4. **Developer TODO/FIXME analysis**: 36 TODO comments catalogued
5. **Commit diff analysis**: Detailed examination of 12 critical bug-fix commits

---

## 2. Codebase Overview

### Architecture Summary
LogCabin implements the Raft consensus protocol as described in Diego Ongaro's PhD dissertation. The implementation uses a **monitor-style concurrency model** with a single `Core::Mutex` protecting nearly all `RaftConsensus` state.

**Key components:**
- `RaftConsensus` — Central consensus module (monitor pattern)
- `Peer` — Per-remote-server state and RPC handling
- `Configuration` / `ConfigurationManager` — Membership management (joint consensus)
- `SegmentedLog` — On-disk log storage with segmented files
- `StateMachine` — Applies committed entries, manages snapshots via `fork()`

### Concurrency Model
- **5+ threads per server**: leaderDiskThread, timerThread, stateMachineUpdaterThread, stepDownThread, plus one peerThread per remote server (detached)
- **Single monitor lock** (`RaftConsensus::mutex`) protects all shared state
- **Lock release pattern**: Long-blocking operations (RPC calls, disk I/O) temporarily release the lock via `MutexUnlock<>`
- **One atomic variable**: `leaderDiskThreadWorking` (std::atomic<bool>) polled by `stepDown()`
- **Event loop**: epoll-based (`Event::Loop`) for network I/O, separate from Raft threads

### RPC Types
3 Raft RPCs: `RequestVote`, `AppendEntries`, `InstallSnapshot`

### Key Deviations from Raft Paper
1. **Deferred leader disk writes**: Leader appends to memory, replicates to followers, and flushes to disk asynchronously via `leaderDiskThread`. Commit index only advances after both majority replication AND leader disk sync.
2. **Joint consensus for membership changes** (dissertation §4.3), not the simpler single-server change.
3. **Pre-vote mechanism** (`withholdVotesUntil`): Followers reject RequestVote RPCs received within one election timeout of a valid leader heartbeat, preventing disruptive removed servers.
4. **Fork-based snapshots**: State machine snapshots taken by forking a child process for copy-on-write semantics.
5. **Cluster clock**: Monotonic cluster-wide logical clock for session management.

---

## 3. Code Analysis Findings

### Finding 1: PANIC Format String Argument Mismatch

- **Location**: `Server/RaftConsensus.cc:1392-1399`
- **Description**: The PANIC message for unknown entry types has mismatched format specifiers and arguments.
  ```cpp
  PANIC("Leader %lu is trying to send us an unknown log entry "
        "type for index %lu (term %lu)...",
        index,        // maps to "Leader %lu" — WRONG (should be leaderId)
        entry.term(), // maps to "index %lu"  — WRONG (should be index)
        leaderId);    // maps to "term %lu"   — WRONG (should be entry.term())
  ```
- **Analysis**: All three format parameters are assigned to the wrong values. "Leader" shows the entry index, "index" shows the term, and "term" shows the leader ID. The server PANICs regardless so there is no safety impact, but diagnostic output will be completely misleading.
- **Verification status**: **Confirmed bug** — verified by reading lines 1392-1399 directly.
- **Severity**: Low (cosmetic, only affects debug output on PANIC)

### Finding 2: Non-Atomic Truncate + Append in `handleAppendEntries`

- **Location**: `Server/RaftConsensus.cc:1340-1407`
- **Description**: When a follower detects a log conflict, it truncates the suffix at line 1383 (`log->truncateSuffix(lastIndexKept)`) and then appends new entries at line 1405 (`append(entries)`). These are two separate disk operations with a crash window between them.
  ```cpp
  // Developer comment at lines 1351-1355:
  // "there is a window of vulnerability on the follower's disk between
  // the truncate and append operations (which are not done atomically)
  // when the follower processes the later request."
  ```
- **Analysis**: If the server crashes after truncate but before append completes, entries are lost. The leader may have already counted this follower's acknowledgment from a previous RPC for commitment purposes. The developer-acknowledged mitigation (term comparison at line 1373) only handles duplicate RPCs, not the crash-during-truncate scenario.
- **Verification status**: **Developer-acknowledged issue** — explicitly documented in code comments.
- **Severity**: High (crash during truncate+append can lose acknowledged entries)

### Finding 3: `matchIndex` Not Updated on Unexpected Decrease in AppendEntries Response

- **Location**: `Server/RaftConsensus.cc:2326-2337`
- **Description**: When a successful AppendEntries response indicates a lower matchIndex than expected, the code logs a warning but does not update `matchIndex`. However, it unconditionally sets `nextIndex = matchIndex + 1` based on the stale (higher) value.
  ```cpp
  if (peer.matchIndex > prevLogIndex + numEntries) {
      WARNING("matchIndex should monotonically increase...");
      // matchIndex NOT updated
  } else {
      peer.matchIndex = prevLogIndex + numEntries;
      advanceCommitIndex();
  }
  peer.nextIndex = peer.matchIndex + 1;  // uses stale matchIndex!
  ```
- **Analysis**: If this path is triggered (e.g., by message reordering), the leader maintains a falsely high `matchIndex` for the peer and calculates `nextIndex` from it. This could cause the leader to skip entries that the follower needs, and in the worst case, count stale acknowledgments toward commitment.
- **Verification status**: **Code inconsistency** — the warning suggests this is unexpected, but the handling is incomplete.
- **Severity**: Medium (potential safety issue if triggered; currently unlikely without pipelining)

### Finding 4: `withholdVotesUntil` Blocks Term Discovery from Higher-Term Candidates

- **Location**: `Server/RaftConsensus.cc:1540-1549`
- **Description**: When `withholdVotesUntil` is active (server recently heard from leader), a RequestVote with a higher term is rejected WITHOUT calling `stepDown(request.term())`:
  ```cpp
  if (withholdVotesUntil > Clock::now()) {
      response.set_term(currentTerm);
      response.set_granted(false);
      return;  // Does not update currentTerm to the higher value
  }
  ```
- **Analysis**: This is an intentional design choice for the pre-vote/leader-stickiness mechanism (Raft dissertation §4.2.3). However, it deviates from strict Raft semantics where any server observing a higher term must update its own term. This can delay term convergence after network partitions heal, because followers of the old leader will ignore the new (higher-term) candidate until their `withholdVotesUntil` expires.
- **Verification status**: **Design decision** — intentional, documented in Raft dissertation.
- **Severity**: Medium (delays partition recovery convergence)

### Finding 5: Busy-Wait in `stepDown` While Holding Global Mutex

- **Location**: `Server/RaftConsensus.cc:2935-2940`
- **Description**: `stepDown()` holds the global `RaftConsensus::mutex` while busy-waiting with `usleep(500)` for the `leaderDiskThread` to finish:
  ```cpp
  while (leaderDiskThreadWorking)
      usleep(500);
  ```
- **Analysis**: During this busy-wait, ALL other Raft operations are blocked — RPC handlers, peer threads, timer thread. If the disk is slow (e.g., under heavy I/O), the server becomes unresponsive for the duration, potentially causing cascading election timeouts. The code comment explains this is intentional to avoid releasing the lock (which would allow the server to incorrectly believe writes are flushed).
- **Verification status**: **Developer-acknowledged issue** — comment explains the rationale.
- **Severity**: Medium (availability issue under slow disk conditions)

### Finding 6: `commitIndex` Bounds Check Only Via Assert (Disabled in Release Builds)

- **Location**: `Server/RaftConsensus.cc:1416-1418`
- **Description**: The follower sets `commitIndex` from the leader's request with only an assertion guard:
  ```cpp
  if (commitIndex < request.commit_index()) {
      commitIndex = request.commit_index();
      assert(commitIndex <= log->getLastLogIndex());  // no-op in release
  }
  ```
- **Analysis**: In release builds compiled with `NDEBUG`, the assert is compiled out. A malformed AppendEntries request with `commit_index > lastLogIndex` would silently set `commitIndex` to an out-of-bounds value, potentially causing out-of-bounds log access in `getNextEntry()` or `advanceCommitIndex()`.
- **Verification status**: **Robustness issue** — defense-in-depth gap.
- **Severity**: Medium (relies on correct leader behavior; no defense against malformed messages in release builds)

### Finding 7: Fork with Locks Held by Other Threads (Snapshot Creation)

- **Location**: `Server/StateMachine.cc:734`
- **Description**: The `takeSnapshot()` method calls `fork()` while the StateMachine mutex is held and other threads may hold additional mutexes (RaftConsensus mutex, ThreadId mutex, malloc internals, etc.). The child process inherits locked mutexes that no child thread will ever unlock.
- **Analysis**: This is the root cause of issues #121, #196, and #213. A watchdog thread (StateMachine.cc:652-716) exists to kill stuck children, but this is a mitigation, not a fix. Failed snapshots delay log compaction and waste resources.
- **Verification status**: **Developer-acknowledged issue** — GitHub issues #121, #196, #213 all track this class of bug.
- **Severity**: High (can cause child deadlock during snapshot, cascading to delayed log compaction)

### Finding 8: PANIC on Corrupt Closed Segment — No Graceful Recovery

- **Location**: `Storage/SegmentedLog.cc:954-962`
- **Description**: When a closed segment has a corrupt entry during startup, the server PANICs:
  ```cpp
  if (!error.empty()) {
      PANIC("Could not read entry %lu in log segment %s ...");
  }
  ```
  Compare with open segments (lines 1019-1047) where corrupt trailing entries are gracefully truncated with a warning.
- **Analysis**: A single bit-flip in a closed segment (from disk error, firmware bug, or cosmic ray) makes the server unable to start, permanently reducing cluster capacity until manual intervention. Open segments handle corruption gracefully but closed segments do not. Related to issue #221 (cluster unavailability from power failures) which similarly causes PANICs on recoverable conditions.
- **Verification status**: **Code inconsistency** — open and closed segments handle corruption differently without justification.
- **Severity**: High (single-point-of-failure for node recovery; affects cluster fault tolerance)

### Finding 9: Crash Window in Segment Rename-Before-Truncate (`truncateSuffix`)

- **Location**: `Storage/SegmentedLog.cc:724-749`
- **Description**: When truncating a closed segment, the code renames the file first, then truncates it:
  ```cpp
  FS::rename(dir, segment.filename, dir, newFilename);
  FS::fsync(dir);
  // CRASH WINDOW: file renamed but not yet truncated
  FS::File f = FS::openFile(dir, segment.filename, O_WRONLY);
  FS::truncate(f, segment.bytes);
  FS::fsync(f);
  ```
- **Analysis**: If a crash occurs between rename and truncate, the file's name claims it covers entries X-Y but it still contains data for entries X-Z (Z > Y). Recovery code at line 964-973 handles this by truncating extra bytes with a warning. Developer comments in `SegmentedLog.h:64-68` acknowledge this window.
- **Verification status**: **Developer-acknowledged issue** — documented in header comments with recovery code.
- **Severity**: Medium (recovered gracefully but represents an inconsistency window)

### Finding 10: `shouldTakeSnapshot` — uint64 Underflow and Division by Zero

- **Location**: `Server/StateMachine.cc:599-605`
- **Description**: Two arithmetic issues in the snapshot progress reporting:
  ```cpp
  uint64_t curr = 0;
  if (lastIncludedIndex > stats.last_snapshot_index())
      curr = lastIncludedIndex - stats.last_snapshot_index();
  uint64_t prev = curr - 1;      // Underflow when curr == 0 → UINT64_MAX
  uint64_t logEntries = stats.last_log_index() - stats.last_snapshot_index();
  if (curr != logEntries &&
      10 * prev / logEntries != 10 * curr / logEntries) {  // div-by-zero if logEntries == 0
  ```
- **Analysis**: When `curr == 0`, `prev` underflows to `~0UL`. When `logEntries == 0`, division by zero occurs. Both paths are reachable (empty log, no progress since snapshot).
- **Verification status**: **Confirmed bug** — verified by reading lines 599-605 directly. Related to open GitHub issue #190 (uint overflow).
- **Severity**: Medium (crash on div-by-zero; misleading progress messages on underflow)

### Finding 11: `flushToOS()` Is a No-Op — Snapshot Data Not Fsynced by Child

- **Location**: `Server/StateMachine.cc:764`, `Storage/SnapshotFile.cc:196-199`
- **Description**: The snapshot child process calls `writer->flushToOS()` before `_exit(0)`, but `Writer::flushToOS()` is empty:
  ```cpp
  void Writer::flushToOS() {
      // Nothing to do.
  }
  ```
  The actual fsync happens in the parent via `Writer::save()` in `consensus->snapshotDone()`.
- **Analysis**: If the parent crashes after `waitpid` returns but before `snapshotDone()` fsyncs, the snapshot data is only in the kernel page cache and could be lost on power failure. On restart, `discardPartialSnapshots()` removes incomplete snapshots, so no corruption occurs, but the snapshot work is wasted.
- **Verification status**: **Robustness issue** — the recovery path handles this correctly, but the crash window is real.
- **Severity**: Low (no corruption, only wasted work)

### Finding 12: `rpcFailuresSinceLastWarning` Accessed Without Lock or Atomics

- **Location**: `Server/RaftConsensus.h:426-429`, `Server/RaftConsensus.cc:281-298`
- **Description**: `rpcFailuresSinceLastWarning` is a plain `uint64_t` accessed without the mutex during `callRPC()` (which releases the lock). The comment says "Accessed only from callRPC() without holding the lock." Only a single peer thread accesses each Peer's callRPC, so this is safe by design, but lacks defensive atomics.
- **Verification status**: **Robustness issue** — safe by current design but not by type system.
- **Severity**: Low (safe given current single-peer-thread-per-Peer invariant)

### Finding 13: `handleInstallSnapshot` — Follower Self-Increments Term as Backwards-Compat Workaround

- **Location**: `Server/RaftConsensus.cc:1481-1498`
- **Description**: When a snapshot chunk arrives at an unexpected offset and the leader is version 1, the follower increments its own term to force the leader to step down:
  ```cpp
  if (!request.has_version() || request.version() < 2) {
      stepDown(currentTerm + 1);  // Artificial term bump
  }
  ```
- **Analysis**: This is a compatibility workaround for old leaders that don't support the `bytes_stored` response field (issue #174). It can cause unnecessary cluster disruption: a single snapshot chunk reordering forces a full election cycle. On an unstable network, this could cause rapid term inflation.
- **Verification status**: **Design decision** — backwards compatibility workaround for version 1 protocol.
- **Severity**: Low (only affects mixed-version clusters with version 1 leaders)

### Finding 14: `addresses` String Read Without Lock in `Peer::getSession()`

- **Location**: `Server/RaftConsensus.cc:330-333`
- **Description**: The peer's `addresses` string is read after the lock is released:
  ```cpp
  Core::MutexUnlock<Mutex> unlockGuard(lockGuard);
  RPC::Address target(addresses, Protocol::Common::DEFAULT_PORT);
  ```
  Meanwhile, `setConfiguration()` (cc:601) can write to `addresses` under the lock from another thread.
- **Analysis**: Reading a `std::string` concurrently with writing it is undefined behavior. This data race could cause crashes or corrupted address values.
- **Verification status**: **Confirmed bug** — the `addresses` field is documented as requiring the lock (header line 194), but this usage violates that requirement.
- **Severity**: Medium (data race on std::string, potential crash)

### Finding 15: Stale Snapshot File Descriptor After Leader Step-Down

- **Location**: `Server/RaftConsensus.h:442-445`
- **Description**: The `Peer::snapshotFile` unique_ptr persists across leader step-down because peers don't have a hook for step-down cleanup:
  ```cpp
  // TODO(ongaro): It'd be better to destroy this as soon as this server
  // steps down, but peers don't have a hook for that right now.
  ```
- **Analysis**: After stepping down, the open file descriptor holds the old snapshot file. If a new snapshot is written, the stale FD points to a deleted file. This wastes file descriptors. `beginLeadership()` resets it on next leadership, but the stale FD persists in between.
- **Verification status**: **Developer-acknowledged issue** — explicit TODO in code.
- **Severity**: Low (resource leak, not correctness issue)

---

## 4. GitHub Issues & PRs Verification

### 4.1 Confirmed Bugs (with verification notes)

| Issue | Title | Severity | Status | Root Cause |
|-------|-------|----------|--------|------------|
| **#44** | Critical Raft data corruption: commitment of entries from prior terms | **Critical** | Fixed | Leader committed entries from prior terms by replica count alone, violating Raft Figure 8 safety property. Fixed by implementing the correct commitment rule (§5.4.2). |
| **#160** | Packing entries into AppendEntries requests is broken | **Critical** | Fixed | Missing `break` statement after `RemoveLast()` caused non-contiguous entries to be packed and sent to followers at wrong indices. Single-line fix: adding `break;`. |
| **#200** | Slow disk writes cause spurious leader elections | **High** | Fixed | Election timer reset at start of `handleAppendEntries` instead of after disk write. Slow disks caused timer to expire during write. |
| **#205** | Removed leader should not start new elections | **High** | Fixed | After a leader processes its own removal from the cluster, it would still start elections and win votes from uninformed peers, causing extended unavailability during reconfiguration. |
| **#221** (dup of #191) | Cluster unavailable due to power failures | **High** | Fixed | PANIC on recoverable corrupt open segment (version 0 after incomplete header write). Correlated power failures across a rack could make majority of nodes permanently unable to start. |
| **#174** | Resiliency in InstallSnapshot | **Medium** | Fixed | Follower PANICs repeatedly (crash loop) after reboot during snapshot reception. Self-healing when term changes, but follower is down for the duration. |
| **#208** | Client stops acknowledging responses | **Critical** | Partially Fixed | Missing `doneWithRPC()` in keepalive retry path caused unbounded server-side session state accumulation → corrupt snapshots → production outage. Immediate fix applied, but defense-in-depth items remain open. |
| **#213** | logcabind deadlock at flockfile | **High** | Fixed | Interaction between `flockfile()`, logrotate, and signal handling caused logging thread to block indefinitely, cascading to total system deadlock. |
| **#190** | uint overflow in `shouldTakeSnapshot` | **Medium** | Open | Unsigned integer underflow when `curr == 0` and potential division by zero when `logEntries == 0`. |

### 4.2 Design Defects

| Issue | Title | Description |
|-------|-------|-------------|
| **#202** | Leader steps down when followers' disks are slow | Step-down timeout conflates network reachability with disk I/O latency. Workaround: increase timeout to 12x election timeout. Still OPEN. |
| **#244** | Adding new member requires all originals up | `setConfiguration` requires ALL new-config servers to be caught up, stricter than Raft's majority requirement. Conservative for safety but problematic in cloud environments. |
| **#56** | Disruptive servers after downsizing | Well-known Raft membership change problem. Fixed via `withholdVotesUntil` mechanism. |

### 4.3 Excluded (false/disputed/user-error)

| Issue | Title | Verdict | Reason |
|-------|-------|---------|--------|
| **#195** | Failed assertion at RaftService::appendEntries | **User error** | Two nodes configured with the same server ID after incomplete reset. Invalid configuration, not a LogCabin bug. Reporter confirmed. |
| **#54** | Sessions sometimes expire | **Dev branch bug** | Bug in unreleased local storage backend that assigned duplicate log indices. Not a production issue. |
| **#42** | Assertion failure in raft | **Already fixed** | Early-stage bug; assertion replaced with proper handling months before the issue was filed. |
| **#204** | Miss erase when RPC responses timeout | **Minor / Mitigated** | RPC objects are cleaned up via destructor cancellation. The leak is only for the lifetime of the RPC object. |

### 4.4 Open Issues of Interest

| Issue | Title | Age | Assessment |
|-------|-------|-----|-----------|
| **#226** | Deadlock in client on GetConfiguration timeout | 9 years | Classic lock-ordering inversion between Event::Loop lock and File::Monitor mutex. Rare (once in tens of thousands of installs) but confirmed deadlock. |
| **#196** | Deadlock in unit test (fork/lock) | 10 years | Fork/lock deadlock in child process during snapshot — ThreadId mutex held during fork. Specific instance of #121. |
| **#198** | LogCabin abort after running out of file descriptors | 10 years | Undiagnosed FD leak under network partition conditions. Server eventually hits ulimit and aborts. |
| **#208** | Client stops acknowledging responses (remaining items) | 10 years | Defense-in-depth items unimplemented: RAII-style doneWithRPC, server-side per-session limits, protobuf size guards. |

### 4.5 Open PRs of Interest

| PR | Title | Assessment |
|----|-------|------------|
| **#247** | Fix compiler detection, update to Python 3 | Build modernization, no Raft changes |
| **#239** | Dockerfile and VSCode launch scripts | Development tooling, no Raft changes |
| **#231** | Don't panic, fall back to pseudo random (issue #203) | Resilience fix for fd exhaustion during `/dev/urandom` open |

---

## 5. Historical Bug Patterns

### 5.1 Bug Hotspot Analysis

| File | Total Commits | Bug-Fix Commits | Bug Density |
|------|--------------|-----------------|-------------|
| `Server/RaftConsensus.cc` | 107 | 15+ | **Highest** |
| `Server/RaftConsensus.h` | 58 | 8+ | High |
| `Server/StateMachine.cc` | 46 | 6+ | High |
| `Server/RaftConsensusInvariants.cc` | 20 | 2 | Low |
| `Storage/SegmentedLog.cc` | 16 | 3 | Medium |
| `Storage/SnapshotFile.cc` | 12 | 2 | Medium |
| `Server/RaftService.cc` | 10 | 1 | Low |

### 5.2 Recurring Bug Types

1. **Persistence/crash recovery** (5 incidents): Issues #44, #160, #221/191, plus the non-atomic truncate+append and segment rename-before-truncate
2. **Fork/lock deadlocks** (3 incidents): Issues #121, #196, #213 — all from fork-based snapshot creation
3. **Configuration/membership change** (4 incidents): Issues #56, #205, #210, #244 — the most operationally disruptive category
4. **Timeout/election disruption** (3 incidents): Issues #200, #202, #57 — slow disks causing unnecessary elections
5. **Resource leaks** (2 incidents): Issues #198 (FD leak), #208 (session state leak)

### 5.3 Most Refactored Areas

The `handleAppendEntries` function has been modified most frequently due to:
- Entry packing bug (#160)
- Duplicate RPC handling
- Slow disk timeout fix (#200)
- Assertion guards after #160

The configuration management code (`Configuration`, `ConfigurationManager`, `setConfiguration`) has undergone significant refactoring over multiple commits, indicating inherent complexity.

---

## 6. Summary

### What We Found

**New findings from code analysis:**
1. PANIC format string argument mismatch (`RaftConsensus.cc:1392`) — confirmed
2. `matchIndex` not updated on unexpected decrease (`RaftConsensus.cc:2326`) — code inconsistency
3. `addresses` string data race in `Peer::getSession()` (`RaftConsensus.cc:330`) — confirmed
4. `shouldTakeSnapshot` underflow + div-by-zero (`StateMachine.cc:599`) — confirmed (correlates with open issue #190)
5. PANIC on corrupt closed segment with no graceful recovery (`SegmentedLog.cc:954`) — code inconsistency

**Confirmed open bugs (from issue verification):**
1. Issue #190: uint overflow — confirmed, open since 2015
2. Issue #226: Client-side deadlock (lock ordering inversion) — confirmed, open since 2017
3. Issue #196: Fork/lock deadlock in snapshot child — confirmed, open since 2015
4. Issue #198: FD leak under network partitions — undiagnosed, open since 2016
5. Issue #202: Leader step-down sensitivity to slow disks — design defect, open since 2016
6. Issue #208: Remaining defense-in-depth items for session management — partially addressed

**Developer-acknowledged issues (TODOs):**
- Non-atomic truncate+append in `handleAppendEntries` (explicit code comment)
- Fork/lock hazard in snapshot creation (watchdog mitigation, not fix)
- Single condition variable for all state changes (performance concern)
- Stale snapshot FDs after leader step-down (explicit TODO)
- Hardcoded session timeout needing Raft-based agreement (explicit TODO)
- 3 incomplete invariant checks in `RaftConsensusInvariants.cc` (explicit TODOs)

### What We Excluded

| Finding | Reason for Exclusion |
|---------|---------------------|
| `startNewElection` persistence ordering | Initially flagged as non-atomic (vote before persist), but verified that `updateLogMetadata()` calls fsync synchronously and completes BEFORE `interruptAll()` wakes peer threads. The lock prevents any RPC from being sent before persistence. Safe by design. |
| `handleRequestVote` crash window | The `votedFor` is set at line 1570 and persisted at line 1571. A crash between these lines would lose the vote, but since the RPC response hasn't been sent, no candidate has counted it. Safe because the response is the commit point, not the local state. |
| Leader deferred disk sync | The `leaderDiskThread` + `lastSyncedIndex` mechanism prevents commitment before the leader's disk write completes. Entries replicated to followers before leader persistence cannot be committed because `advanceCommitIndex()` requires the local server's `lastSyncedIndex`. Safe by design. |
| `becomeLeader` no-op before persist | Same as above — the no-op entry is replicated to peers but cannot be committed until the leader's disk sync advances `lastSyncedIndex`. |
| Issue #195 (assertion failure) | User error — duplicate server IDs after incomplete node reset. |
| Issue #54 (session expiration) | Bug in unreleased local dev branch, not production code. |

### Recommended TLA+ Modeling Directions

Based on all findings, the top 5 areas for formal verification:

#### 1. Non-Atomic Persistence on Followers (Truncate + Append)
- **Why**: The developer-acknowledged crash window between truncate and append (`RaftConsensus.cc:1383-1405`) can cause acknowledged entries to vanish. This is the most architecturally fundamental persistence issue.
- **What to model**: The follower's truncate-then-append sequence, crash recovery, and the leader's commitment calculation based on prior acknowledgments.
- **Properties**: Log Matching Property, durability of committed entries.
- **Related**: Code comment at lines 1351-1355, Finding #2.

#### 2. Configuration Change Protocol (Joint Consensus + Disruptive Servers)
- **Why**: 4 separate bugs (#56, #205, #210, #244) involved configuration changes. This is the most error-prone area historically. The interaction between `withholdVotesUntil`, configuration transitions (STABLE → STAGING → TRANSITIONAL → STABLE), and the `commitIndex >= configuration->id` guard is complex.
- **What to model**: Full joint consensus protocol with server addition/removal, including the `withholdVotesUntil` mechanism and the server self-removal check.
- **Properties**: At most one leader per term during reconfiguration, liveness of configuration change completion, prevention of disruptive removed servers.
- **Related**: Issues #56, #205, #210, #244; `setConfiguration`, `advanceCommitIndex` Cnew creation.

#### 3. Leader Disk Thread and Deferred Persistence
- **Why**: The split between in-memory append and deferred disk sync (`leaderDiskThread`) is a performance optimization that introduces subtle correctness dependencies. The `stepDown` busy-wait (Finding #5) and the interaction between `logSyncQueued`, `leaderDiskThreadWorking`, and `lastSyncedIndex` are error-prone.
- **What to model**: Leader append → replicate → disk sync → commit advance pipeline, including crash scenarios during deferred sync and leader step-down during sync.
- **Properties**: Committed entries are durable on leader, no premature commitment.
- **Related**: Finding #5 (busy-wait), `leaderDiskThreadMain` (lines 2025-2054), `stepDown` drain logic (lines 2942-2951).

#### 4. InstallSnapshot Protocol Resilience
- **Why**: Issue #174 (follower crash loop after reboot during snapshot) revealed fragility in the chunked snapshot transfer protocol. The version compatibility workaround (Finding #13, artificial term bump) adds additional complexity. Snapshot completion (`readSnapshot`) discards the entire log, a drastic and irreversible operation.
- **What to model**: Multi-chunk snapshot transfer with follower crash/restart, version negotiation, and the interaction between `lastSnapshotIndex` and `commitIndex`.
- **Properties**: Follower eventually receives complete snapshot, no repeated PANICs, monotonicity of `lastSnapshotIndex`.
- **Related**: Issue #174, Finding #13, `handleInstallSnapshot` (lines 1429-1523).

#### 5. Session Management and Exactly-Once Semantics
- **Why**: Issue #208 showed how a single missing `doneWithRPC()` call cascaded into snapshot corruption and a production outage. The session expiration logic uses cluster time (not wall clock), session timeout is hardcoded, and expired sessions silently drop committed commands.
- **What to model**: Client session lifecycle (open, keep-alive, expire), `firstOutstandingRPC` tracking, and the interaction between session state accumulation and snapshot size.
- **Properties**: Exactly-once semantics under session expiration, bounded server-side session state, snapshot serializability.
- **Related**: Issue #208, Finding #10 (arithmetic bugs in snapshot logic), StateMachine session handling.
