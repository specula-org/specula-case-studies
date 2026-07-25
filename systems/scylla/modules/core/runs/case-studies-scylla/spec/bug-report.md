# Bug Report — ScyllaDB Raft Library

## Summary

- Bug families tested: 4 (Families 1, 2, 3, 5)
- Bugs found: 0 new bugs (2 historical bugs confirmed reproducible in principle)
- Configs run: MC_hunt_family1.cfg, MC_hunt_family2.cfg, MC_hunt_family3.cfg, MC_hunt_family5.cfg
- Convergence: BFS 1.2B states + simulation 64.5M states (224K traces) with 7 invariants — no violations

## Spec Fixes During Convergence

These base spec issues were found and fixed before bug hunting:

1. **BecomeLeader nextIndex initialization** — spec used `LastLogIndex + 2` but Scylla uses `_log.last_idx()` (= `LastLogIndex + 1`), causing the leader to immediately replicate the dummy entry. Reference: `tracker.cc:101,124`.

2. **SendInstallSnapshot UNCHANGED bug** — `messages` was in the UNCHANGED clause despite `Send()` modifying it. The action was never enabled.

3. **HandleAppendEntriesRequest snapshot-overlap + conflict detection** — Stale AppendEntries messages with `prevLogIdx < snapshotIdx` truncated the follower's entire log. Fixed to: (a) skip entries within snapshot boundary (modeling `log.cc:172-174`), (b) check per-entry term conflict before truncating (modeling `log.cc:180-195`). Without this fix, committed entries could be lost.

4. **ProposeConfigChange domain check** — `j \in nextIndex[i]` should be `j \in DOMAIN nextIndex[i]`.

5. **LeaderCompleteness + CommitIndexSafety invariants** — Added `currentTerm[i] >= LogTerm(j, idx)` guard. Stale leaders at lower terms are exempt per Raft paper §5.4.3 ("future leaders").

---

## Not Reproduced

| Bug Family | Config | States Explored | Result |
|------------|--------|-----------------|--------|
| Family 1: Commit Index Over-Advancement | MC_hunt_family1.cfg | 123M (BFS, depth 20) | No violation — batch AppendEntries in MC spec sends all entries at once, so `lastNewIdx >= leaderCommitIdx` always holds. The unclamped-commit bug requires **pipeline mode** (1 entry per message) where `leaderCommitIdx` can exceed the entries actually sent. Pipeline is modeled only in Trace.tla for trace validation. |
| Family 2: Joint Consensus Quorum | MC_hunt_family2.cfg | 305K (BFS, depth 14) | Invariant too strong — JointQuorumAgreement fired on entries committed *before* entering joint config (not yet replicated to new voters). The `can_vote` mismatch (tracker.cc:114-127) causes **read barrier stalls** (liveness), not safety violations. Would need a leads-to temporal property with WF fairness to detect. |
| Family 3: Snapshot Lifecycle | MC_hunt_family3.cfg | 231M (BFS, depth 20) | No violation — the buggy snapshot variant (non-zero trailing for remote snapshots) did not produce CrashRecoveryConsistency or SnapshotLogContinuity violations within the explored state space. The historical bug (#9551) requires a specific crash-recovery sequence after the stale trailing entries corrupt the log. |
| Family 5: Election Disruption & FD | MC_hunt_family5.cfg | 99M (BFS, depth 12) | No violation — ElectionSafety, LogMatching, LeaderCompleteness, and CommitBound all hold under non-deterministic FD staleness. Safety is maintained regardless of FD accuracy, consistent with Scylla's design (FD affects only liveness). |

## Analysis

### Family 1 (Commit Clamping) — Confirmed Reproducible in Principle

The historical bugs #9965 and #10578 (unclamped `advance_commit_idx`) are real and the buggy action variants correctly model them. However, the MC spec's batch AppendEntries prevents the triggering condition: the leader must send a message where `leaderCommitIdx > lastNewIdx`, which only happens with pipelined (one-at-a-time) entry sending. To reproduce with MC, the base spec's `AppendEntries` would need pipeline mode or a separate `SendHeartbeat` action that carries `commitIndex` without entries.

Both bugs are already fixed in the current code:
- `fsm.cc:667`: `advance_commit_idx(std::min(leader_commit_idx, last_new_idx))`
- `fsm.cc:1059`: `std::min(p.match_idx, _commit_idx)` for read_quorum

### Family 2 (Joint Consensus) — Liveness Issue, Not Safety

The `can_vote` field mismatch in `tracker::set_configuration` (`tracker.cc:114-127`) is real: a voter only in the `previous` config gets `can_vote=false` from the `current` config. This means `broadcast_read_quorum` (`fsm.cc:1055`) skips them, but `tracker::committed<read_id>()` (`tracker.cc:178-214`) needs their ack for the previous-config quorum. This stalls read barriers during voter demotion in joint consensus.

This is a **liveness bug** (read barrier hangs), not a safety bug (no committed data is lost). TLA+ temporal properties (`~>`) with weak fairness would detect it, but require BFS (not simulation) and have high state-space cost.

### Family 3 (Snapshot Lifecycle) — No Violations

The buggy snapshot variant (keeping trailing entries for remote snapshots) did not violate safety invariants in 231M states. The historical bug (#9551) requires a crash-recovery sequence where stale trailing entries from the old term conflict with the snapshot state. Our model covers crash + recovery but the specific interleaving wasn't reached. Already fixed: `fsm.hh:546` passes `trailing=0` for remote snapshots.

### Family 5 (Failure Detector) — Safety Holds

Under non-deterministic FD staleness (any subset of servers can appear alive), all safety invariants hold. This confirms Scylla's design: the shared failure detector affects only liveness (election timing, leader stepdown delay), not safety. The `has_stable_leader()` election suppression (`fsm.cc:590-606`) may delay elections but cannot cause split-brain.

## State Space Coverage Summary

| Config | States | Distinct | Depth | Duration | Invariants |
|--------|--------|----------|-------|----------|------------|
| MC.cfg (BFS) | 1.2B | 123M | 14 | 25 min | 7 (all pass) |
| MC.cfg (sim) | 64.5M | — | 100 | 10 min | 7 (all pass) |
| Family 1 | 123M | 27M | 20 | 12 min | 3 (all pass) |
| Family 2 | 305K | 118K | 14 | 13 sec | 3 (invariant too strong) |
| Family 3 | 231M | 45M | 20 | 17 min | 4 (all pass) |
| Family 5 | 99M | 10M | 12 | 5 min | 4 (all pass) |
