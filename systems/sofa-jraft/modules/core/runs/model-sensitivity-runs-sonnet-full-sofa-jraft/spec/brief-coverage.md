# Brief Coverage Self-Audit: sofa-jraft

Phase 2.5 self-audit — mapping brief §2/§5/§6.1 → spec/MC artifacts.

---

## Families (brief §2)

| Family | Mechanism | Hunt cfg | Notes |
|---|---|---|---|
| Family 1 — Non-Atomic Vote Persistence | Two-write window in `handleRequestVoteRequest` higher-term path; crash between writes allows re-vote | `MC_hunt_family1.cfg` | Modeled as 3-step split action (`HigherTermStep1/2/3`); `Crash` + `RestartFromPersisted` actions present |
| Family 2 — Missing Higher-Term Check on Response Paths | `onInstallSnapshotReturned` never checks `response.term`; EBUSY early return bypasses term check | `MC_hunt_family2.cfg` | Two split actions: `HandleInstallSnapshotResponseNormal` (bug) vs `...WithHigherTerm` (fixed); `HandleAppendEntriesResponseBusyHigherTerm` (bug path present) |
| Family 3 — Snapshot Install / Applied-Index Notification Ordering | `doSnapshotLoad` skips `notifyLastAppliedIndexUpdated()`; pending ReadIndex closures stuck | `MC_hunt_family3.cfg` | `HandleInstallSnapshotRequest` leaves `pendingReadIndex` unchanged (models bug); `NotifyReadIndexAfterSnapshot` models the correct path |
| Family 4 — ReadIndex Safety Gaps | Single-peer fast-path skips no-op-at-current-term guard; `stepDown` doesn't clear `pendingReadIndex` | `MC_hunt_family4.cfg` | `ServeReadIndex` (buggy, no guard) vs `ServeReadIndexSafe`; `StepDown` (buggy) vs `StepDownSafe`; single-server config for MC-4 |
| Family 5 — Code Path Inconsistencies | `handleInstallSnapshot` missing `updateLastLeaderTimestamp`; wrong `&&` in `onCaughtUp` ABA guard | `MC_hunt_family5.cfg` | `HandleInstallSnapshotRequest` leaves `lastLeaderContact` unchanged (models bug); `onCaughtUp` ABA guard (CR-1) is code-review-only; not modeled separately (no MC-checkable finding for it in §6.1) |

---

## Invariants (brief §5)

| Invariant | Type | Defined in | Wired in MC.tla | Enabled in hunt cfg |
|---|---|---|---|---|
| ElectionSafety | Safety | `base.tla` | Yes (MCElectionSafety via INVARIANT) | `MC_hunt_family1.cfg`, `MC_hunt_family2.cfg`, `MC_hunt_family3.cfg`, `MC_hunt_family4.cfg`, `MC_hunt_family5.cfg` |
| LogMatching | Safety | `base.tla` | Yes | `MC_hunt_family2.cfg` (via INVARIANT) |
| LeaderCompleteness | Safety | `base.tla` | Yes (commented in MC.cfg; enabled in family2) | `MC_hunt_family2.cfg` |
| VoteOncePerTerm | Safety | `base.tla` | Yes (commented in MC.cfg) | `MC_hunt_family1.cfg` |
| PersistBeforeSend | Safety | `base.tla` | Yes (commented in MC.cfg) | `MC_hunt_family1.cfg` |
| StepDownOnHigherTerm | Safety | `base.tla` | Yes (commented in MC.cfg) | `MC_hunt_family2.cfg`, `MC_hunt_family5.cfg` |
| ReadIndexSafety | Safety | `base.tla` | Yes (commented in MC.cfg) | `MC_hunt_family3.cfg`, `MC_hunt_family4.cfg` |
| NoPendingReadAfterStepDown | Safety | `base.tla` | Yes (commented in MC.cfg) | `MC_hunt_family3.cfg`, `MC_hunt_family4.cfg` |

All 8 Safety invariants from brief §5 are defined, wired, and enabled in ≥1 hunt cfg. ✓

---

## Findings (brief §6.1)

| Finding | Trigger mechanism | Expected invariant violation | Hunt cfg | Reachable? |
|---|---|---|---|---|
| MC-1 — Two-write crash window in higher-term vote grant | `ElectionTimeout` → `HandleRequestVoteRequestHigherTermStep1` → `Crash` → `RestartFromPersisted` → re-vote | `VoteOncePerTerm`, `ElectionSafety` | `MC_hunt_family1.cfg` | Yes — `Crash` enabled, both write steps present |
| MC-2 — Leader continues after InstallSnapshot response with higher term | Leader sends `InstallSnapshot` → follower sees higher term → `HandleInstallSnapshotResponseNormal` (no term check) | `StepDownOnHigherTerm`, `LeaderCompleteness` | `MC_hunt_family2.cfg` | Yes — `InstallSnapshot` + `HandleInstallSnapshotResponseNormal` enabled |
| MC-3 — EBUSY early-return bypasses term check | Leader sends `AppendEntries` → follower responds EBUSY + higher term → `HandleAppendEntriesResponseBusyHigherTerm` (no step-down) | `StepDownOnHigherTerm`, `ElectionSafety` | `MC_hunt_family2.cfg` | Yes — `HandleAppendEntriesResponseBusyHigherTerm` present; EBUSY response mechanism modeled |
| MC-4 — Single-node cluster ReadIndex before no-op committed | `ElectionTimeout` (s1 only) → `ServeReadIndex` before `AdvanceCommitIndex` at currentTerm | `ReadIndexSafety` | `MC_hunt_family4.cfg` (Server={s1}) | Yes — single-server config, `ServeReadIndex` doesn't check `HasNoopAtCurrentTerm` |
| MC-5 — Pending ReadIndex resolved after step-down | Leader adds `ServeReadIndex` → `StepDown` (pendingReadIndex NOT cleared) → `ApplyCommittedEntries` fires on former leader | `NoPendingReadAfterStepDown`, `ReadIndexSafety` | `MC_hunt_family3.cfg`, `MC_hunt_family4.cfg` | Yes — `StepDown` leaves `pendingReadIndex` non-empty; `ApplyCommittedEntries` can resolve them |

All 5 model-checkable findings from brief §6.1 have a hunt cfg whose fault setup makes the trigger reachable. ✓

---

## Out-of-scope Notes

- **CR-1 (`onCaughtUp` wrong `&&`)**: No MC-checkable finding in §6.1. Configuration change state machine not modeled (brief §3.2 "Do Not Model" includes complex membership change). Noted as code-review-only in brief.
- **TV-1, TV-2, TV-3**: Test-verifiable findings; not modeled (brief §6.2 scope).
- **CR-2 through CR-5**: Code-review-only; not modeled (brief §6.3 scope).
- **PreVote protocol**: Explicitly excluded per brief §3.2.
- **Disruptor ring buffer mechanics**: Explicitly excluded per brief §3.2.
- **Family 5 `onCaughtUp` ABA guard** (CR-1): The `&&`/`||` bug requires modeling the configuration change state machine, which is out of scope. The `lastLeaderContact` gap (the safety-relevant part of Family 5) IS modeled via `HandleInstallSnapshotRequest` leaving `lastLeaderContact` unchanged.
