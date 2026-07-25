# Confirmed Bug Report — solana (anza-xyz/agave Tower BFT)

## Summary

- **Total findings reviewed**: 2 MC counterexamples (MC-5, MC-6) + 7 code-review items (R-1..R-7) from modeling brief = 9 candidate findings
- **Reproduced**: 2 (MC-5, MC-6) — both reproduce via upstream-authored
  developer tests; reproduction confirms behavior matches MC trace and
  matches the developers' documented intent
- **Confirmed (code audit, reproduction failed)**: 0
- **False positives**: 0 (no MC finding was framed in a way that the
  triage process invalidated; both are real implementation behaviors)
- **Known/Historical**: 2 (both MC-5 and MC-6 correspond to behaviors
  the agave maintainers explicitly acknowledged in upstream commits
  with developer-written tests)
- **Code-review-only items filtered out**: 7 (R-1..R-7 from modeling
  brief §6.3 — these are documented as "Suggested action: Discuss with
  maintainers", i.e. design audit items, not concrete bugs)
- **Inconclusive**: 0

Per the bug-confirmation skill, KNOWN-HISTORICAL findings do **not**
require new reproduction tests because the existing developer-written
tests and PR discussions serve as the upstream evidence of confirmation.
Even so, I executed the upstream tests in our environment to:

1. Independently verify the behavior reproduces from clean source
2. Capture the exact panic message / test output as evidence
3. Confirm that the MC trace's abstract action sequence corresponds
   to the implementation's executable code paths.

The reproduction scripts and captured outputs are in
`.specula-output/repro/`.

### Why the bug-report's 2 findings are the *only* MC-confirmed findings

The bug-hunting round explored five bug families with ≈ 15 billion
states across simulation runs.  Only Family 4 (Duplicate-Slot
Reconciliation & Fork-Choice State Hazards) produced counterexamples
(MC-5, MC-6).  The other families either:

- Returned no invariant violation (Families 1, 2, 5)
- Returned no violation under the spec's PoH-oracle abstraction
  (Family 3 — see "Abstraction Limitations" in `bug-report.md` §
  "Abstraction Limitations").

Therefore the only candidate bugs for this confirmation phase are the
two Family-4 findings.

---

## Bug 1: Dual-Hash Duplicate-Confirm Panic (MC-5)

- **Source**: MC (counterexample: 9 states, `MC_hunt_family4_sim3.out`)
- **Status**: KNOWN-HISTORICAL — reproduced via upstream-authored
  `#[should_panic]` tests; behavior is the documented and deliberate
  developer response to detected ≥1/3 Byzantine equivocation
- **Severity**: High (process death / liveness halt under Byzantine
  vote-equivocation that crosses the 0.52 DUPLICATE_THRESHOLD on two
  distinct hashes for the same slot)
- **Location**:
  - `core/src/replay_stage.rs:2226-2230` — `process_duplicate_confirmed_slots`
    panic site (channel-receiver path; the line cited in the bug-report
    as "line 2231" is the comment immediately after; the actual
    `assert_eq!` is at lines 2226-2230 in the current source).
  - `core/src/replay_stage.rs:4389-4393` — `mark_slots_duplicate_confirmed`
    panic site (function-call path; both share the same panic message).

### Description

When two distinct duplicate-confirmed notifications for the same slot
arrive carrying different bank hashes, the `assert_eq!(prev_hash,
duplicate_confirmed_hash, "Additional duplicate confirmed notification
for slot {slot} with a different hash")` fires and panics the validator
process.  This requires `DUPLICATE_THRESHOLD = 0.52` of stake to be
accumulated on **each** of two distinct (slot, hash) pairs — implying
≥ 4% Byzantine stake equivocating across forks plus honest stake split.

### Prerequisites

```
Prerequisites:
- [code] Function reachable from public API: VERIFIED — call chain
  cluster_info_vote_listener → track_optimistic_confirmation_vote
  (cluster_info_vote_listener.rs:705) → returns reached_duplicate_confirmed
  → sender.send(...) → process_duplicate_confirmed_slots
  (replay_stage.rs:2205-2254)
- [code] Two distinct (slot, hash) pairs can each reach DUPLICATE_THRESHOLD:
  VERIFIED — VoteStakeTracker (vote_stake_tracker.rs:14-38) accumulates
  per-(slot, hash), no cross-hash dedup at this layer
- [spec] Developer intent on panic-vs-warn semantics:
  VERIFIED — anza-xyz/agave PR #2700 (commit 1444baa426, 2024-08-22,
  Author: Ashwin Sekar @anza.xyz) explicitly added the panic with
  `#[should_panic]` tests.  PR feedback notes: "catch panic explicitely,
  comments, add root test case", "add custom string to panic message",
  "use should_panic".  This is deliberate developer intent: halt is
  the chosen response to detected ≥0.52 dup-conf-on-two-hashes (which
  implies ≥1/3-equivalent Byzantine-induced state).
- [spec] Byzantine threshold for triggering: VERIFIED — DUPLICATE_THRESHOLD
  = 1.0 − SWITCH_FORK_THRESHOLD − DUPLICATE_LIVENESS_THRESHOLD =
  1.0 − 0.38 − 0.1 = 0.52 (replay_stage.rs:113-115).  For BOTH hashes
  to cross 0.52, total = ≥ 1.04, so ≥ 4% of stake must equivocate.
```

### Counterfactual fix check

NOT APPLICABLE.  This is a local-property finding ("a specific
`assert_eq!` site panics on a specific input") rather than a system-wide
property finding.  Phase 2 explicitly says: "The violated property is
local — a specific function returns the wrong value, a specific check
is missing on a specific code path.  Re-running TLC contributes nothing
in these cases."

### Report Tier

**Tier C** — record only, not submitted.

Rationale: The panic is **deliberate developer intent** evidenced by
PR #2700 with three `#[should_panic]` tests.  The maintainers know
about the dual-hash case, have explicitly chosen the halt response
over the alternative (warn-and-discard), and have written tests that
enforce the panic.  Per the bug-confirmation guide Step 3:

> Developer says "we know about this, it's a deliberate trade-off"
> → Classify as NOT a bug unless you can show their trade-off analysis
> is flawed.

The trade-off (halt > continue under detected Byzantine equivocation)
is defensible — continuing under detected ≥1/3 Byzantine state risks
forking and arbitrary safety violation; halting is the standard BFT
"abort on detected safety-impossible state" pattern.  An argument can
be made that the threshold (≥4% Byzantine, not ≥33%) is uncomfortably
low and that a `warn!` would be preferable, but this is a design-tradeoff
discussion rather than a clear bug.

### Trigger scenario

From `MC_hunt_family4_sim3.out`:

| Step | Action | Effect |
|------|--------|--------|
| 1 | Init | all towers empty, only genesis rooted |
| 2 | ByzVoteOnBothForks(v4, 2, hB, hA) | Byzantine v4 emits two Vote-txs for slot 2 with hashes hB and hA |
| 3-4 | RecordVote(v3, 3, hB), RecordVote(v4, 1, hA) | decoration |
| 5 | ByzInjectDupConfirmSignal(2, hA) | first DupConf signal |
| 6 | ByzInjectDupConfirmSignal(2, hB) | second DupConf signal with DIFFERENT hash |
| 7 | decoration |
| 8 | ProcessDuplicateConfirmedSignal(v3, 2, hB) | v3 records duplicateConfirmed[2]={hB} |
| 9 | ProcessDuplicateConfirmedSignal(v1, 2, hA) | v1 sees existing duplicateConfirmed[2]={hB} ≠ hA → assert_eq! fires → v1 panics |

The MC's `ByzInjectDupConfirmSignal` is an over-approximation: in the
real cluster the DupConf signal is produced only when ≥0.52 of stake
crosses the threshold on a (slot, hash).  Two distinct (slot, hash)
pairs each crossing 0.52 is reachable with ≥4% Byzantine stake (plus
honest split across the two leader-equivocated banks).

### Developer intent investigation

- **PR #2700 (anza-xyz/agave, 2024-08-22, Ashwin Sekar)**:
  *"replay: do not early return when marking slots duplicate confirmed"*
  - Changed `return` → `continue` so a single bad slot does not abort
    processing of the rest of the batch.  This was the actual bug fix.
  - The `assert_eq!` was **kept** by deliberate decision; the PR
    feedback log shows iterations adding the custom message and the
    `#[should_panic]` test.
  - Author Ashwin Sekar is the primary maintainer of consensus code
    at Anza.

- **Test `test_mark_slots_duplicate_confirmed`** in
  `core/src/replay_stage.rs:10159-10275` has:
  `#[should_panic(expected = "Additional duplicate confirmed notification for slot 6")]`

- **Test `test_process_duplicate_confirmed_slots`** (two variants:
  `same_batch`, `seperate_batches`) — `core/src/replay_stage.rs:10277-...`
  — also `#[should_panic]` with the same message.

- These three tests collectively encode the developers' position that
  the panic is the correct response to dual-hash duplicate-confirm.

### Reproduction test

- `.specula-output/repro/test_bug1_mc5_dup_confirm_panic.sh`
- Runs the three upstream `#[should_panic]` tests against the live
  agave source.  Each test triggers the panic at
  `replay_stage.rs:2226` (or :4389) via legitimate public-API
  function calls — no internal-state injection, just the documented
  duplicate-confirm code path with two different hashes for slot 6.

### Reproduction result

**PASS (panic fires; all three tests pass)**.  Output excerpt
(`.specula-output/repro/test_bug1_output.txt`):

```
thread 'replay_stage::tests::test_mark_slots_duplicate_confirmed' panicked at
core/src/replay_stage.rs:4389:17:
assertion `left == right` failed: Additional duplicate confirmed notification
for slot 6 with a different hash
  left: FXeAfSxNwkdxWdfc9uBfVHto3yXZtFyrUDjiU9udww2Y
 right: A9vDWdmLRsKR167xuYTtUfVE17cVS62mZPMUBtagxfKm
test replay_stage::tests::test_mark_slots_duplicate_confirmed - should panic ... ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 611 filtered out;
finished in 0.45s
```

And:

```
thread 'replay_stage::tests::test_process_duplicate_confirmed_slots::seperate_batches' panicked at
core/src/replay_stage.rs:2226:21:
assertion `left == right` failed: Additional duplicate confirmed notification
for slot 6 with a different hash
test replay_stage::tests::test_process_duplicate_confirmed_slots::same_batch - should panic ... ok
test replay_stage::tests::test_process_duplicate_confirmed_slots::seperate_batches - should panic ... ok

test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 610 filtered out;
finished in 0.47s
```

These three lines (one per test variant) match the MC counterexample:
the `assert_eq!` fires when two different hashes arrive for the same
slot.

### Recommendation

Treat as documented design choice, not a bug.  If escalated to upstream
at all, frame as a discussion about whether to convert the `assert_eq!`
to `warn!` + slashing-evidence-emit when on-chain slashing is
implemented (referenced issues solana-labs/solana #7521, #8113, both
multi-year OPEN).  Until slashing is in place, the halt is the
conservative response.

---

## Bug 2: Tower-Stranding via PurgeUnconfirmedSlot (MC-6)

- **Source**: MC (counterexample: 11 states, `MC_hunt_family4_mc6_sim.out`)
- **Status**: KNOWN-HISTORICAL — the structural state (Tower retains
  vote on slot whose bank-forks entry has been purged) is real and
  reachable, but the "Should never consider switching to ancestor"
  panic at `consensus.rs:1104` is unreachable in this scenario because
  the safeguard at `consensus.rs:1041-1074` (the "freebie SwitchProof"
  path) catches it first.  PR #28172 (commit `c2bb2b8e6`, 2022-10-03)
  is the historical fix that addressed the closely-related "reset to
  last voted slot when marked duplicate" issue.
- **Severity**: Medium (liveness hazard / refactor risk — internal state
  inconsistency that depends on a workaround comment-marked
  "TODO: Properly handle this case"; no externally observable harm
  under current code)
- **Location**:
  - `core/src/replay_stage.rs:2019-2124` — `purge_unconfirmed_slot`
    (the asymmetric mutation: clears bank_forks, ancestors, descendants,
    progress, blockstore — but NOT the Tower)
  - `core/src/replay_stage.rs:1921-1929` — `dump_then_repair_correct_slots`
    (the call site that triggers the purge after a dup-conf with
    different hash)
  - `core/src/consensus.rs:1041-1074` — the "freebie SwitchProof"
    safeguard that prevents the consensus.rs:1104 panic in this scenario
  - `core/src/consensus.rs:1100-1109` — the would-be panic site
    "Should never consider switching to ancestor"

### Description

After `purge_unconfirmed_slot(s)` clears slot `s` from the
local fork-choice view (bank_forks, ancestors, descendants, progress,
blockstore), the Tower struct still contains the vote on slot `s`.  The
spec invariant `TowerVotesAreOnExistingForks` (`∀ v, vote ∈ tower[v].votes :
vote.slot ∉ purgedView[v]`) is violated in this state.  However, the
documented safeguard at `consensus.rs:1041-1074` detects this state on
the next `make_check_switch_threshold_decision` and returns a "freebie"
`SwitchForkDecision::SwitchProof(Hash::default())` instead of reaching
the panic at line 1104.

The freebie path is documented with the comment:

```
// Our last vote slot was purged because it was on a duplicate fork,
// don't continue below where checks may panic. We allow a freebie vote
// here that may violate switching thresholds
// TODO: Properly handle this case
```

So the panic is reachable in the abstract state model (the spec
invariant fires), but the executable code has a workaround that
catches it.  The "may violate switching thresholds" line is a real
safety concession — the validator may vote on a fork without the
documented 38% switch-threshold evidence — but the implementation
accepts this as a trade-off for liveness during fork-recovery from
the wrong fork.

### Prerequisites

```
Prerequisites:
- [code] PurgeUnconfirmedSlot does not touch the Tower:
  VERIFIED — sed -n '2019,2124p' core/src/replay_stage.rs has no
  tower mutation (verified by the reproduction script's grep step).
- [code] Stranded state is reachable from public API:
  VERIFIED — call chain ClusterInfoVoteListener (gossip) →
  DupConfMsg → process_duplicate_confirmed_slots →
  check_slot_agrees_with_cluster (SlotStateUpdate::DuplicateConfirmed)
  → mark_fork_invalid_candidate → dump_then_repair_correct_slots
  → purge_unconfirmed_slot (replay_stage.rs:1921)
- [code] consensus.rs:1041-1074 safeguard fires when tower.last_voted_slot
  is purged: VERIFIED — fork_choice retains the (last_voted_slot,
  last_voted_hash) entry with latest_invalid_ancestor = Some(last_voted_slot)
  even after the bank-forks-side purge.  progress.get_hash(last_voted_slot)
  returns None after purge, so the .map(...).unwrap_or(true) branch hits
  the freebie path and returns SwitchProof.
- [spec] Developer intent on the asymmetric purge:
  VERIFIED — the freebie-path comment "TODO: Properly handle this case"
  is explicit acknowledgment that the asymmetric purge is suboptimal
  but tolerated.  PR #28172 (commit c2bb2b8e6, Justin Starry, 2022-10-03)
  is the historical fix that addressed the related reset-fork case.
  The implementation choice is to accept the structural inconsistency
  rather than to refactor purge to also clear the tower.
```

### Counterfactual fix check

The proposed fix from the bug-report Recommendation #1 ("atomic
purge+tower-adjust: when `purge_unconfirmed_slot(s)` removes slot `s`
from `bank_forks`, simultaneously roll the Tower back") is a system-wide
property change (it would clear the structural inconsistency that the
TowerVotesAreOnExistingForks invariant detects).  However, in this
case the counterfactual check is not informative because:

- The MC trace's bad state (TowerVotesAreOnExistingForks violated)
  exists at the *spec model* level, where the freebie-path safeguard
  was deliberately not modeled.
- In the *implementation*, the would-be panic is gated by the
  consensus.rs:1041-1074 safeguard, which is functionally equivalent
  to the counterfactual fix (it catches the stranded state before any
  externally-observable effect).
- Therefore the MC trace's invariant violation does not correspond to
  observable code-level harm.  The framing should be downgraded from
  "panic / liveness halt" to "structural state inconsistency relying
  on a workaround safeguard."

```
Counterfactual fix check:
- Applied edit: NOT EXECUTED — the freebie-path safeguard at
  consensus.rs:1041-1074 already implements an equivalent compensating
  action in the implementation.  Re-running TLC with the equivalent
  spec edit would be informative but the bug claim's *observable*
  harm is already null.
- Conclusion: reframed from "process death / liveness halt" to
  "structural state inconsistency that the freebie-path safeguard
  catches at runtime."  The freebie path is documented but explicitly
  marked TODO; refactoring would be cleaner but is not required for
  current safety.
```

### Report Tier

**Tier C** — record only, not submitted.

Rationale: The structural state-stranding is real and the modeling
brief correctly identifies it as a "future-refactor risk."  However,
the executable code does not panic in this scenario because of the
documented safeguard.  The "freebie vote may violate switching
thresholds" concession is acknowledged in the comment as a trade-off
for fork-recovery liveness.  Reporting this as a bug to maintainers
would be redundant — they already have the TODO comment and PR #28172
on record.

### Trigger scenario

From `MC_hunt_family4_mc6_sim.out`:

| Step | Action | Effect |
|------|--------|--------|
| 1 | Init | initial state |
| 2 | ByzVoteOnBothForks(v4, 2, hB, hA) | Byz equivocates on slot 2 |
| 3 | RecordVote(v3, 1, hA) | v3 honestly votes on canonical (1, hA) |
| 4 | RecordVote(v1, 1, hA) | v1 honestly votes on (1, hA); tower[v1] now has the vote |
| 5 | RecordVote(v2, 3, hB) | decoration |
| 6 | ByzInjectDupConfirmSignal(1, hB) | Byz DupConf for slot 1 with hB ≠ hA = canonical |
| 7 | ProcessDuplicateConfirmedSignal(v1, 1, hB) | v1: duplicateConfirmed[1]={hB} |
| 8-9 | decoration |
| 10 | PurgeUnconfirmedSlot(v4, 1) | v4 purges slot 1 |
| 11 | PurgeUnconfirmedSlot(v1, 1) | v1 purges slot 1; tower[v1].votes=[(1, hA)] ∧ 1 ∈ purgedView[v1] — **invariant violated** |

At step 11, the implementation would have:
- v1's bank_forks does not contain slot 1
- v1's progress does not contain slot 1
- v1's heaviest_subtree_fork_choice has (1, hA) marked invalid
  (latest_invalid_ancestor = Some(1))
- v1's tower has last_voted_slot = 1, last_voted_hash = hA

When v1 next calls select_vote_and_reset_forks → check_switch_threshold:
- The safeguard at consensus.rs:1041-1074 detects:
  - `latest_invalid_ancestor(&(1, hA))` returns Some(1)
  - `progress.get_hash(1)` returns None → unwrap_or(true) → freebie path
  - Returns `SwitchForkDecision::SwitchProof(Hash::default())`
- The would-be panic at consensus.rs:1104 is not reached.

### Developer intent investigation

- **PR #28172 (solana-labs/solana, 2022-10-03, Justin Starry)**:
  *"Allow validators to reset to the slot which matches their last voted
  slot"*
  - Adds the test `test_unconfirmed_duplicate_slots_and_lockouts_for_non_heaviest_fork`
    that exercises the duplicate-confirm-then-reset path.
  - The fix is in `select_vote_and_reset_forks` and is the historical
    workaround for the *reset* side of the stranded-tower hazard.
  - The PR does NOT modify `purge_unconfirmed_slot` to clear the
    tower — the developers chose to handle the asymmetric state at
    consumer sites rather than fix the underlying purge.

- **Comment at consensus.rs:1063-1066** (the freebie path):
  > // Our last vote slot was purged because it was on a duplicate fork,
  > // don't continue below where checks may panic. We allow a freebie vote
  > // here that may violate switching thresholds
  > // **TODO: Properly handle this case**

  This is direct developer acknowledgment that the asymmetric purge is
  known and accepted as a workaround, with "Properly handle this case"
  left as future work.

- **Test `test_purge_unconfirmed_duplicate_slot`** in
  `core/src/replay_stage.rs:6978-7127` exercises the function in
  isolation but explicitly does NOT assert anything about the Tower.
  This is consistent with the asymmetry being intentional.

### Reproduction test

- `.specula-output/repro/test_bug2_mc6_purge_tower_stranding.sh`
- Runs:
  - `test_purge_unconfirmed_duplicate_slot` — confirms the
    bank_forks/progress clearing behavior (the MC trace's
    `PurgeUnconfirmedSlot` action's effect on `purgedView`).
  - `test_unconfirmed_duplicate_slots_and_lockouts` and
    `test_unconfirmed_duplicate_slots_and_lockouts_for_non_heaviest_fork`
    — exercise the duplicate-confirm + reset-fork recovery flow that
    the freebie-path safeguard supports.
- Greps `purge_unconfirmed_slot`'s body for any tower mutation
  (none found — confirming the asymmetry).
- Displays the freebie-path safeguard source as documentation of the
  workaround.

### Reproduction result

**PASS (state-stranding state IS reachable; would-be panic is NOT
reachable due to the safeguard).**  Output excerpt
(`.specula-output/repro/test_bug2_output.txt`):

```
test replay_stage::tests::test_purge_unconfirmed_duplicate_slot ... ok
test replay_stage::tests::test_purge_unconfirmed_duplicate_slots_and_reattach ... ok

test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; ...

test replay_stage::tests::test_unconfirmed_duplicate_slots_and_lockouts ... ok
test replay_stage::tests::test_unconfirmed_duplicate_slots_and_lockouts_for_non_heaviest_fork ... ok

test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; ...

--- (d) The structural asymmetry: purge_unconfirmed_slot has no tower mutation ---
    (no tower mutation found — confirming the asymmetric purge)
```

The reproduction confirms:

1. `purge_unconfirmed_slot` clears bank_forks/progress (the MC trace's
   modeling is accurate).
2. The function has no tower mutation (the asymmetry the MC detects
   is structurally present in the source).
3. The downstream duplicate-confirm + reset path passes correctly
   (the safeguard machinery works as documented).
4. The "Should never consider switching to ancestor" panic at
   consensus.rs:1104 does NOT fire in this scenario (the freebie-path
   safeguard catches it first).

### Recommendation

Two layered options, escalating in invasiveness:

1. **Cleanup-only (preferred)**: Replace the TODO comment at
   consensus.rs:1066 with a documented invariant + a
   `debug_assert!(progress.get_hash(last_voted_slot).is_none())` so
   that the freebie path is justified by an explicit "tower has
   vote on purged slot" precondition rather than left as an unmarked
   workaround.

2. **Refactor (bigger change)**: Atomic purge+tower-adjust — when
   `purge_unconfirmed_slot(s)` removes slot `s` from `bank_forks`,
   simultaneously roll the Tower back to the deepest non-purged
   vote (or set `stray_restored_slot` so that
   `is_stray_last_vote()` returns true and the existing
   `empty_ancestors_due_to_minor_unsynced_ledger()` path handles it).
   This removes the asymmetry and the freebie-path workaround
   together.

Neither is urgent because (a) the freebie path catches the panic and
(b) the safety concession ("freebie vote may violate switching
thresholds") is bounded (the validator was on the wrong fork anyway,
since the duplicate-confirm came from the cluster with ≥ 0.52 stake
on a different hash).

---

## Filtered Findings (not submitted to maintainers)

### Code-review-only items (R-1..R-7, per modeling brief §6.3)

All 7 of these are explicitly labeled "Suggested action: Discuss with
maintainers" in the modeling brief, which means they are design audit
items rather than concrete bugs.  They are filtered out from this
report per the bug-confirmation skill's Phase 1 Step 1 ("filter out
defensive coding suggestions, style issues, and theoretical-only
concerns"):

| ID | Description | Filter reason |
|----|-------------|---------------|
| R-1 | `Default for Tower` sets `root_slot = Some(0)` | Design-audit / sentinel choice; no externally observable harm |
| R-2 | `assert!` in `adjust_lockouts_after_replay` doesn't cover legacy Tower1_7_14 empty-stack case | Defensive coding; legacy path not reachable in current production |
| R-3 | Refresh-vote `last_vote_tx_blockhash`/`last_timestamp` regress on crash | Non-safety state; cosmetic on restart |
| R-4 | `SlotHashKey` indexes on bank_hash but vote-txs commit to block_id | Design audit; no current divergence |
| R-5 | Three divergent stake views (`BlockCommitment`, `VoteTracker`, `LatestValidatorVotesForFrozenBanks`) | Design audit; documented as intentionally separate |
| R-6 | "Should never consider switching to ancestor" panic reachable post-purge — same as MC-6 | Covered above as Bug 2; freebie-path safeguard catches it |
| R-7 | Single-depth threshold check argued in #5850 to be insufficient | Long-running discussion item; PR #34120 already addressed depth-4 |

### MC-checkable findings that did NOT produce counterexamples

Per `bug-report.md` § "Not Reproduced":

- **MC-1, MC-4 (Family 3, OC equivocation accounting)**: Not reproduced
  due to a stated spec abstraction limitation (the spec assumes a
  global `CanonicalSlotHash[slot]`; the real implementation can have
  leader equivocation or partition-driven divergent leader-frozen
  hashes that split honest votes).  Documented as a future-iteration
  modeling extension, not a discovered bug.
- **MC-2 (Family 1, Tower adoption/crash)**: 1.49 B states explored,
  no `LockoutSafety` or `TowerConsistentWithPersistedAfterCrash`
  violation.
- **MC-3, MC-7 (Family 2, Switch-threshold via gossip-vote)**: 1.86 B
  states, no `SwitchProofRequiresRealLockout` violation.
- **MC-5 lockout depth (Family 5)**: 1.46 B states, no
  `LockoutSafety` / `RootedSlotsForkConsistent` / `NoEquivocatingVoteFromHonest`
  violation.
- **MC-8 (Family 1, future tower from snapshot)**: Subsumed by MC-2's
  exploration; no violation.

None of these are "false positives" because no positive claim was made
— the model check ran and reported no violation.  The "Abstraction
Limitations" notes in the bug-report explain why some hypothesis
families (MC-1/MC-4) cannot be confirmed under the current spec
abstraction.

---

## Methodology notes

### Why both findings are KNOWN-HISTORICAL rather than NEW

The bug-confirmation skill distinguishes:

- **NEW bug**: A finding that doesn't match an existing JIRA, CVE,
  upstream issue, or already-accepted report.  MUST have a new
  reproduction test.
- **KNOWN-HISTORICAL bug**: A finding that matches existing upstream
  evidence.  The existing ticket / PR / `#[should_panic]` test serves
  as confirmation — no new reproduction required.

MC-5 is KNOWN-HISTORICAL because:
- anza-xyz/agave PR #2700 explicitly added the panic with developer-
  written `#[should_panic]` tests
- The PR commit message and feedback log show the panic semantics
  were intentional

MC-6 is KNOWN-HISTORICAL because:
- The asymmetric purge is documented at consensus.rs:1063-1066 with
  the explicit "TODO: Properly handle this case" comment
- solana-labs/solana PR #28172 is the historical fix for the
  related reset-fork case
- The freebie-path safeguard is itself the developers' acknowledged
  workaround

Per the skill, both can be classified WITHOUT new reproductions.
I nonetheless executed the upstream tests to verify the behavior
reproduces in our environment and to capture the exact panic-message
output as concrete evidence.

### Phase 1 → Phase 2 → Phase 3 progression

For each finding I ran:

1. **Phase 1 Investigation** (5 sub-steps):
   - Step 1 (Triage filters): Both findings have observable harm
     stated ("process death", "tower state inconsistency"); fell
     through to Step 2.
   - Step 2 (Code audit): Located the buggy code, traced call chains,
     identified existing safeguards.  For MC-5, no safeguard before
     the panic (the panic IS the response).  For MC-6, the freebie-path
     safeguard at consensus.rs:1041-1074 catches the would-be panic.
   - Step 3 (Developer intent): Found PR #2700 + `#[should_panic]`
     tests for MC-5 (deliberate intent); found freebie-path comment
     + PR #28172 for MC-6 (acknowledged workaround).
   - Step 4 (Prerequisite verification): All prerequisites verified
     against source.
   - Step 5 (Precedent re-check): No precedent cited by these
     findings, skipped.

2. **Phase 2 Counterfactual Fix Check**:
   - For MC-5: NOT APPLICABLE (local property, single panic site).
   - For MC-6: Reframed via Step 4 prerequisite verification, no TLC
     re-run needed because the freebie-path safeguard already implements
     an equivalent compensating action.

3. **Phase 3 Reproduction**: Executed upstream-authored tests
   covering both findings.  Both PASS (the upstream tests behave as
   the developers intend, which is the panic for MC-5 and the
   safeguarded recovery for MC-6).

### Final tier assignment

Both findings are Tier C (record only, not submitted):

- **MC-5**: Deliberate developer-intended halt-on-detected-Byzantine
  response, with `#[should_panic]` tests.  No alternative
  recommendation that the developers haven't already considered.
- **MC-6**: Internal state inconsistency caught by existing
  safeguard; the documented `TODO` confirms the maintainers are aware.

If a Tier B / Tier A escalation were warranted, the strongest case
would be MC-5 reframed as "halt-trigger threshold (≥0.52 dup-conf on
two hashes, implying ≥4% Byzantine + honest split) is uncomfortably
low; consider warn-instead-of-halt once slashing exists."  But this
is a discussion item for the consensus team rather than a concrete
bug report.
