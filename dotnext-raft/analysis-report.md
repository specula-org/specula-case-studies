# Analysis Report: dotnet/dotNext Raft

## Executive Summary

dotnet/dotNext is a production-grade C# Raft consensus library with ~17K LOC (6K core protocol, 3.6K WAL, 1.4K transport, 2K HTTP transport). Analysis uncovered **1 new correctness bug** (election restriction deviation), **1 copy-paste bug** (event handler wiring), and **5 bug families** spanning 42+ historical bug-fix commits and 21+ confirmed GitHub issues. The most significant finding is a sideband configuration change protocol that deviates fundamentally from the Raft paper.

---

## Coverage Statistics

| Metric | Count |
|--------|-------|
| Git bug-fix commits analyzed | 42 |
| GitHub issues deeply read (with comments) | 35+ |
| Confirmed bugs from issues | 21 |
| False positives excluded | 5 (user error/misconfiguration) |
| Core files fully read | 25+ |
| New findings from deep analysis | 12 |
| Bug families identified | 5 |

---

## Phase 1: Structural Map

### Repository Layout

```
src/cluster/DotNext.Net.Cluster/Net/Cluster/Consensus/Raft/
├── RaftCluster.cs                    # Main coordinator, RPC handlers
├── RaftCluster.TermTracking.cs       # ReplicationWithSenderTermDetector
├── RaftCluster.DefaultImpl.cs        # ILocalMember implementation
├── RaftCluster.Membership.cs         # Member add/remove
├── RaftCluster.Configuration.cs      # Node configuration
├── LeaderState.cs                    # Leader orchestration
├── LeaderState.Replication.cs        # Per-member replicator
├── LeaderState.Lease.cs              # Leader lease
├── LeaderState.Context.cs            # Replicator context
├── LeaderState.Monitoring.cs         # Heartbeat monitoring
├── CandidateState.cs                 # Election logic
├── FollowerState.cs                  # Timeout tracking
├── StandbyState.cs                   # Bootstrap mode
├── RefreshableState.cs               # Base for timeout states
├── RaftState.cs                      # Abstract state base
├── ConsensusState.cs                 # Consensus state base
├── IPersistentState.cs               # Persistence interface
├── PersistentStateExtensions.cs      # IsUpToDateAsync, ContainsAsync
├── ConsensusOnlyState.cs             # In-memory persistence
├── ElectionTimeout.cs                # Timeout randomization
├── Membership/
│   ├── ClusterConfigurationStorage.cs
│   ├── InMemoryClusterConfigurationStorage.cs
│   ├── PersistentClusterConfigurationStorage.cs
│   ├── IClusterConfigurationStorage.cs
│   └── IClusterConfiguration.cs
└── StateMachine/
    ├── WriteAheadLog.cs              # Main WAL (+ 13 partial files)
    ├── WriteAheadLog.NodeState.cs    # Term/vote persistence
    ├── WriteAheadLog.Flusher.cs      # Flush ordering
    ├── WriteAheadLog.Cleaner.cs      # Log compaction
    ├── WriteAheadLog.Applier.cs      # Entry application
    └── WriteAheadLog.LockManagement.cs
```

### Concurrency Model

- **Single async heartbeat loop**: `LeaderState.DoHeartbeats()` runs one round at a time
- **Parallel replication per round**: `ForkHeartbeats()` spawns per-member tasks via `TaskCompletionPipe`
- **Async state transitions**: All transitions dispatched via `ThreadPool.UnsafeQueueUserWorkItem`, serialized by `AsyncExclusiveLock transitionLock`
- **WAL locking**: 5 lock types (Read, ReadBarrier, Append, Commit, Overwrite) managed by `QueuedSynchronizer`
- **Config storage**: `AsyncExclusiveLock` per storage instance
- **Copy-on-write member list**: `ImmutableHashSet` with `MemoryBarrierProcessWide()`

### Key Architectural Differences from Standard Raft

1. **Combined heartbeat/replication** — no separate heartbeat mechanism
2. **No matchIndex array** — all-or-nothing quorum counting per round
3. **Sideband configuration** — config NOT stored as log entries
4. **Asynchronous state transitions** — ThreadPool dispatch with WeakGCHandle guards
5. **Term+vote atomic persistence** — single `WriteAsync` in `NodeState`

---

## Phase 2: Bug Archaeology

### Hotspot Analysis (files most frequently in bug-fix commits)

| Rank | File | Bug-Fix Touches |
|------|------|----------------|
| 1 | `RaftCluster.cs` | 82 |
| 2 | `PersistentState.cs` (now WriteAheadLog) | 72 |
| 3 | `LeaderState.cs` | 51 |
| 4 | `Http/RaftHttpCluster.cs` | 40 |
| 5 | `PersistentState.Partition.cs` | 33 |

### Bug-Fix Commits by Component

#### State Transitions (7 bugs)

| Commit | Summary | Severity |
|--------|---------|----------|
| `2e2740505` | Deadlock when two candidates vote simultaneously (TOCTOU on term read) | CRITICAL |
| `9777f177a` | PreVote HTTP handler rejected unknown senders, causing infinite loop | HIGH |
| `cd51b6a91` | Race between state stop and dispose — use-after-dispose | HIGH |
| `10f580acf` | Synchronous state transitions from async continuations — re-entrancy | HIGH |
| `67d40b7d4` | Race between follower timeout and concurrent vote refresh (#168) | MEDIUM |
| `a5b4f4b38` | LeaderChanged event fires before LeadershipToken valid | MEDIUM |
| `4e689e935` | Leader stickiness `lastUpdated` not refreshed on election | MEDIUM |

#### Vote/Term Handling (7 bugs)

| Commit | Summary | Severity |
|--------|---------|----------|
| `5e5fe1637` | Term not incremented when transitioning to Candidate | CRITICAL |
| `554bbba51` | Candidate does not vote for self (self-vote not persisted) | CRITICAL |
| `e8c8c4bf8` | Term write non-volatile — stale reads possible | HIGH |
| `b371600d7` | Term double-check after lock acquisition missing | HIGH |
| `ecbbdc030` | Term update and last-vote erasure not atomic (separate `Task.WhenAll`) | HIGH |
| `ffd66deae` | Vote/PreVote accepted from unknown cluster members | MEDIUM |
| `287762551` | Pre-vote optimization caused regression (reverted) | MEDIUM |

#### Log Replication / Commit Index (8 bugs)

| Commit | Summary | Severity |
|--------|---------|----------|
| `842459806` | Commit count calculation off-by-one (#24) | CRITICAL |
| `ee39f3da5` | AppendEntries skipped entries when prevLogIndex > localCommitIndex | HIGH |
| `ebd3b96c0` | WAL partition write position calculated incorrectly | HIGH |
| `227403b5b` | WAL aux reader used relative index instead of absolute | HIGH |
| `549e2fbd3` | Applied index not updated on snapshot installation | HIGH |
| `c7ee41bbc` | Cleanup boundary off-by-one in flusher | HIGH |
| `91ca62267` | NextIndex could go negative | MEDIUM |
| `c180f2b66` | NextIndex bound check missing for empty heartbeats | MEDIUM |

#### Leader Lease (3 bugs)

| Commit | Summary | Severity |
|--------|---------|----------|
| `44268e20e` / `f0072cc4e` | Lease renewal race, ObjectDisposedException — complete rewrite | HIGH |
| `7b27337f6` | Lease timing measured from commit, not heartbeat start | HIGH |
| `cc638a7b9` | Lease renewal counted stale-term responses | MEDIUM |

#### Configuration / Membership (3+ bugs)

| Commit | Summary | Severity |
|--------|---------|----------|
| `390e5d1b2` | IsRemote was stored, not computed — cluster recovery fails | HIGH |
| `966635fe7` | Config storage methods not synchronized | MEDIUM |
| `8ed5ff591` | Concurrent reads of persistent config file unsafe | MEDIUM |
| `786ed9f12` | Missing decrement of catch-up rounds (infinite loop) | MEDIUM |

#### WAL / Persistence (5 bugs)

| Commit | Summary | Severity |
|--------|---------|----------|
| `4cf8439ba` | Log compaction deadlock (foreground vs background) | HIGH |
| `2d7e323fd` | Background compaction index calculation wrong | HIGH |
| `2f5a0c0b0` | Memory leak from log entry list allocation (#184) | MEDIUM |
| `aadf32242` | Stack overflow in async dispose (#63) | MEDIUM |
| `80aa3390b` | Consistency check too permissive | MEDIUM |

### GitHub Issues — Confirmed Bugs

| # | Title | Component | Severity | Status |
|---|-------|-----------|----------|--------|
| 221 | Leader deadlock in 16-node cluster | State transitions | CRITICAL | Fixed v5.0.3 |
| 185 | Cluster stops making progress (commit stuck) | Replication | CRITICAL | Fixed v4.13.1 |
| 244/242 | WAL crash from unsafe I/O cancellation | WAL | CRITICAL | Fixed v5.7.0 |
| 24 | Commit index exceeds last log index | WAL | CRITICAL | Fixed v2.12.1 |
| 168 | Short-lived leader election at startup | Election | HIGH | Fixed v4.12.2 |
| 153 | Cluster fails to elect after nodes rejoin | Membership | HIGH | Fixed v4.7.x |
| 105 | Loading persisted config doesn't work | Config | HIGH | Fixed v4.4.1 |
| 108 | Starting nodes in sequence breaks persistent config | Config | HIGH | Fixed v4.5.0 |
| 277 | Membership modification blocked after failure | Membership | HIGH | Closed |
| 233 | ConnectTimeout not respected; accidental snapshot | Transport | HIGH | Fixed v5.5.0 |
| 184 | Leader memory leak when node is down | WAL/Memory | HIGH | Fixed v4.13.1 |
| 57 | WAL Content-Length corruption | WAL/HTTP | HIGH | Fixed v3.1.0 |
| PR 170 | CommitChecker.index field not initialized | Replication | HIGH | Fixed v4.12.2 |
| 147 | Replicator.ReadAsync incorrectly returns false | Replication | MEDIUM | Fixed v4.8.0 |
| 99 | NextIndex initialization wrong for custom IPersistentState | Replication | MEDIUM | Fixed v4.2.0 |
| 89 | Unexpected election timeouts on vote rejection | Election | MEDIUM | Fixed |
| 149 | Infinite loop in leadership with fast member start | Election | MEDIUM | Fixed |

### Excluded Issues (False Positives)

| # | Reason |
|---|--------|
| 135 | User error: incorrect ClusterMemberId usage |
| 130 | Could not reproduce; user setup issue |
| 109 | Misconfigured allowedNetworks/file permissions |
| 100 | By design: AppendAndCommitAsync error handling |
| 15 | Unrelated (Metaprogramming library) |

---

## Phase 3: Deep Analysis Findings

### New Findings

#### F-17: IsUpToDateAsync Election Restriction Bug (HIGH — Liveness)

**File**: `PersistentStateExtensions.cs:29-32`

```csharp
internal static async ValueTask<bool> IsUpToDateAsync(
    this IAuditTrail<IRaftLogEntry> auditTrail, long index, long term, CancellationToken token)
{
    var localIndex = auditTrail.LastEntryIndex;
    return index >= localIndex
        && term >= await auditTrail.GetTermAsync(localIndex, token).ConfigureAwait(false);
}
```

**Bug**: Uses `index >= localIndex && term >= localLastTerm` (conjunctive). The Raft paper requires `(term > localTerm) || (term == localTerm && index >= localIndex)` (disjunctive).

**Scenario**: Candidate with lastIndex=3, lastTerm=5 requesting vote from voter with lastIndex=10, lastTerm=3. Paper says grant (term 5 > term 3), code says reject (3 < 10 fails). The candidate has a more up-to-date log (higher term) but shorter, and is incorrectly rejected.

**Impact**: Liveness bug, not safety. The code is STRICTER than the paper, so ElectionSafety is preserved. But the cluster may fail to elect a leader in certain partition/recovery scenarios where the only valid candidate has a shorter log with a higher last term.

**Classification**: Model-checkable (MC-1)

#### F-27: MemberAdded Event Remove Accessor Bug (LOW — Copy-Paste)

**File**: `RaftCluster.Membership.cs:96-100`

```csharp
public event Action<...> MemberAdded
{
    add => memberAddedHandlers += value;
    remove => memberRemovedHandlers -= value;  // BUG: should be memberAddedHandlers
}
```

**Impact**: Unsubscribing from `MemberAdded` incorrectly modifies `memberRemovedHandlers`. Memory leak + corrupted event subscriptions.

**Classification**: Code-review-only (CR-1). Trivial fix.

#### F-18/F-19: No Sender Membership Check on AppendEntries/InstallSnapshot (MEDIUM)

**File**: `RaftCluster.cs:594` (AppendEntries) and `RaftCluster.cs:537` (InstallSnapshot)

Unlike `VoteAsync` (line 804: `!members.ContainsKey(sender)`) and `PreVoteAsync` (line 718: `members.ContainsKey(sender)`), neither `AppendEntriesAsync` nor `InstallSnapshotAsync` verifies that the sender is a known cluster member. A node not in the membership could send entries and be accepted as leader.

**Classification**: Model-checkable (MC-3)

#### Sideband Config: Config Applied on Quorum, Not Commit (HIGH)

**File**: `LeaderState.cs:189-191`

```csharp
if (quorum >= majority)
{
    await configurationStorage.ApplyAsync(Token).ConfigureAwait(false);
}
```

The leader applies proposed config to active after ANY heartbeat round achieving quorum, regardless of whether the config change is committed to a majority via the log. Since config is not a log entry, it has no commit semantics. This means config can be "applied" even if a minority of nodes have the proposed config.

**Classification**: Model-checkable (MC-2)

#### Non-Atomic Persistent Config Apply (MEDIUM)

**File**: `PersistentClusterConfigurationStorage.cs:165-176`

`ApplyProposedAsync` performs:
1. Copy proposed.list → active.list (via truncate + write + flush)
2. Fire change events
3. Update in-memory cache
4. Clear proposed.list

A crash between steps 1 and 4 leaves both files populated. A crash mid-step-1 (after truncation but before flush) corrupts the active configuration.

**Classification**: Model-checkable (MC-5)

#### Follower Timeout Reset Before Vote Decision (LOW)

**File**: `RaftCluster.cs:825-828`

`Refresh()` is called on the follower state BEFORE checking `IsVotedFor` and `IsUpToDateAsync`. If the vote is ultimately rejected, the election timer was still reset. This is conservative (delays elections) but deviates from the Raft paper which says reset timer only when granting a vote.

**Classification**: Test-verifiable (TV-3)

#### Leader Stickiness Check Not Re-Verified Inside Lock (LOW)

**File**: `RaftCluster.cs:804`

The `lastUpdated.Elapsed < ElectionTimeout` check (leader stickiness) is performed before acquiring `transitionLock`. Inside the lock, this check is NOT repeated. A heartbeat arriving between the check and lock acquisition could make the stickiness condition true, but the vote would still be granted.

**Classification**: Test-verifiable (TV-2)

### Verified Non-Issues

1. **Vote counting scheme** (`CandidateState.cs:79-131`): The +1/-1 counting with `votes > 0` check is mathematically equivalent to strict majority. With N members: `votes > 0` ⟺ `yes_count > N/2` ⟺ strict majority. CORRECT.

2. **Term+vote atomic persistence** (`WriteAheadLog.NodeState.cs`): Both are written in a single `WriteAsync(buffer, offset:0)` call with `WriteThrough`. CORRECT.

3. **NextIndex management** (`LeaderState.Replication.cs`): Initialized to `lastLogIndex+1`, decremented by 1 on failure, advanced on success. Access is single-threaded within the heartbeat loop. CORRECT.

4. **Combined heartbeat/replication**: Every heartbeat round also replicates entries. Empty heartbeats occur naturally when `nextIndex > currentIndex`. This is a valid optimization, not a bug.

5. **Commit quorum with current-term check** (`LeaderState.cs:149-183`): `commitQuorum` counts only `ReplicatedWithLeaderTerm` responses, ensuring the Raft Section 5.4.2 requirement is met. CORRECT.

---

## Phase 4: Bug Family Synthesis

See `modeling-brief.md` for the complete Bug Family analysis, modeling recommendations, proposed extensions, proposed invariants, and findings classification.

### Summary of Bug Families

| # | Family | Historical Bugs | New Findings | Priority |
|---|--------|----------------|--------------|----------|
| 1 | Election Restriction Deviation | 4+ | 1 (F-17) | HIGH |
| 2 | Sideband Configuration Change Protocol | 5+ | 3 | HIGH |
| 3 | State Transition Atomicity and Ordering | 5+ | 1 | MEDIUM |
| 4 | Leader Lease Correctness | 3 | 0 | MEDIUM |
| 5 | WAL Commit Index and Persistence Ordering | 6+ | 0 | MEDIUM |

### Severity Distribution

| Severity | Historical | New | Total |
|----------|-----------|-----|-------|
| CRITICAL | 5 | 0 | 5 |
| HIGH | 20 | 2 | 22 |
| MEDIUM | 17 | 2 | 19 |
| LOW | 0 | 2 | 2 |
