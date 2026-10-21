# Bug Report — asterinas-local-flock-ownership

The bounded execution requested by the controller is complete. All 18 runtime traces obtained fresh matching witnesses. Thirteen of the 16 targeted configurations exhausted their reachable graphs without violations. Three configurations produced source-mapped Case C counterexamples representing two mechanisms.

The general `MC.cfg` search reached its configured 30-minute limit without a reported invariant violation. It did not exhaust the graph, so general exhaustive convergence is **not established**. Targeted checking continued under the explicit [controller decision](validation-controller-decision.md). This report does not turn that timeout into a pass or describe the candidates as separately confirmed bugs.

## Summary

- The campaign covers all five scenarios in the modeling brief, including the supplied FL-SQ-1 and FL-SQ-2 questions. It is not a blind discovery or a claim of novelty.
- The fixed Linux oracle is v6.16.5, commit `4645fefac0b24d509b962c096b0327e87f34b1d2`. The runtime Linux control is separately identified below.
- Source is Asterinas `0c60537098f4c2949ad2d382aaf499de72263d76`, tree `4693fdec88cd7da14bed4f1541eba593f123059c`. Source anchors below refer to that uninstrumented pin, not shifted instrumentation line numbers.
- There are two run-local model findings, MC-1 and MC-2. The severity labels below are provisional Phase 3 impact estimates. Separate confirmation, severity classification, repair and upstream submission were not executed. No persistent AST ID was allocated.
- The fresh replay covers 18 traces and 1,481 events with all 49 action types. The preserved runtime manifests report zero dropped events and two guest CPUs. C00, C06 and C11 remain prefixes. A matching prefix does not establish syscall completion.
- The exact reviewed Category B adapter implements existential acceptance. Every event invokes its full base action and exact post-state comparison. No model, configuration, oracle, instrumentation, harness or adapter semantics changed during this round.
- TLC used one JVM at a time, two workers, a 3 GiB heap and 1 GiB off-heap for model checking. Trace replay used the reviewed 3 GiB/two-worker adapter. Each model-checking run had a 30-minute budget, and all starts met the 6 GiB host-memory admission threshold.
- No simulation follow-up was required. All 13 nonviolating hunts exhausted at depths 41–116, above the method's depth-25 threshold. Violating hunts retained their counterexamples instead of weakening their properties.

The [run ledger](output/round1-20261005T202037Z/tlc-runs.json) records all 17 model-checking tasks, their exact launch options, timestamps, exit codes, counts and log paths. The [trace results](output/round1-20261005T202037Z/trace-results.json) record every fresh replay and trace hash. [Enabled obligations](output/round1-20261005T202037Z/enabled-obligations.json) bind the coverage claims to the actual configuration entries.

## General model-checking limit

[MC.cfg](MC.cfg) enables `MCTypeOK`, `CompatibleOwners`, `UniqueOwnerItem` and `Structure`. Task `cd40d24a53794789b870f02ab4e028a3` ended with wrapper exit 124. Its last progress report records 115,549,323 generated states, 20,081,186 distinct states, 10,460,133 states still queued and depth 13. These are last-reported counts, not exact shutdown totals. The [raw log](output/round1-20261005T202037Z/MC-bfs.log), [launch record](output/round1-20261005T202037Z/MC-bfs.request.json) and [process outcome](output/round1-20261005T202037Z/MC-bfs.result.json) are preserved.

All traces pass for the unchanged specification, and no Case A or Case B correction was exposed by this campaign. The unexhausted general frontier remains a verification limitation. The targeted results below are complete results for their own finite fixtures and enabled checks.

## Bug 1: Conflicting conversions retain the old shared flock

- **Run-local ID:** MC-1.
- **Scenario:** Scenario 2, C05 and C06. These are two manifestations of FL-SQ-1.
- **Provisional severity:** Medium. Applications can observe a Linux-visible conflict after a failed conversion or block both converters in the finite release-after-success fixture.
- **Violations:** `ConversionOracle` in [C05](MC_hunt_2_conversion_oracle.cfg), and `ConvertersDrain` in [C06](MC_hunt_2_converters.cfg).
- **Counterexamples:** [C05, 80 states](output/round1-20261005T202037Z/MC_hunt_2_conversion_oracle-bfs.log) and [C06, 57 concrete states plus stuttering](output/round1-20261005T202037Z/MC_hunt_2_converters-bfs.log).
- **Classification:** Case C. The model preserves the source behavior. No invariant or implementation transition was changed to suppress either result.

### Trace summary

| Trace states | Observed modeled execution |
|---|---|
| C05 states 23 and 27 | Independent owners B and A install SH items. |
| C05 states 42 and 47 | A's EX\|NB request conflicts with B and returns EAGAIN. A's old SH item remains. |
| C05 states 58 and 66 | B's UN removes B's item and returns. A's SH item remains as the only installed lock. |
| C05 states 75 and 80 | C's EX\|NB probe conflicts with A and returns EAGAIN. The fixed Linux oracle returns OK, falsifying `ConversionOracle`. |
| C06 states 17 and 28 | A and B install their SH items. |
| C06 states 41 and 53 | A's EX conversion registers on B's queue, then B's EX conversion registers on A's queue. Neither old SH item is removed. |
| C06 state 57 and its stuttering suffix | Both converters are parked with `result = WAIT`. Their fixture unlocks follow successful conversion, so neither can reach its promised release. `ConvertersDrain` fails under the declared weak fairness assumptions. |

The complete extracted state records are available for [C05](output/round1-20261005T202037Z/MC_hunt_2_conversion_oracle-states.json) and [C06](output/round1-20261005T202037Z/MC_hunt_2_converters-states.json). The C06 log explicitly names the violated temporal property. The structured summary tool omitted that name because this TLC version uses the singular temporal-property diagnostic, so the raw diagnostic was retained as the authority.

### Root cause and source mapping

[try_set_lock at flock.rs:114](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/flock/source/kernel/core/src/fs/file/flock.rs:114) holds the list Mutex, checks for another owner's conflict, and returns EAGAIN or registers the waiter at lines 116–120. Same-owner replacement occurs only after that check at lines 122–127. Thus a conflicting conversion leaves the caller's existing SH item installed. The [blocking retry loop at line 147](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/flock/source/kernel/core/src/fs/file/flock.rs:147) repeats that same conflict check. Its normal waiter closure and request/item Drop paths remain modeled, but neither converter reaches a release in this execution.

The fixed generic local Linux v6.16.5 implementation [removes an existing different-mode lock before checking conflicts](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/linux-v6.16.5/fs/locks.c:1101). The oracle is restricted to that source path, valid operations and the stated exclusions, including OOM. This finding does not claim atomic upgrades or universal old-mode retention semantics.

The already executed Linux C05 control on Linux 7.2.8/tmpfs records success for C's final probe. The freshly matched Asterinas C05 trace records EAGAIN at that probe. The C06 runtime prefix records both actual registrations against the other retained SH owner. The Linux control did not boot the archived v6.16.5 source, and no Linux C06 runtime result is claimed.

### Affected code

- `kernel/core/src/fs/file/flock.rs:114`: Conflict handling precedes same-owner mode replacement.
- `kernel/core/src/fs/file/flock.rs:147`: Blocking conversion retries without first discarding the previous mode.

### Recommendation

Align conversion ordering with the pinned generic local Linux path: remove the previous differing mode before conflict handling, while preserving Drop notifications and the full retry protocol. A later repair should validate both C05's distinguishing return and C06's controlled conversion cycle without imposing atomic upgrade semantics.

## Bug 2: A final temporary reference can deadlock flock cleanup

- **Run-local ID:** MC-2.
- **Scenario:** Scenario 5, C11, corresponding to FL-SQ-2.
- **Provisional severity:** High. A controlled close/unlock overlap can strand cleanup while holding the inode's flock-list Mutex, blocking later operations that require that Mutex.
- **Invariant:** `NoRecursiveListWait` in [the temporary-reference hunt](MC_hunt_5_temporary_last_reference.cfg).
- **Counterexample:** [34 states](output/round1-20261005T202037Z/MC_hunt_5_temporary_last_reference-bfs.log). TLC reported search depth 35, which is distinct from the counterexample's length.
- **Classification:** Case C. Re-entry follows from an actual modeled last reference drop and the production destructor chain. No synthetic deadlock action or missing recursive-owner exception is involved.

### Trace summary

| State | Observed modeled execution |
|---|---|
| 21 | B's prior SH flock syscall has returned, leaving one descriptor reference to B. |
| 26–28 | Thread t1 holds the list Mutex while unlocking independent A. It upgrades B from one to two strong references, then decides to retain B's item because B is not A. |
| 29–31 | Thread t2 removes B's last descriptor, releases the FD-table guard, and drops ClosedFile. B now has only the temporary reference retained by t1. |
| 32 | t1 drops that temporary reference while retaining the outer list guard. B reaches zero references and enters `destroying`. |
| 33–34 | B's destructor enters flock cleanup and t1 attempts the same list Mutex. The final state has `listOwner = t1`, t1 at `unlockWait`, `dtor = b`, and an outer `afterTemp` continuation on its stack. |

The [extracted state records](output/round1-20261005T202037Z/MC_hunt_5_temporary_last_reference-states.json) preserve the complete reference and ownership chain. The safety violation stopped TLC before it supplied a separate C11 verdict for the enabled `FinalReleaseCompletes` property. That property's result is **not established for C11**.

### Root cause and compensation checks

[unlock at flock.rs:166](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/flock/source/kernel/core/src/fs/file/flock.rs:166) holds the list Mutex across `retain`. Its closure obtains a temporary owner through `Weak::upgrade` at lines 40–41 and 168. That Arc is dropped inside the closure before the outer guard can be released.

The actual Rust Arc last-put path calls payload destruction synchronously. [InodeHandle::drop at line 537](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/flock/source/kernel/core/src/fs/file/inode_handle.rs:537) calls `unlock_flock`, which uses the same inode's flock list. [Mutex::lock at line 35](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/flock/source/ostd/src/sync/mutex.rs:35) waits on a boolean acquisition and has no recursive-owner path. The guard cannot release until the suspended outer retain call returns.

The relevant compensations were retained and checked. `get_file_fast!` keeps A alive, which does not retain the independently opened B. The installed flock owner is Weak. B's earlier flock syscall has finished, no B alias remains, and logging adds no owner Arc. `sys_close` releases its table guard before dropping ClosedFile, whose range-lock cleanup uses a different lock. Item Drop notifications do not move the temporary owner's destructor outside the held list guard.

The freshly matched C11 runtime prefix observes the successful upgrade, FD removal, ClosedFile put leaving one reference, last temporary put, real destructor entry and nested attempt with `selfHeld = true` on SMP 2. That runtime case uses an EX item while the targeted fixture uses SH. The upgrade/drop/cleanup mechanism is independent of the stored mode, and each history is replayed with its actual mode. This is direct window evidence, not a watchdog-based inference or a separately completed confirmation phase.

### Affected code

- `kernel/core/src/fs/file/flock.rs:166`: A temporary upgraded owner can be destroyed while the list guard is held.
- `kernel/core/src/fs/file/inode_handle.rs:537`: Payload destruction re-enters flock cleanup.
- `ostd/src/sync/mutex.rs:35`: The nested request cannot acquire the Mutex held by its own suspended caller.

### Recommendation

Move potentially final temporary-owner puts outside the list-Mutex critical section while preserving owner identity, expired-item removal and notifications. A later repair should retain the exact C11 reference window and the extra-alias, close-before and close-after controls.

## Not Reproduced

The following configurations exhausted their own reachable state graphs without violations of their enabled checks. This does not establish behavior outside their finite admission bounds, or replace the time-limited general search. No nonviolating hunt was shallow enough to require simulation.

| Scenario | Configuration and raw log | Distinct states | Depth | Result |
|---|---|---:|---:|---|
| Compatible owners (C01) | [MC_hunt_1_compatible_owners.cfg](output/round1-20261005T202037Z/MC_hunt_1_compatible_owners-bfs.log) | 5,785 | 95 | No violation; exhausted. |
| Captured identity on FD reuse | [MC_hunt_1_fd_reuse.cfg](output/round1-20261005T202037Z/MC_hunt_1_fd_reuse-bfs.log) | 391 | 49 | No violation; exhausted. |
| OFD aliases (C02) | [MC_hunt_1_ofd_alias.cfg](output/round1-20261005T202037Z/MC_hunt_1_ofd_alias-bfs.log) | 947 | 90 | No violation; exhausted. |
| Conversion and downgrade (C04) | [MC_hunt_2_downgrade.cfg](output/round1-20261005T202037Z/MC_hunt_2_downgrade-bfs.log) | 1,061 | 105 | No violation; exhausted. |
| Blocker migration (C08) | [MC_hunt_3_blocker_migration.cfg](output/round1-20261005T202037Z/MC_hunt_3_blocker_migration-bfs.log) | 868 | 116 | No violation; exhausted. |
| Release after registration (C07) | [MC_hunt_3_release_after_registration.cfg](output/round1-20261005T202037Z/MC_hunt_3_release_after_registration-bfs.log) | 415 | 73 | No violation; exhausted. |
| Release before registration (C07) | [MC_hunt_3_release_before_registration.cfg](output/round1-20261005T202037Z/MC_hunt_3_release_before_registration-bfs.log) | 161 | 65 | No violation; exhausted. |
| Competing waiters (C09 safety) | [MC_hunt_3_wake_race.cfg](output/round1-20261005T202037Z/MC_hunt_3_wake_race-bfs.log) | 14,439 | 114 | No violation; exhausted. |
| Alias and final close (C03) | [MC_hunt_4_alias_close.cfg](output/round1-20261005T202037Z/MC_hunt_4_alias_close-bfs.log) | 62 | 62 | No violation; exhausted. |
| In-flight reference after close (C10) | [MC_hunt_4_inflight_close.cfg](output/round1-20261005T202037Z/MC_hunt_4_inflight_close-bfs.log) | 496 | 86 | No violation; exhausted. |
| Close after scan (C12) | [MC_hunt_5_close_after_control.cfg](output/round1-20261005T202037Z/MC_hunt_5_close_after_control-bfs.log) | 45 | 45 | No violation; exhausted. |
| Close before scan (C12) | [MC_hunt_5_close_before_control.cfg](output/round1-20261005T202037Z/MC_hunt_5_close_before_control-bfs.log) | 41 | 41 | No violation; exhausted. |
| Extra alias (C12) | [MC_hunt_5_extra_alias_control.cfg](output/round1-20261005T202037Z/MC_hunt_5_extra_alias_control-bfs.log) | 93 | 50 | No violation; exhausted. |

C09 checks incompatible ownership and retry safety. It deliberately does not assert `FixtureCompletes`: request-item Drop may repeatedly drain a contender that retries and re-enqueues. The existing FL-CR-1 remains a review-only scheduling question, not a third model finding or a wall-clock latency defect.

## Protocol coverage and evidence boundaries

| Question | Bounded evidence |
|---|---|
| OFD identity, aliases and incompatible ownership | C01, C02, FD reuse and C03 targeted checks completed without violations. The matching runtime traces retain distinct opens and shared dup identity. |
| Mode conversion and other contenders | The sole-owner conversion/downgrade check completed. C05 and C06 expose the shared retention mechanism described in MC-1. |
| Release, registration, notification and retry | Both C07 ordering checks, C08 blocker migration and C09 safety completed. Runtime C07-notify additionally captures notification before parking. A notification does not reserve a grant. |
| Captured references after FD removal | C10 completed with its independent post-cleanup probe. C13's matching runtime trace covers the original open reference surviving descriptor removal. |
| Temporary references and eventual cleanup | C11 exposes MC-2. All three C12 model controls completed, and their existing runtime traces matched. |

The current runtime evidence is `harness/evidence/attempt-20261005T165124-821788448/`. The top-level `harness/STATUS.md`, `status.json` and `coverage.json` predate that v12 attempt and remain historical. The [Phase 0 audit](output/phase0-20261005T201613Z/trace-audit.json) binds all 18 current traces to preserved raw manifests and serial logs. Its unchanged coverage check reproduces C00's one overlapping pair among four cross-thread pairs, or 25%. This percentage belongs to C00, not the aggregate of all traces.

All runtime fixtures use the shared-table reference path. The borrowed-table branch has the existing reviewed model and synthetic coverage only. The modeled ordinary file, valid flags, stable inode, signal-free execution and other exclusions remain unchanged. No FIFO selection, general starvation freedom, fixed completion time or weak-memory proof is claimed.

The [lightweight persistent lookup](output/round1-20261005T202037Z/persistent-findings-lookup.json) found no matching record. That is not an upstream novelty claim. Confirmation, final severity classification, repair and registry allocation belong to later authorized phases.

All raw TLC logs and JSON counterexamples are preserved under this report's output directory. Generated trace-exploration modules and binaries were archived before the trace tool's cleanup. The C05 analysis-log copy changes only its JSON file reference to an absolute path for the structured reader, and leaves the raw log unchanged. No semantic input was changed or self-approved during analysis.
