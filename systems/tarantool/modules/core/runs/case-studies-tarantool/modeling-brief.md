# Modeling Brief: tarantool/tarantool Raft Consensus

## 1. System Overview

- **System**: tarantool/tarantool — C-based Raft leader election engine for Tarantool database
- **Language**: C, ~2200 LOC core logic (`src/lib/raft/raft.c` + `src/box/raft.c`)
- **Protocol**: Raft leader election only (Ongaro 2014) — log replication handled separately
- **Key architectural choices**:
  - Uses **vclocks** (vector clocks) instead of single log index for vote eligibility
  - **Dual state tracking**: `volatile_term`/`volatile_vote` (in-memory) vs `term`/`vote` (persisted). Volatile state used for decisions; persisted state for broadcasts.
  - **Leader witness map**: Bitmap of peers who see the leader — acts as implicit pre-vote, gating all elections via `if (leader_witness_map != 0) return`
  - **Multi-pass WAL write**: Term and vote persisted separately. Foreign votes deferred until term is flushed (so vclock is current before comparing).
  - WAL write failure is fatal (panic)
- **Concurrency model**: Single-threaded cooperative fibers. State machine runs synchronously (no yields); separate worker fiber for async WAL writes and broadcasts.

## 2. Bug Families

### Family 1: Leader Witness Map Election Blocking (HIGH)

**Mechanism**: Stale `is_leader_seen` witness bits in `leader_witness_map` prevent all elections by blocking `raft_sm_election_update` (raft.c:346). Bits can become stale through ordering issues, leader resignations, or disabled nodes.

**Evidence**:
- Historical: #12018 — disabled nodes broadcast stale `is_leader_seen=true`, causing permanent election deadlock (Critical, FIXED)
- Historical: #7512 — relay heartbeats mask TX thread hang, followers never detect leader death (High, FIXED with strict fencing)
- Code analysis: raft.c:527-531 — `raft_process_term` (clears witness map) called BEFORE `raft_notify_is_leader_seen` (re-sets bits). A higher-term message with `is_leader_seen=true` sets a stale bit referring to the old term's leader.
- Code analysis: raft.c:605-627 — leader resignation handler only clears self witness bit; remote bits survive. Non-cfg-candidate nodes have no path to clear stale remote bits.
- Code analysis: raft.c:978 — timer callback only clears self bit, not remote bits.

**Affected code paths**:
- `raft_process_msg` (raft.c:503-654) — term bump → witness update ordering
- `raft_sm_election_update` (raft.c:334-350) — gate on `leader_witness_map != 0`
- `raft_sm_election_update_cb` (raft.c:966-983) — timer callback
- `raft_notify_is_leader_seen` (raft.c:455-468)

**Suggested modeling approach**:
- Variables: `leaderWitnessMap[Server -> SUBSET Server]` (who each server thinks sees the leader)
- Actions: `ReceiveMessage` must model the term-bump-then-witness ordering. `LeaderResign` only clears self bit. `ElectionTimeoutFire` only clears self bit, then checks.
- Key: model message `is_leader_seen` field as carrying stale information when sender hasn't yet processed the term bump.

**Priority**: High
**Rationale**: The witness map is the sole gate for all elections. Any stale bit = liveness failure. 3 historical bugs. The remaining ordering issue (Finding 1) is not addressed by existing fixes.

---

### Family 2: WAL Write In-Progress State Machine Fragility (HIGH)

**Mechanism**: During WAL writes, the state machine is "frozen" as FOLLOWER with `is_write_in_progress=true`. External events (heartbeats, config changes, leader discovery) are partially processed, creating inconsistent state or extending timeouts beyond safety bounds.

**Evidence**:
- Historical: 6 bug-fix commits (4 Critical/High) — crashes and assertion failures during WAL writes (#5506, commit 03512e53b, commit 82757e55e, commit df6cf5ec6, commit 08a836b17)
- Code analysis: raft.c:678-680 — heartbeat during WAL write updates `leader_last_seen` but doesn't reset timer. Effective death timeout = `death_timeout + WAL_write_duration`.
- Code analysis: raft.c:854-868 — `raft_sm_follow_leader` during WAL write doesn't revoke pending volatile vote. Vote persisted even though leader already known.
- Code analysis: raft.c:1258-1269 — `raft_cfg_election_quorum` can trigger `raft_sm_become_leader` without checking `is_write_in_progress`.

**Affected code paths**:
- `raft_worker_handle_io` (raft.c:700-796) — multi-pass WAL write with post-write state transitions
- `raft_process_heartbeat` (raft.c:656-696) — partial processing during write
- `raft_sm_follow_leader` (raft.c:854-868) — conditional behavior during write
- `raft_sm_pause_and_dump` (raft.c:827-836) — entry to write-in-progress state
- `raft_cfg_*` (raft.c:1200+) — configuration changes during write

**Suggested modeling approach**:
- Variables: `isWriteInProgress[Server -> BOOLEAN]`, `volatileTerm[Server -> Nat]`, `volatileVote[Server -> Server \cup {Nil}]`, `persistedTerm[Server -> Nat]`, `persistedVote[Server -> Server \cup {Nil}]`
- Actions: `BeginWalWrite` sets `isWriteInProgress=TRUE`, freezes state as FOLLOWER. `CompleteWalWrite` flushes volatile→persisted, then transitions (become candidate, wait for leader, etc.). `ReceiveHeartbeatDuringWrite` updates timestamp only. `ReceiveMessageDuringWrite` can set volatile state but defers action. `ConfigChangeDuringWrite` applies config but defers state transitions.
- Granularity: The WAL write must be split into at least 2 steps (begin + complete) to model the interleaving window. For the multi-pass pattern (Family 3), split further.

**Priority**: High
**Rationale**: 6 historical bugs, most error-prone area. The dual volatile/persisted state is unique to Tarantool's Raft and not captured in any standard Raft spec. Perfect TLA+ modeling target.

---

### Family 3: Non-Atomic Term/Vote Persistence (HIGH)

**Mechanism**: Term and vote are written as separate WAL entries. The multi-pass WAL write deliberately persists term first, then re-checks vclock eligibility before persisting vote. A crash between writes, or incorrect vclock comparison, violates one-vote-per-term.

**Evidence**:
- Historical: #7253 (Critical) — old leader confirms data not on new leader. Vote applied before pending writes updated vclock.
- Historical: #8497 (Fixed) — crash between term and vote writes = double vote in same term
- Historical: commit c9155ac86 (Critical) — split-brain via foreign term+vote persisted with pending transactions
- Historical: commit 8a124e502 — broadcasting term without vote increases split-vote probability
- Code analysis: raft.c:759-760 — foreign vote deferred when `volatile_term > term` (the fix for #7253)
- Code analysis: raft.c:422-453 — recovery applies term and vote independently, no consistency check
- Open: #8095 — PROMOTE entry not guaranteed on new leader

**Affected code paths**:
- `raft_worker_handle_io` (raft.c:737-795) — multi-pass write: dump term → flush → recheck vclock → dump vote
- `raft_process_recovery` (raft.c:422-453) — independent term/vote application
- `raft_sm_schedule_new_term` + `raft_sm_schedule_new_vote` (separate calls at raft.c:955-963)

**Suggested modeling approach**:
- Variables: (shared with Family 2) `persistedTerm`, `persistedVote`, `volatileTerm`, `volatileVote`, `candidateVclock[Server -> Vclock]`
- Actions: `WalWriteTermOnly` — persists term without vote (the "goto do_dump" path). `WalWriteTermAndVote` — persists both (the "goto do_dump_with_vote" path). `RevokeVote` — if vclock check fails after term flush. `Crash` — recovers from persisted state only. `Recover` — applies term and vote from WAL entries independently.
- Key: The vclock comparison after term flush (`raft_can_vote_for` at line 761) is the critical safety mechanism. Model `vclock` state changes between term write and vote write (other transactions can commit during WAL flush, advancing the local vclock).

**Priority**: High
**Rationale**: 4 historical bugs including Critical split-brain. The multi-pass WAL pattern is the load-bearing fix for #7253 — must be modeled precisely. Crash recovery with split persistence is a classic TLA+ strength.

---

### Family 4: Promote/Demote Race Conditions (MEDIUM)

**Mechanism**: `box.ctl.promote()` interacts with concurrent elections, quorum changes, and repeated invocations, causing assertion failures, infinite term bumps, or indefinite hangs.

**Evidence**:
- Historical: 8 bug-fix commits (7 Critical/High) — #10836, #8168, #8217, #9855, #9263, #11703, commit dd89c57e7
- Open: #12076 — promote stuck when synchro queue empties
- Code: raft.c:1212-1220 — `raft_promote` doesn't guard against `is_write_in_progress`

**Affected code paths**:
- `raft_promote` (raft.c:1212-1220)
- `box_raft_try_promote` (box/raft.c:524-582)
- `box_raft_leader_step_off` (box/raft.c:310-321)

**Suggested modeling approach**:
- Variables: `isPromoting[Server -> BOOLEAN]`
- Actions: `Promote(s)` — bumps term, votes for self, becomes candidate. Model as a special case of election start. `Demote(s)` — resigns and restores config. `ConcurrentPromote` — two servers promote simultaneously.
- Note: Most historical bugs are fixed. The remaining issues (#12076, #8095) involve the synchro queue, which is outside core Raft scope. Model promote as an election trigger only.

**Priority**: Medium
**Rationale**: Most bugs fixed. The promote mechanism is just a special case of election start in the core Raft model. The synchro queue interactions are out of scope.

---

### Family 5: Fencing / Leader Health Detection (LOW)

**Mechanism**: Leader fails to detect its own abnormality (disk failure, TX hang) and continues appearing alive.

**Evidence**:
- Historical: #7512 (Fixed) — relay heartbeats mask TX thread hang
- Historical: #9399 (Fixed) — no step-off on WAL IO error
- Open: #12292 — leader doesn't detect read-only disk
- Code: raft.c:633-642 — conflicting leader = no-op (XXX comment)

**Priority**: Low
**Rationale**: The relay/TX thread separation is architectural. Fencing is outside core Raft protocol. The conflicting leader no-op is a defense-in-depth issue (two leaders should never occur if vote persistence is correct).

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|------|-----|-----|
| Leader witness map | Family 1: sole gate for elections, 3 historical bugs, remaining ordering issue | `leaderWitnessMap` variable + per-message `isLeaderSeen` field. Model stale bits surviving term bumps. |
| Dual volatile/persisted state | Family 2: 6 historical bugs, unique architecture | `volatileTerm`/`volatileVote` vs `term`/`vote`. WAL write as multi-step action. |
| Multi-pass WAL write | Family 3: load-bearing fix for Critical #7253 | Split WAL write into term-only and term+vote steps. Model vclock change between steps. |
| Crash and recovery | Family 3: validates persistence correctness | `Crash` action resets volatile state, recovers from persisted. `Recover` applies WAL entries. |
| Vclock-based vote eligibility | Core Tarantool deviation from Raft | `vclock[Server -> [Server -> Nat]]`. `CanVoteFor` checks component-wise >=. |
| Election timeout with witness gate | Family 1: election suppression mechanism | Timer fires → clear self witness bit → check `leaderWitnessMap == 0` → start election |
| Promote as election trigger | Family 4: 8 historical bugs | `Promote` action = bump term + self-vote, constrained by `isWriteInProgress` |

### 3.2 Do Not Model (with rationale)

| What | Why |
|------|-----|
| Log replication / AppendEntries | Tarantool Raft is election-only; log replication is a separate subsystem. |
| Synchro queue / limbo ownership | Outside core Raft protocol. The limbo is a Tarantool-specific concept with its own complex state machine. |
| Fencing mechanism | Family 5: architectural issue (relay vs TX thread). Not protocol-level. |
| Timer edge cases | Family 5 (partial): libev timer misuse (negative timeouts, 0-repeat). Implementation bugs, not protocol logic. |
| Relay / applier threads | Transport layer. Model messages as unreliable channels. |
| Snapshot / log compaction | Not part of Tarantool's Raft engine. |
| MVCC / dirty reads | Fixed by MVCC engine, orthogonal to Raft. |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Witness map | `leaderWitnessMap[Server -> Nat]` (bitmap) | Track who sees leader; gate elections | Family 1 |
| Dual state | `volatileTerm`, `volatileVote`, `persistedTerm`, `persistedVote` | Model WAL write window | Family 2, 3 |
| WAL write state | `isWriteInProgress[Server -> BOOLEAN]` | Model frozen state machine during WAL | Family 2 |
| Multi-pass WAL | (split WAL write action) | Term-first then vote write with vclock recheck | Family 3 |
| Crash/recovery | (Crash action + Recover action) | Reset to persisted state, apply WAL entries | Family 3 |
| Vclock | `vclock[Server -> [Server -> Nat]]` | Vote eligibility via component-wise comparison | Core deviation |
| Message is_leader_seen | `isLeaderSeen` field in messages | Stale witness information propagation | Family 1 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| ElectionSafety | Safety | At most one leader per term | Standard |
| OneVotePerTerm | Safety | Each server votes at most once per term (including across crashes) | Family 3 |
| VoteConsistency | Safety | `persistedVote != 0` implies `persistedVote` was granted in `persistedTerm` | Family 3 |
| WitnessMapAccuracy | Safety | If `leaderWitnessMap[s]` has bit for `p`, then `p` genuinely saw the leader in the current term (or bit is stale from ordering) | Family 1 |
| LeaderWitnessLiveness | Liveness | If leader is dead and all peers know it, eventually `leaderWitnessMap == 0` and an election starts | Family 1 |
| WalWriteSafety | Safety | During `isWriteInProgress`, state == FOLLOWER | Family 2 |
| NoStaleVoteAfterCrash | Safety | After crash recovery, node does not vote for two different candidates in the same term | Family 3 |
| PromoteTermProgress | Liveness | After `Promote(s)`, eventually `s` becomes leader or a different leader exists | Family 4 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| F1-1 | Stale witness bit from term-bump ordering blocks election | LeaderWitnessLiveness | 1 |
| F1-2 | Remote witness bits survive leader resignation, blocking non-candidate followers | LeaderWitnessLiveness | 1 |
| F2-1 | Heartbeat during WAL write extends effective death timeout beyond safety bound | LeaderWitnessLiveness (delayed) | 2 |
| F2-2 | Quorum config change during WAL write triggers become_leader assertion | WalWriteSafety | 2 |
| F3-1 | Crash between term-write and vote-write allows double vote in same term | OneVotePerTerm, NoStaleVoteAfterCrash | 3 |
| F3-2 | Multi-pass WAL write with vclock change between passes revokes vote correctly | VoteConsistency (should PASS) | 3 |
| F4-1 | Concurrent promote from two nodes causes infinite term bumps | PromoteTermProgress | 4 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| T-1 | `raft_cfg_election_quorum` assertion violation during WAL write | Unit test: lower quorum while write in progress and node has enough votes |
| T-2 | `raft_sm_follow_leader` wastes WAL write for already-known leader | Unit test: send leader announce during pending vote WAL write |
| T-3 | Recovery with out-of-order term/vote WAL entries | Unit test: replay WAL with vote before term |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| C-1 | Conflicting leader detected = no-op (raft.c:633-642, XXX comment) | Discuss with maintainers: should bump term or alert |
| C-2 | WAL write failure = panic (box/raft.c:449, XXX comment) | Stub acknowledged by developers, needs proper error handling |
| C-3 | Random election timeout has poor distribution (raft.c:124-128, XXX comment) | Low risk but could increase split-vote probability |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/tarantool/analysis-report.md`
- **Key source files**:
  - `artifact/tarantool/src/lib/raft/raft.c` (core state machine, 1431 lines)
  - `artifact/tarantool/src/lib/raft/raft.h` (structs/API, 454 lines)
  - `artifact/tarantool/src/box/raft.c` (integration layer, 746 lines)
  - `artifact/tarantool/src/box/raft.h` (box API, 176 lines)
- **Existing TLA+ spec**: `artifact/tarantool/proofs/tla/wip/raft.tla` (350 lines, incomplete, no invariants)
- **GitHub issues**: #7253 (split-brain), #12018 (election deadlock), #8497 (non-atomic persist), #7512 (leader hang), #12292 (read-only disk), #12076 (promote stuck), #8095 (PROMOTE gap)
- **Reference**: Raft paper (Ongaro & Ousterhout, 2014)
- **Unit tests**: `artifact/tarantool/test/unit/raft.c` (2491 lines, comprehensive election tests with fakeev)
