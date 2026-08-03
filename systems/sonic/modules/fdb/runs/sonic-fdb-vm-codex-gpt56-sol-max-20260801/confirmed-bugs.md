# Confirmation Report — fdb

## Final Result

Reproduced bugs: 6 = 4 NEW + 2 KNOWN-unfixed + 0 KNOWN-fixed + 0 UNKNOWN
Masked live findings: 1
Env-limited findings: 0
False positives: 0
Dropped: 0
Needs more info: 0
Pending repair: 0
Incomplete: 0
Deferred: 0
Total disposition entries: 7
Dispositions: 7 total = 6 reproduced + 0 env-limited + 1 masked + 0 false-positive + 0 needs-more-info + 0 dropped + 0 pending-repair + 0 incomplete + 0 deferred

| Entry | Finding | Status | Counts as final bug? |
|---|---|---|---|
| 1 | MC-1 | REPRODUCED | yes |
| 2 | MC-2 | REPRODUCED | yes |
| 3 | MC-3 | REPRODUCED | yes |
| 4 | MC-4 | MASKED | no |
| 5 | MC-5 | REPRODUCED | yes |
| 6 | MC-6 | REPRODUCED | yes |
| 7 | MC-7 | REPRODUCED | yes |

## Entry 1: A delayed FLUSHED callback deletes a post-flush relearn

- **Finding ID**: MC-1
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-1/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: orchagent/fdborch.h:84
- **Severity**: Medium

## Description

The counterexample is genuine, but it demonstrates an over-strong epoch invariant rather than a wrong production outcome. Request 1 removes the only matching ASIC entry; request 2 then succeeds idempotently over an empty set. The delayed request-1 acknowledgement clears the boolean last written by request 2, but also correctly removes the stale software entry, leaving ASIC, cache, STATE_DB, and counters aligned.

## Trigger scenario

A normal dynamic FDB learn is followed by two matching `FLUSHFDBREQUEST` `PORTVLAN` operations before processing request 1’s callback. Both SAI calls succeed. The first removes the entry; the second finds none. The delayed consolidated request-1 callback then matches scope, type, MAC, and `is_flush_pending`.

The counterexample reaches this condition at State 11 (`pendingEpoch=2`, ASIC absent) and records `ackEpoch=1`, `markedEpoch=2` at State 15.

## Developer intent

[PR #2136](https://github.com/sonic-net/sonic-swss/pull/2136) introduced `is_flush_pending` as a membership guard preventing callbacks from deleting entries outside a pending flush window. Its implementation and tests do not promise per-request epoch ownership. The [SAI FDB notification payload](https://github.com/opencomputeproject/SAI/blob/master/inc/saifdb.h) likewise has event, FDB entry, and attributes but no flush request identifier.

Upstream issue and open/closed/merged PR searches, including recently merged work, found related asynchronous-flush precedents [#1470](https://github.com/sonic-net/sonic-swss/pull/1470) and [#2136](https://github.com/sonic-net/sonic-swss/pull/2136), but no prior report of this exact overlapping-request epoch mechanism. Novelty is therefore `NEW`.

## Reproduction result

Executed [test_bugMC-1_overlapping_flush.sh](/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/repro/test_bugMC-1_overlapping_flush.sh):

```text
MC1_REPRO level=0 public_api_two_flushes timing=none
MC1_LEVEL=0 requests=2 flush1_had_entry=1 flush2_had_entry=0 pending_after_second=1 request_elapsed_ms=0
MC1_LEVEL=0 after_old_ack cache_present=0 state_db_present=0 asic_present=0 vlan_count=0 port_count=0
MC1_LEVEL=0 after_second_ack cache_present=0 state_db_present=0 asic_present=0 vlan_count=0 port_count=0
[  PASSED  ] 1 test.
MC1_REPRO level=1 public_api_two_flushes timing=delayed_callback
MC1_LEVEL=1 requests=2 flush1_had_entry=1 flush2_had_entry=0 pending_after_second=1 request_elapsed_ms=0
MC1_LEVEL=1 after_old_ack cache_present=0 state_db_present=0 asic_present=0 vlan_count=0 port_count=0
MC1_LEVEL=1 after_second_ack cache_present=0 state_db_present=0 asic_present=0 vlan_count=0 port_count=0
[  PASSED  ] 1 test.
MC1_REPRO level=2 injection=counterexample_state_11
MC1_LEVEL=2 injected=counterexample_state_11 cache_present=1 pending=1 asic_present=0
MC1_LEVEL=2 after_old_ack cache_present=0 state_db_present=0 asic_present=0 vlan_count=0 port_count=0
[  PASSED  ] 1 test.
MC1_REPRO level=3 public_api_two_flushes source_change=timing_only
MC1_LEVEL=3 requests=2 flush1_had_entry=1 flush2_had_entry=0 pending_after_second=1 request_elapsed_ms=40
MC1_LEVEL=3 after_old_ack cache_present=0 state_db_present=0 asic_present=0 vlan_count=0 port_count=0
MC1_LEVEL=3 after_second_ack cache_present=0 state_db_present=0 asic_present=0 vlan_count=0 port_count=0
[  PASSED  ] 1 test.
MC1_ESCALATION_COMPLETE invariant_mismatch=1 live_harm=0 real_consumer_wrong_outcome=none
```

Levels 0/1 trigger the marker mismatch using normal operations, but no live harm. Level 2 injects exactly counterexample State 11. `MirrorOrch::updateFdb` (`orchagent/mirrororch.cpp:1739`) is a real delete consumer, but the deletion is correct because the corresponding ASIC entry is already absent. No bad state exists for a downstream mechanism to resolve or mask.

## Recommendation

Revise `FlushAckMatchesRequest` to prohibit deletion of an entry incarnation not covered by any successful matching flush, while preserving scope/type checks. It should not require the callback epoch to equal the latest write to a boolean that has no request identity.

The required semantic draft is at [repair-request.body.md](/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-1/repair-request.body.md).

## Repair round 1 evidence
<!-- specula-repair-token: 8e01f9956a293229bbff94b1d6f37de7 -->
- **Repair request**: `/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/spec/repair-requests/RR-001.md`
  Read its updated `## Evidence` before confirming the current violation.
- **Phase 3 result**: r1 (phase3-repair): replaced unsupported epoch equality with execution-time incarnation coverage, passed all traces and MC.cfg, and reran every hunt; the scoped hunt now reports a distinct post-flush-relearn violation in `output/repair_final_RR001_mc1_bfs.out`.
- **Current violation analysis**: A successful dynamic flush removes generation 1 and marks the cached key with a boolean pending flag. SAI then relearns the same key on the same port; the duplicate path leaves that flag attached to the current semantic incarnation. A delayed FLUSHED callback tests only scope, type, MAC, and the boolean, so it deletes software generation 2 while ASIC/kernel retain it.
- **Counterexample**: `spec/output/repair_final_RR001_mc1_bfs.out`

## Phase 4 confirmation after repair round 1

- **Source**: MC
- **Novelty**: KNOWN (cite: https://github.com/sonic-net/sonic-swss/pull/2136; fix-status: unfixed)
- **Location**: orchagent/fdborch.h:84
- **Severity**: High

## Description

A successful dynamic flush removes the ASIC’s generation-1 entry and marks the cached entry using only `is_flush_pending`. A legitimate same-key, same-port `SAI_FDB_EVENT_LEARNED` then establishes generation 2, but the duplicate-learn path preserves the old pending flag. When the delayed generation-1 `FLUSHED` callback arrives, [`handleSyncdFlushNotif()`](/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-1/worktree/orchagent/fdborch.cpp:295) checks scope, type, MAC, and that boolean—not entry incarnation—and deletes generation 2 from the cache and `STATE_DB`. The ASIC entry remains present.

Correction to the pre-repair analysis: the original RR-001 overlapping-flush trace had no reincarnation and left the stores aligned. The repaired [counterexample](/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/spec/output/repair_final_RR001_mc1_bfs.out:2478) is distinct: it includes a real post-flush relearn before the delayed callback and therefore supersedes the earlier “no live harm” conclusion.

## Trigger scenario

The Level 0 reproduction used normal notification interfaces:

1. Deliver an initial `LEARNED` notification for a dynamic VLAN FDB entry.
2. Submit a valid `PORTVLAN` `FLUSHFDBREQUEST`; SAI successfully removes the original ASIC entry.
3. Deliver a legitimate same-key, same-port `LEARNED` notification representing traffic relearning the entry.
4. Deliver the delayed consolidated `FLUSHED` notification for the earlier flush.
5. Query the real `MuxOrch` FDB consumer twice.

No FDB-orchestrator state was injected, no timing failpoint was needed, and no production source was modified to create the symptom.

## Developer intent

[Upstream PR #2136](https://github.com/sonic-net/sonic-swss/pull/2136) previously reported the same flush/add notification race and introduced the pending boolean so callbacks would delete only requested entries. That fix handles fresh insertions but misses the same-key, same-port duplicate-learn path, which retains the old flag. Searches across upstream issues and open, merged, and closed PRs found no subsequent fix for this mechanism; the current worktree still contains the boolean-only design.

## Reproduction result

The executable reproduction is [test_bugMC-1_post_flush_relearn.sh](/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/repro/test_bugMC-1_post_flush_relearn.sh:1). It was built and executed against the supplied worktree:

```text
MC1_REPRO level=0 interface=normal_notification_consumers timing=none
Running main() from ./googletest/src/gtest_main.cc
Note: Google Test filter = FdbOrchTest.BugMc1PostFlushRelearnDelayedAck
[==========] Running 1 test from 1 test suite.
[----------] Global test environment set-up.
[----------] 1 test from FdbOrchTest
[ RUN      ] FdbOrchTest.BugMc1PostFlushRelearnDelayedAck
MC1_AFTER_FLUSH flush_success=1 flush_had_entry=1 asic_present=0 cache_present=1 pending=1
MC1_AFTER_RELEARN event=SAI_FDB_EVENT_LEARNED same_key=1 same_port=1 asic_present=1 cache_present=1 pending=1 mux_consumer_port=Ethernet0
MC1_AFTER_DELAYED_FLUSHED cache_present=0 state_db_present=0 asic_present=1 vlan_count=0 port_count=0 mux_consumer_port=<empty>
MC1_PERSISTENCE_CHECK repeat_query=1 asic_present=1 cache_present=0 state_db_present=0 mux_consumer_port=<empty>
MC1_BUG_TRIGGERED expected_cache_present=1 expected_state_db_present=1 expected_mux_consumer_port=Ethernet0
[       OK ] FdbOrchTest.BugMc1PostFlushRelearnDelayedAck (141 ms)
[----------] 1 test from FdbOrchTest (141 ms total)

[----------] Global test environment tear-down
[==========] 1 test from 1 test suite ran. (141 ms total)
[  PASSED  ] 1 test.
```

The test passes because its assertions confirm the defect.

Checklist:

1. **Did Level 0 or Level 1 alone trigger it?** yes — Level 0, through normal notification consumers, without timing assistance.
2. **Was Level 2 or Level 3 used?** no; no injected FDB-orchestrator precondition or source patch was used.
3. **Which real consumer observes the wrong outcome?** [`MuxOrch::getMuxPort()`](/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-1/worktree/orchagent/muxorch.cpp:1921), whose call to `FdbOrch::getPort()` returns empty after the callback despite the ASIC entry remaining present.
4. **Is the bad state permanent or masked?** It persists indefinitely until an independent future FDB event changes the entry. A repeated consumer query remains wrong, and there is no periodic FDB reconciliation, loopback, resend, or caller guard that repairs or masks it.

## Recommendation

Associate each pending flush with the precise per-key FDB incarnation it targeted. A valid relearn—including a same-key, same-port relearn—must create a new incarnation that is not owned by the earlier flush. Process a delayed `FLUSHED` callback only when its captured incarnation still matches the current cache entry. Retain this reproduction as a regression test.

## Repair round 2 evidence
<!-- specula-repair-token: c9b5090cbe614948d636bd58bf1a0e8a -->
- **Current violation analysis**: A successful dynamic flush removes generation 1 and marks the cached key with a boolean pending flag. SAI then relearns the same key on the same port; the duplicate path leaves that flag attached to the current semantic incarnation. A delayed FLUSHED callback tests only scope, type, MAC, and the boolean, so it deletes software generation 2 while ASIC/kernel retain it.
- **Counterexample**: `spec/output/repair_RR003_MC_hunt_mc1_stale_flush_bfs.out`

## Phase 4 confirmation after repair round 2

- **Source**: MC
- **Novelty**: KNOWN (cite: https://github.com/sonic-net/sonic-swss/pull/2136; fix-status: unfixed)
- **Location**: orchagent/fdborch.h:84
- **Severity**: High

## Description

A successful dynamic flush removes ASIC generation 1 and sets only `is_flush_pending` on the cached entry. A legitimate same-key, same-port relearn establishes ASIC generation 2, but the duplicate-learn path preserves that flag; the delayed generation-1 callback then deletes generation 2 from the cache and STATE_DB while ASIC retains it.

Correction: the earlier “no live harm” result applied only to the repaired-away overlapping-flush trace. The [round-2 counterexample](/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/spec/output/repair_RR003_MC_hunt_mc1_stale_flush_bfs.out:36) contains a post-flush relearn and records `ackGen=1`, `removedGen=2`.

## Trigger scenario

1. Deliver a normal dynamic `LEARNED` notification.
2. Submit a valid `PORTVLAN` `FLUSHFDBREQUEST`; SAI removes generation 1 while its callback remains delayed.
3. Deliver the legitimate same-key, same-port `LEARNED` notification caused by subsequent traffic.
4. Deliver the older consolidated `FLUSHED` notification.
5. Query `MuxOrch::getMuxPort()` twice.

No FdbOrch state injection, failpoint, sleep, or production-logic modification was used.

## Developer intent

Merged upstream [PR #2136](https://github.com/sonic-net/sonic-swss/pull/2136) reported this same three-stage flush/add race and introduced `is_flush_pending` to prevent callbacks from deleting entries outside their flush. The fix handles newly inserted records but misses the duplicate same-port learn path, which retains the existing record and pending bit.

Open/closed issue and PR searches, including recently merged FDB changes, found no later repair. Current HEAD still contains the boolean-only design, so the known defect remains unfixed.

## Reproduction result

Executed [test_bugMC-1_post_flush_relearn.sh](/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/repro/test_bugMC-1_post_flush_relearn.sh:1) at Level 0:

`timeout 3m /users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/repro/test_bugMC-1_post_flush_relearn.sh`

```text
MC1_REPRO level=0 interface=normal_notification_consumers timing=none
Running main() from ./googletest/src/gtest_main.cc
Note: Google Test filter = FdbOrchTest.BugMc1PostFlushRelearnDelayedAck
[==========] Running 1 test from 1 test suite.
[----------] Global test environment set-up.
[----------] 1 test from FdbOrchTest
[ RUN      ] FdbOrchTest.BugMc1PostFlushRelearnDelayedAck
MC1_AFTER_FLUSH flush_success=1 flush_had_entry=1 asic_present=0 cache_present=1 pending=1
MC1_AFTER_RELEARN event=SAI_FDB_EVENT_LEARNED same_key=1 same_port=1 asic_present=1 cache_present=1 pending=1 mux_consumer_port=Ethernet0
MC1_AFTER_DELAYED_FLUSHED cache_present=0 state_db_present=0 asic_present=1 vlan_count=0 port_count=0 mux_consumer_port=<empty>
MC1_PERSISTENCE_CHECK repeat_query=1 asic_present=1 cache_present=0 state_db_present=0 mux_consumer_port=<empty>
MC1_BUG_TRIGGERED expected_cache_present=1 expected_state_db_present=1 expected_mux_consumer_port=Ethernet0
[       OK ] FdbOrchTest.BugMc1PostFlushRelearnDelayedAck (157 ms)
[----------] 1 test from FdbOrchTest (157 ms total)

[----------] Global test environment tear-down
[==========] 1 test from 1 test suite ran. (157 ms total)
[  PASSED  ] 1 test.
```

The test passes because its assertions require the defect.

Checklist:

1. **Did Level 0 or Level 1 alone trigger it?** yes — Level 0 through normal notification consumers.
2. **Level 2/3 reachability evidence:** not applicable; neither was used.
3. **Real consumer observing the wrong outcome:** [`MuxOrch::getMuxPort()`](/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-1/worktree/orchagent/muxorch.cpp:1921) returns an empty port despite ASIC generation 2 remaining present.
4. **Permanent or masked:** persistent and not self-healing. A repeated consumer query remains wrong; FdbOrch has no periodic FDB reconciliation, resend, loopback, or caller guard. Only an independent later FDB event could change the state.

## Recommendation

Track the precise per-key FDB incarnation covered by each pending flush. Every valid relearn, including a same-key/same-port event, must create a new incarnation not owned by the earlier flush; process a delayed callback only if its captured incarnation still matches. Retain this reproduction as a regression test.

---

## Entry 2: A delayed AGE event deletes a newer FDB incarnation

- **Finding ID**: MC-2
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-2/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: orchagent/fdborch.cpp:640

## Description

The completed TLC run violates `StaleEventCannotDeleteNewer`: State 9 handles generation-1 AGE while the current entry is generation 2; State 11 records `eventGen=1, removedGen=2`.

`FdbOrch` looks up the mutable current entry at line 640. Its stale check at line 652 compares only bridge ports, so a same-port reincarnation passes. The AGE path then erases the cache and `STATE_DB` at lines 797–813 without removing the newer ASIC entry.

Upstream open/closed issue and recently merged PR searches found no report or fix for this same-port incarnation mechanism. Nearby work addresses unresolvable bridge ports ([#4458](https://github.com/sonic-net/sonic-swss/pull/4458)), notification deduplication ([#4586](https://github.com/sonic-net/sonic-swss/pull/4586)), MAC-move guarding ([#4602](https://github.com/sonic-net/sonic-swss/pull/4602)), and EVPN-MH integration ([#4615](https://github.com/sonic-net/sonic-swss/pull/4615)).

## Trigger scenario

The escalation ladder reached Level 2:

- Level 0: unavailable because this environment has no live SONiC SAI/ASIC stack.
- Level 1: timing assistance cannot generate or delay hardware callbacks without that producer.
- Level 2: succeeded using the admissible counterexample sequence through public `FdbOrch::update()`:
  `LEARN(gen1) → retain AGE(gen1) → LEARN(gen2, same port) → deliver AGE(gen1)`.
- Level 3: unnecessary because Level 2 triggered deterministically.

No cache prepopulation or product-logic modification was used.

## Developer intent

Lines 637–638 state that AGE means SAI/ASIC has already removed the entry, so only software should be cleaned. The different-port branch likewise deliberately continues deletion to synchronize with ASIC state.

PR [#4586](https://github.com/sonic-net/sonic-swss/pull/4586) additionally treats identical AGE payloads as end-state-idempotent. That assumption fails across an intervening same-port re-learn because the SAI payload and `FdbData` contain no incarnation identifier.

## Reproduction result

Executed twice successfully:

```text
/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/repro/test_bugMC-2_delayed_age.sh
```

Actual output:

```text
MC-2 ladder Level 0: unavailable (no live SONiC SAI/ASIC stack in this confirmation environment)
MC-2 ladder Level 1: not triggerable here (timing alone cannot reorder callbacks without the live producer)
MC-2 ladder Level 2: injecting the admissible counterexample delivery order: LEARN(gen1), queue AGE(gen1), LEARN(gen2,same port), deliver AGE(gen1)
Running main() from ./googletest/src/gtest_main.cc
Note: Google Test filter = VxlanFdbOrchTest.BugMC2DelayedAgeDeletesNewerSamePortIncarnation
[==========] Running 1 test from 1 test suite.
[----------] Global test environment set-up.
[----------] 1 test from VxlanFdbOrchTest
[ RUN      ] VxlanFdbOrchTest.BugMC2DelayedAgeDeletesNewerSamePortIncarnation
MC-2 before_delayed_age logical_generation=2 cache_present=1 state_db_present=1 mux_port=Ethernet0
MC-2 after_delayed_age delayed_event_generation=1 cache_present=0 state_db_present=0 mux_lookup_completed=1 mux_port=<empty> sai_remove_calls=0
[       OK ] VxlanFdbOrchTest.BugMC2DelayedAgeDeletesNewerSamePortIncarnation (106 ms)
[----------] 1 test from VxlanFdbOrchTest (106 ms total)

[----------] Global test environment tear-down
[==========] 1 test from 1 test suite ran. (106 ms total)
[  PASSED  ] 1 test.
```

The test passes because its assertions capture the defective current behavior. Correct behavior would retain `cache_present=1`, `state_db_present=1`, and `mux_port=Ethernet0`.

Reproduction checklist:

1. Did Level 0 or Level 1 alone trigger it? **no**.
2. Level 2 instantiated counterexample States 4–11: `LEARN(k1,p1,gen1) → AGE(k1,p1,gen1) delayed → LEARN(k1,p1,gen2) committed → delayed AGE(gen1) removes gen2`.
3. Real consumer observing the wrong outcome: `MuxOrch::getMuxPort()` at `orchagent/muxorch.cpp:1938`. The executable observed `Ethernet0` before AGE and an empty port afterward.
4. The bad state is **persistent and not automatically masked**. `fdbsyncd` consumes the `STATE_DB` deletion, erases its own cache, and may delete the kernel entry. Its refresh path requires that erased cache row. Recovery requires an independent later LEARN or restart replay; no steady-state reconciliation repairs it.

## Recommendation

Do not delete current software state based only on MAC/BV and bridge-port equality. Before accepting AGE, either verify synchronously that the current ASIC key is absent or carry an ASIC-origin incarnation/sequence through the notification pipeline. If the current entry still exists, ignore the stale AGE without decrementing counters or notifying consumers. Retain this same-port delayed-AGE regression with fixed expectations.

## Repair round 1 evidence
<!-- specula-repair-token: 8e01f9956a293229bbff94b1d6f37de7 -->
- **Current violation analysis**: A generation-1 AGE is delayed until after generation 2 has been learned and committed for the same MAC/BV and bridge port. The AGE handler resolves the notification to the mutable current cache entry and has no same-port incarnation check; even its stale-port branch deliberately continues. It therefore deletes software generation 2 while ASIC/kernel retain the newer entry.
- **Counterexample**: `spec/output/repair_final_MC_hunt_mc2_stale_age_bfs.out`

## Phase 4 confirmation after repair round 1

- **Source**: MC
- **Novelty**: NEW
- **Location**: orchagent/fdborch.cpp:612

## Description

The repaired TLC run still violates `StaleEventCannotDeleteNewer`. States 5–8 commit generation 2; States 9–11 handle generation-1 AGE and record `eventGen=1, removedGen=2`, leaving ASIC/kernel generation 2 while cache and `STATE_DB` are absent.

`FdbOrch` resolves AGE against the current row at line 612. Its only stale check compares bridge ports at line 621, and line 630 deliberately continues deletion. Line 779 then deletes the current software state without a SAI removal.

Correction to prior wording: `FdbData` stores no generation. In this exact trace, generation-2 LEARN creates the row; in an already-learned variant, the unversioned row merely represents the current incarnation.

Upstream open/closed issue and recently merged PR searches found no report for this same-port incarnation mechanism. Nearby work concerns unresolvable bridge ports ([#4458](https://github.com/sonic-net/sonic-swss/pull/4458)), deleted bridge ports ([#2623](https://github.com/sonic-net/sonic-swss/pull/2623)), notification deduplication ([#4586](https://github.com/sonic-net/sonic-swss/pull/4586)), and downstream duplicate VXLAN deletes ([#4674](https://github.com/sonic-net/sonic-swss/pull/4674)).

## Trigger scenario

The escalation ladder reached Level 2:

- Level 0: unavailable without a live SONiC SAI/ASIC callback producer.
- Level 1: timing assistance cannot create or delay those callbacks here.
- Level 2: instantiated exact counterexample State 4 at public `FdbOrch::update()`. State 4 contains pending `LEARN(gen1)`, `AGE(gen1)`, and same-port `LEARN(gen2)`; States 5–8 deliver generation 2, followed by generation-1 AGE in States 9–11.
- Level 3: unnecessary because Level 2 reproduced deterministically twice.

No cache prepopulation, private-function call, or product-logic modification was used.

## Developer intent

Lines 609–610 state that AGE means SAI/ASIC already removed the entry, so software alone should be cleaned. The different-port branch likewise deliberately continues deletion to synchronize with ASIC state.

PR [#4586](https://github.com/sonic-net/sonic-swss/pull/4586) deduplicates byte-identical notifications, but LEARN and AGE remain distinct and no incarnation data is introduced. Existing tests cover different-port AGE and AGE-before-relearn, not delayed same-port AGE.

## Reproduction result

Executed:

```text
timeout 5m /users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/repro/test_bugMC-2_delayed_age.sh
```

Actual output:

```text
MC-2 ladder Level 0: unavailable (no live SONiC SAI/ASIC stack in this confirmation environment)
MC-2 ladder Level 1: not triggerable here (timing alone cannot reorder callbacks without the live producer)
MC-2 ladder Level 2: instantiate CE State 4 at the public FdbOrch handler boundary; deliver LEARN(gen2,same port), then delayed AGE(gen1)
Running main() from ./googletest/src/gtest_main.cc
Note: Google Test filter = VxlanFdbOrchTest.BugMC2DelayedAgeDeletesNewerSamePortIncarnation
[==========] Running 1 test from 1 test suite.
[----------] Global test environment set-up.
[----------] 1 test from VxlanFdbOrchTest
[ RUN      ] VxlanFdbOrchTest.BugMC2DelayedAgeDeletesNewerSamePortIncarnation
MC-2 Level 2 CE State 4: pending={LEARN(gen1),AGE(gen1),LEARN(gen2)} deliver=LEARN(gen2),AGE(gen1)
MC-2 before_delayed_age harness_logical_generation=2 cache_present=1 state_db_present=1 mux_lookup_completed=1 mux_port=Ethernet0
MC-2 after_delayed_age delayed_event_generation=1 cache_present=0 state_db_present=0 mux_lookup_completed=1 mux_port=<empty> sai_remove_calls=0
[       OK ] VxlanFdbOrchTest.BugMC2DelayedAgeDeletesNewerSamePortIncarnation (106 ms)
[----------] 1 test from VxlanFdbOrchTest (106 ms total)

[----------] Global test environment tear-down
[==========] 1 test from 1 test suite ran. (106 ms total)
[  PASSED  ] 1 test.
```

Correct behavior would retain `cache_present=1`, `state_db_present=1`, and `mux_port=Ethernet0`.

Reproduction checklist:

1. Did Level 0 or Level 1 alone trigger it? **no**.
2. Level 2 instantiated exact counterexample State 4: pending `{LEARN(gen1), AGE(gen1), LEARN(gen2)}`; States 5–8 commit `LEARN(gen2)` and States 9–11 deliver `AGE(gen1)`, recording `removedGen=2`.
3. Real consumer observing the wrong outcome: `MuxOrch::getMuxPort()` at `orchagent/muxorch.cpp:1938`. It returned `Ethernet0` before AGE and an empty port afterward.
4. The bad state is **persistent and not automatically masked**. `fdbsyncd` can propagate the `STATE_DB` deletion, while its refresh requires the cache row that deletion removes. Recovery requires an independent later LEARN or restart replay.

## Recommendation

Before accepting AGE, verify that the current ASIC key is absent or carry a producer-origin incarnation/sequence through the notification pipeline. If a newer entry remains, ignore the stale AGE without changing counters, `STATE_DB`, or observers. Retain this regression with fixed expectations.

## Repair round 2 evidence
<!-- specula-repair-token: c9b5090cbe614948d636bd58bf1a0e8a -->
- **Current violation analysis**: A generation-1 AGE is delayed until after generation 2 has been learned and committed for the same MAC/BV and bridge port. The AGE handler resolves the notification to the mutable current cache entry and has no same-port incarnation check; even its stale-port branch deliberately continues. It therefore deletes software generation 2 while ASIC/kernel retain the newer entry.
- **Counterexample**: `spec/output/repair_RR003_MC_hunt_mc2_stale_age_bfs.out`

## Phase 4 confirmation after repair round 2

- **Source**: MC
- **Novelty**: NEW
- **Location**: orchagent/fdborch.cpp:612

## Description

Repair-round-2 TLC output `repair_RR003_MC_hunt_mc2_stale_age_bfs.out` still violates `StaleEventCannotDeleteNewer`. State 11 records `eventGen=1, removedGen=2`: cache and `STATE_DB` are absent while ASIC/kernel retain generation 2.

The clean-source AGE handler resolves the notification against the mutable current row at line 612, checks only bridge-port equality at line 621, and deletes through `storeFdbEntryState()` at line 779. The conformance-instrumented equivalents are lines 640, 652, and 813. `FdbData` carries no incarnation identifier, so a same-port stale AGE is indistinguishable from an AGE for the current entry.

Open/closed issues, recently merged PRs, and current FDB PRs were searched on 2026-08-01. Adjacent work covers byte-identical deduplication ([#4586](https://github.com/sonic-net/sonic-swss/pull/4586)), key-based storm collapsing ([#4533](https://github.com/sonic-net/sonic-swss/pull/4533)), batch draining ([#4604](https://github.com/sonic-net/sonic-swss/pull/4604)), and ZMQ notification transport ([#4806](https://github.com/sonic-net/sonic-swss/pull/4806)); none reports this same-port incarnation deletion mechanism. Novelty remains `NEW`.

## Trigger scenario

The escalation ladder reached Level 2:

- Level 0: unavailable without a live SONiC SAI/ASIC callback producer.
- Level 1: timing assistance cannot generate and delay those callbacks in this environment.
- Level 2: instantiated counterexample State 4 through public `FdbOrch::update()`: pending `{LEARN(ev1,gen1), AGE(ev2,gen1), LEARN(ev3,gen2)}`; States 5–8 commit `ev3`, then States 9–11 deliver delayed `ev2`.
- Level 3: unnecessary because Level 2 reproduced deterministically twice.

No cache prepopulation, private-function call, or product-logic modification was used.

## Developer intent

The AGE comment states that SAI/ASIC has already removed the notified entry, so only software state should be cleaned. The different-port branch deliberately continues deletion to synchronize SONiC with SAI. Both policies assume the AGE still identifies the current ASIC incarnation.

The LRU policy only deduplicates byte-identical payloads; LEARN and AGE remain distinct. Existing tests cover different-port AGE and normal AGE-then-relearn ordering, not an older same-port AGE delivered after a newer LEARN.

## Reproduction result

Executed [test_bugMC-2_delayed_age.sh](/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/repro/test_bugMC-2_delayed_age.sh):

```text
timeout 5m /users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/repro/test_bugMC-2_delayed_age.sh
```

Actual repeat-run output:

```text
MC-2 ladder Level 0: unavailable (no live SONiC SAI/ASIC stack in this confirmation environment)
MC-2 ladder Level 1: not triggerable here (timing alone cannot reorder callbacks without the live producer)
MC-2 ladder Level 2: instantiate CE State 4 at the public FdbOrch handler boundary; deliver LEARN(gen2,same port), then delayed AGE(gen1)
Running main() from ./googletest/src/gtest_main.cc
Note: Google Test filter = VxlanFdbOrchTest.BugMC2DelayedAgeDeletesNewerSamePortIncarnation
[==========] Running 1 test from 1 test suite.
[----------] Global test environment set-up.
[----------] 1 test from VxlanFdbOrchTest
[ RUN      ] VxlanFdbOrchTest.BugMC2DelayedAgeDeletesNewerSamePortIncarnation
MC-2 Level 2 CE State 4: pending={LEARN(gen1),AGE(gen1),LEARN(gen2)} deliver=LEARN(gen2),AGE(gen1)
MC-2 before_delayed_age harness_logical_generation=2 cache_present=1 state_db_present=1 mux_lookup_completed=1 mux_port=Ethernet0
MC-2 after_delayed_age delayed_event_generation=1 cache_present=0 state_db_present=0 mux_lookup_completed=1 mux_port=<empty> sai_remove_calls=0
[       OK ] VxlanFdbOrchTest.BugMC2DelayedAgeDeletesNewerSamePortIncarnation (106 ms)
[----------] 1 test from VxlanFdbOrchTest (106 ms total)

[----------] Global test environment tear-down
[==========] 1 test from 1 test suite ran. (106 ms total)
[  PASSED  ] 1 test.
```

The decisive line is `MC-2 after_delayed_age ... cache_present=0 state_db_present=0 ... mux_port=<empty> sai_remove_calls=0`. Correct incarnation-aware behavior would retain the cache row, `STATE_DB` row, and `Ethernet0` lookup.

Reproduction checklist:

1. Did Level 0 or Level 1 alone trigger it? **no**.
2. Level 2 used exact admissible counterexample States 4–11: `LEARN(ev3,gen2,p1) → commit gen2 → AGE(ev2,gen1,p1) → removedGen=2`.
3. Real consumer observing the wrong result: `MuxOrch::getMuxPort()` at `orchagent/muxorch.cpp:1938`. It returned `Ethernet0` before AGE and an empty port afterward.
4. The state is **persistent absent an independent new LEARN or restart replay** and is not automatically masked. `fdbsyncd` can propagate the `STATE_DB` deletion and erase its cache; `macRefreshStateDB()` requires that erased row, so no steady-state reconciliation restores it.

## Recommendation

Carry a producer-origin incarnation/sequence with FDB notifications, or verify that the current ASIC key is absent before accepting AGE. A stale AGE must leave counters, cache, `STATE_DB`, and observers unchanged. Retain this test with fixed expectations.

---

## Entry 3: VTEP replacement credits the new member to the old endpoint

- **Finding ID**: MC-3
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-3/debate.md

- **Source**: MC
- **Novelty**: KNOWN (cite: https://github.com/sonic-net/sonic-swss/pull/4262#issuecomment-4347971135; fix-status: unfixed)
- **Severity**: Medium
- **Location**: orchagent/l2nhgorch.cpp:634

## Description

VTEP replacement creates the SAI member for `new_vtep_ip`, but credits `m_nhg_vtep[nh_id].ip`, which still contains the old endpoint until line 653. The resulting stale reference drives incorrect tunnel cleanup: the new tunnel is uncached while referenced, and the old tunnel is leaked.

## Trigger scenario

With old and new IMR tunnels present:

1. `SET 10 remote_vtep=192.0.2.10`
2. `SET 100 nexthop_group=10`
3. `SET 10 remote_vtep=192.0.2.20`
4. Resend step 3, then withdraw each endpoint’s IMR user and delete group 100.

This matches MC States 10–12: remove `ep2`, install member `ep1`, then incorrectly restore `ep2`’s reference.

## Developer intent

The original EVPN-MH PR explicitly acknowledged this exact stale-IP refcount bug and reported changing the argument to `new_vtep_ip`; a reviewer confirmed the fix. That PR was not merged, and current master retains the defective argument. [Developer acknowledgement](https://github.com/sonic-net/sonic-swss/pull/4262#issuecomment-4347971135), [reviewer confirmation](https://github.com/sonic-net/sonic-swss/pull/4262#issuecomment-4349558932).

## Reproduction result

Executed [test_bugMC-3_vtep_replacement.sh](/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/repro/test_bugMC-3_vtep_replacement.sh) at Level 0:

```text
timeout 5m /users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/repro/test_bugMC-3_vtep_replacement.sh

SOURCE_SHA=4f3dda156e52ed7647b1dbf900d54d87efaea455
SOURCE_UNMODIFIED=l2nhgorch.cpp plus vxlanorch.cpp:1013-1272,1711-1835
LEVEL=0 interface=L2_NEXTHOP_GROUP_TABLE normal_SET_DEL no_failpoints
INITIAL member_endpoint=192.0.2.10 old_ip_ref=1 new_ip_ref=0 l2_ref=1
REPLACEMENT actual_member_endpoint=192.0.2.20 actual_old_ip_ref=1 actual_new_ip_ref=0 l2_ref=1
REPLACEMENT expected_member_endpoint=192.0.2.20 expected_old_ip_ref=0 expected_new_ip_ref=1
RESEND old_ip_ref=1 new_ip_ref=0 corrected=no
NEW_IMR_DELETE new_tunnel_present=0 new_dynamic_tunnel_cached=0 active_sai_members=1 member_endpoint=192.0.2.20 sai_tunnel_delete_refusals=1
NEW_IMR_DELETE expected_new_tunnel_present=1 expected_new_dynamic_tunnel_cached=1 while_active_sai_members=1
OLD_IMR_DELETE old_tunnel_present=1 old_total_ref=1 old_ip_ref=1
OLD_IMR_DELETE expected_old_tunnel_present=0 expected_old_total_ref=-1
GROUP_DELETE active_sai_members=0 stale_old_tunnel_present=1 stale_old_ip_ref=1
BUG_TRIGGERED stale_old_credit=1 missing_new_credit=1 new_tunnel_deleted_while_member_live=1 old_tunnel_leaked=1 permanent_after_resend=1
```

Checklist:

1. Did Level 0 or Level 1 alone trigger it? **yes — Level 0**.
2. Level 2/3 evidence: **not applicable; neither was used**. Preconditions were created through normal `VxlanTunnelOrch::addTunnelUser()` IMR operations and normal APP_DB SET events.
3. Real consumer observing harm: `VxlanTunnelOrch::delTunnelUser()` at `orchagent/vxlanorch.cpp:1812-1828`, followed by `VxlanTunnel::deleteDynamicDIPTunnel()` at `:1205-1241`. They remove the new tunnel’s software state while its SAI member remains.
4. Permanent or masked? **Permanent until unrelated control-plane churn/restart**. An identical SET resend does not repair it, and group cleanup leaves the stale old credit. SAI’s refusal to delete a referenced hardware tunnel does not mask it because the caller still discards its endpoint and tunnel cache.

## Recommendation

Capture `old_vtep_ip` before replacement, decrement that endpoint, and credit `new_vtep_ip` immediately after successful member creation. Add rollback for partial failures and a replacement/resend/delete test asserting endpoint-specific tunnel references.

## Repair round 1 evidence
<!-- specula-repair-token: 8e01f9956a293229bbff94b1d6f37de7 -->
- **Current violation analysis**: VTEP replacement removes the old member and reference, then successfully creates a member for the new endpoint. The increment still uses the cached old endpoint because the cache is updated only after the loop. The final graph contains the new endpoint while reference accounting credits the old one; a second hunt independently reproduces the mismatch.
- **Counterexample**: `spec/output/repair_final_MC_hunt_mc4_vtep_replacement_bfs.out`

## Phase 4 confirmation after repair round 1

- **Source**: MC
- **Novelty**: KNOWN (cite: https://github.com/sonic-net/sonic-swss/pull/4262#issuecomment-4347971135; fix-status: unfixed)
- **Severity**: Medium
- **Location**: orchagent/l2nhgorch.cpp:634

## Description

After creating the SAI member for `new_vtep_ip`, line 634 credits `m_nhg_vtep[nh_id].ip`, which still holds the old endpoint until line 653. The member therefore references the new tunnel while endpoint accounting credits the old tunnel.

Correction to prior evidence: the current repair-round counterexample is States 5–7, replacing `ep1` with `ep2`; State 7 has `nhgMembers[g1] = {ep2}` but `tunnelRefs = [ep1 |-> 1, ep2 |-> 0]`. The earlier States 10–12 endpoint ordering came from an older trace.

## Trigger scenario

Using normal tunnel and APP_DB operations:

1. Establish IMR tunnels for `192.0.2.10` and `192.0.2.20`.
2. `SET 10 remote_vtep=192.0.2.10`
3. `SET 100 nexthop_group=10`
4. `SET 10 remote_vtep=192.0.2.20`
5. Resend step 4, withdraw the new endpoint’s IMR user, then withdraw the old endpoint and delete group 100.

This corresponds to the current counterexample’s `MCL2NhgUpdateVtepIpBegin(ep1,ep2)` and subsequent remove/install steps.

## Developer intent

The upstream PR discussion explicitly identifies using `new_vtep_ip` instead of the stale cached IP as the refcount fix, and its reviewer acknowledges that fix. [Developer acknowledgement](https://github.com/sonic-net/sonic-swss/pull/4262#issuecomment-4347971135), [reviewer confirmation](https://github.com/sonic-net/sonic-swss/pull/4262#issuecomment-4349558932).

PR #4262 was closed unmerged. Upstream `master` still resolves to SHA `4f3dda156e52ed7647b1dbf900d54d87efaea455` and retains the stale argument at line 634, so the known defect remains unfixed. [Current source](https://github.com/sonic-net/sonic-swss/blob/4f3dda156e52ed7647b1dbf900d54d87efaea455/orchagent/l2nhgorch.cpp#L634).

## Reproduction result

Executed [test_bugMC-3_vtep_replacement.sh](/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/repro/test_bugMC-3_vtep_replacement.sh) at Level 0:

```text
timeout 5m /users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/repro/test_bugMC-3_vtep_replacement.sh

SOURCE_SHA=4f3dda156e52ed7647b1dbf900d54d87efaea455
SOURCE_UNMODIFIED=l2nhgorch.cpp plus vxlanorch.cpp:1013-1272,1711-1835
LEVEL=0 interface=L2_NEXTHOP_GROUP_TABLE normal_SET_DEL no_failpoints
INITIAL member_endpoint=192.0.2.10 old_ip_ref=1 new_ip_ref=0 l2_ref=1
REPLACEMENT actual_member_endpoint=192.0.2.20 actual_old_ip_ref=1 actual_new_ip_ref=0 l2_ref=1
REPLACEMENT expected_member_endpoint=192.0.2.20 expected_old_ip_ref=0 expected_new_ip_ref=1
RESEND old_ip_ref=1 new_ip_ref=0 corrected=no
NEW_IMR_DELETE new_tunnel_present=0 new_dynamic_tunnel_cached=0 active_sai_members=1 member_endpoint=192.0.2.20 sai_tunnel_delete_refusals=1
NEW_IMR_DELETE expected_new_tunnel_present=1 expected_new_dynamic_tunnel_cached=1 while_active_sai_members=1
OLD_IMR_DELETE old_tunnel_present=1 old_total_ref=1 old_ip_ref=1
OLD_IMR_DELETE expected_old_tunnel_present=0 expected_old_total_ref=-1
GROUP_DELETE active_sai_members=0 stale_old_tunnel_present=1 stale_old_ip_ref=1
BUG_TRIGGERED stale_old_credit=1 missing_new_credit=1 new_tunnel_deleted_while_member_live=1 old_tunnel_leaked=1 permanent_after_resend=1
```

Exit code: `0`. The `REPLACEMENT` and `BUG_TRIGGERED` lines demonstrate the current State-7 mismatch and downstream harm.

Checklist:

1. Did Level 0 or Level 1 alone trigger it? **yes — Level 0**.
2. Level 2/3 evidence: **not applicable; neither was used**.
3. Real consumer/caller: `VxlanTunnelOrch::delTunnelUser()` at `orchagent/vxlanorch.cpp:1812-1828`, called by `EvpnRemoteVnip2pOrch::delOperation()` at `:2656`. `VxlanTunnel::deleteDynamicDIPTunnel()` at `:1205-1240` then removes the new endpoint’s cache while its SAI member remains.
4. Permanent or later resolved? **Permanent until unrelated control-plane teardown or restart.** An identical SET resend does not repair it, and group deletion leaves the stale old credit. SAI’s tunnel-deletion refusal does not mask the defect because its false return is ignored and the software state is still discarded.

## Recommendation

Capture the old endpoint before replacement, decrement that endpoint, and credit `new_vtep_ip` immediately after successful member creation. Add rollback for partial failures and a replacement/resend/withdraw/delete regression test asserting endpoint-specific tunnel references.

## Repair round 2 evidence
<!-- specula-repair-token: c9b5090cbe614948d636bd58bf1a0e8a -->
- **Current violation analysis**: VTEP replacement removes the old member and reference, then successfully creates a member for the new endpoint. The increment still uses the cached old endpoint because the cache is updated only after the loop. The final graph contains the new endpoint while reference accounting credits the old one; a second hunt independently reproduces the mismatch.
- **Counterexample**: `spec/output/repair_RR003_MC_hunt_mc4_vtep_replacement_bfs.out`

## Phase 4 confirmation after repair round 2

- **Source**: MC
- **Novelty**: KNOWN (cite: https://github.com/sonic-net/sonic-swss/pull/4262#issuecomment-4347971135; fix-status: unfixed)
- **Severity**: Medium
- **Location**: orchagent/l2nhgorch.cpp:634

## Description

After creating the SAI member for `new_vtep_ip`, line 634 credits `m_nhg_vtep[nh_id].ip`, which remains the old endpoint until line 653. This leaves the member on the new tunnel but the reference on the old tunnel, causing premature new-tunnel cleanup and an old-tunnel leak.

Correction to prior evidence: the current RR003 counterexample uses States 6–8, not round 1’s States 5–7. State 8 has `nhgMembers[g1] = {ep2}` and `tunnelRefs = [ep1 |-> 1, ep2 |-> 0]`.

## Trigger scenario

Using normal tunnel and APP_DB operations:

1. Establish IMR tunnels for `192.0.2.10` and `192.0.2.20`.
2. `SET 10 remote_vtep=192.0.2.10`
3. `SET 100 nexthop_group=10`
4. `SET 10 remote_vtep=192.0.2.20`
5. Resend step 4, withdraw each endpoint’s IMR user, then delete group 100.

This matches `MCL2NhgUpdateVtepIpBegin(ep1,ep2)` and the remove/install actions in current counterexample States 6–8.

## Developer intent

The upstream discussion explicitly identifies changing the stale argument to `new_vtep_ip` as the refcount fix, and a reviewer acknowledges it. PR #4262 was closed unmerged; upstream `master` remains at `4f3dda156e52ed7647b1dbf900d54d87efaea455` with the defective line intact. Tracker searches covering issues and recently closed/merged PRs found no later fix at this site. [Developer acknowledgement](https://github.com/sonic-net/sonic-swss/pull/4262#issuecomment-4347971135), [reviewer confirmation](https://github.com/sonic-net/sonic-swss/pull/4262#issuecomment-4349558932), [current affected source](https://github.com/sonic-net/sonic-swss/blob/4f3dda156e52ed7647b1dbf900d54d87efaea455/orchagent/l2nhgorch.cpp#L634).

## Reproduction result

Executed [test_bugMC-3_vtep_replacement.sh](/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/repro/test_bugMC-3_vtep_replacement.sh) at Level 0. The relevant production sources were unchanged from HEAD.

Command:

```text
timeout 5m /users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/repro/test_bugMC-3_vtep_replacement.sh
```

Exit code: `0`

```text
SOURCE_SHA=4f3dda156e52ed7647b1dbf900d54d87efaea455
SOURCE_UNMODIFIED=l2nhgorch.cpp plus vxlanorch.cpp:1013-1272,1711-1835
LEVEL=0 interface=L2_NEXTHOP_GROUP_TABLE normal_SET_DEL no_failpoints
INITIAL member_endpoint=192.0.2.10 old_ip_ref=1 new_ip_ref=0 l2_ref=1
REPLACEMENT actual_member_endpoint=192.0.2.20 actual_old_ip_ref=1 actual_new_ip_ref=0 l2_ref=1
REPLACEMENT expected_member_endpoint=192.0.2.20 expected_old_ip_ref=0 expected_new_ip_ref=1
RESEND old_ip_ref=1 new_ip_ref=0 corrected=no
NEW_IMR_DELETE new_tunnel_present=0 new_dynamic_tunnel_cached=0 active_sai_members=1 member_endpoint=192.0.2.20 sai_tunnel_delete_refusals=1
NEW_IMR_DELETE expected_new_tunnel_present=1 expected_new_dynamic_tunnel_cached=1 while_active_sai_members=1
OLD_IMR_DELETE old_tunnel_present=1 old_total_ref=1 old_ip_ref=1
OLD_IMR_DELETE expected_old_tunnel_present=0 expected_old_total_ref=-1
GROUP_DELETE active_sai_members=0 stale_old_tunnel_present=1 stale_old_ip_ref=1
BUG_TRIGGERED stale_old_credit=1 missing_new_credit=1 new_tunnel_deleted_while_member_live=1 old_tunnel_leaked=1 permanent_after_resend=1
```

The `REPLACEMENT`, `NEW_IMR_DELETE`, and `BUG_TRIGGERED` lines demonstrate the invariant violation and downstream harm.

Checklist:

1. Did Level 0 or Level 1 alone trigger it? **yes — Level 0**, using normal public executor and tunnel-user operations without timing assistance.
2. Level 2/3 evidence: **not applicable; neither state injection nor a source patch was used**.
3. Real consumer/caller: `EvpnRemoteVnip2pOrch::delOperation()` at `orchagent/vxlanorch.cpp:2656` calls `VxlanTunnelOrch::delTunnelUser()` at `:1812-1828`; `VxlanTunnel::deleteDynamicDIPTunnel()` at `:1205-1240` then discards the new endpoint’s tunnel state while its SAI member remains.
4. Permanent or masked? **Permanent until unrelated restart/reconstruction**. An identical SET resend does not repair the accounting, and group deletion leaves the stale old credit. SAI’s deletion refusal does not mask it because the caller still discards its software endpoint and tunnel cache.

## Recommendation

Capture the old endpoint before replacement, decrement it, and credit `new_vtep_ip` immediately after successful member creation. Add rollback for partial failures and a replacement/resend/withdraw/delete regression test asserting endpoint-specific tunnel references.

---

## Entry 4: Bridge-port teardown continues after its FDB flush fails

- **Finding ID**: MC-4
- **Status**: MASKED
- **Debate**: not run
- **Transcript**: /users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-4/debate.md

- **Source**: MC
- **Novelty**: KNOWN (cite: https://github.com/sonic-net/sonic-buildimage/issues/27835; fix-status: unfixed)
- **Location**: orchagent/fdborch.cpp:1555; orchagent/portsorch.cpp:7506

## Description

`FdbOrch::flushFDBEntries` logs a SAI flush failure but returns `void`; `PortsOrch::removeBridgePort` therefore proceeds immediately to bridge-port removal.

The implementation defect is real, but the counterexample’s `NoDanglingTopologyReference` consequence is masked: sairedis tracks the FDB entry’s bridge-port reference and rejects removal with `SAI_STATUS_OBJECT_IN_USE (-17)`. The FDB and bridge port both remain, rather than leaving an FDB reference to a removed bridge port.

## Trigger scenario

The test exercised the normal APP_DB lifecycle:

1. Configure `PORT_TABLE`, `VLAN_TABLE`, and `VLAN_MEMBER_TABLE`.
2. Delete the VLAN member normally.
3. At Level 1, inject legitimate SAI flush failures. Teardown continued and removed an unreferenced bridge port.
4. At Level 2, instantiate the learned-FDB precondition from [counterexample State 2](</users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/spec/output/MC_hunt_mc6_topology_reuse_final_bfs.out:167>) using the real virtual-SAI FDB API and a learned notification, then repeat the deletion and flush failures.

The corresponding reachable sequence is:

`APP_DB port/VLAN/member SET → dynamic FDB learned on bridge port → APP_DB VLAN-member DEL → SAI flush failure → bridge-port removal attempt`.

## Developer intent

The bridge-port path deliberately flushes FDB entries before removal. [Issue #27835](https://github.com/sonic-net/sonic-buildimage/issues/27835) previously reported the same call-site sequence and showed sairedis rejecting removal because FDB references remained.

[Merged PR #4734](https://github.com/sonic-net/sonic-swss/pull/4734) fixed one specific cause—unsupported flush-all—but retained the `void` flush API and unconditional removal attempt. [Open PR #3211](https://github.com/sonic-net/sonic-swss/pull/3211) separately proposes retaining the VLAN-member task when bridge-port removal fails.

## Reproduction result

Executed [test_bugMC-4_bridge_port_flush_guard.sh](</users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/repro/test_bugMC-4_bridge_port_flush_guard.sh>). Investigation details are in [investigation.md](</users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-4/investigation.md>).

```text
$ timeout 10m .../repro/test_bugMC-4_bridge_port_flush_guard.sh
RUN: .../tests/mock_tests/tests --gtest_filter=VxlanFdbOrchTest.MC4BridgePortRemovalIsMaskedBySaiReferenceGuard
Running main() from ./googletest/src/gtest_main.cc
[==========] Running 1 test from 1 test suite.
[ RUN      ] VxlanFdbOrchTest.MC4BridgePortRemovalIsMaskedBySaiReferenceGuard
MC4 LEVEL0 normal_app_db_delete: flush_success, bridge_port_removed=yes
MC4 LEVEL1 flush_failure: calls=2, teardown_continued=yes, bridge_port_removed=yes
MC4 LEVEL2 precondition: counterexample_state=2, learned_fdb_present=yes
MC4 LEVEL2 flush_failure: calls=2, caller_task_erased=yes
MC4 MASK sai_meta_reference_guard: remove_status=-17, expected_OBJECT_IN_USE=-17, bridge_port_present=yes, fdb_present=yes, admin_state=down
[       OK ] VxlanFdbOrchTest.MC4BridgePortRemovalIsMaskedBySaiReferenceGuard (220 ms)
[==========] 1 test from 1 test suite ran. (220 ms total)
[  PASSED  ] 1 test.
RESULT: PASS - flush failure is unobservable to PortsOrch, but the real SAI reference guard prevents a dangling bridge port
```

- Level 0 or Level 1 alone triggered the claimed invariant violation: **no**. Level 1 proved teardown continues after failure, but had no retained FDB reference.
- Level 2 used an admissible counterexample state: exact State 2, where a learned dynamic FDB entry references the current bridge-port generation.
- The real caller is `PortsOrch::doVlanMemberTask` at `orchagent/portsorch.cpp:6107-6109`. It ignores the failed `removeBridgePort` result and erases the pending DEL.
- The claimed dangling state never occurs: the sairedis reference guard masks it immediately. The adjacent state—FDB retained, bridge port retained admin-down, and no queued VLAN-member retry—persists until unrelated recovery activity.

## Recommendation

Return a status from `flushFDBEntries`, stop bridge-port removal when flushing fails, and keep the VLAN-member task pending. Also make `doVlanMemberTask` honor `removeBridgePort` failure. Retain the SAI reference guard and model it explicitly so future checking distinguishes prevented dangling deletion from stranded teardown.

## Repair round 1 evidence
<!-- specula-repair-token: 8e01f9956a293229bbff94b1d6f37de7 -->
- **Current violation analysis**: PortsOrch begins bridge-port teardown while an ASIC FDB entry still references that port. FdbOrch exposes no flush result and only logs the SAI failure, after which PortsOrch immediately removes the bridge port. Hardware retains an FDB reference to the removed topology generation; the broader scenario-1 hunt independently reaches the same root cause.
- **Counterexample**: `spec/output/repair_final_MC_hunt_mc6_topology_reuse_bfs.out`

## Phase 4 confirmation after repair round 1

- **Source**: MC
- **Novelty**: KNOWN (cite: https://github.com/sonic-net/sonic-buildimage/issues/27835; fix-status: unfixed)
- **Location**: orchagent/fdborch.cpp:1555; orchagent/portsorch.cpp:7506; orchagent/portsorch.cpp:7510

## Description

`FdbOrch::flushFDBEntries` logs a SAI flush failure but returns no status. `PortsOrch::removeBridgePort` therefore immediately attempts bridge-port removal.

The defect is real, but the claimed dangling-reference consequence is masked. sairedis tracks the retained FDB entry’s bridge-port reference and rejects removal with `SAI_STATUS_OBJECT_IN_USE (-17)`. Consequently, repaired-counterexample State 7—FDB present while the bridge port is absent—is unreachable in the implementation.

## Trigger scenario

1. Configure a port, VLAN, and VLAN member through normal APP_DB tables.
2. Instantiate repaired-counterexample State 2 using the real virtual-SAI FDB API and a learned notification.
3. Delete the VLAN member through the normal `VLAN_MEMBER_TABLE` consumer.
4. Make both admissible FDB flush calls fail.
5. Observe teardown continue, bridge-port removal return `OBJECT_IN_USE`, and `doVlanMemberTask` erase the DEL without scheduling a retry.

The real-API sequence is:

`APP_DB port/VLAN/member SET → dynamic FDB learn → APP_DB member DEL → SAI flush failure → bridge-port removal attempt`.

## Developer intent

The removal path deliberately flushes FDB entries before deleting the bridge port. [Issue #27835](https://github.com/sonic-net/sonic-buildimage/issues/27835) previously reported the same failed-flush/removal sequence and sairedis rejection at these sites.

[Merged PR #4734](https://github.com/sonic-net/sonic-swss/pull/4734) fixed one unsupported flush-all cause, but the current source still retains the `void` flush API and unconditional removal attempt.

## Reproduction result

Executed [test_bugMC-4_bridge_port_flush_guard.sh](</users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/repro/test_bugMC-4_bridge_port_flush_guard.sh>):

```text
$ timeout 10m .../repro/test_bugMC-4_bridge_port_flush_guard.sh
RUN: .../tests/mock_tests/tests --gtest_filter=VxlanFdbOrchTest.MC4RepairTraceIsBlockedBySaiReferenceGuard
Running main() from ./googletest/src/gtest_main.cc
Note: Google Test filter = VxlanFdbOrchTest.MC4RepairTraceIsBlockedBySaiReferenceGuard
[==========] Running 1 test from 1 test suite.
[----------] Global test environment set-up.
[----------] 1 test from VxlanFdbOrchTest
[ RUN      ] VxlanFdbOrchTest.MC4RepairTraceIsBlockedBySaiReferenceGuard
MC4 REPAIR TRACE State2: learned_fdb_present=yes, bridge_port_present=yes
MC4 REPAIR TRACE State6: flush_status=failed, flush_calls=2, fdb_present=yes, bridge_port_present=yes
MC4 IMPLEMENTATION MASK: remove_status=-17, expected_OBJECT_IN_USE=-17, bridge_port_present=yes, fdb_present=yes, admin_state=down
MC4 CALLER: vlan_member_task_erased=yes, retry_scheduled=no
MC4 MODEL MISMATCH: repaired_State7_bridge_port_present=no is unreachable
[       OK ] VxlanFdbOrchTest.MC4RepairTraceIsBlockedBySaiReferenceGuard (250 ms)
[----------] 1 test from VxlanFdbOrchTest (250 ms total)

[----------] Global test environment tear-down
[==========] 1 test from 1 test suite ran. (250 ms total)
[  PASSED  ] 1 test.
RESULT: PASS - repaired State 7 is blocked by the real SAI reference guard; the caller still erases its task
```

The prior Level 0 and Level 1 evidence remains valid: normal removal succeeded at Level 0, while Level 1 established that teardown continues after flush failure without a retained FDB reference. Level 2 deterministically proved the mask; no source patch was used.

The real caller is `PortsOrch::doVlanMemberTask` at `orchagent/portsorch.cpp:6107-6109`. It erases the task despite failed bridge-port removal. The claimed dangling state never occurs because the SAI guard fires immediately. The adjacent stranded state—retained FDB, retained admin-down bridge port, and no queued retry—persists until unrelated recovery activity.

## Recommendation

Return status from `flushFDBEntries`, stop bridge-port removal after a failed flush, and retain the VLAN-member task for retry. Make `doVlanMemberTask` honor `removeBridgePort` failure, and model the SAI reference guard so future checking cannot advance from repaired State 6 to the impossible State 7.

## Repair round 2 evidence
<!-- specula-repair-token: c9b5090cbe614948d636bd58bf1a0e8a -->
- **Current violation analysis**: PortsOrch begins bridge-port teardown while an ASIC FDB entry still references that port. FdbOrch exposes no flush result and only logs the SAI failure, after which PortsOrch immediately removes the bridge port. Hardware retains an FDB reference to the removed topology generation; the broader scenario-1 hunt independently reaches the same root cause.
- **Counterexample**: `spec/output/repair_RR003_MC_hunt_mc6_topology_reuse_bfs.out`

## Phase 4 confirmation after repair round 2

- **Source**: MC
- **Novelty**: KNOWN (cite: https://github.com/sonic-net/sonic-buildimage/issues/27835; fix-status: unfixed)
- **Location**: orchagent/fdborch.cpp:1486; orchagent/portsorch.cpp:7506; orchagent/portsorch.cpp:7510

## Description

`FdbOrch::flushFDBEntries` logs a SAI failure but returns `void`. `PortsOrch::removeBridgePort` consequently proceeds directly to bridge-port removal.

The defect is real, but RR003’s `NoDanglingTopologyReference` consequence is masked. sairedis tracks the retained FDB entry’s bridge-port reference and synchronously rejects removal with `SAI_STATUS_OBJECT_IN_USE (-17)`. The FDB and admin-down bridge port remain; RR003 State 6, which removes the referenced bridge-port generation, is unreachable.

RR003 also corrects the earlier state numbering: final removal is now State 6, not State 7. It leaves `vlanMember[p1]` true through State 5, whereas the real APP_DB path removes the VLAN member before entering `removeBridgePort`.

## Trigger scenario

1. Configure a physical port, VLAN, and VLAN member through normal APP_DB tables.
2. Instantiate RR003 State 2, `MCSaiLearnEvent(k1,p1,ev2)`, using the real virtual-SAI FDB API and learned-notification entry point.
3. Delete the VLAN member through its normal consumer.
4. Return legitimate failures from both removal-path FDB flushes.
5. Observe bridge-port removal return `OBJECT_IN_USE`, while `doVlanMemberTask` erases the DEL without retrying.

Reachable sequence:

`APP_DB port/VLAN/member SET → dynamic FDB learn → APP_DB member DEL → SAI flush failure → bridge-port removal attempt`

## Developer intent

The code deliberately flushes FDB entries before removing a bridge port. [Issue #27835](https://github.com/sonic-net/sonic-buildimage/issues/27835) already reported the same failed-flush/removal sequence and sairedis rejection at these sites.

[Merged PR #4734](https://github.com/sonic-net/sonic-swss/pull/4734) fixed the specific unsupported flush-all cause, but retained the `void` dynamic-flush API and unconditional removal attempt. [Open PR #3211](https://github.com/sonic-net/sonic-swss/pull/3211) separately proposes retaining the task when bridge-port removal fails.

## Reproduction result

Executed [test_bugMC-4_bridge_port_flush_guard.sh](</users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/repro/test_bugMC-4_bridge_port_flush_guard.sh>). Full evidence is recorded in [investigation.md](</users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-4/investigation.md>).

```text
$ timeout 10m /users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/repro/test_bugMC-4_bridge_port_flush_guard.sh
PRECHECK: source_sha=4f3dda156e52ed7647b1dbf900d54d87efaea455, virtual_sai=/tmp/fdb-harness-bootstrap-test/root/usr/lib/x86_64-linux-gnu/libsaivs.so
RUN: /users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-4/worktree/tests/mock_tests/tests --gtest_filter=VxlanFdbOrchTest.MC4RR2TraceIsBlockedBySaiReferenceGuard
Running main() from ./googletest/src/gtest_main.cc
Note: Google Test filter = VxlanFdbOrchTest.MC4RR2TraceIsBlockedBySaiReferenceGuard
[==========] Running 1 test from 1 test suite.
[----------] Global test environment set-up.
[----------] 1 test from VxlanFdbOrchTest
[ RUN      ] VxlanFdbOrchTest.MC4RR2TraceIsBlockedBySaiReferenceGuard
MC4 RR2 TRACE State2: learned_fdb_present=yes, bridge_port_present=yes
MC4 RR2 TRACE State5: flush_status=failed, flush_calls=2, fdb_present=yes, bridge_port_present=yes
MC4 IMPLEMENTATION MASK: remove_status=-17, expected_OBJECT_IN_USE=-17, bridge_port_present=yes, fdb_present=yes, admin_state=down
MC4 CALLER: vlan_member_task_erased=yes, retry_scheduled=no
MC4 MODEL MISMATCH: RR003_State6_bridge_port_present=no is unreachable
[       OK ] VxlanFdbOrchTest.MC4RR2TraceIsBlockedBySaiReferenceGuard (209 ms)
[----------] 1 test from VxlanFdbOrchTest (209 ms total)

[----------] Global test environment tear-down
[==========] 1 test from 1 test suite ran. (209 ms total)
[  PASSED  ] 1 test.
RESULT: PASS - RR003 State 6 is blocked by the real SAI reference guard; the caller still erases its task
```

Checklist:

1. Level 0 or Level 1 alone triggered the claimed violation: **no**.
2. Level 2 instantiated exact RR003 State 2 through the reachable sequence shown above.
3. The real caller is `PortsOrch::doVlanMemberTask` at `orchagent/portsorch.cpp:6107-6109`; it erases the task despite failed removal. No consumer observes the claimed dangling-reference state because it is never created.
4. The claimed bad state is immediately masked by sairedis’s object-reference guard. The adjacent state—retained FDB, retained admin-down bridge port, and no queued retry—persists until unrelated recovery.

## Recommendation

Return status from `flushFDBEntries`, stop bridge-port removal after a failed flush, and keep the VLAN-member task pending. Make `doVlanMemberTask` honor `removeBridgePort` failure. Model both the sairedis reference guard and the real VLAN-member-before-bridge-removal ordering.

---

## Entry 5: A delayed LEARN reclassifies a newer MCLAG remote entry as local

- **Finding ID**: MC-5
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-5/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: orchagent/fdborch.cpp:894

## Description

MC-5 is a real TLC counterexample but not a reproducible production defect. Its LEARN(p1) → MOVE(p1) trace ends with different model-only generations, while ASIC, kernel, cache, STATE_DB, and observer all retain the same destination, bridge port, and type.

Production cannot execute the cited SAI repair loop for this trace: it requires both MCLAG origin and a changed bridge port ([fdborch.cpp](/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-5/worktree/orchagent/fdborch.cpp:870)). A normal same-port MOVE instead takes the intentional duplicate path, and STATE_DB stores only `port` and `type`, with no generation field.

An upstream search covering open/closed issues and merged/closed PRs found no prior report of this mechanism. The closest results were [PR #2811](https://github.com/sonic-net/sonic-swss/pull/2811), which introduced the MCLAG attribute repair, and [issue #2913](https://github.com/sonic-net/sonic-swss/issues/2913)/[PR #3524](https://github.com/sonic-net/sonic-swss/pull/3524), which concern a different add/flush race.

## Trigger scenario

The counterexample performs:

1. `MCSaiLearnEvent(k1,p1,ev1)`
2. `MCSaiMoveEvent(k1,p1,ev2)`
3. Completion of generation-1 software handling
4. A repair-failure transition that consumes the MOVE

However, LEARN(p1) creates a local LEARN-origin entry, and MOVE(p1) reports the same bridge port. Both prerequisites for the MCLAG repair loop are therefore false.

A separate reachable sequence—`MCLAG_FDB_TABLE(p1) -> MOVE(p2)`—does enter the repair loop. Even with all three SAI writes failing, cache, STATE_DB, and observers commit the real incoming hardware destination p2.

## Developer intent

The same-port duplicate return is explicitly documented in the implementation ([fdborch.cpp](/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-5/worktree/orchagent/fdborch.cpp:152)), while the MOVE handler deliberately continues to observer notification at line 935. Real consumers such as `MuxOrch::updateFdb` consume `entry.port_name`, not an incarnation counter ([muxorch.cpp](/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-5/worktree/orchagent/muxorch.cpp:1948)).

## Reproduction result

Executed [test_bugMC-5_move_incarnation.sh](/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/repro/test_bugMC-5_move_incarnation.sh), exit code 0:

```text
MC5_PRECHECK source_revision=4f3dda156e52ed7647b1dbf900d54d87efaea455
MC5_PRECHECK test_binary=/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-5/worktree/tests/mock_tests/tests
Running main() from ./googletest/src/gtest_main.cc
Note: Google Test filter = VxlanFdbOrchTest.MC5MoveRepairFailureOwnership
[==========] Running 1 test from 1 test suite.
[----------] Global test environment set-up.
[----------] 1 test from VxlanFdbOrchTest
[ RUN      ] VxlanFdbOrchTest.MC5MoveRepairFailureOwnership
MC5_LEVEL0 exact_sequence=LEARN(p1)->MOVE(p1) cache_port=Ethernet0 state_db_port=Ethernet0 observer_port=Ethernet0 generation_field=absent outcome=NO_WRONG_DESTINATION
MC5_LEVEL1 timing_delay_ms=2 observer_port=Ethernet0 outcome=NO_WRONG_DESTINATION
MC5_LEVEL2 exact_trace_armed_sai_failure=true repair_calls=0 outcome=REPAIR_LOOP_UNREACHABLE
MC5_LEVEL2 reachable_api_sequence=MCLAG_FDB_TABLE(p1)->MOVE(p2) sai_repair_failures=3 incoming_hardware_port=Ethernet4 cache_port=Ethernet4 state_db_port=Ethernet4 observer_port=Ethernet4 outcome=NO_WRONG_DESTINATION
MC5_LEVEL3 source_delay=NOT_APPLICABLE reason=deterministic_mutually_exclusive_guards outcome=NO_ADMISSIBLE_PATCH_TO_TRIGGER_CLAIM
MC5_RESULT unique_effective_destination_violation=NOT_OBSERVED model_generation_has_no_production_consumer=true
[       OK ] VxlanFdbOrchTest.MC5MoveRepairFailureOwnership (205 ms)
[----------] 1 test from VxlanFdbOrchTest (205 ms total)

[----------] Global test environment tear-down
[==========] 1 test from 1 test suite ran. (205 ms total)
[  PASSED  ] 1 test.
```

- Level 0 or Level 1 alone triggered MC-5: **no**.
- Level 2 exact-trace injection was admissible but made zero failure calls; the reachable real-API sequence was `MCLAG_FDB_TABLE(p1) -> MOVE(p2)`.
- No real consumer observed a wrong destination.
- No transient or permanent bad destination occurred, so no downstream mechanism masked or repaired one.

## Recommendation

Repair the model by constraining its repair-failure transition to the implementation’s MCLAG-origin and changed-bridge-port guards. The same-port local MOVE should be modeled as an idempotent duplicate-store path that continues notification.

The required semantic draft is [repair-request.body.md](/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-5/repair-request.body.md).

## Repair round 1 evidence
<!-- specula-repair-token: 8e01f9956a293229bbff94b1d6f37de7 -->
- **Repair request**: `/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/spec/repair-requests/RR-002.md`
  Read its updated `## Evidence` before confirming the current violation.
- **Phase 3 result**: r1 (phase3-repair): added origin-aware MCLAG reachability and implementation guards/continuation semantics, passed all traces and MC.cfg, and reran every hunt; the scoped hunt now reports a distinct remote AGE retry-ownership violation.
- **Current violation analysis**: SAI ages a MCLAG-owned FDB entry, removing it from hardware while software still advertises it. FdbOrch attempts to recreate the remote entry, but a failed create is only logged before an unconditional return. The one-shot notification is consumed with no retry or compensation owner, leaving cache/STATE_DB present while ASIC/kernel are absent.
- **Counterexample**: `spec/output/repair_final_MC_hunt_scenario_2_incarnation_bfs.out`

## Phase 4 confirmation after repair round 1

- **Source**: MC
- **Novelty**: NEW
- **Location**: orchagent/fdborch.cpp:713

## Description

The replacement TLC counterexample is real, but its trigger is not implementation-faithful. It models `MCFdbOrchMclagAdvertise` as installing a hardware-dynamic FDB entry, allowing ordinary SAI aging to remove it.

Production instead translates an MCLAG row whose logical type is `dynamic` into `SAI_FDB_ENTRY_TYPE_STATIC` with `ALLOW_MAC_MOVE=true` ([fdborch.cpp](/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-5/worktree/orchagent/fdborch.cpp:2120)). The SAI interface defines aging for dynamic entries and restricts `ALLOW_MAC_MOVE` to static entries ([saiswitch.h](/tmp/fdb-harness-bootstrap-test/root/usr/include/sai/saiswitch.h:1524), [saifdb.h](/tmp/fdb-harness-bootstrap-test/root/usr/include/sai/saifdb.h:181)).

The conditional code defect does exist: if such an AGE notification is forcibly supplied and recreation fails, HEAD line 713 only logs the failure before returning at line 720, with no retry owner. However, the counterexample cannot reach that premise through its preceding MCLAG advertise action.

The previous assertion that “SAI ages the current MCLAG-owned entry” is therefore corrected. The trace conflates the logical `dynamic` label with the installed hardware type.

A search of open/closed upstream issues, exact log text, and recently merged/closed FDB PRs found no prior report for this precise failure mechanism. [PR #1331](https://github.com/sonic-net/sonic-swss/pull/1331) is the feature-introduction change, not a defect report.

## Trigger scenario

The counterexample:

1. Executes `MCFdbOrchMclagAdvertise(k1,p1)` but records the ASIC entry as dynamic ([counterexample](/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/spec/output/repair_final_MC_hunt_scenario_2_incarnation_bfs.out:175)).
2. Executes `MCSaiAgeEvent(k1,ev1)`, removing the current entry at line 314.
3. Consumes the notification after recreation failure, with `fdbRetry=FALSE` and an empty queue at lines 459–514.

The real table sequence `MCLAG_FDB_TABLE(Vlan40:<mac>, Ethernet0, type=dynamic)` instead programs the entry as SAI static. Level 0 and timing-assisted Level 1 therefore cannot trigger AGE.

Level 2 injected the exact counterexample step as a negative control. It confirmed the conditional log-and-return behavior, but explicitly required the inadmissible precondition `current_remote_STATIC_removed`.

`MuxOrch::getMuxPort` is a real cache consumer ([muxorch.cpp](/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-5/worktree/orchagent/muxorch.cpp:1938), but it observes stale state only under that injected premise. No real consumer receives a wrong outcome from the admissible Level-0/1 sequence.

## Developer intent

The [MCLAG HLD](https://github.com/sonic-net/SONiC/pull/596) documents the static-plus-allow-move representation as the mechanism for preventing unwanted remote-MAC aging while still permitting hardware MAC moves. This matches both the production attribute mapping and the SAI contract.

## Reproduction result

Executed [test_bugMC-5_remote_age_retry.sh](/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/repro/test_bugMC-5_remote_age_retry.sh), exit code 0:

```text
MC5_PRECHECK source_revision=4f3dda156e52ed7647b1dbf900d54d87efaea455
MC5_PRECHECK test_binary=/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-5/worktree/tests/mock_tests/tests
Running main() from ./googletest/src/gtest_main.cc
Note: Google Test filter = VxlanFdbOrchTest.MC5RemoteAgeRetryOwnership
[==========] Running 1 test from 1 test suite.
[----------] Global test environment set-up.
[----------] 1 test from VxlanFdbOrchTest
[ RUN      ] VxlanFdbOrchTest.MC5RemoteAgeRetryOwnership
MC5_LEVEL0 real_sequence=MCLAG_FDB_TABLE(Vlan40:aa:bb:cc:55:00:05,Ethernet0,type=dynamic) programmed_sai_type=STATIC allow_mac_move=true sai_aging_scope=DYNAMIC_ONLY outcome=REMOTE_ENTRY_NOT_AGE_ELIGIBLE
MC5_LEVEL1 timing_delay_ms=2 orch_drains=2 notification_depth=0 recreate_calls=0 outcome=NO_TRIGGER
MC5_LEVEL2 injected_step=MCSaiAgeEvent(k1,ev1) precondition=current_remote_STATIC_removed admissible=false recreate_status=SAI_STATUS_TABLE_FULL notification_depth=0 pending_tasks=0 retry_owner=false cache_port=Ethernet0 state_db_port=Ethernet0 asic_present=false conditional_symptom=DROPPED_RECREATE
MC5_LEVEL3 source_patch=NOT_USED reason=delay_cannot_make_STATIC_entry_dynamic-age-eligible_without_logic_change outcome=NO_ADMISSIBLE_PATCH
MC5_RESULT live_harm=NOT_REPRODUCED counterexample_artifact=MCLAG_LOGICAL_DYNAMIC_MODELED_AS_ASIC_DYNAMIC repair_target=SPEC_REPAIR
[       OK ] VxlanFdbOrchTest.MC5RemoteAgeRetryOwnership (202 ms)
[----------] 1 test from VxlanFdbOrchTest (202 ms total)

[----------] Global test environment tear-down
[==========] 1 test from 1 test suite ran. (202 ms total)
[  PASSED  ] 1 test.
```

## Recommendation

Repair `MCFdbOrchMclagAdvertise` to distinguish the logical FDB type from the installed SAI type, or track explicit hardware-aging eligibility. `MCSaiAgeEvent` should require a currently age-eligible hardware-dynamic entry. Continue checking retry ownership for any separately demonstrated stale or otherwise admissible AGE path.

The required semantic draft is [repair-request.body.md](/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-5/repair-request.body.md).

## Repair round 2 evidence
<!-- specula-repair-token: c9b5090cbe614948d636bd58bf1a0e8a -->
- **Repair request**: `/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/spec/repair-requests/RR-003.md`
  Read its updated `## Evidence` before confirming the current violation.
- **Phase 3 result**: r1 (phase3-repair): distinguished logical MCLAG type from installed SAI type and aging eligibility, modeled guarded LEARN/MOVE conversion plus successful remote AGE disposition, passed all traces and MC.cfg, reran every hunt, and replaced the artifact only with the independent stale-LEARN result.
- **Current violation analysis**: A local LEARN is queued and its hardware row ages before FdbOrch consumes either notification. A newer same-port MCLAG update then installs the key as remote-owned and SAI static. When the delayed LEARN is finally handled, FdbOrch has no incarnation check: it changes the current row to dynamic, stores the stale notification as FDB_ORIGIN_LEARN, and deletes MCLAG state ownership. The result is independent of repair-failure injection.
- **Counterexample**: `spec/output/repair_RR003_MC_hunt_scenario_2_incarnation_bfs.out`

## Phase 4 confirmation after repair round 2

- **Source**: MC
- **Novelty**: NEW
- **Location**: orchagent/fdborch.cpp:439

## Description

A delayed generation-1 LEARN is applied to the current generation-2 MCLAG entry because [FdbOrch](/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-5/worktree/orchagent/fdborch.cpp:439) identifies entries only by FDB key, without an incarnation check. It changes the replacement row from static to dynamic, records `FDB_ORIGIN_LEARN`, and removes MCLAG ownership at [fdborch.cpp:184](/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-5/worktree/orchagent/fdborch.cpp:184).

The subsequently queued AGE deletes the cache/state entry without removing the now-dynamic hardware row. The MCLAG desired entry remains in APPL_DB, but no automatic replay repairs it.

Correction to the model-only chronology: the counterexample consumes AGE before LEARN because it models notifications as an event set. Production uses FIFO ordering. The real FIFO sequence—LEARN, AGE, newer MCLAG update, then delayed notification consumption—still triggers the takeover and leaves an even stronger unmanaged hardware row after AGE.

## Trigger scenario

1. A normal VLAN FDB row learns locally on `Ethernet0`; LEARN is queued.
2. The hardware row ages; AGE is queued behind LEARN.
3. Before FdbOrch consumes either notification, a same-key, same-port MCLAG update installs a newer remote-owned static row.
4. The delayed LEARN is consumed and reclassifies that row as local/dynamic.
5. The queued AGE removes cache/state ownership but leaves the dynamic hardware entry present.
6. Two idle executor drains produce no repair.

## Developer intent

The same-port branch was introduced for a current remote-to-local learning transition, as documented by [sonic-swss PR #1331](https://github.com/sonic-net/sonic-swss/pull/1331). Its comments assume the received LEARN describes the current row; they do not define behavior for a notification predating a replacement entry.

I searched upstream issues, merged/closed PRs, and git history for the stale-LEARN/MCLAG-incarnation mechanism, including recently closed FDB work. No matching report or fix was found. The closest results—[#3524](https://github.com/sonic-net/sonic-swss/pull/3524) and [#4739](https://github.com/sonic-net/sonic-swss/pull/4739)—address different flush and EVPN ordering races.

## Reproduction result

The [Level 1 regression test](/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-5/worktree/tests/mock_tests/fdborch/fdborch_vxlan_ut.cpp:4289) was executed through the [reproduction script](/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/repro/test_bugMC-5_delayed_learn_mclag.sh). It uses real serialized FDB notifications and the real MCLAG APPL_DB consumer; only notification-consumption timing is controlled.

```text
MC5_PRECHECK source_revision=4f3dda156e52ed7647b1dbf900d54d87efaea455
MC5_PRECHECK test_binary=/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-5/worktree/tests/mock_tests/tests
MC5_PRECHECK production_patch=none timing_assistance=notification_consumption_delay
Running main() from ./googletest/src/gtest_main.cc
Note: Google Test filter = VxlanFdbOrchTest.MC5DelayedLearnReclassifiesNewerMclagEntry
[==========] Running 1 test from 1 test suite.
[----------] Global test environment set-up.
[----------] 1 test from VxlanFdbOrchTest
[ RUN      ] VxlanFdbOrchTest.MC5DelayedLearnReclassifiesNewerMclagEntry
MC5_LEVEL0 sequence=LEARN->consume->AGE->consume->MCLAG final_origin=MCLAG final_sai_type=STATIC outcome=NO_TRIGGER
MC5_LEVEL1 queued_sequence=LEARN->AGE queue_depth=2 newer_update=MCLAG same_port=Ethernet0 origin=MCLAG sai_type=STATIC old_hw_present=false
MC5_LEVEL1 queue_head=LEARN executor_interleaving=MCLAG_TABLE_BEFORE_FDB_NOTIFICATION
MC5_LEVEL1 delayed_learn_consumed=true current_origin=LEARN current_sai_type=DYNAMIC mclag_state_present=false local_state_present=true hw_present=true hw_type=DYNAMIC hw_set_calls=2 outcome=STALE_LEARN_RECLASSIFIED_NEWER_REMOTE
MC5_LEVEL1 queued_age_consumed=true app_mclag_desired_present=true cache_present=false mclag_state_present=false local_state_present=false hw_present=true hw_type=DYNAMIC hardware_remove_calls=0
MC5_PERSISTENCE idle_drains=2 app_mclag_desired_present=true cache_present=false hw_present=true resend_owner=false
MC5_CONSUMER caller=MuxOrch::getMuxPort->FdbOrch::getPort lookup_result=true observed_port=EMPTY expected_port=Ethernet0 wrong_outcome=true
MC5_RESULT escalation=1 live_harm=REPRODUCED mechanism=DELAYED_LEARN_OVERRIDES_NEWER_MCLAG downstream_age_mask=false permanent_until_external_resend=true
[       OK ] VxlanFdbOrchTest.MC5DelayedLearnReclassifiesNewerMclagEntry (208 ms)
[----------] 1 test from VxlanFdbOrchTest (208 ms total)

[----------] Global test environment tear-down
[==========] 1 test from 1 test suite ran. (208 ms total)
[  PASSED  ] 1 test.
```

Checklist:

1. **Did Level 0 or Level 1 alone trigger it?** yes — Level 1 triggered through normal serialized notification and table-consumer interfaces with timing assistance only. No defective FDB state was injected.
2. **Was Level 2 or Level 3 used?** no. The reachable sequence was port/VLAN setup → port UP → SAI LEARN → SAI AGE → MCLAG table SET → consume queued notifications.
3. **Which real consumer observes the wrong outcome?** [MuxOrch::getMuxPort](/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-5/worktree/orchagent/muxorch.cpp:1938) calls `FdbOrch::getPort` and observes an empty port instead of `Ethernet0`.
4. **Is it permanent or masked?** It persists indefinitely under idle processing. The queued AGE does not mask it; it deletes cache/state while leaving the dynamic hardware row. Repair requires new external input such as an ICCPd resend or another MAC event—there is no automatic downstream retry, loopback, or guard.

The complete captured output is preserved in [reproduction-output.txt](/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-5/reproduction-output.txt).

## Recommendation

Associate queued LEARN/AGE notifications with a per-key incarnation or sequence number and discard events older than the currently installed entry. A MCLAG replacement must invalidate older queued notifications, and AGE handling must not remove ownership for—or rely on hardware semantics from—a newer incarnation.

---

## Entry 6: Deferred SET replay applies an obsolete destination

- **Finding ID**: MC-6
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-6/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: orchagent/fdborch.cpp:1932

## Description

The TLC counterexample genuinely violates `LatestDesiredWins`. Deferred entries are appended to `saved_fdb_entries` without generation tracking or same-key coalescing. `updateVlanMember` replays that vector in insertion order at `orchagent/fdborch.cpp:1847`, allowing an older destination to reach SAI while the newer intent remains deferred.

## Trigger scenario

On a valid P2MP platform:

1. Normal `VXLAN_FDB_TABLE` SET for `(Vlan40, MAC)` targets p1.
2. A newer SET for the same key targets p2.
3. Both defer because their endpoint memberships are absent.
4. Normal `REMOTE_VNI_TABLE` add makes only p1 a VLAN endpoint member.
5. Replay programs p1, although AppDB’s latest value is p2.

No timing hooks, internal deferred-state injection, or production-logic changes were used.

## Developer intent

[PR #406](https://github.com/sonic-net/sonic-swss/pull/406) introduced saved FDB work for eventual installation after dependencies become ready. [PR #1275](https://github.com/sonic-net/sonic-swss/pull/1275) established remote-VTEP updates where the newer same-key value should win. [PR #4615](https://github.com/sonic-net/sonic-swss/pull/4615) added the P2MP endpoint dependency but no deferred-value coalescing.

Novelty searches covered upstream open/closed issues, recently merged/closed PRs, and local history through the checkout HEAD. The closest reports—[issue #1134](https://github.com/sonic-net/sonic-swss/issues/1134), [PR #2756](https://github.com/sonic-net/sonic-swss/pull/2756), [PR #4734](https://github.com/sonic-net/sonic-swss/pull/4734), and [PR #4739](https://github.com/sonic-net/sonic-swss/pull/4739)—concern different ordering, dependency, flush, or deletion mechanisms. No prior report or fix for this append-only obsolete replay was found.

## Reproduction result

Executable: [test_bugMC-6_deferred_latest_intent.sh](/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/repro/test_bugMC-6_deferred_latest_intent.sh)

Command executed:

```sh
timeout 2400 sudo chroot '/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-6/.build-root-bookworm' /usr/bin/env CPPFLAGS='-I/usr/include -I/usr/include/swss' LDFLAGS='-L/host-local/lib -L/usr/lib/x86_64-linux-gnu' LIBS='-lyaml-cpp' LD_LIBRARY_PATH='/host-local/lib:/usr/lib/x86_64-linux-gnu' MC6_JOBS=20 /bin/bash '/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/repro/test_bugMC-6_deferred_latest_intent.sh'
```

Actual output:

```text
build_ok
Running main() from ./googletest/src/gtest_main.cc
Note: Google Test filter = VxlanFdbOrchP2mpTest.DeferredLatestIntentProgramsObsoleteEndpoint
[==========] Running 1 test from 1 test suite.
[----------] Global test environment set-up.
[----------] 1 test from VxlanFdbOrchP2mpTest
[ RUN      ] VxlanFdbOrchP2mpTest.DeferredLatestIntentProgramsObsoleteEndpoint
MC-6 escalation_level=0
normal_ops=VXLAN_FDB_SET(p1),VXLAN_FDB_SET(p2),REMOTE_VNI_ADD(p1)
sai_calls_before_dependency=0
appdb_latest_endpoint=10.0.0.102
dependency_endpoint_member=10.0.0.101
sai_create_endpoint=10.0.0.101
sai_create_calls_after_idle_cycles=1
expected_endpoint=10.0.0.102
persistent_without_new_dependency=yes
BUG_TRIGGERED obsolete_destination_visible_to_sai=yes
[       OK ] VxlanFdbOrchP2mpTest.DeferredLatestIntentProgramsObsoleteEndpoint (108 ms)
[----------] 1 test from VxlanFdbOrchP2mpTest (108 ms total)

[----------] Global test environment tear-down
[==========] 1 test from 1 test suite ran. (108 ms total)
[  PASSED  ] 1 test.
```

Checklist:

1. Did Level 0 or Level 1 alone trigger it? **yes** — Level 0, using normal AppDB operations and the ordinary dependency notification.
2. Level 2/3 precondition evidence: **N/A** — neither state injection nor a production source patch was used.
3. Real consumer observing the wrong outcome: **SAI/ASIC forwarding plane**, through `sai_fdb_api->create_fdb_entry` at `orchagent/fdborch.cpp:2277`, receives endpoint p1 instead of p2.
4. Permanence/masking: **persistent without a new external p2 dependency event**. Three idle executor cycles produced no reconciliation, and there is no timer, loopback, resend, AppDB reread, or caller guard that autonomously corrects it.

## Recommendation

Coalesce deferred work by `(VLAN, MAC)` so a newer SET replaces all older saved values. Alternatively, attach generations and reject replay entries older than the current desired generation before calling SAI. Add a regression covering deferred p1, deferred p2, then dependency readiness for p1.

## Repair round 1 evidence
<!-- specula-repair-token: 8e01f9956a293229bbff94b1d6f37de7 -->
- **Current violation analysis**: While dependencies are absent, SET p1 and a newer SET p2 are appended as separate saved entries. When the dependency appears, updateVlanMember replays insertion order and publishes p1 while p2 remains the latest desired value. The saved-work representation has no generation-based coalescing, so obsolete intent becomes externally visible.
- **Counterexample**: `spec/output/repair_final_MC_hunt_scenario_3_deferred_bfs.out`

## Phase 4 confirmation after repair round 1

- **Source**: MC
- **Novelty**: NEW
- **Location**: orchagent/fdborch.cpp:1949

## Description

`LatestDesiredWins` is violated. Deferred FDB entries are appended to a vector without generation tracking or same-key replacement. When endpoint `p1` becomes ready, `updateVlanMember` replays insertion order and publishes obsolete `p1`, although AppDB’s latest value is `p2`.

Correction to prior evidence: the current repair-round trace includes a third, repeated `p2` SET. Generations 1–3 are saved in states 2–4, dependency `p1` appears in state 5, generation 1 reaches ASIC in state 7, and state 9 has applied `p1` while desired generation 3 remains `p2`.

The issue/PR tracker and local history were searched, including recently closed and merged PRs through 2026-08-01. The closest reports concern [NVO dependency retry](https://github.com/sonic-net/sonic-swss/pull/2756), [cross-channel ordering](https://github.com/sonic-net/sonic-swss/issues/1134), [flush-all behavior](https://github.com/sonic-net/sonic-swss/pull/4734), and a [neighbor/FDB race](https://github.com/sonic-net/sonic-swss/pull/4739); none report or fix this same append-only, deferred same-key replay mechanism. Novelty is therefore `NEW`.

## Trigger scenario

On a valid P2MP platform:

1. SET one `VXLAN_FDB_TABLE` key to `p1` while its endpoint membership is absent.
2. SET the same key to newer `p2`, then repeat `p2`; all three operations use `ProducerStateTable.set`.
3. Add the ordinary `REMOTE_VNI_TABLE` dependency for `p1`.
4. The VLAN-member notification replays generation 1 first and sends `p1` to SAI. Both `p2` entries remain deferred.

The repository’s existing P2MP integration test independently establishes same-key `ProducerStateTable.set` updates without an intervening DEL as a supported operation.

## Developer intent

[PR #406](https://github.com/sonic-net/sonic-swss/pull/406) introduced saved FDB work for later replay, while [PR #1275](https://github.com/sonic-net/sonic-swss/pull/1275) expects a newer remote-VTEP update to win. [PR #4615](https://github.com/sonic-net/sonic-swss/pull/4615) added P2MP endpoint membership checks but did not add coalescing or generation validation. Publishing an older deferred destination conflicts with those behaviors.

## Reproduction result

The executable reproducer is [test_bugMC-6_deferred_latest_intent.sh](</users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/repro/test_bugMC-6_deferred_latest_intent.sh>) with its [C++ test body](</users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/repro/test_bugMC-6_deferred_latest_intent.cpp>). It was built and executed against `worktree-1`.

```text
build_ok
Running main() from ./googletest/src/gtest_main.cc
Note: Google Test filter = VxlanFdbOrchP2mpTest.DeferredLatestIntentProgramsObsoleteEndpoint
[==========] Running 1 test from 1 test suite.
[----------] Global test environment set-up.
[----------] 1 test from VxlanFdbOrchP2mpTest
[ RUN      ] VxlanFdbOrchP2mpTest.DeferredLatestIntentProgramsObsoleteEndpoint
MC-6 escalation_level=0
normal_ops=VXLAN_FDB_SET(p1),VXLAN_FDB_SET(p2),VXLAN_FDB_SET(p2),REMOTE_VNI_ADD(p1)
sai_calls_before_dependency=0
appdb_latest_endpoint=10.0.0.102
dependency_endpoint_member=10.0.0.101
sai_create_endpoint=10.0.0.101
sai_create_calls_after_idle_cycles=1
expected_endpoint=10.0.0.102
persistent_without_new_dependency=yes
BUG_TRIGGERED obsolete_destination_visible_to_sai=yes
[       OK ] VxlanFdbOrchP2mpTest.DeferredLatestIntentProgramsObsoleteEndpoint (110 ms)
[----------] 1 test from VxlanFdbOrchP2mpTest (110 ms total)

[----------] Global test environment tear-down
[==========] 1 test from 1 test suite ran. (110 ms total)
[  PASSED  ] 1 test.
```

Reproduction checklist:

1. **yes** — Level 0 alone triggered it using normal `ProducerStateTable` SETs and a normal remote-VNI add; scheduling only controlled when accepted updates were consumed.
2. **Not applicable** — no Level 2 state injection or Level 3 source patch was used. The capability hook only selected a valid P2MP SAI platform.
3. The real consumer is `sai_fdb_api->create_fdb_entry` at `orchagent/fdborch.cpp:2277`. The production call carried endpoint `10.0.0.101` instead of desired `10.0.0.102`, affecting ASIC forwarding.
4. The stale state is **persistent under quiescence**. Three idle executor cycles produced no correction, and no timer, loopback, resend, or caller guard exists. A distinct future external membership event for `p2` could repair it, but none is automatically generated or guaranteed.

## Recommendation

Coalesce deferred entries by logical FDB key and retain only the newest generation. Before replay, validate the saved generation against current desired state and discard obsolete work. Add a P2MP regression for `SET(p1)`, `SET(p2)`, repeated `SET(p2)`, followed by dependency readiness for `p1`, asserting that `p1` never reaches SAI.

## Repair round 2 evidence
<!-- specula-repair-token: c9b5090cbe614948d636bd58bf1a0e8a -->
- **Current violation analysis**: While dependencies are absent, SET p1 and a newer SET p2 are appended as separate saved entries. When the dependency appears, updateVlanMember replays insertion order and publishes p1 while p2 remains the latest desired value. The saved-work representation has no generation-based coalescing, so obsolete intent becomes externally visible.
- **Counterexample**: `spec/output/repair_RR003_MC_hunt_scenario_3_deferred_bfs.out`

## Phase 4 confirmation after repair round 2

- **Source**: MC
- **Novelty**: NEW
- **Location**: orchagent/fdborch.cpp:1949

## Description

RR003 confirms `LatestDesiredWins` is violated. Deferred same-key FDB SETs are appended without generation tracking or coalescing; when `p1` becomes eligible, `updateVlanMember` replays insertion order and publishes obsolete `p1` while AppDB’s latest destination remains `p2`.

Correction to prior evidence: RR003 contains exactly two SETs—`p1`, then `p2`—not a third repeated `p2`.

## Trigger scenario

1. On a valid P2MP platform, SET `(Vlan40, MAC)` to `p1` while its endpoint membership is absent.
2. SET the same key to newer `p2`; both values become separate saved entries.
3. Add the normal `REMOTE_VNI_TABLE` dependency for `p1`.
4. VLAN-member replay processes saved `p1` first and sends it to SAI; `p2` remains deferred.

This maps to RR003 states 2–8: generations 1 and 2 are saved, dependency readiness triggers replay, generation 1 reaches ASIC, and applied `p1` remains behind desired `p2`.

## Developer intent

[PR #406](https://github.com/sonic-net/sonic-swss/pull/406) introduced saved FDB work for later installation. [PR #1275](https://github.com/sonic-net/sonic-swss/pull/1275) established that a newer same-key remote-VTEP update should win. [PR #4615](https://github.com/sonic-net/sonic-swss/pull/4615) added the P2MP endpoint dependency without adding deferred-value coalescing.

Upstream open/closed issues and recently merged/closed PRs were searched. The closest changes—[PR #4734](https://github.com/sonic-net/sonic-swss/pull/4734), [PR #4739](https://github.com/sonic-net/sonic-swss/pull/4739), [PR #4780](https://github.com/sonic-net/sonic-swss/pull/4780), and [PR #2756](https://github.com/sonic-net/sonic-swss/pull/2756)—address different flush, neighbor-ordering, static-L2, or dependency-retry mechanisms. No report or fix for obsolete same-key deferred replay was found.

## Reproduction result

Executable: [test_bugMC-6_deferred_latest_intent.sh](/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/repro/test_bugMC-6_deferred_latest_intent.sh)  
Test body: [test_bugMC-6_deferred_latest_intent.cpp](/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/repro/test_bugMC-6_deferred_latest_intent.cpp)

Command executed:

```sh
timeout 2400 sudo chroot '/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-6/.build-root-bookworm' /usr/bin/env CPPFLAGS='-I/usr/include -I/usr/include/swss' LDFLAGS='-L/host-local/lib -L/usr/lib/x86_64-linux-gnu' LIBS='-lyaml-cpp' LD_LIBRARY_PATH='/host-local/lib:/usr/lib/x86_64-linux-gnu' MC6_JOBS=20 MC6_REPO='/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-6/worktree' /bin/bash '/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/repro/test_bugMC-6_deferred_latest_intent.sh'
```

Actual output:

```text
build_ok
Running main() from ./googletest/src/gtest_main.cc
Note: Google Test filter = VxlanFdbOrchP2mpTest.DeferredLatestIntentProgramsObsoleteEndpoint
[==========] Running 1 test from 1 test suite.
[----------] Global test environment set-up.
[----------] 1 test from VxlanFdbOrchP2mpTest
[ RUN      ] VxlanFdbOrchP2mpTest.DeferredLatestIntentProgramsObsoleteEndpoint
MC-6 escalation_level=0
normal_ops=VXLAN_FDB_SET(p1),VXLAN_FDB_SET(p2),REMOTE_VNI_ADD(p1)
sai_calls_before_dependency=0
appdb_latest_endpoint=10.0.0.102
dependency_endpoint_member=10.0.0.101
sai_create_endpoint=10.0.0.101
sai_create_calls_after_idle_cycles=1
expected_endpoint=10.0.0.102
persistent_without_new_dependency=yes
BUG_TRIGGERED obsolete_destination_visible_to_sai=yes
[       OK ] VxlanFdbOrchP2mpTest.DeferredLatestIntentProgramsObsoleteEndpoint (110 ms)
[----------] 1 test from VxlanFdbOrchP2mpTest (110 ms total)

[----------] Global test environment tear-down
[==========] 1 test from 1 test suite ran. (110 ms total)
[  PASSED  ] 1 test.
```

The decisive lines are `appdb_latest_endpoint=10.0.0.102`, `sai_create_endpoint=10.0.0.101`, and `BUG_TRIGGERED obsolete_destination_visible_to_sai=yes`.

Checklist:

1. Did Level 0 or Level 1 alone trigger it? **yes**—Level 0, using normal AppDB operations and ordinary dependency notification.
2. Level 2/3 precondition evidence: **not applicable**; neither state injection nor a production source patch was used.
3. Real consumer/caller: the SAI/ASIC forwarding interface receives the wrong endpoint through `sai_fdb_api->create_fdb_entry` at `orchagent/fdborch.cpp:2277`.
4. Permanence/masking: **persistent under quiescence**. Three idle executor cycles did not correct it, and no timer, loopback, AppDB reread, resend, or caller guard does so automatically. A separate future `p2` membership event could repair it, but that external event is neither automatic nor guaranteed.

## Recommendation

Coalesce saved entries by logical `(VLAN, MAC)` key so a newer SET replaces older deferred values. Alternatively, attach generations and discard any replay older than current desired intent before invoking SAI. Add this two-SET P2MP sequence as a regression test.

---

## Entry 7: Startup discards the one-shot kernel NHG dump before NVO readiness

- **Finding ID**: MC-7
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-7/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: fdbsyncd/fdbsync.cpp:1140
- **Severity**: High
- **Reproduction test**: [test_bugMC-7_startup_nhg_replay.cpp](/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/repro/test_bugMC-7_startup_nhg_replay.cpp)
- **Escalation**: Level 2

## Description

Startup issues its one-shot `RTM_GETNEXTHOP` dump before processing the buffered EVPN NVO configuration. `onMsgNhg()` discards valid records while NVO is false, and neither readiness processing nor restart assistance replays them, leaving the production APP_DB consumer without the kernel NHG.

## Trigger scenario

1. Stop fdbsyncd while zebra/kernel remain active.
2. Install an L2 FDB nexthop through `ip nexthop add id 268435458 via 192.0.2.1 fdb`.
3. Restart fdbsyncd with an existing `VXLAN_EVPN_NVO` configuration.
4. The startup dump delivers the existing NHG before fdbsyncd processes NVO readiness.
5. Readiness becomes true, but the discarded ID is never published. A later NHG created after readiness is published normally.

This matches counterexample State 3, `MCKernelNhgChangeWhileDown(g1)`, followed by the startup-dump step at State 5.

## Developer intent

The [EVPN-MH HLD](https://github.com/sonic-net/SONiC/blob/master/doc/vxlan/EVPN/EVPN_VxLAN_Multihoming.md) explicitly assigns fdbsyncd responsibility for handling L2-NHG notifications and the kernel dump, publishing `L2_NEXTHOP_GROUP_TABLE`, whose consumer is L2NhgOrch. Although the HLD excludes full warm reboot, MC-7 also affects an ordinary fdbsyncd process restart.

The code was introduced by [PR #4615](https://github.com/sonic-net/sonic-swss/pull/4615). Searches covered open issues, closed/merged PRs, recent fdbsyncd changes, and organization-wide exact terms. They found feature PRs and unrelated fixes such as [PR #4674](https://github.com/sonic-net/sonic-swss/pull/4674), but no prior report or fix for this ordering mechanism. Novelty is therefore `NEW`.

## Reproduction result

No provenance-compatible binary or prior build log existed. The runner pinned source SHA `4f3dda156e52ed7647b1dbf900d54d87efaea455`, compiled the unmodified production handler, and used real Redis `ProducerStateTable`/`ConsumerStateTable` transport.

Levels 0–1 used the real daemon and kernel API, but this host’s Linux 5.15/libnl runtime did not dispatch either startup or live FDB-nexthop records to `onMsgNhg`; therefore those attempts did not trigger MC-7. Level 2 injected the admissible dump record through the registered public `onMsgRaw()` entrypoint.

Exact command:

```text
timeout 6m bash /users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-7/run-repro.sh
```

Actual output:

```text
source_sha=4f3dda156e52ed7647b1dbf900d54d87efaea455
build_compat=define missing installed-swsscommon CFG_VXLAN_EVPN_NVO_TABLE_NAME as VXLAN_EVPN_NVO
reachable_real_api_precondition=id 268435458 via 192.0.2.1 scope link proto unspec fdb
test=MC-7 startup NHG dump before NVO readiness
level=2 (admissible counterexample-state injection)
trace_step=State 3 MCKernelNhgChangeWhileDown(g1), delivered at State 5 startup dump
initial_nvo_ready=0
app_consumer_events_after_dump=0
app_consumer_saw_early_set_after_dump=0
nvo_ready_after_config=1
app_consumer_events_after_settle=0
app_consumer_saw_early_set_after_settle=0
app_consumer_control_events=1
app_consumer_live_control_set=1
app_consumer_live_control_fields=1
app_consumer_live_control_remote_vtep=192.0.2.2
app_consumer_saw_early_set_after_control=0
real_consumer=L2NhgOrch APP_DB transport (ConsumerStateTable)
correct_expected=both IDs 268435458 and 268435459 published after startup settles
observed=only post-readiness ID 268435459 is published; startup ID remains absent
permanent_without_external_resend=yes
MC7_REPRODUCED
exit_code=0
```

Required checklist:

1. Did Level 0 or Level 1 alone trigger it? **No.**
2. Level 2 precondition reachability: **Yes.** The real kernel API successfully created the exact object, and the injection instantiates counterexample State 3 followed by State 5. Sequence: stop fdbsyncd → `ip nexthop add … fdb` → restart → `RTM_GETNEXTHOP` returns `RTM_NEWNEXTHOP`.
3. Real consumer: production `ConsumerStateTable`, constructed for orchestration at `orchagent/orch.cpp:1219` and consumed by `L2NhgOrch::doTask()` at `orchagent/l2nhgorch.cpp:843`, observed no early SET but did observe the post-readiness control SET. This consequence is demonstrated, not argued-only.
4. Permanence: **Permanent in a quiescent system.** Readiness and another normal configuration-processing pass do not repair it, and an unrelated later NHG event does not reconstruct the discarded ID. Only an unguaranteed external resend/change of that same ID could repair it.

The full evidence record is in [investigation.md](/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-7/investigation.md).

## Recommendation

Buffer valid NHG dump records while NVO is unavailable and replay them in dependency order when readiness becomes true, or issue a fresh `RTM_GETNEXTHOP` dump on that transition. Add a regression test for dump-before-NVO ordering and ensure restart reconciliation explicitly covers `L2_NEXTHOP_GROUP_TABLE`.

## Repair round 1 evidence
<!-- specula-repair-token: 8e01f9956a293229bbff94b1d6f37de7 -->
- **Current violation analysis**: After a crash, the startup GETNEXTHOP dump is consumed before EVPN NVO readiness. onMsgNhg discards the record, and AppRestartAssist does not replay the L2 NHG table after configuration becomes ready. Restart settles with kernel state present and APP state absent, with no guaranteed later event to repair the divergence.
- **Counterexample**: `spec/output/repair_final_MC_hunt_scenario_5_restart_bfs.out`

## Phase 4 confirmation after repair round 1

- **Source**: MC
- **Novelty**: NEW
- **Location**: fdbsyncd/fdbsync.cpp:1140
- **Severity**: High
- **Reproduction test**: [test_bugMC-7_startup_nhg_replay.cpp](/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/repro/test_bugMC-7_startup_nhg_replay.cpp)
- **Escalation**: Level 2

## Description

Startup requests its one-shot `RTM_GETNEXTHOP` dump before processing buffered EVPN NVO configuration. Because NVO readiness initially is false, [`onMsgNhg()`](/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-7/worktree/fdbsyncd/fdbsync.cpp:1140) discards valid records; readiness processing and `AppRestartAssist` provide no later NHG replay.

The repaired counterexample still violates `RestartConverges`: after readiness, replay, and settling, the kernel NHG remains present while APP NHG remains absent.

## Trigger scenario

1. Configure an EVPN NVO.
2. Stop fdbsyncd while zebra and the kernel remain active.
3. Create or retain an L2 FDB nexthop through `ip nexthop add … fdb`.
4. Restart fdbsyncd.
5. [`fdbsyncd.cpp:89`](/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-7/worktree/fdbsyncd/fdbsyncd.cpp:89) requests the kernel dump before adding the NVO CONFIG_DB subscriber to the select loop.
6. The dump record reaches `onMsgNhg()` while readiness is false and is discarded.
7. NVO readiness becomes true, but no second dump or saved-record replay occurs.

This instantiates repaired-counterexample State 3, `MCKernelNhgChangeWhileDown(g1)`, followed by the State 5 startup-dump miss.

## Developer intent

The SONiC EVPN-MH design explicitly assigns fdbsyncd responsibility for handling L2-NHG kernel notifications and dumps and publishing `L2_NEXTHOP_GROUP_TABLE`; L2NhgOrch then consumes that table to create ASIC objects. The document excludes full warm reboot, but this trigger only requires an ordinary fdbsyncd process restart. [EVPN-MH HLD](https://github.com/sonic-net/SONiC/blob/master/doc/vxlan/EVPN/EVPN_VxLAN_Multihoming.md)

The code originated in [PR #4615](https://github.com/sonic-net/sonic-swss/pull/4615). Fresh searches covered upstream issues and recently closed/merged PRs for `RTM_GETNEXTHOP`, `L2_NEXTHOP_GROUP_TABLE`, fdbsyncd/NVO restart, and nexthop-group restart. Results were feature-development PRs [#3226](https://github.com/sonic-net/sonic-swss/pull/3226), [#4262](https://github.com/sonic-net/sonic-swss/pull/4262), [#4538](https://github.com/sonic-net/sonic-swss/pull/4538), and [#4615](https://github.com/sonic-net/sonic-swss/pull/4615), plus unrelated fix [#4674](https://github.com/sonic-net/sonic-swss/pull/4674). None reports or fixes this startup-drop/no-replay mechanism, so novelty remains `NEW`.

## Reproduction result

The harness compiled the unmodified production handler at source SHA `4f3dda156e52ed7647b1dbf900d54d87efaea455` and used real Redis `ProducerStateTable`/`ConsumerStateTable` transport.

Exact command:

```text
timeout 6m bash /users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-7/run-repro.sh
```

Actual output:

```text
exit_code=0
source_sha=4f3dda156e52ed7647b1dbf900d54d87efaea455
build_compat=define missing installed-swsscommon CFG_VXLAN_EVPN_NVO_TABLE_NAME as VXLAN_EVPN_NVO
reachable_real_api_precondition=id 268435458 via 192.0.2.1 scope link proto unspec fdb
test=MC-7 startup NHG dump before NVO readiness
level=2 (admissible counterexample-state injection)
trace_step=State 3 MCKernelNhgChangeWhileDown(g1), delivered at State 5 startup dump
initial_nvo_ready=0
app_consumer_events_after_dump=0
app_consumer_saw_early_set_after_dump=0
nvo_ready_after_config=1
app_consumer_events_after_settle=0
app_consumer_saw_early_set_after_settle=0
app_consumer_control_events=1
app_consumer_live_control_set=1
app_consumer_live_control_fields=1
app_consumer_live_control_remote_vtep=192.0.2.2
app_consumer_saw_early_set_after_control=0
real_consumer=L2NhgOrch APP_DB transport (ConsumerStateTable)
correct_expected=both IDs 268435458 and 268435459 published after startup settles
observed=only post-readiness ID 268435459 is published; startup ID remains absent
permanent_without_external_resend=yes
MC7_REPRODUCED
```

The decisive lines are `app_consumer_saw_early_set_after_settle=0`, the successful post-readiness positive control, and `permanent_without_external_resend=yes`. Correct behavior would publish both IDs after startup settles.

Required checklist:

1. Did Level 0 or Level 1 alone trigger it? **no**. Prior Level 0–1 attempts created the object through the real kernel API and varied readiness timing, but this host’s Linux/libnl combination did not dispatch FDB-nexthop records to the daemon.
2. Level 2 reachability: stop fdbsyncd → `ip nexthop add id 268435458 via 192.0.2.1 fdb` → restart fdbsyncd → the kernel answers `RTM_GETNEXTHOP` with `RTM_NEWNEXTHOP`. This is also exactly repaired-counterexample State 3 followed by State 5.
3. Real consumer: `L2NhgOrch`, instantiated at [`orchagent/orchdaemon.cpp:526`](/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-7/worktree/orchagent/orchdaemon.cpp:526) and dispatching this table at [`orchagent/l2nhgorch.cpp:843`](/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-7/worktree/orchagent/l2nhgorch.cpp:843). Its production `ConsumerStateTable` transport observed no startup SET while observing the positive-control SET.
4. Permanence: **permanent in a quiescent system**. Readiness processing, a second configuration pass, and an unrelated later NHG event did not reconstruct the discarded ID. No periodic dump, restart replay, loopback, or caller guard repairs it; only an unguaranteed external resend of that same ID can do so.

The corrected evidence record is [investigation.md](/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-7/investigation.md).

## Recommendation

Buffer valid startup NHG records until NVO readiness and replay them in dependency order, or issue another `RTM_GETNEXTHOP` dump when readiness transitions to true. Add a regression test for dump-before-NVO ordering and include `L2_NEXTHOP_GROUP_TABLE` in explicit restart reconciliation.

## Repair round 2 evidence
<!-- specula-repair-token: c9b5090cbe614948d636bd58bf1a0e8a -->
- **Current violation analysis**: After a crash, the startup GETNEXTHOP dump is consumed before EVPN NVO readiness. onMsgNhg discards the record, and AppRestartAssist does not replay the L2 NHG table after configuration becomes ready. Restart settles with kernel state present and APP state absent, with no guaranteed later event to repair the divergence.
- **Counterexample**: `spec/output/repair_RR003_MC_hunt_scenario_5_restart_bfs.out`

## Phase 4 confirmation after repair round 2

- **Source**: MC
- **Novelty**: NEW
- **Location**: fdbsyncd/fdbsync.cpp:1140
- **Severity**: High
- **Reproduction test**: [test_bugMC-7_startup_nhg_replay.cpp](/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/repro/test_bugMC-7_startup_nhg_replay.cpp)
- **Escalation**: Level 2

## Description

Startup requests its one-shot `RTM_GETNEXTHOP` dump before adding the NVO CONFIG_DB subscriber to the select loop. [`onMsgNhg()`](/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-7/worktree/fdbsyncd/fdbsync.cpp:1140) discards records while NVO readiness is false, and neither readiness processing nor `AppRestartAssist` reconstructs them.

The repair-round-2 counterexample reaches a settled state with the kernel NHG present and APP NHG absent, violating `RestartConverges`.

## Trigger scenario

1. Configure an EVPN NVO.
2. Stop fdbsyncd while zebra and the kernel remain active.
3. Create or retain an L2 FDB nexthop using `ip nexthop add id 268435458 via 192.0.2.1 fdb`.
4. Restart fdbsyncd.
5. [`fdbsyncd.cpp:89`](/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-7/worktree/fdbsyncd/fdbsyncd.cpp:89) requests the dump before CONFIG_DB processing.
6. The dump record reaches `onMsgNhg()` while readiness is false and is discarded.
7. NVO readiness becomes true, but no second dump or replay occurs.

This matches counterexample State 3, `MCKernelNhgChangeWhileDown(g1)`, followed by the missed startup dump at State 5 and permanent divergence through settled State 9.

## Developer intent

The SONiC EVPN-MH design identifies fdbsyncd as producer and L2NhgOrch as consumer of `L2_NEXTHOP_GROUP_TABLE`, and assigns fdbsyncd responsibility for processing kernel L2-NHG notifications and dumps. The document excludes full warm reboot, but this trigger only requires an ordinary fdbsyncd process restart. [EVPN-MH HLD](https://github.com/sonic-net/SONiC/blob/master/doc/vxlan/EVPN/EVPN_VxLAN_Multihoming.md)

The affected code originated in [PR #4615](https://github.com/sonic-net/sonic-swss/pull/4615). Fresh searches covered exact NHG terms, upstream issues, and all recently closed/merged fdbsyncd PRs; results were feature/precursor PRs and unrelated fix [#4674](https://github.com/sonic-net/sonic-swss/pull/4674). None reported or fixed this dump-before-readiness/no-replay mechanism, so novelty remains `NEW`.

## Reproduction result

The relevant production sources had no local diff. The harness compiled them at SHA `4f3dda156e52ed7647b1dbf900d54d87efaea455` and used the real Redis `ProducerStateTable`/`ConsumerStateTable` transport.

Levels 0–1 previously established that the public kernel API accepts the FDB nexthop, but this host’s Linux 5.15/libnl runtime did not dispatch its dump or live notifications. The current round therefore reran the admissible Level-2 counterexample-state injection.

Exact command:

```text
timeout 6m bash /users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-7/run-repro.sh
```

Actual output:

```text
source_sha=4f3dda156e52ed7647b1dbf900d54d87efaea455
build_compat=define missing installed-swsscommon CFG_VXLAN_EVPN_NVO_TABLE_NAME as VXLAN_EVPN_NVO
reachable_real_api_precondition=id 268435458 via 192.0.2.1 scope link proto unspec fdb
test=MC-7 startup NHG dump before NVO readiness
level=2 (admissible counterexample-state injection)
counterexample=spec/output/repair_RR003_MC_hunt_scenario_5_restart_bfs.out
trace_step=State 3 MCKernelNhgChangeWhileDown(g1), delivered at State 5 startup dump
initial_nvo_ready=0
app_consumer_events_after_dump=0
app_consumer_saw_early_set_after_dump=0
nvo_ready_after_config=1
app_consumer_events_after_settle=0
app_consumer_saw_early_set_after_settle=0
app_consumer_control_events=1
app_consumer_live_control_set=1
app_consumer_live_control_fields=1
app_consumer_live_control_remote_vtep=192.0.2.2
app_consumer_saw_early_set_after_control=0
real_consumer=L2NhgOrch APP_DB transport (ConsumerStateTable)
correct_expected=both IDs 268435458 and 268435459 published after startup settles
observed=only post-readiness ID 268435459 is published; startup ID remains absent
permanent_without_external_resend=yes
MC7_REPRODUCED
exit_code=0
```

The decisive evidence is the missing early SET after settling, paired with the successful post-readiness positive control.

Required checklist:

1. Did Level 0 or Level 1 alone trigger it? **no**.
2. Level-2 reachability: **stop fdbsyncd → `ip nexthop add id 268435458 via 192.0.2.1 fdb` → restart fdbsyncd → `RTM_GETNEXTHOP` returns `RTM_NEWNEXTHOP`**. This instantiates exact counterexample State 3 followed by State 5.
3. Real consumer: `L2NhgOrch::doTask()` at [`orchagent/l2nhgorch.cpp:843`](/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-7/worktree/orchagent/l2nhgorch.cpp:843), using the production `ConsumerStateTable` constructed at [`orchagent/orch.cpp:1219`](/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-7/worktree/orchagent/orch.cpp:1219). The test directly demonstrated that transport receives no startup SET while receiving the control SET; the consequence is not argued-only.
4. Permanence: **permanent in a quiescent system**. Readiness processing, another configuration pass, and an unrelated later NHG event do not reconstruct the discarded ID. There is no periodic dump, restart-table replay, loopback, or caller guard that masks or resolves it; only an unguaranteed resend of that same ID can repair it.

The updated evidence record is [investigation.md](/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-7/investigation.md).

## Recommendation

Buffer valid startup NHG records until NVO readiness and replay them in dependency order, or issue a new `RTM_GETNEXTHOP` dump when readiness transitions to true. Add a regression test for dump-before-NVO ordering and explicitly include `L2_NEXTHOP_GROUP_TABLE` in restart reconstruction.

---
