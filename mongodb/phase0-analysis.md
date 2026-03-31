# MongoDB TLA+ Phase 0: Comprehensive Analysis

## Inventory

**10 repositories, 45 TLA+ files, ~8000 LOC total**

### Replication (5 repos, 15 specs)

| Spec | Repo | LOC | Vars | Actions | Invariants | Abstraction Level |
|------|------|-----|------|---------|------------|-------------------|
| RaftMongo.tla | mongo (official) | 331 | 5 | 9 | 3 inv + 1 temporal | High (atomic election, no messages) |
| RaftMongoReplTimestamp.tla | mongo (official) | 445 | 9 | 12 | 4 inv | High + durability/restart |
| MongoReplReconfig.tla | mongo (official) | 492 | 7 | 9 | 5 inv + 3 temporal | High + reconfiguration |
| RaftMongoWithRaftReconfig.tla | mongo (official) | 263 | 5 | 7 | 2 inv | Exploratory (never deployed) |
| MongoRepl.tla | will62794 | 689 | 12 | 11 | 9+ inv/temporal | Low (messages, voting, matchEntry) |
| MongoReplSimpler.tla | will62794 | 604 | 10 | 6 | 9+ inv/temporal | Medium (no messages) |
| MongoReplReconfig.tla | will62794 | 498 | 7 | 9 | 6 inv + 2 temporal | High + ablation testing |
| RaftMongo.tla | visualzhou | 294 | 4 | 6 | 3 inv + 1 temporal | Very high (global term!) |
| RaftMongoSyncSources.tla | models repo | 377 | 5 | 7 | 3 inv + cycle checks | Medium + sync source |

### Logless Reconfiguration (1 repo, 7 specs)

| Spec | LOC | Vars | Actions | Invariants |
|------|-----|------|---------|------------|
| MongoStaticRaft.tla (OSM) | 200 | 5 | 6 | 5 |
| MongoLoglessDynamicRaft.tla (CSM) | 131 | 5 | 4 | 0 (in MC) |
| MongoRaftReconfig.tla (composed) | 162 | 7 | ~12 | 3 + refinement |
| Defs.tla | 20 | - | - | - |
| + 3 MC wrappers | ~95 | - | - | - |

**Status**: TLAPS machine-checked proof exists. Safety fully proved. **Most mature spec.**

### Distributed Transactions (1 repo, 6 specs)

| Spec | LOC | Vars | Actions | Invariants |
|------|-----|------|---------|------------|
| MultiShardTxn.tla | 594 | 22 | 15 | 5 isolation levels |
| Storage.tla | 446 | 7 | 11 | (via MST) |
| ClientCentric.tla | 228 | - | - | SI/RR/RC/RU/SER defs |
| MCMultiShardTxn.tla | 23 | - | - | StateConstraint |
| + Util.tla, Tests | ~295 | - | - | - |

### Sharding (4 specs)

| Spec | LOC | Vars | Actions | Invariants |
|------|-----|------|---------|------------|
| MoveRange.tla | 487 | 19 | 12 | 6 |
| TxnsCollectionIncarnation.tla | 582 | 14 | 15 | 7 |
| TxnsMoveRange.tla | 327 | 14 | 5 | 4 |
| RangeDeletionsSecondaryNodes.tla | 187 | 6 | 7 | 5 |

### Leader Leases (4 specs)

| Spec | LOC | Vars | Actions | Invariants |
|------|-----|------|---------|------------|
| leaseGuard.tla | 296 | 8 | 9 | 6 |
| leaseRaft1.tla | 289 | 8 | 8 | 7 |
| leaseRaft2.tla | 245 | 7 | 8 | 5 |
| leaseRaftWithTimers.tla | 327 | 10 | 10 | 7 |

### Other (2 specs)

| Spec | LOC | Status |
|------|-----|--------|
| locking.tla | 275 | Immature, PlusCal, no invariants |
| InitSyncDocs.tla | 286 | Historical (MMAP deprecated) |

---

## Critical Findings

### Finding 1: `Restart` is DEAD CODE in Distributed Transactions

`MultiShardTxn.tla` defines `Restart(s)` (lines 184-197) but it is **NOT included in the Next relation** (lines 540-559). This means **coordinator failure during 2PC is never explored** -- the single most critical fault scenario for distributed transactions.

Additionally, the defined `Restart` action is buggy:
- Does NOT reset storage layer variables (`txnSnapshots`, `txnStatus`, `stableTs`, `oldestTs`, `allDurableTs`)
- Does not handle messages in flight (prepare/vote messages to/from crashed shard are not cleared)
- No coordinator recovery protocol exists in the spec

### Finding 2: `MoveKey` (chunk migration) is DEAD CODE

`MoveKey(k, sfrom, sto)` is defined but NOT in Next. Concurrent chunk migration during transactions is never explored, despite being a known source of production bugs.

### Finding 3: No Abort Decision in 2PC

`ShardTxnAbort` handles spontaneous abort, but there is **no `ShardTxnCoordinatorDecideAbort`**. If a participant fails to prepare, the coordinator hangs forever. `RouterTxnAbort` is entirely commented out.

### Finding 4: No Unified Replication + Reconfig + Durability Spec

The three most critical concerns are each in separate specs that cannot interact:
- `RaftMongo.tla` — commit point propagation, NO reconfig
- `MongoReplReconfig.tla` — reconfig safety, NO commit point propagation
- `RaftMongoReplTimestamp.tla` — durability/restart, NO reconfig

Bugs at the intersection (e.g., reconfig during commit point propagation with node restart) are invisible to all specs.

### Finding 5: SERVER-39626 Acknowledged But Unchecked

The official `MCRaftMongo.cfg` states: "NeverRollbackCommitted and NeverRollbackBeforeCommitPoint can be violated... requires at least 5 servers, 3 terms, and oplogs of length 4+, which are larger limits than we can easily model-check."

The core safety properties are **known to be violable** but tested only at bounds too small to trigger the violation.

### Finding 6: leaseRaft2 Missing Limbo-Read Guard

`leaseRaft1.tla` has explicit limbo-read guarding for inherited leases:
```
currentTerm[i] # lease[i].term => LastCommitted(k, i) = LastInPriorTerm(k, i)
```
`leaseRaft2.tla` has NO equivalent check. Combined with `BaitInv` cutting off exploration at depth 99, the `LinearizableReads` invariant may be vacuously satisfied.

### Finding 7: TxnsCollectionIncarnation `createdDatabases` Bypass

Every transaction adds `"db"` to `rCreatedDatabases`, which causes the `SNAPSHOT_INCOMPATIBLE` database version check to be **always bypassed**. Either this masks real bugs or reflects an intentional simplification that needs documentation.

### Finding 8: Reconfig Spec Divergence

Two versions of `MongoReplReconfig.tla` differ on:
- **Voting**: official requires `HasSameConfig` (exact match); Schultz uses `IsNewerConfig` (>=)
- **Rollback term update**: official does NOT update terms during rollback; Schultz DOES
- **LeaderCompleteness**: composed spec uses `<=` (includes current term); static uses `<`

It's unclear which matches the production implementation.

### Finding 9: Dead Code in Storage.tla

- `WriteReadConflictExists` (line 144) has a tautological condition (`mtxnSnapshots[tOther].ts = mtxnSnapshots[tOther].ts` — compares to itself)
- `TxnCanStart` (line 221) is defined but never called

### Finding 10: No Network Model in Any Production Spec

All production specs use atomic point-to-point operations. No message loss, reordering, duplication, or partitions. Only the research-oriented `MongoRepl.tla` has explicit messages, but it's not maintained.

---

## Strategic Attack Plan

### Target A: Distributed Transactions (HIGHEST VALUE)

**Why**: Most complex, newest, most dead code, Jepsen already found anomalies in MongoDB 4.2.6.

**Attack vectors**:
1. **Enable Restart + fix it**: Add coordinator crash/recovery to 2PC. Model coordinator document persistence. This alone could find bugs.
2. **Enable MoveKey + stale router catalog**: Model concurrent chunk migration. Fix MoveKey to NOT update rCatalog (simulating stale cache).
3. **Add abort path**: Model coordinator abort decision when participant fails to prepare.
4. **Multi-router**: Use Router = {r1, r2} with same txn ID on different routers.
5. **Add message loss**: Make prepare/commit messages losable.
6. **Counter-bounded fault injection**: Apply Specula's methodology — bounded Restart, MoveKey, MessageLoss counts.

**Expected outcome**: High probability of finding real bugs. The dead code suggests these scenarios were planned but never implemented.

### Target B: Unified Replication Spec (HIGH VALUE)

**Why**: No spec combines replication + reconfig + durability. Cross-layer bugs are invisible.

**Attack vectors**:
1. Build a unified spec combining RaftMongo commit point propagation + MongoReplReconfig reconfiguration + RaftMongoReplTimestamp durability/restart
2. Check SERVER-39626 with larger bounds (5 servers, 3 terms, 4+ log entries)
3. Add read concern modeling (local, majority, snapshot, linearizable)
4. Model rollback of committed snapshot during reconfig

**Expected outcome**: Medium-high probability. The specs were separated for state space reasons, but Specula's techniques (symmetry, counter-bounded faults) may make unification feasible.

### Target C: LeaseGuard (MEDIUM VALUE, LOW EFFORT)

**Why**: Brand new protocol (SIGMOD 2026), leaseRaft2 has a concrete gap.

**Attack vectors**:
1. Verify leaseRaft2 LinearizableReads without BaitInv depth limit
2. Add limbo-read guard to leaseRaft2 and compare
3. Model per-server clock skew in leaseGuard (currently uses global clock)
4. Combine lease protocol with reconfiguration

**Expected outcome**: Medium probability. The missing limbo-read guard in leaseRaft2 is a concrete lead.

### Target D: Trace Validation (HIGHEST PROOF-OF-METHOD VALUE)

**Why**: MongoDB's own trace validation attempt failed ("abstraction gap"). Success here = strongest possible demonstration of Specula's superiority.

**Attack vectors**:
1. Instrument MongoDB's replication protocol (C++) to emit NDJSON traces
2. Validate against RaftMongo.tla using Specula's trace validation methodology
3. Focus on commit point propagation — the area with most known bugs
4. If traces don't match spec, either the spec is wrong or the implementation is wrong — both are wins

**Expected outcome**: High difficulty, but success would be the most impactful result. MongoDB's VLDB 2020 paper explicitly documented their failure here.

---

## Recommended Execution Order

1. **Target A (Distributed Transactions)** — Start here. Enable dead code, add fault injection, run MC. Fastest path to finding bugs.
2. **Target C (LeaseGuard)** — Low-hanging fruit. Check leaseRaft2 limbo-read gap. Quick win.
3. **Target B (Unified Replication)** — Higher effort but high value. Build incrementally.
4. **Target D (Trace Validation)** — Longest effort but most impactful for the paper narrative.

Targets A and C can run in parallel. Target B feeds into Target D.
