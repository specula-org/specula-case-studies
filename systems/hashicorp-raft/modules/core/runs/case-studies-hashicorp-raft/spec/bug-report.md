# Bug Report — hashicorp/raft

## Summary

- Bug families tested: 3
- Bugs found: 0
- Bugs retracted: 2 (Bug Family 1: Phantom Lease — spec fidelity issue)
- Configs run: MC_hunt_phantom_lease.cfg, MC_hunt_lease_loyalty.cfg, MC_hunt_persist_vote.cfg, MC_hunt_config_safety.cfg

---

## ~~Bug 1: Phantom Contact via Heartbeat Response (Issue #666)~~ — RETRACTED

- **Status**: RETRACTED — spec fidelity issue, not a real bug
- **Bug Family**: Family 1 — Leader Phantom Lease
- **Invariant violated**: NoPhantomContact
- **Config**: MC_hunt_phantom_lease.cfg
- **Counterexample**: 10 states, BFS 6 seconds (output/hunt_phantom_lease.out)
- **Retraction date**: 2026-03-18
- **Reference**: https://github.com/hashicorp/raft/issues/666#issuecomment-4070293531

### Original Claim

TLC found that `HandleHeartbeatResponse` records a follower in `leaseContact` without checking `resp.Term`, allowing a leader to count a higher-term follower as a valid lease contact ("phantom contact"). The counterexample showed s2 at term 2 being recorded as a contact by s1 (leader at term 1).

### Why This Is Not A Real Bug

The counterexample requires a follower to reach a higher term while the leader's heartbeats are still being delivered. Maintainer @tgross identified two mechanisms in the real system that prevent this precondition:

**Mechanism 1: Heartbeats reset follower election timeout.** When a follower receives a heartbeat (even one it will reject on other grounds), `appendEntries()` calls `setLastContact()` at `raft.go:1580` for accepted requests. More importantly, if the follower is at the same term as the leader and receiving heartbeats normally, it will never time out and never start an election. The term cannot diverge while heartbeats are flowing.

**Mechanism 2: Leader contact blocks vote granting.** Even if a partitioned follower (F2) tries to start an election, any follower (F1) still receiving heartbeats from the leader will reject the vote request because of the leader contact check at `raft.go:1650-1656`. This prevents F2 from forming a quorum to win election.

**Combined effect**: As long as the leader can deliver heartbeats to a follower, that follower cannot reach a higher term — either by starting its own election (Mechanism 1) or by voting for another candidate (Mechanism 2). Therefore, the `resp.Term > req.Term` condition that triggers phantom contacts **cannot occur in practice** while heartbeats are being delivered.

### Spec Fidelity Gap

Our TLA+ spec's `Timeout(i)` action allows any follower to start an election at any time, without modeling the constraint that recent heartbeat receipt suppresses election timeout. This made TLC explore states where a follower simultaneously receives heartbeats AND enters a higher term — a combination impossible in the real system.

To correctly model this, the spec would need a `lastHeartbeat` variable per follower, with `Timeout(i)` guarded by a "no recent heartbeat" condition. Without this, the spec's state space is a strict superset of the real system's reachable states.

### What IS Real (Liveness Issue, Not Safety)

Maintainer @tgross confirmed a **different but related liveness bug**: when a leader's disk stalls, heartbeats continue (by design), preventing followers from electing a new leader even though the cluster cannot commit new entries. This is a liveness issue (cluster stuck), not a safety issue (stale reads). The heartbeat's dual effect — maintaining leader lease AND suppressing follower elections — prevents recovery.

The maintainers are working on a fix: checking whether `replicateTo()` has been blocked for too long, and stopping heartbeats if so. See https://github.com/hashicorp/raft/issues/666#issuecomment-4077990688.

---

## ~~Bug 2: Fraudulent Lease Quorum from Phantom Contacts~~ — RETRACTED

- **Status**: RETRACTED — same spec fidelity issue as Bug 1
- **Bug Family**: Family 1 — Leader Phantom Lease
- **Invariant violated**: LeaseImpliesLoyalty
- **Config**: MC_hunt_lease_loyalty.cfg
- **Counterexample**: 11 states, BFS 11 seconds (output/hunt_lease_loyalty.out)
- **Retraction date**: 2026-03-18
- **Reference**: https://github.com/hashicorp/raft/issues/666#issuecomment-4070293531

### Why Retracted

Same root cause as Bug 1 retraction. The counterexample requires s2 to reach term 2 (via `Timeout`) while still receiving heartbeats from s1 — impossible in the real system because heartbeats suppress follower election timeouts.

The disk blocking amplification scenario (leader disk blocked → only heartbeats flow → phantom contacts accumulate) is also not triggerable as described: if the leader's heartbeats are reaching followers, those followers stay at the same term, so heartbeat responses will have `resp.Term = req.Term` and the missing term check is irrelevant.

The real impact of disk blocking + heartbeat independence is the liveness issue described in Bug 1's retraction.

---

## Not Reproduced

| Bug Family | Config | States Explored | Result |
|------------|--------|-----------------|--------|
| Family 2: Config Change Safety | MC_hunt_config_safety.cfg | BFS: 840M states (depth 16) + Sim: 378M states (5M traces) | No violation |
| Family 3: Non-Atomic persistVote | MC_hunt_persist_vote.cfg | BFS: 933M states (depth 16) + Sim: 554M states (7.7M traces) | No violation |

**Family 2 analysis**: The configuration change safety invariant (`ConfigSafety`) was checked with 3 config changes, elections during transitions, crashes, and message loss. No violations found. The `configurationChangeChIfStable` guard (raft.go:663-673) appears to effectively prevent multiple uncommitted config changes. However, the spec uses a simplified single-step config change model; joint consensus edge cases are not modeled.

**Family 3 analysis**: The non-atomic `persistVote` bug family (writing term and votedFor in separate disk operations) was checked with 3 crashes, 5 elections, and message loss. No `ElectionSafety` violations found. While the spec correctly models the crash window between `setCurrentTerm()` and `persistVote()`, the 3-server model may be too small to trigger the double-vote scenario where a crashed node recovers with stale votedFor and votes again in the same term. The bug requires: (1) crash between persist steps, (2) recovery, (3) receiving another RequestVote in the same term from a different candidate, (4) granting the vote due to stale votedFor=Nil.

## Spec Fixes During Convergence

| Fix Type | Description |
|----------|-------------|
| Spec (Case B) | `MergeEntries`: conflict-aware log merging matching raft.go:1541-1565 |
| Invariant (Case A) | `LeaderCompleteness` / `LeaderLogCompleteness`: guard for stale leader terms |

---

## Lessons Learned

### Spec Fidelity: Modeling Election Timeout Suppression

The Bug Family 1 retraction highlights a critical spec fidelity gap. Standard Raft TLA+ specs (including the canonical one) model `Timeout(i)` as an unconstrained action — any follower can start an election at any step. This is a valid abstraction for the Raft paper's model, where election timeouts are the only mechanism preventing unnecessary elections.

However, hashicorp/raft's `heartbeat()` goroutine adds a **bidirectional coupling** not present in paper Raft:
- Leader → Follower: heartbeat resets `lastContact`, suppressing election timeout
- Follower → Leader: heartbeat response updates `lastContact` for lease check

Our spec modeled the second direction (leader lease) but not the first (election suppression). This created an asymmetric model where TLC could explore states with term divergence that the real system's election suppression prevents.

**Takeaway**: When modeling systems with heartbeat-based lease mechanisms, the follower-side effect of heartbeats on election timing must be modeled alongside the leader-side lease tracking. Without both sides, the spec explores unreachable states and may report false positives.

### Safety vs Liveness

The real bug in this code is a **liveness** issue (cluster cannot recover from disk stall), not the **safety** issue we reported (stale reads from phantom lease). This distinction matters:
- Safety bugs (linearizability violation) are unconditionally severe
- Liveness bugs (cluster stuck) are serious but involve different tradeoffs (e.g., temporary disk stalls should NOT cause leadership flapping)

The maintainers' proposed fix reflects this: rather than adding a term check to heartbeats (which wouldn't help since terms don't diverge), they plan to add a timeout on `replicateTo()` blocking duration, stopping heartbeats only after a sufficiently long disk stall.
