# MongoDB Resharding Coordinator — Analysis & Modeling Plan

## Why This Target

MongoDB 的 TLA+ 验证覆盖了复制协议、重配置、分布式事务，但 **resharding coordinator 从未被形式化验证**。同时它产出了 15+ 个 bug，包含 P1/P2 级别的数据丢失问题。这是一个 3 方分布式状态机（Coordinator + Donor + Recipient），failover recovery 是核心难点——正是 TLA+ 最擅长的场景。

## Architecture Overview

```
Config Server (Coordinator)
    │
    ├── kInitializing
    │     └── Create temp collection, build participant list
    ├── kPreparingToDonate
    │     └── Wait for all Donors to report minFetchTimestamp
    ├── kCloning
    │     └── Wait for all Recipients to finish cloning
    ├── kApplying
    │     └── Wait for all Recipients to finish applying oplog
    ├── kBlockingWrites
    │     └── Wait for all Donors to block writes (critical section)
    ├── kCommitting
    │     └── Swap temp collection → real collection
    └── kDone

Donor Shard                         Recipient Shard
    │                                    │
    ├── kDonating                        ├── kCloning (fetch data)
    ├── kDonatingOplogEntries            ├── kApplying (apply oplog)
    ├── kBlockingWrites                  ├── kStrictConsistency
    └── kDone                            └── kDone
```

## Core Files (6,759 LOC)

| File | LOC | Role |
|------|-----|------|
| `resharding_coordinator.inl` | 2,204 | **Main state machine** — all transitions |
| `resharding_coordinator.h` | 647 | State machine interface + method declarations |
| `resharding_recipient_service.cpp` | 2,287 | Recipient state machine |
| `resharding_donor_service.cpp` | 1,531 | Donor state machine |
| `resharding_coordinator_observer.h/cpp` | ~300 | Coordinator waits for participant state changes |
| `resharding_coordinator_dao.h/cpp` | ~400 | Coordinator document persistence |
| `reshard_collection_coordinator.cpp/h` | ~400 | Top-level DDL coordinator wrapper |

## Known Bug Patterns (from research)

### Pattern 1: Coordinator Failover Recovery (CRITICAL)
- **SERVER-61483** (P2): Coordinator fails to recover abort decision on step-up → commits instead → DATA LOSS
- **SERVER-73915**: Coordinator hangs on step-up
- **SERVER-74647**: State machine creation not idempotent → permanent hang

### Pattern 2: Abort/Commit Race (HIGH)
- **SERVER-66046**: Coordinator won't automatically abort when recipient errors
- **SERVER-61473**: onCompletion() called multiple times → config server crash
- **SERVER-100785**: Malformed zones → config server crash at commit stage

### Pattern 3: Participant Synchronization (HIGH)
- **SERVER-120917** (2026-03): Resharding hangs in cloning phase
- **SERVER-68628** (P2): Retry after failover → crash or lost writes due to stale routing

### Pattern 4: State Transition Ordering (MEDIUM)
- **SERVER-119048** (2026-02): Registry resyncs on startup and rollback — ordering matters
- **SERVER-111411** (2026-02): Timeseries with forceRedistribution — wrong state handling

## Modeling Approach

### Abstraction Level

Model at **coordinator state machine + participant readiness signals** level:
- Coordinator states: the 7 states above
- Each participant (donor/recipient) abstracted as a readiness signal (ready/not ready/error)
- Coordinator document persistence: write + majority commit + step-down rollback
- Recovery: step-up reads persisted doc, resumes from that state

### What to Model
1. **Coordinator state transitions** — faithful to `resharding_coordinator.inl`
2. **Coordinator document persistence** — write, majority-commit, step-down rollback
3. **Participant readiness** — abstracted: each participant can signal ready, error, or not respond
4. **Coordinator crash/recovery** — step-down, doc persisted state, step-up resume
5. **Abort decision** — coordinator can abort at any state, abort must be durable before sending
6. **Concurrent abort + commit race** — the main bug pattern

### What NOT to Model
- Data cloning mechanics (not protocol-level)
- Oplog application details (implementation-level)
- Network message format (abstracted to readiness signals)
- WiredTiger storage engine (too low-level)
- Temp collection creation/swap (DDL details)

### Bug Families for Spec

| Family | Mechanism | Key Bugs | Variables | Priority |
|--------|-----------|----------|-----------|----------|
| 1 | Coordinator failover: abort decision lost on step-up | SERVER-61483, SERVER-73915, SERVER-74647 | coordDoc, coordDocDurable, recoveredState | CRITICAL |
| 2 | Abort/commit race: abort not propagated to all participants | SERVER-66046, SERVER-61473 | abortReason, participantAcks, abortSent | HIGH |
| 3 | Participant hang: coordinator stuck waiting for a participant that will never respond | SERVER-120917, SERVER-68628 | participantState, participantAlive | HIGH |
| 4 | Non-idempotent state creation: recovery creates duplicate state machine | SERVER-74647, SERVER-119048 | instanceExists, registryState | MEDIUM |

### Proposed Invariants

| Invariant | Type | What it checks | Family |
|-----------|------|----------------|--------|
| AbortDecisionDurable | Safety | If coordinator decides abort, the abort doc is majority-committed before sending abort to participants | 1 |
| NoCommitAfterAbort | Safety | Once abort is decided, coordinator never transitions to kCommitting | 1, 2 |
| RecoveryConsistency | Safety | After step-up recovery, coordinator state matches persisted doc | 1 |
| AllParticipantsAckBeforeCommit | Safety | Coordinator only enters kCommitting when all participants are ready | 2, 3 |
| NoOrphanedParticipants | Liveness | If coordinator completes (kDone), all participants eventually reach kDone | 3 |
| IdempotentCreation | Safety | Creating coordinator instance twice for same reshardingUUID produces same result | 4 |

### MC Hunting Strategy

| Config | Fault Injection | Target | Expected States |
|--------|----------------|--------|-----------------|
| MC_hunt_failover.cfg | MaxCrash=2, MaxAbort=1 | AbortDecisionDurable, RecoveryConsistency | 10K-100K |
| MC_hunt_abort_race.cfg | MaxAbort=1, MaxParticipantError=1 | NoCommitAfterAbort | 10K-100K |
| MC_hunt_hang.cfg | MaxParticipantHang=1, MaxCrash=1 | NoOrphanedParticipants | 10K-100K |
| MC_hunt_idempotent.cfg | MaxCrash=2 | IdempotentCreation | 1K-10K |

## Execution Plan

### Step 1: Deep Code Reading (I do this, you review findings)
- Read `resharding_coordinator.inl` — the main state machine
- Read `resharding_coordinator_observer.h` — how coordinator waits for participants
- Read `resharding_coordinator_dao.cpp` — document persistence
- Map all state transitions and their persistence points
- Identify crash windows (between state change and majority commit)

### Step 2: Write Modeling Brief (I write, you approve)
- Based on code reading, produce formal modeling brief per the `modeling-brief-format.md` spec
- Include specific `file:line` references for every claim

### Step 3: Write TLA+ Spec (I write, you review)
- base.tla: coordinator state machine + participant abstraction + crash/recovery
- MC.tla: counter-bounded fault injection
- Hunting configs per bug family

### Step 4: Run TLC (I execute, you monitor)
- Convergence → hunting → analyze counterexamples

### Step 5: Bug Confirmation (if bugs found)
- Map counterexample to code path
- Write reproduction test
