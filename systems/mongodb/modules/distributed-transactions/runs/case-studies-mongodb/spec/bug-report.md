# Bug Report — MongoDB Transaction Router & Resource Contention (v3 Spec)

## Summary

- Bug families tested: 4
- Bugs found: 2 (both known historical bugs, confirming spec faithfully models them)
- New bugs found: 0
- Convergence: MC.cfg BFS — 7,568 states, 2,495 distinct, depth 13, structural invariants all pass
- Total states explored across all hunting configs: ~1,400+

---

## Bug 1: Ticket Starvation Deadlock (SERVER-60682)

- **Bug Family**: 2 — Ticket/Resource Starvation Deadlock
- **Severity**: P2/Critical
- **Status**: Known, FIXED (via `ScopedAdmissionPriority kExempt` at `transaction_coordinator_util.cpp:499`)
- **Invariant violated**: `NoTicketDeadlock`
- **Config**: MC_hunt_family2.cfg (`CoordTicketExempt = FALSE`, `MaxTickets = 2`, 2 shards)
- **Counterexample**: 4 states (output/MC_hunt_family2.out)

### Trace Summary

| State | Action | tickets | cPhase | sState |
|-------|--------|---------|--------|--------|
| 1 | Initial | 2 | CP_none | SS_none, SS_none |
| 2 | RouterStartTxn(r1,t1) | 2 | CP_none | SS_inProg, SS_inProg |
| 3 | RouterCommitTxn(r1,t1) | 2 | CP_preparing | SS_inProg, SS_inProg |
| 4 | CoordDecideCommit(t1) | **0** | **CP_decided** | SS_prepared, SS_prepared |

### Root Cause

Both shards prepare and each acquires a write ticket (2 tickets total). The coordinator enters `CP_decided` and needs to persist the decision (`CoordPersistAndSend`), which requires a write ticket. With `CoordTicketExempt = FALSE` (pre-fix behavior) and `tickets = 0`, the coordinator is permanently blocked. The prepared transactions hold tickets indefinitely because they cannot complete without the coordinator's decision → circular deadlock.

### Affected Code

- `transaction_coordinator_util.cpp:496-500`: Pre-fix code required a write ticket for `persistDecision()`. The fix adds `ScopedAdmissionPriority kExempt` to bypass the ticket pool.
- `transaction_participant.cpp:2089`: Prepared transactions hold WiredTiger locks and a write ticket.

### Fix Verification

With `CoordTicketExempt = TRUE` (post-fix): `CoordPersistAndSend` bypasses ticket check, coordinator always makes progress. BFS with 7,568 states confirms no deadlock.

---

## Bug 2: Error Code Misclassification — Session Reaper (SERVER-105751)

- **Bug Family**: 3 — Error Code Misclassification
- **Severity**: High
- **Status**: Known, partially addressed (session reaper should not touch prepared txns, but race window exists)
- **Invariant violated**: `ClassificationMatchesReality` (7 states), `NoSilentDataLoss` (9 states)
- **Config**: MC_hunt_family3.cfg (`MaxReaper = 1`, 2 shards)
- **Counterexample**: 7 states (output/MC_hunt_family3.out)

### Trace Summary (ClassificationMatchesReality)

| State | Action | sState(s1) | sState(s2) | cPhase | cAcks |
|-------|--------|------------|------------|--------|-------|
| 1 | Initial | SS_none | SS_none | CP_none | {} |
| 2 | RouterStartTxn | SS_inProg | SS_inProg | CP_none | {} |
| 3 | RouterCommitTxn | SS_inProg | SS_inProg | CP_preparing | {} |
| 4 | CoordDecideAbort | SS_prepared | SS_aborted | CP_decided | {} |
| 5 | **SessionReaperFire(s1)** | **SS_reaped** | SS_aborted | CP_decided | {} |
| 6 | CoordPersistAndSend | SS_reaped | SS_aborted | CP_sending | {} |
| 7 | CoordSendDecisionToShard(s1) | SS_reaped | SS_aborted | CP_sending | **{s1}** |

### Root Cause

1. Session reaper destroys s1's prepared transaction (State 5: SS_prepared → SS_reaped)
2. Coordinator sends abort decision to s1 (State 7)
3. s1 responds `NoSuchTransaction` (because the session was reaped)
4. Coordinator classifies `NoSuchTransaction` as a `DecisionAckError` (`transaction_coordinator_util.cpp:933`)
5. `DecisionAckError` is treated as a successful acknowledgment → s1 added to `cAcks`
6. But s1 is in `SS_reaped` state — it never actually processed the abort. The prepared data was neither committed nor aborted.

The `NoSilentDataLoss` invariant catches the downstream consequence: when the coordinator finishes (`CP_done`), it believes all participants have processed the decision, but a reaped participant's data is in limbo.

### Affected Code

- `transaction_coordinator_util.cpp:933-935`: `isTwoPhaseDecisionAckError()` classifies `NoSuchTransaction` (code 251) as an ack
- `transaction_coordinator_util.cpp:836-845`: `isVoteAbortError()` and `isTwoPhaseDecisionAckError()` error code lists
- `error_codes.yml`: Code 251 (`NoSuchTransaction`) appears in both error category lists
- `kill_sessions_local.cpp`: Session reaper logic — should filter prepared transactions but race window exists

### Note

This same pattern triggers with both commit and abort decisions. The first counterexample (output/MC_classification_violation.out, found during convergence) showed the commit path; Family 3 hunting found the abort path.

---

## Not Reproduced

| Bug Family | Config | States | Depth | Invariants Checked | Result |
|------------|--------|--------|-------|--------------------|--------|
| Family 1: Router Path | MC_hunt_family1.cfg | 466 | 10 | CommitTypeConsistency, AllParticipantsReachTerminal | PASS |
| Family 4: SWS Retry | MC_hunt_family4.cfg | 478 | 10 | RetryNeverContradictsOriginal, SWSCorrectness | PASS |

### Analysis of Non-Findings

**Family 1 (Router Commit Path)**: The `DirectCommitPartial` fault injection (SERVER-116284 pattern) was tested with `MaxPartialSend = 2`. The `AllParticipantsReachTerminal` invariant holds because:
- Partial sends leave the router in `RPFailed` state, not `RPDone`
- The invariant only checks terminal state when `rPhase = RPDone`
- The partial commit is thus correctly classified as a failure

The `CommitTypeConsistency` invariant holds across all 466 states, confirming the 5-way commit type selection logic in `_commitTransaction()` (lines 1649-1771) is correctly modeled.

**Family 4 (SWS Retry Safety)**: The `RetryNeverContradictsOriginal` invariant holds across 478 states with `MaxSWSWriteFail = 1`, `MaxDelayedCommit = 1`, and `MaxRetry = 2`. The recovery token protocol correctly distinguishes:
- Write shard committed → recovery returns commit (safe)
- Write shard in-progress → recovery aborts it (pessimistic but consistent)
- Once aborted, delayed commits cannot overwrite (SSAborted → DelayedCommitArrival blocked)

This confirms the SERVER-48307 fix is effective in the modeled code paths. The `disallowSingleWriteShardCommit` sticky flag bug (SERVER-102481) is modeled via non-deterministic `rDisallowSWS` in `RouterStartTxn` — when TRUE, the SWS path is bypassed and 2PC is selected instead. `SWSCorrectness` holds: the SWS path is never entered with >1 write shard.

---

## Spec Convergence Summary

| Phase | States | Depth | Duration | Invariants | Result |
|-------|--------|-------|----------|------------|--------|
| MC.cfg (structural) | 7,568 | 13 | <1s | 5 structural | PASS |
| MC.cfg (extension) | 1,474 | 10 | <1s | 3 extension | ClassificationMatchesReality violated (Case C) |

Converged in 1 round. Trace validation required 2 fixes to Trace.tla (participant constraint, ASSUME move) — no base spec changes.

---

## Spec Fixes During Validation

| Fix | Type | Description |
|-----|------|-------------|
| ASSUME `Cardinality(Shard) >= 2` | Move | Moved from base.tla to MC.tla — not needed for trace validation |
| TraceRouterStartTxn constraints | Trace-only | Added `ValidateParticipants` and `ValidateDisallowSWS` to constrain non-determinism |
