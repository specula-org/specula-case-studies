# RethinkDB Raft Implementation — Analysis Report

## Coverage Statistics

| Metric | Count |
|--------|-------|
| Git bug-fix commits analyzed | 27 |
| GitHub issues deeply read (full thread) | 38 |
| GitHub issues confirmed as bugs | 17 (12 fixed, 5 unfixed) |
| GitHub issues classified as design defects | 6 |
| GitHub issues excluded (user error / not Raft) | 9 |
| GitHub issues uncertain / needs investigation | 6 |
| Core files deep-analyzed (full read) | 7 |
| LOC of core Raft logic | ~3,089 |

---

## 1. Codebase Structure

### Core Files

| File | LOC | Purpose |
|------|-----|---------|
| `src/clustering/generic/raft_core.hpp` | 1,015 | Types, RPC definitions, class declaration |
| `src/clustering/generic/raft_core.tcc` | 2,064 | Main Raft algorithm implementation |
| `src/clustering/generic/raft_network.hpp` | 81 | Network interface + business card |
| `src/clustering/generic/raft_network.tcc` | 87 | Network implementation |
| `src/clustering/administration/persist/raft_storage_interface.hpp` | 90 | Storage interface for table Raft |
| `src/clustering/administration/persist/raft_storage_interface.cc` | 244 | Storage implementation (B-tree backed) |

### Concurrency Model

- **Cooperative multitasking** via coroutines (not OS threads)
- **Two mutexes**: `mutex` (main Raft state), `log_mutex` (log + snapshot writes)
- **Watchables**: `committed_state`, `latest_state` — observable state containers
- **Coroutines**: 1 candidate/leader coro + N `leader_send_updates` coros (one per peer)
- **Timers**: `watchdog` (election timeout), `watchdog_leader_only` (leader-specific)
- Key invariant: mutex is released during blocking operations (RPC sends, condition waits), allowing other coroutines to mutate state

### Key Architectural Deviations from Raft Paper

1. **Virtual heartbeats** instead of periodic AppendEntries (start/stop messages; failure detection delegated to transport layer)
2. **Persisted commit_index** (prevents state machine regression on crash)
3. **Joint consensus** for config changes (faithful to Raft paper Section 6)
4. **No PreVote** — uses `watchdog_leader_only` to suppress disruptive elections
5. **Leaders accept RequestVote** from config members (workaround for virtual heartbeats having no reply channel)
6. **Raft is per-table**, not cluster-wide — system metadata uses eventually-consistent replication

---

## 2. Git History Bug-Fix Catalog

### Bug 1 — `92fa1e644c` — "Iron out some bugs in Raft implementation"
- **Component**: Concurrency, Election, Invariants
- **Root cause**: Multiple: (a) non-interruptible mutex acquisitions blocked shutdown, (b) invariant loop started at `prev_index` instead of `prev_index + 1`, (c) inverted `leader_drainer.has()` check, (d) `candidate_run_election()` didn't release mutex while sleeping, (e) `request_vote_drainer` uninitialized
- **Severity**: HIGH

### Bug 2 — `66c29ea837` — "Fix another Raft bug"
- **Component**: Invariants, Log
- **Root cause**: Cross-member invariant check read entries before log start
- **Severity**: MEDIUM

### Bug 3 — `9871a1a410` — "Fix a Raft snapshot bug"
- **Component**: Snapshot, Lifecycle
- **Root cause**: InstallSnapshot discarded entire log even when only prefix covered; destructor cleanup ordering
- **Severity**: HIGH — data loss

### Bug 4 — `f5bc92aca0` — "Fix bugs that caused lock-up when stopping Raft"
- **Component**: Configuration change, Lifecycle
- **Root cause**: `propose_config_change` used latest (including uncommitted) config instead of committed config, allowing overlapping config changes
- **Severity**: HIGH — safety violation

### Bug 5 — `91bcec8659` — "Leader should have an entry in match_indexes for itself"
- **Component**: Replication (commit advancement)
- **Root cause**: `match_indexes` missing self-entry; in 2-node cluster nothing could commit
- **Severity**: CRITICAL

### Bug 6 — `15a3175b3e` — "Election starvation from RequestVote RPCs"
- **Component**: Election
- **Root cause**: `last_heard_from_leader` reset on any RequestVote (even rejected), preventing up-to-date node from starting election
- **Severity**: HIGH — election liveness failure

### Bug 7 — `ad4f9d02eb` — "candidate_run_election() should release mutex while sleeping"
- **Component**: Election, Concurrency
- **Root cause**: Mutex held during vote-request sleep, blocking all RPCs
- **Severity**: HIGH — deadlock

### Bug 8 — `96fefea48b` — "Fix an election timing bug"
- **Component**: Election
- **Root cause**: Shared `last_heard_from_leader` timer for leader and candidate RPCs; split into two separate timestamps
- **Severity**: MEDIUM

### Bug 9 — `7af0fb2ec6` — "Fix bug in previous commit"
- **Component**: Replication
- **Root cause**: `leader_send_updates` forgot to reacquire mutex after wait loop
- **Severity**: HIGH

### Bug 10 — `688c1f345b` — "Fix off-by-one error in Raft"
- **Component**: Replication
- **Root cause**: Wake condition `ls.log_index > next_index` should be `>= next_index`
- **Severity**: MEDIUM

### Bug 11 — `4093d396c5` — "Fix a bug in the Raft algorithm"
- **Component**: Virtual heartbeat, Election
- **Root cause**: Leader treated its own virtual heartbeat as a follower heartbeat; `on_rpc_from_leader` didn't guard against self
- **Severity**: HIGH

### Bug 12 — `1df78072b5` — "Strengthen Raft tests. Fix some bugs"
- **Component**: Election, Virtual heartbeat
- **Root cause**: Leader rejected ALL RequestVote RPCs, preventing term discovery; stale heartbeat sender state
- **Severity**: HIGH — term advancement blocked

### Bug 13 — `4e21ad1163` — "Fix iterator invalidation in raft_member_t"
- **Component**: Replication
- **Root cause**: Iterator invalidation in `leader_spawn_update_coros` erase loop
- **Severity**: HIGH — crash / use-after-free

### Bug 14 — `1b70048c19` — "Fix a bug in raft_network.hpp"
- **Component**: Network
- **Root cause**: Stale connection state pointer when member disconnected
- **Severity**: MEDIUM

### Bug 15 — `67a57bb37c` — "Fix various bugs in table_readiness"
- **Component**: Election, Virtual heartbeat
- **Root cause**: `effective_last_heard_from_leader()` didn't return `current_microtime()` for leader mode; didn't reset timer after stepping down
- **Severity**: MEDIUM

### Bug 16 — `af6ad0f478` — "Fix bugs when snapshotting is delayed"
- **Component**: Snapshot, Log
- **Root cause**: AppendEntries rejected when `prevLogIndex` before snapshot boundary; conflict detection loop started before snapshot boundary
- **Severity**: HIGH — blocked replication

### Bug 17 — `3fb075a7fd` — "Fix snapshot incompatible with log entries"
- **Component**: Snapshot
- **Root cause**: `write_snapshot` called without `clear_log` when log entries conflicted with snapshot
- **Severity**: HIGH — log/snapshot inconsistency

### Bug 18 — `3889ed0b22` — "Make Raft store commit index on disk"
- **Component**: Persistence, State machine
- **Root cause**: Commit index not persisted; state machine regressed on restart
- **Severity**: CRITICAL — linearizability violation

### Bug 19 — `cf97eb5b05` — "Fix for #4422"
- **Component**: Persistence
- **Root cause**: `log_index_to_str` missing `& 0x0f` nibble mask; `write_log_replace_tail` off-by-one (`<` instead of `<=`)
- **Severity**: CRITICAL — persistent log corruption

### Bug 20 — `347a7e635b` — "Fix #4234"
- **Component**: Election, Configuration change
- **Root cause**: Non-voting members blocked from starting elections during config changes, causing deadlock
- **Severity**: CRITICAL — cluster deadlock

### Bug 21 — `c665c97ac2` — "Fix some subtle Raft bugs"
- **Component**: Configuration change, Concurrency
- **Root cause**: `leader_continue_reconfiguration` checked only committed config for step-down (should check latest too); `candidate_or_leader_note_term` spawned coroutine even when already follower
- **Severity**: HIGH

### Bug 22 — `15714934a8` — "Fixes #5289, #4979, #4949, #4866"
- **Component**: Election, Replication, Concurrency
- **Root cause**: `update_term` called before `become_follower`, corrupting state while `candidate_run_election` still running; RequestVote RPC constructed without lock; stale config in `propose_config_change`
- **Severity**: CRITICAL — split-brain (Jepsen-discovered)

### Bug 23 — `238f9d49ee` — "Reset virtual heartbeat when changing the raft term"
- **Component**: Virtual heartbeat
- **Root cause**: `virtual_heartbeat_watchdog_blockers` not reset on term change; election suppressed after old leader gone
- **Severity**: HIGH — election liveness failure

### Bug 24 — `5ab7736236` — "Handle multiple calls to on_connected_members within same term"
- **Component**: Virtual heartbeat
- **Root cause**: `guarantee(virtual_heartbeat_sender.is_nil())` too strict for reconnection scenario
- **Severity**: MEDIUM — crash

### Bug 25 — `d5d134a853` — "Avoid use of 32-bit int in str_to_log_index"
- **Component**: Persistence
- **Root cause**: 32-bit int used for 64-bit shift operation; UB for large log indices
- **Severity**: MEDIUM

### Bug 26 — `9f12645d47` — "Fixes metadata writes being interrupted"
- **Component**: Persistence
- **Root cause**: Storage writes used interruptible signals; crash could leave half-written persistent state
- **Severity**: CRITICAL — persistence corruption

### Bug 27 — `a37c84b65e` — "Require explicit commit of write transactions"
- **Component**: Persistence
- **Root cause**: Write transactions implicitly committed by destructor even when incomplete
- **Severity**: HIGH — persistence corruption

---

## 3. GitHub Issues Catalog

### Confirmed Bugs (Fixed)

| # | Title | Severity | Root Cause | Component |
|---|-------|----------|------------|-----------|
| #5289 | Split-brain via log erasure during reconfig | CRITICAL | multi_table_manager timestamp bypass erased Raft log | Membership/persistence |
| #4979 | "log doesn't go forward this far" guarantee | CRITICAL | Same root cause as #5289 | Log/persistence |
| #4234 | Single-replica table stuck in waiting_for_quorum | CRITICAL | Non-voter couldn't start election during joint consensus | Election/config change |
| #4336 | Non-voting replica wins elections then steps down | HIGH | Timer phase-difference bias | Election |
| #6038 | Raft election timeout infinite loops | HIGH | I/O latency exceeded election timeout with 100+ tables | Election |
| #4866 | Branch history incomplete crash | HIGH | Branch history GC'd before replica fully erased | Config change/GC |
| #4875 | Segfault in mark_ready() | HIGH | Destruction order race | Replication |
| #4254 | Crash in contract_executor_t | MEDIUM | mutex_assertion failed during drain | Contract execution |
| #4262 | Crash during shutdown | MEDIUM | Shutdown ordering | Lifecycle |
| #4668 | Inactive replica blocks reconfiguration | HIGH | Migration timestamp in future; workaround caused #5289 | Multi table manager |
| #6033 | Data corruption in disk I/O | HIGH | Disk I/O bug causing deserialization failures | Storage |
| PR #7037 | 32-bit overflow in log index parsing | MEDIUM | `int` instead of `uint64_t` | Persistence |

### Confirmed Bugs (Unfixed)

| # | Title | Severity | Root Cause | Component |
|---|-------|----------|------------|-----------|
| #4357 | Non-transitive connectivity prevents failover | HIGH | Requires transitive connectivity for quorum | Election/network |
| #4824 | Fuzzer: committed != active_config | HIGH | Config divergence reproduced in fuzzer | Config change |
| #6444 | Duplicate key crash in minidir | MEDIUM | Duplicate contract_ack entry on reconnect | Contract ack |
| #6071 | Frozen backfill, 1000x slowdown | HIGH | Backfill tight loop after reconfig | Replication |
| #5584 | Lock timeout in check_invariants | MEDIUM | Raft lock contention under slow I/O | Invariant checking |

### Design Defects

| # | Title | Impact |
|---|-------|--------|
| #4357 | Non-transitive connectivity | Multi-hour production outages |
| #4605 | Primary reports "ready" when disconnected from majority | Misleading status |
| #1905 | No cluster_id prevents accidental merges | Production data conflicts |
| #6880 | Re-provisioned server crashes cluster | 24-hour reconnect timeout |
| #4898 | Duplicate table names (metadata not Raft-backed) | Regular production issue |
| #3009 | Float-point math divergence across architectures | Data inconsistency |

---

## 4. Deep Analysis Findings

### Finding DA-1: Tautological Invariant Check (CONFIRMED BUG)
- **Location**: `raft_core.tcc:852`
- **Code**: `guarantee(readiness_for_change.get() || !readiness_for_change.get(), ...)`
- **Issue**: `X || !X` is always true. Intended: `readiness_for_change.get() || !readiness_for_config_change.get()`
- **Impact**: The invariant "config-change readiness implies regular-change readiness" is never verified
- **Classification**: Code-review-only

### Finding DA-2: Virtual Heartbeat Commit-Lag Window
- **Location**: `raft_core.tcc:1401-1408` and `1719-1725`
- **Issue**: Virtual heartbeats don't carry commit index. Followers learn commit index only via explicit AppendEntries RPCs. Between heartbeat "start" and next AppendEntries, followers have stale commit knowledge.
- **Classification**: Model-checkable

### Finding DA-3: Deferred Step-Down Creates Stale-Term Window
- **Location**: `raft_core.tcc:1987-2022`
- **Issue**: `candidate_or_leader_note_term` spawns an async coroutine to step down. Between detection and coroutine execution, the node operates with stale term. All callers verified to return immediately.
- **Classification**: Model-checkable

### Finding DA-4: Leader Cannot Learn Higher Terms via Virtual Heartbeats
- **Location**: `raft_core.tcc:906-914`
- **Issue**: No reply channel for virtual heartbeat rejection. Leader continues sending stale heartbeats until a follower starts an election.
- **Compensating mechanism**: Leaders accept RequestVote from config members (lines 431-440)
- **Classification**: Model-checkable

### Finding DA-5: Transport Failure Detection Latency Affects Election Timeout
- **Location**: `raft_core.tcc:932-935`
- **Issue**: Virtual heartbeat watchdog blockers suppress election timeout. If transport is slow to detect disconnection, election timeout depends on transport, not Raft parameters.
- **Classification**: Model-checkable

### Finding DA-6: In-Memory State Mutated Before txn.commit()
- **Location**: `raft_storage_interface.cc:141-147, 154-159, 180-186, 199-200, 212-242`
- **Issue**: All storage write methods update in-memory state before `txn.commit()`. If commit fails without crashing, in-memory state diverges from disk.
- **Classification**: Code-review-only (low practical risk)

### Finding DA-7: Missing Global Invariants
- Vote uniqueness per term not checked
- Leader completeness not checked
- match_indexes consistency with peer logs not verified
- **Classification**: Model-checkable

### Finding DA-8: No next_index Optimization on Rejection
- **Location**: `raft_core.tcc:1904-1908`
- **Issue**: `next_index` decrements by 1 per rejection — O(N) RPCs to find match point.
- **Classification**: Test-verifiable (performance only)

---

## 5. Bug Family Analysis

### Family 1: Virtual Heartbeat Architecture (HIGH)

**Mechanism**: Virtual heartbeats (start/stop messages delegated to transport) replace real AppendEntries heartbeats, creating windows where leader staleness is undetected and followers have stale commit knowledge.

**Historical Evidence**:
- Bug #11 (`4093d396c5`): Leader treated own virtual heartbeat as follower heartbeat
- Bug #12 (`1df78072b5`): Leader rejected ALL RequestVote, couldn't discover higher terms
- Bug #23 (`238f9d49ee`): Watchdog blockers not reset on term change, suppressing elections
- Bug #24 (`5ab7736236`): Duplicate `on_connected_members_change` callback crash
- Issue #4357: Non-transitive connectivity prevents failover

**Code Analysis Evidence**:
- DA-2: Commit index lags until explicit AppendEntries
- DA-4: No reply channel for virtual heartbeat rejection
- DA-5: Election timeout depends on transport failure detection

**Affected Code Paths**:
- `on_connected_members_change()` (lines 888-953)
- `on_rpc_from_leader()` (lines 957-1031)
- `leader_send_updates()` (lines 1701-1940)
- `candidate_and_leader_coro()` leader init (lines 1401-1415)

---

### Family 2: Configuration Change Safety (HIGH)

**Mechanism**: Joint consensus + leader step-down + non-voter election interaction creates deadlock and safety violations. Tautological invariant means config-readiness correctness is never verified.

**Historical Evidence**:
- Bug #4 (`f5bc92aca0`): Overlapping config changes from using latest instead of committed config
- Bug #20 (`347a7e635b`): Non-voters blocked from elections → cluster deadlock (#4234)
- Bug #21 (`c665c97ac2`): Premature leader step-down checking only committed config
- Bug #22 (`15714934a8`): Stale config in `propose_config_change` (#5289 root cause chain)
- Issue #4824: Raft fuzzer reproduces committed ≠ active_config

**Code Analysis Evidence**:
- DA-1: Tautological invariant at line 852

**Affected Code Paths**:
- `propose_config_change()` (lines 216-257)
- `leader_continue_reconfiguration()` (lines 1943-1977)
- `update_readiness_for_change()` (lines 1243-1270)

---

### Family 3: Term/Mode Transition Ordering (HIGH)

**Mechanism**: The order of `update_term` and `become_follower`, and async spawning of transitions, creates windows of inconsistent state.

**Historical Evidence**:
- Bug #22 (`15714934a8`): `update_term` before `become_follower` corrupted state
- Bug #21 (`c665c97ac2`): `note_term` spawned coroutine when already follower → crash
- Bug #1 (`92fa1e644c`): Non-interruptible mutex during transitions

**Code Analysis Evidence**:
- DA-3: Deferred step-down via spawned coroutine creates stale-term window

**Affected Code Paths**:
- `candidate_or_leader_note_term()` (lines 1980-2026)
- `candidate_or_leader_become_follower()` (lines 1272-1283)
- `update_term()` (lines 1108-1120)

---

### Family 4: Election Timer / Liveness (MEDIUM)

**Mechanism**: Election timer bugs cause starvation, livelock, or unnecessary churn.

**Historical Evidence**:
- Bug #6 (`15a3175b3e`): Rejected RequestVote reset timer → starvation
- Bug #7 (`ad4f9d02eb`): Mutex held during sleep → deadlock
- Bug #8 (`96fefea48b`): Shared timer for leader/candidate RPCs
- Bug #15 (`67a57bb37c`): Timer not reset after stepping down
- Issue #6038: Livelock with 100+ tables

---

### Family 5: Snapshot-Log Consistency (MEDIUM)

**Mechanism**: Snapshot operations can leave log in inconsistent state at boundary conditions.

**Historical Evidence**:
- Bug #3 (`9871a1a410`): Entire log discarded instead of just prefix
- Bug #16 (`af6ad0f478`): Valid AppendEntries rejected at snapshot boundary
- Bug #17 (`3fb075a7fd`): Incompatible log entries not cleared on snapshot install

---

### Family 6: Persistence Correctness (MEDIUM)

**Mechanism**: Storage layer bugs can corrupt persistent state.

**Historical Evidence**:
- Bug #18 (`3889ed0b22`): Commit index not persisted → state machine regression
- Bug #19 (`cf97eb5b05`): Hex encoding + off-by-one → log corruption
- Bug #26 (`9f12645d47`): Writes interrupted mid-transaction
- Bug #27 (`a37c84b65e`): Implicit transaction commit on partial writes

**Code Analysis Evidence**:
- DA-6: In-memory state mutated before txn.commit()

---

## 6. Hotspot Analysis

| Component | Historical Bugs | Open Issues | Priority |
|-----------|----------------|-------------|----------|
| Virtual heartbeat | 4 | 1 (#4357) | HIGH |
| Configuration change | 4 | 1 (#4824) | HIGH |
| Term/mode transitions | 3 | 0 | HIGH |
| Election timers | 5 | 0 | MEDIUM |
| Persistence | 4 | 0 | MEDIUM |
| Snapshot/log | 3 | 0 | MEDIUM |
| Replication | 3 | 0 | MEDIUM |
