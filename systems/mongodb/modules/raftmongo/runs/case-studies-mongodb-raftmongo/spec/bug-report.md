# Bug Report — MongoDB RaftMongo Replication Commit Point Protocol

## Summary

- Bug families tested: 5 (commit point propagation, lastWritten pipeline, election/catchup, heartbeat side-channel, rollback safety)
- Bugs found: 0 new bugs (1 expected violation of documented behavior)
- Configs run: MC.cfg, MC_small.cfg, MC_hunt_nojournal.cfg, MC_hunt_commitbranch.cfg, MC_hunt_server39626.cfg

## Expected Violation: Non-Journal Commit Point Loss (Documented Behavior)

- **Bug Family**: Family 2 (lastWritten / lastApplied / lastDurable confusion)
- **Severity**: N/A — documented trade-off, not a bug
- **Invariant violated**: NeverRollbackCommitted
- **Config**: MC_hunt_nojournal.cfg (WriteConcernMajorityShouldJournal=FALSE)
- **Counterexample**: 12 states, output in spec/output/MC_hunt_nojournal.out

### Trace Summary

1. **s1 elected leader** in term 1 (States 2-4): s1 → Candidate → gets s2's vote → Leader
2. **s2 starts election** in term 2 (State 5): concurrent Candidate while s1 is still Leader
3. **s1 writes no-op** (State 6): log = <<[term 1]>>, lastWritten = (1,1), lastApplied = (1,1)
4. **s3 syncs from s1** (State 7): s3 gets log = <<[term 1]>>, lastWritten = (1,1)
5. **Leader advances commit point** (State 8): With `WriteConcernMajorityShouldJournal=FALSE`, `Agree()` uses `lastWritten`. s1 + s3 have lastWritten.index >= 1 → majority. Entry [term 1, index 1] committed. **But lastDurable is still (0,0) on both nodes.**
6. **s3 crashes** (State 9): log truncated to lastDurable (0,0) → empty. The committed entry is lost from s3.
7. **s2 gets s3's vote** (State 10): s3 (empty log) votes for s2 (empty log) — both are equally "fresh"
8. **s2 wins election** in term 2 (State 11): s2 becomes leader with votes from s2+s3
9. **s2 writes no-op** (State 12): log = <<[term 2]>>. Now the committed entry [term 1, index 1] exists only on s1, and s1 would need to roll back to converge with the new leader s2.

### Root Cause

When `writeConcernMajorityShouldJournal = false`, the commit point is calculated using `lastWritten` instead of `lastDurable` (topology_coordinator.cpp:3141-3153). This means entries can be "committed" before being persisted to disk. If a majority of nodes crash before journaling, the committed entry is lost.

### Affected Code

- `topology_coordinator.cpp:3141`: `const bool useDurableOpTime = _rsConfig.getWriteConcernMajorityShouldJournal()`
- `topology_coordinator.cpp:3153`: `const OpTimeAndWallTime opTime = useDurableOpTime ? durableOpTime : writtenOpTime`

### Classification

**Case A (Invariant Too Strong)**: This is documented MongoDB behavior. The `writeConcernMajorityShouldJournal` setting defaults to `true` since MongoDB 4.0+. When set to `false`, users accept the risk of losing acknowledged writes after crashes. The `NeverRollbackCommitted` invariant is too strong for this configuration.

This finding **validates the spec's Family 2 extension** — the three-level pipeline (lastWritten → lastApplied → lastDurable) correctly models the implementation's behavior and the spec can detect the durability gap.

---

## Not Reproduced

| Bug Family | Config | States Explored | Result |
|------------|--------|-----------------|--------|
| Family 1: SERVER-39626 (5 servers, 3 terms, 4+ log) | MC_hunt_server39626.cfg | 198M states, 3.2M sim traces | No violation (simulation, killed at 10 min) |
| Family 1+4: Commit point branch safety | MC_hunt_commitbranch.cfg | 569M states (BFS, killed) | No violation |
| Family 1+2+3+5: Standard config (journal=true) | MC_small.cfg | 89M states (BFS complete) | No violation — all 11 invariants pass |
| Family 1+2+3+5: Larger bounds (journal=true) | MC.cfg | 329M states, 12.7M sim traces | No violation |

### Notes on SERVER-39626

The modeling brief identifies SERVER-39626 as a known safety violation at 5 servers, 3 terms, 4+ log entries. Our simulation with these bounds (MC_hunt_server39626.cfg) did not reproduce it. Possible reasons:

1. **Spec differences**: Our spec includes the three-level pipeline, explicit election protocol, and firstOpTimeOfMyTerm guard — these may prevent the exact sequence that triggers SERVER-39626 in the original spec
2. **Simulation coverage**: 3.2M random traces may not explore the specific narrow path; BFS at 5 servers is infeasible (state space > 10^12)
3. **Bug may be fixed**: The implementation may have been patched since the original report

To reproduce SERVER-39626, a dedicated investigation with the exact original spec bounds and BFS would be needed. The original MongoDB spec (RaftMongo.tla) explicitly documents that `MCRaftMongo.cfg` is too small to trigger it.

## State Space Coverage Summary

| Config | Mode | States | Distinct | Traces | Duration | Result |
|--------|------|--------|----------|--------|----------|--------|
| MC_small.cfg | BFS | 89M | 7.7M | - | 2.5 min | All pass |
| MC.cfg | Simulation | 329M | - | 12.7M | ~10 min | All pass |
| MC_hunt_nojournal.cfg | BFS | 324K | 82K | - | 5s | **Violation** |
| MC_hunt_commitbranch.cfg | BFS | 569M | 72M | - | ~24 min (killed) | No violation |
| MC_hunt_server39626.cfg | Simulation | 198M | - | 3.2M | ~10 min (killed) | No violation |
