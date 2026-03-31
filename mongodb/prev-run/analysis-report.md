# Analysis Report: MongoDB Distributed Transactions (2PC Coordinator)

## Coverage Statistics

| Metric | Count |
|--------|-------|
| GitHub/JIRA issues collected | 45+ |
| Issues deeply read (full discussion) | 33 |
| Issues confirmed as real bugs | 30 |
| Issues excluded as false positive | 2 |
| Issues excluded as operational/metrics | 3 |
| TLA+ spec files fully read | 8 |
| C++ source files analyzed | 5 (via GitHub API) |
| Bug families identified | 6 |
| Open TODOs in C++ source | 6 |
| Dead code items in TLA+ spec | 10 |

---

## Phase 1: Reconnaissance

### System Architecture

MongoDB's distributed transaction system has three layers:

1. **mongos Router** (`transaction_router.cpp`, ~121K): Tracks participant shards, classifies transactions into commit paths (single-shard / read-only / single-write-shard / full 2PC), sends `coordinateCommitTransaction` to coordinator.

2. **Coordinator Shard** (`transaction_coordinator.cpp` ~34K, `transaction_coordinator_util.cpp` ~49K): Drives the 2PC protocol — writes participant list, sends prepare, collects votes, writes decision, sends commit/abort, deletes coordinator doc.

3. **Storage Layer** (WiredTiger): Manages snapshots, prepare conflicts, oplog entries. Modeled abstractly in `Storage.tla`.

### 2PC Protocol Steps

```
Router                          Coordinator                    Participants
  |                                |                              |
  |-- coordinateCommitTransaction -->                              |
  |                                |-- write participant list ---  |
  |                                |   (majority commit)          |
  |                                |-- prepareTransaction ------> |
  |                                |                              |-- prepare + vote
  |                                |<-- voteCommit (prepareTs) ---|
  |                                |                              |
  |                                |-- write decision ----------  |
  |                                |   (majority commit)          |
  |                                |-- commitTransaction -------> |
  |                                |   (commitTs=max(prepareTs))  |
  |                                |<-- ack --------------------- |
  |                                |                              |
  |                                |-- delete coordinator doc --- |
  |                                |   (w:1 best-effort)          |
```

### Commit Path Classification

| CommitType | Condition | Protocol |
|---|---|---|
| kNoShards | 0 participants | Return OK immediately |
| kSingleShard | 1 participant | Direct commitTransaction |
| kReadOnly | N read-only, 0 write | Direct commit to all |
| kSingleWriteShard | 1 write + N read-only | Commit reads first, then write shard |
| kTwoPhaseCommit | 2+ write shards | Full 2PC via coordinateCommitTransaction |
| kRecoverWithToken | Retry after failover | coordinateCommitTransaction with empty participants |

### TLA+ Spec Landscape

| Spec | Source | LOC | Status |
|------|--------|-----|--------|
| `MultiShardTxn.tla` | vldb25-dist-txns (MongoDB official) | 594 | Baseline — missing Restart, MoveKey, abort |
| `Storage.tla` | vldb25-dist-txns | 446 | Storage layer with dead code |
| `base.tla` | case-studies/mongodb/spec/ | 870 | Modified — fixed vars tuple, improved Restart (still dead) |
| `MC.tla` | case-studies/mongodb/spec/ | 65 | Counter-bounded fault injection wrapper |

---

## Phase 2: Bug Archaeology

### All Confirmed Bugs (Grouped by Family)

#### Family 1: 2PC Coordinator Recovery on Failover

| Ticket | Severity | Summary | Root Cause | Fixed |
|--------|----------|---------|------------|-------|
| SERVER-106075 | Critical | Prepared txns with apiVersion fail after failover; coordinator misclassifies error as ack → torn commit | apiVersion not persisted in oplog; error category gap | 7.0.26, 8.0.16 |
| SERVER-61483 | Critical | Resharding coordinator fails to recover abort decision on step-up → commits instead → data loss | Missing `.onError()` handler for reading coordinator doc | 5.0.5 |
| SERVER-48307 | Critical | Single-write-shard retry incorrectly reports "definitive abort" after failover → duplicate execution | Router retry logic doesn't handle read-only shard failover | 4.2.8 |
| SERVER-38918 | High | ShardNotFound during commit delivery → `fassert` crash (no safe alternative) | Shard removed during 2PC | OPEN TODO |
| SERVER-82883 | High | Coordinator recovery blocks on WiredTiger ticket acquisition after step-up | Recovery ops compete for tickets with prepared txns | 7.0.5 |
| SERVER-38307 | Medium | Corrupt coordinator doc crashes entire recovery process | No try/catch during doc parsing | OPEN TODO |

#### Family 2: Session Reaper vs. Active 2PC Races

| Ticket | Severity | Summary | Root Cause | Fixed |
|--------|----------|---------|------------|-------|
| SERVER-105751 | Critical | Router reaps TransactionParticipant with prepared txn; destructor aborts; coordinator treats as success → torn commit | Reaper lacks guard against prepared sessions | 8.0.13 |
| SERVER-61816 | High | Reaper kills local transaction before coordinator sends abort → no-op write hangs forever | Reaper and coordinator race on same transaction | 5.0.6 |
| SERVER-92607 | High | Eager reaping destroys yielded TransactionRouter → invariant crash on resume | Reaper doesn't check yielded state | 8.1.0 |
| SERVER-50365 | Medium | Transaction reaper deadlocks with WiredTiger cache pressure | Cache eviction blocked by transactions needing abort | Fixed |

#### Family 3: Resource Contention Deadlocks During Prepared State

| Ticket | Severity | Summary | Root Cause | Fixed |
|--------|----------|---------|------------|-------|
| SERVER-60682 | Critical | Coordinator blocks on write ticket to persist decision → cascading deadlock | Ticket pool shared between coordinator and blocked ops | 5.0.6 |
| SERVER-65821 | High | setFCV holds global S lock, waits for prepared txns; coordinator needs IX → deadlock | Lock ordering: S(global) vs IX(config collection) | 5.0.10 |
| SERVER-41980 | High | Prepared txns release ticket but hold IX lock; non-txn ops get tickets but block on lock; commitTransaction can't get ticket | Ticket acquired after lock during unstash (ordering violation) | 4.2.0-rc5 |
| SERVER-57476 | High | Oplog slot held during prepare conflict retry blocks replication → circular deadlock | Slot not released before retry loop | 5.0.0-rc2 |
| SERVER-82883 | Medium | (See Family 1) Coordinator recovery acquires tickets unnecessarily | Same ticket contention family | 7.0.5 |

#### Family 4: Chunk Migration / Resharding During Transactions

| Ticket | Severity | Summary | Root Cause | Fixed |
|--------|----------|---------|------------|-------|
| SERVER-71219 | Critical | Migration misses writes from prepared txns after failover → data loss | Sharding handler callback only registered during prepare | 6.0.5 |
| SERVER-68361 | Critical | Migration misses documents with changed shard keys | `getPreImageDocumentKey` returns empty | 6.0.4 |
| SERVER-78050 | Critical | Chunk migration pins stale snapshot → misses concurrent writes → data loss | `abandonSnapshot()` not called after splicing update list | 7.0.0-rc4 |
| SERVER-89529 | High | Retryable writes during resharding create empty-namespace noop entries → duplicate execution | Namespace filter excludes empty namespace entries | 8.0.5 |
| SERVER-99969 | High | Cross-shard retryable txn in prepared state blocks migration session cloner | Session cloner hits RetryableTransactionInProgress | 8.2.0 |
| SERVER-55573 | High | Deadlock between stepdown and chunk migration | Worker op contexts lack session association | 5.0.0-rc1 |

#### Family 5: Stale Router Cache / Cross-Shard Snapshot Inconsistency

| Ticket | Severity | Summary | Root Cause | Fixed |
|--------|----------|---------|------------|-------|
| SERVER-42856 | High | Stale mongos routes writes to wrong shard | Timestamp mismatch between routing version and snapshot | 4.2.1 |
| SERVER-84760 | High | Snapshot isolation violation: data from one snapshot + catalog from another | DDL not isolated within transactions (<7.0) | Won't Fix <7.0 |
| SERVER-88746 | High | Writes don't conflict with concurrent drop/rename | Write path skips catalog consistency check | 7.0.10 |
| SERVER-107699 | High | Sub-router uses stale atClusterTime from previous transaction | State reset ordering in TransactionRouter | 8.2.0 |
| SERVER-84723 | High | Per-shard independent snapshots + concurrent DDL → inconsistent metadata | No cross-shard DDL consistency coordination | 7.0.6 |

#### Family 6: Abort/Commit Decision Propagation Gaps

| Ticket | Severity | Summary | Root Cause | Fixed |
|--------|----------|---------|------------|-------|
| SERVER-66067 | Critical | Transaction API best-effort abort interferes with 2PC commit → partial commit | Layer mismatch: Transaction API bypasses TransactionRouter | Fixed |
| SERVER-116284 | High | commitTransaction sender destroyed before reaching all shards → dangling prepared txns | AsyncRequestsSender destruction on error | 8.2.7 |
| SERVER-116340 | Medium | abortTransaction on different connection finds stale txn number → NoSuchTransaction | Connection-level txn number desync | OPEN |

### Jepsen Findings (MongoDB 4.2.6, May 2020)

Even at strongest read/write concern levels, Jepsen found:
- **Read skew**: Transactions observed partial effects of prior transactions
- **Cyclic information flow (G1c)**: Two snapshot-isolated transactions observed each other's effects
- **Retrocausal transactions**: Transaction read result of its own future write (retry mechanism bug)
- **Duplicate writes**: Same write appeared to execute twice
- Root cause: Transaction retry mechanism bug, patched in 4.2.8

### Additional Referenced Tickets

| Ticket | Summary | Status |
|--------|---------|--------|
| SERVER-37884 | Coordinator must make state durable before sending prepare/decision | Fixed 4.1.7 |
| SERVER-39626 | Majority-committed oplog entries may be rolled back on minority nodes | Fixed |
| SERVER-42772 | Race between joinPreviousRound and coordinator destruction → invariant crash | Fixed 4.2.7 |
| SERVER-45009 | Coordinator tasks delay shutdown (join before interrupt ordering) | Fixed 4.2.7 |
| SERVER-60685 | Coordinator interrupt uses wrong error category → crash in destructor | Fixed 5.0.6 |
| SERVER-67457 | Resharding abort stalls config server indefinitely | Fixed |
| SERVER-115594 | Skip tickets when deleting coordinator doc (Family 3 continuation) | Fixed 8.2 |

---

## Phase 3: Deep Analysis

### TLA+ Specification Gaps

#### Gap 1: Restart Action is Broken Dead Code

**Location**: `base.tla` lines 185-209, `MultiShardTxn.tla` lines 184-197

The `Restart(s)` action is NOT in the Next relation in either spec. In the upstream spec:
- Missing variables in UNCHANGED: `shardOps`, `rCatalog`, `txnStatus`, `stableTs`, `oldestTs`, `allDurableTs`
- `txnSnapshots` reset is commented out
- Would produce TLC errors if enabled (unconstrained variables)

In the modified `base.tla`:
- `shardPreparedTxns'[s] = {}` but `txnSnapshots` preserves prepared state
- After restart, prepared transactions have `txnSnapshots[s][t].prepared = TRUE` but `t ∉ shardPreparedTxns[s]` and `t ∉ shardTxns[s]`
- No action can subsequently process these transactions → permanently orphaned
- The spec comment claims "Prepared txns are preserved (majority committed)" but functionally they are lost

**Impact**: The entire coordinator recovery mechanism (Family 1's primary target) is not testable.

#### Gap 2: No Coordinator Abort Decision

**Location**: `base.tla` / `MultiShardTxn.tla`

The 2PC protocol has only a commit decision (`ShardTxnCoordinatorDecideCommit`). There is:
- No `ShardTxnCoordinatorDecideAbort`
- No vote-to-abort message type
- `RouterTxnAbort` is fully commented out
- `msgsAbort` is declared but never written to or read from (completely dead)

If any participant aborts via `ShardTxnAbort(s, tid)`:
- `coordCommitVotes[s][tid]` never gets a vote from that shard
- `ShardTxnCoordinatorDecideCommit` guard (`votes = all participants`) never satisfied
- Coordinator hangs forever

**Impact**: Cannot model participant failure during 2PC. Cannot verify abort-path correctness (Family 6).

#### Gap 3: MoveKey and Stale Cache are Dead Code

**Location**: `base.tla` lines 547-552

`MoveKey` updates `catalog` but not `rCatalog` (correct modeling of stale cache). However:
- Not in Next
- No `RefreshCatalog` action exists
- No shard version check exists on any shard operation
- After `MoveKey`, router routes to wrong shard; shard processes without validating ownership

**Impact**: Cannot model migration-transaction interaction (Family 4).

#### Gap 4: Atomic Coordinator Decision

**Location**: `base.tla` lines 474-482

`ShardTxnCoordinatorDecideCommit` atomically decides AND broadcasts commit messages. In reality:
1. Decision is written to `config.transaction_coordinators` (majority write)
2. Commit messages are sent to participants
3. If coordinator crashes between 1 and 2, recovery replays from the persisted decision

The TLA+ spec collapses this into one step, hiding the crash window that causes Family 1 bugs.

#### Gap 5: Storage Layer Dead Code

**Location**: `Storage.tla`

| Dead Code | Issue |
|-----------|-------|
| `WriteReadConflictExists` (line 144) | Tautological: `mtxnSnapshots[tOther].ts = mtxnSnapshots[tOther].ts` (compares to itself) |
| `TxnCanStart` (line 221) | Missing node parameter `[n]` on snapshot access |
| `TransactionRemove` (line 309) | Never called from base.tla |
| `SetStableTimestamp` (line 390) | Never called — `stableTs` stays 0, making all guards trivially true |
| `SetOldestTimestamp` (line 395) | Never called |
| `RollbackToStable` (line 402) | Never called |
| `commitIndex` | Declared, initialized, never modified |

#### Gap 6: Network Model is Perfect

Messages are modeled as sets — no loss, no duplication, no reordering. Additionally:
- `msgsPrepare` messages are never consumed (remain in set forever after being "processed")
- `msgsAbort` is completely dead
- `msgsVoteCommit` and `msgsCommit` are properly consumed

#### Gap 7: Spurious Quantification in Next

Six disjuncts in Next quantify over `k ∈ Keys` but never use `k`:
```
\/ \E s \in Shard, tid \in TxId, k \in Keys: ShardTxnCoordinateCommit(s, tid)
```
This multiplies TLC's search space by `|Keys|` per action with zero semantic effect.

#### Gap 8: Global Abort Check is Unrealistic

**Location**: `base.tla` lines 261, 288

Router operations check `~\E as \in Shard : aborted[as][tid]` — the router instantaneously reads the global abort state of all shards. In reality, the router learns about aborts through error responses. This makes the spec overly deterministic about abort propagation.

### C++ Implementation Gaps (from source analysis)

#### C++ Gap 1: fassert on ShardNotFound During Commit (SERVER-38918)

`transaction_coordinator_util.cpp:951`: If a shard is removed from the cluster after voting to commit, the coordinator crashes with `fassert(51068, false)`. There is no safe protocol action — the TODO has been open since 2018.

#### C++ Gap 2: LOGV2_FATAL on Unexpected Errors

`transaction_coordinator.cpp:~625`: If the coordinator encounters a non-NotPrimary, non-Shutdown error after persisting participants, it crashes the process. This is deliberate (force failover) but means any unexpected error during 2PC becomes a process crash.

#### C++ Gap 3: No Idempotency Check for Prepare Responses

`PrepareVoteConsensus` accumulates votes without checking for duplicates from the same shard. Each shard's future resolves exactly once, so this is safe in practice, but a formal model should verify this property.

#### C++ Gap 4: w:1 Coordinator Doc Deletion (SERVER-120584)

The final cleanup step uses `{w: 1}` write concern. If the primary crashes after local delete but before replication, the new primary re-discovers the coordinator doc and re-drives the decision. This is idempotent but creates recovery work.

---

## Cross-Reference: Bug Families vs. TLA+ Spec Coverage

| Bug Family | # Bugs | Currently Modeled? | Spec Gap | Priority |
|---|---|---|---|---|
| 1. Coordinator Recovery | 6 | NO (Restart dead) | Restart broken, no coordinator doc persistence | HIGH |
| 2. Reaper vs. Active Txn | 4 | NO | No reaper action | HIGH |
| 3. Resource Deadlocks | 5 | NO | No ticket/lock model | MEDIUM |
| 4. Migration + Txn | 6 | NO (MoveKey dead) | MoveKey dead, no shard version | HIGH |
| 5. Stale Cache / Snapshot | 5 | PARTIAL (rCatalog exists) | MoveKey dead, no DDL | MEDIUM |
| 6. Abort/Commit Propagation | 3 | NO | No abort decision, msgsAbort dead | MEDIUM |

---

## Excluded Issues (False Positives / Not Relevant)

| Issue | Reason for Exclusion |
|-------|---------------------|
| SERVER-41615 | Diagnostics-only: coordinator diagnostics should distinguish failover-resumed coordinators |
| SERVER-42809 | Metrics-only: track 2PC metrics for coordinator |
| SERVER-40983 | Observability-only: track single transaction metrics on mongos for currentOp |
