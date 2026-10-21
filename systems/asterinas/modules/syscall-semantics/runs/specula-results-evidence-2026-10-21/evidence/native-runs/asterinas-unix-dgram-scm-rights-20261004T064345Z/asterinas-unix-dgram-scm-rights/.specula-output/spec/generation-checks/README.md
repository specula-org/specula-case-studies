# SCM_RIGHTS revision checks

The sections before Revision 2 preserve the revision 1 record at `9573ffb`.
See [Revision 2](#revision-2-completing-companion-configurations) for the new
companion configurations, bounds and completed results. See
[Revision 3](#revision-3-review-findings-5-and-6) for the PEEK oracle repair,
trace completion-witness check and its regression results. See
[Revision 4 correction](#revision-4-correction) for the current `MC.cfg`,
whole-trace event format and corrected coverage. Revision 4 below preserves
the attempt-2 record and its superseded conclusions. Earlier `MC.cfg` bounds
and commands refer to the historical configuration now kept as
`MC_brief_bounds.cfg`.

These original records validate findings 1–4 in `../review-specgen-original.md`.
The implementation pin is Asterinas
`0c60537098f4c2949ad2d382aaf499de72263d76`, tree
`4693fdec88cd7da14bed4f1541eba593f123059c`. The tests use synthetic traces and
the bounded specification. They do not constitute kernel or Linux runtime
validation.

## Reproduce the checks

Run these commands from the workspace root. The runner serializes TLC runs,
preserves existing logs under numbered rerun names, and records the exact Java
command, input hashes, start time, exit code, wall time and TLC statistics in
`results.json`. Each TLC command uses `timeout 5400`, `-Xmx3g`,
`-XX:MaxDirectMemorySize=512m`, `-XX:+UseParallelGC`, two workers and a metadata
directory under `states/`. It preserves the configuration's `CHECK_DEADLOCK`.
SANY uses a 512 MiB heap.

```sh
python3 spec/generation-checks/run_checks.py parse
python3 spec/generation-checks/run_checks.py valid bad-source unknown-event truncated corrupted-post malformed-metadata nonmonotonic Trace
python3 spec/generation-checks/run_checks.py MC_hunt_AST36 MC_hunt_AST32_install MC_hunt_AST32_report
python3 spec/generation-checks/run_checks.py MC_hunt_scenario1 MC_hunt_scenario1_separate_tables MC_hunt_scenario2 MC_hunt_scenario3 MC_hunt_scenario4 MC_cleanup MC base
python3 spec/generation-checks/audit_sources.py
```

`run_checks.py` uses the exact Java binary and both jars requested for the
revision. `-DTLA-Library=.` lets the probe module import the revised modules
from `spec/`. `-noGenerateSpecTE` keeps unsolicited trace-exploration modules
out of the suite. The complete counterexample states remain in each TLC log.

Every top-level configuration is run, including `base.cfg`. The `Trace`
selection runs the original `Trace.tla` and `Trace.cfg`, setting
`JSON=generation-checks/valid.ndjson`. The seven probe configurations copy
`Trace.cfg` and only add the reviewer's `JsonFile` override mechanism. No
smaller companion configuration was added.

## Synthetic trace checks

`valid.ndjson` contains 55 events. It sends A, B, A, B, closes and drops the
original A descriptor, reuses that descriptor for B, receives all four captured
objects, then closes and drops every owner. Receiver-entry provenance remains
visible through cleanup. Its metadata uses the documented strings `fileA`
and `fileB`. Both the probe and original trace configuration check `TypeOK`,
the protocol invariants, `TraceEndComplete` and `TraceMatched` and explore 56
distinct states from one initial state.

A trace result counts only if the initial-state count is nonzero and TLC
finishes without errors while checking those properties. A zero-state success
is invalid evidence. Missing fields can also cause a TLC evaluation error,
which rejects the input. Errors from invalid input must not be interpreted as
implementation counterexamples.

| Input | Expected rejection |
| --- | --- |
| `bad-source.ndjson` | The source identity assertion fails. |
| `unknown-event.ndjson` | The event validation assertion fails. |
| `truncated.ndjson` | `TraceEndComplete` fails after the single `SendBegin` event. |
| `corrupted-post.ndjson` | `TraceMatched` fails because the first event's `send.result` is corrupted. |
| `malformed-metadata.ndjson` | The schema assertion rejects schema 2. |
| `nonmonotonic.ndjson` | The second sender event precedes the first and fails the per-thread timestamp assertion. |

The first three inputs are byte-identical to the reviewer's files under
`../review-checks/`. The other negative inputs each mutate one aspect of the
complete valid trace. These fixtures test the validator, not hook correctness
or real concurrent executions.

## Compatibility counterexamples

The three compatibility configurations remain separate from protocol checks.
The counterexamples agree with the pinned source. Asterinas paths below are
relative to `kernel/core/src/`. Linux paths are relative to its source root:

- `NoFailedNumberInstalled` fails at state 31. A completed PEEK retains entry
  1 in both `installed` and `numberFailed`. In
  `net/socket/unix/ctrl_msg.rs:139-148`, insertion precedes the
  fallible integer copy and no removal compensates for that copy's failure.
- `ReportedPrefixMatchesLinux` fails at state 36. Entries 1 and 2 were
  delivered, entry 3 failed, the header length remains 32, and reported control
  length is zero with truncation set. The header is written before the loop
  at `net/socket/unix/ctrl_msg.rs:130-148`, and
  `net/socket/util/message_header.rs:104-129` suppresses the
  error without counting the failed control message's prefix.
- `PayloadFaultConsumptionMatchesLinux` fails at state 18. A completed
  ordinary receive returns `EFAULT` with `faultRetained = TRUE`. The `?` at
  `net/socket/unix/datagram/message.rs:195` returns before
  the pop at line 202. Linux's selected-file reference unlinks the ordinary
  receive in `net/core/datagram.c:198-199` before payload copying.

These remain the existing AST-32/AST-36 source leads. They are expected model
compatibility violations, not new bug reports or runtime reproductions.

## Type repairs required by executed checks

The first revised AST-36 attempt passed the original sender-close point but
failed when `TypeOK` compared the string `NoOwner` with a receiver operation
tuple. Queue owner tags now use attempt index zero in the same tuple shape as
receiver operations, whose attempt indices start at one. Equality and domain
membership therefore remain defined throughout receive and disposal.

The mixed string/integer return-value domain also requires a TLC-compatible
comparison. It now compares `ToString` of each allowed scalar, keeping the
quotes that distinguish strings from integers. An intermediate attempt to
enumerate a mixed set before rendering it still raised a type error. Both
failed development runs are retained as `MC_hunt_AST36.log` and
`MC_hunt_AST36-r2.log`. The completed compatibility check is
`MC_hunt_AST36-r3.log`. The repair changes representation and evaluation only.
It adds no protocol guard and weakens no property.

## Source annotations

`source-annotations-r2.log` records all 87 distinct cited source ranges, their
callers in the revised artifacts, source-file hashes and numbered excerpts.
Asterinas file bytes were compared to the pinned Git objects. The source tree
was clean. The branch annotations were inspected against those excerpts,
including successful copy, empty queue, payload fault, NULL control, capacity
failure, header/number failure, reporting and cleanup paths. OSTD and
kernel-library paths carry explicit repository-root markers.

The static audit also confirms the 34-action correspondence between the base
model, trace dispatch, mandatory fields and instrumentation table. It checks
that the approved brief, analysis and review are unchanged and that all 12
original configurations are byte-identical to the baseline.

## Execution results

All ten original MC configurations have exited. Three expose their expected
compatibility violations, the separate-tables protocol configuration completes
without a violation, and six runs reach the 5400-second timeout. A timeout is
an incomplete result. Its counts below come from the last progress line,
rather than a complete state graph. No bounds were reduced.

`MC_cleanup.cfg` is incomplete. Its periodic temporal checks reported no
violation, but `BoundedCleanupProgress` is not established for its complete
configured state space. The separate-tables safety result does not establish
the cleanup configuration's liveness property.

| Configuration | Outcome | Distinct states | Search depth | Counterexample states | Queue | Wall seconds | Log |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| `MC.cfg` | incomplete | 25,166,056 | 35 | — | 5,270,015 | 5400.179 | [MC.log](MC.log) |
| `MC_hunt_scenario1.cfg` | incomplete | 44,477,718 | 75 | — | 13,569,182 | 5400.155 | [MC_hunt_scenario1.log](MC_hunt_scenario1.log) |
| `MC_hunt_scenario1_separate_tables.cfg` | complete | 25,318,204 | 89 | — | 0 | 4541.305 | [MC_hunt_scenario1_separate_tables.log](MC_hunt_scenario1_separate_tables.log) |
| `MC_hunt_scenario2.cfg` | incomplete | 48,596,194 | 74 | — | 18,342,093 | 5400.082 | [MC_hunt_scenario2.log](MC_hunt_scenario2.log) |
| `MC_hunt_scenario3.cfg` | incomplete | 35,664,748 | 71 | — | 10,683,170 | 5400.133 | [MC_hunt_scenario3.log](MC_hunt_scenario3.log) |
| `MC_hunt_scenario4.cfg` | incomplete | 48,176,751 | 76 | — | 18,088,793 | 5400.130 | [MC_hunt_scenario4.log](MC_hunt_scenario4.log) |
| `MC_cleanup.cfg` | incomplete | 4,885,294 | 59 | — | 375,379 | 5400.201 | [MC_cleanup.log](MC_cleanup.log) |
| `MC_hunt_AST32_install.cfg` | expected violation: `NoFailedNumberInstalled` | 12,334 | 32 | 31 | 2,752 | 3.074 | [MC_hunt_AST32_install.log](MC_hunt_AST32_install.log) |
| `MC_hunt_AST32_report.cfg` | expected violation: `ReportedPrefixMatchesLinux` | 1,363 | 36 | 36 | 137 | 1.104 | [MC_hunt_AST32_report.log](MC_hunt_AST32_report.log) |
| `MC_hunt_AST36.cfg` | expected violation: `PayloadFaultConsumptionMatchesLinux` | 346 | 19 | 18 | 116 | 1.037 | [MC_hunt_AST36-r3.log](MC_hunt_AST36-r3.log) |

Counterexample lengths count the initial state. Search depth may differ from
counterexample length with two workers. The exact commands and unrounded
statistics are retained in each log and `results.json`.

### Last progress lines for incomplete MC runs

`MC.cfg`:

```text
Progress(35) at 2026-10-05 05:09:25: 62,384,506 states generated (1,111,186 s/min), 25,166,056 distinct states found (390,646 ds/min), 5,270,015 states left on queue.
```

`MC_hunt_scenario1.cfg`:

```text
Progress(75) at 2026-10-04 20:23:00: 253,837,445 states generated (3,163,529 s/min), 44,477,718 distinct states found (442,428 ds/min), 13,569,182 states left on queue.
```

`MC_hunt_scenario2.cfg`:

```text
Progress(74) at 2026-10-04 23:08:42: 241,492,445 states generated (2,927,658 s/min), 48,596,194 distinct states found (513,779 ds/min), 18,342,093 states left on queue.
```

`MC_hunt_scenario3.cfg`:

```text
Progress(71) at 2026-10-05 00:38:42: 161,941,785 states generated (1,892,163 s/min), 35,664,748 distinct states found (348,727 ds/min), 10,683,170 states left on queue.
```

`MC_hunt_scenario4.cfg`:

```text
Progress(76) at 2026-10-05 02:08:42: 237,522,310 states generated (2,938,672 s/min), 48,176,751 distinct states found (499,130 ds/min), 18,088,793 states left on queue.
```

`MC_cleanup.cfg`:

```text
Progress(59) at 2026-10-05 03:38:56: 16,331,258 states generated (195,790 s/min), 4,885,294 distinct states found (63,460 ds/min), 375,379 states left on queue.
```

### Original base and trace configurations

All twelve original top-level configurations were executed. The supplemental
`base.cfg` also reached the timeout. The original `Trace.cfg` completed on the
synthetic fixture selected through `JSON`.

| Configuration | Outcome | Distinct states | Depth | Queue | Wall seconds | Log |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| `base.cfg` | incomplete | 71,252,842 | 29 | 27,986,858 | 5400.208 | [base.log](base.log) |
| `Trace.cfg` | complete | 56 | 56 | 0 | 1.075 | [Trace-config.log](Trace-config.log) |

The final reported progress for `base.cfg` was:

```text
Progress(29) at 2026-10-05 06:38:43: 158,544,114 states generated (1,641,457 s/min), 71,252,842 distinct states found (750,286 ds/min), 27,986,858 states left on queue.
```

### Trace probes and final parsing

| Check | Result | Initial states reported | Distinct states | Exit | Log |
| --- | --- | ---: | ---: | ---: | --- |
| `valid` | complete | 1 | 56 | 0 | [valid.log](valid.log) |
| `bad-source` | expected rejection | not reached | 0 | 75 | [bad-source.log](bad-source.log) |
| `unknown-event` | expected rejection | not reached | 0 | 75 | [unknown-event.log](unknown-event.log) |
| `truncated` | expected rejection (`TraceEndComplete`) | 1 | 2 | 12 | [truncated.log](truncated.log) |
| `corrupted-post` | expected rejection (`TraceMatched`) | 1 | 1 | 13 | [corrupted-post.log](corrupted-post.log) |
| `malformed-metadata` | expected rejection | not reached | 0 | 75 | [malformed-metadata.log](malformed-metadata.log) |
| `nonmonotonic` | expected rejection | not reached | 0 | 75 | [nonmonotonic.log](nonmonotonic.log) |

The assertion failures reject input before initialization finishes. They have
nonzero exit codes and explicit errors. The accepted fixture and the corrupted
post-state check each establish one initial state. The truncated fixture
reaches its second state before `TraceEndComplete` rejects the missing suffix.

The final SANY checks use the same module hashes as the final TLC runs:

| Module | Result | Wall seconds | Log |
| --- | --- | ---: | --- |
| `base.tla` | PASS | 0.275 | [parse-base-final.log](parse-base-final.log) |
| `MC.tla` | PASS | 0.265 | [parse-MC-final.log](parse-MC-final.log) |
| `Trace.tla` | PASS | 0.268 | [parse-Trace-final.log](parse-Trace-final.log) |

Preliminary parser logs and the two superseded AST-36 development runs remain
in the record. `results.json` marks the authoritative run for each check.
The negative probes are classified as expected rejections in that index.

### Criterion verdicts

C6 evaluates whether every configuration was executed and reported under the
requested limits. The six incomplete MC runs have no complete safety or
liveness result. No smaller configuration was substituted.

Commands below are run from the workspace root. Every TLC/SANY log and run
entry in `results.json` also contains the exact Java command and its working
directory. All TLC commands retain `timeout 5400`, the requested memory flags,
two workers and each configuration's own deadlock setting.

| Criterion | Verdict | Command | Evidence |
| --- | --- | --- | --- |
| C1-sender-close | PASS | `python3 spec/generation-checks/run_checks.py valid` | [valid.log](valid.log) |
| C2-trace-typeok | PASS | `python3 spec/generation-checks/run_checks.py valid Trace` | [valid.log](valid.log)<br>[Trace-config.log](Trace-config.log) |
| C3-trace-reject | PASS | `python3 spec/generation-checks/run_checks.py bad-source unknown-event truncated corrupted-post malformed-metadata nonmonotonic` | [bad-source.log](bad-source.log)<br>[unknown-event.log](unknown-event.log)<br>[truncated.log](truncated.log)<br>[corrupted-post.log](corrupted-post.log)<br>[malformed-metadata.log](malformed-metadata.log)<br>[nonmonotonic.log](nonmonotonic.log) |
| C4-annotations | PASS | `python3 spec/generation-checks/audit_sources.py` | [source-annotations-r2.log](source-annotations-r2.log) |
| C5-parse | PASS | `python3 spec/generation-checks/run_checks.py parse` | [parse-base-final.log](parse-base-final.log)<br>[parse-MC-final.log](parse-MC-final.log)<br>[parse-Trace-final.log](parse-Trace-final.log) |
| C6-mc | PASS | `python3 spec/generation-checks/run_checks.py MC MC_cleanup MC_hunt_AST32_install MC_hunt_AST32_report MC_hunt_AST36 MC_hunt_scenario1 MC_hunt_scenario1_separate_tables MC_hunt_scenario2 MC_hunt_scenario3 MC_hunt_scenario4` | [MC.log](MC.log)<br>[MC_cleanup.log](MC_cleanup.log)<br>[MC_hunt_AST32_install.log](MC_hunt_AST32_install.log)<br>[MC_hunt_AST32_report.log](MC_hunt_AST32_report.log)<br>[MC_hunt_AST36-r3.log](MC_hunt_AST36-r3.log)<br>[MC_hunt_scenario1.log](MC_hunt_scenario1.log)<br>[MC_hunt_scenario1_separate_tables.log](MC_hunt_scenario1_separate_tables.log)<br>[MC_hunt_scenario2.log](MC_hunt_scenario2.log)<br>[MC_hunt_scenario3.log](MC_hunt_scenario3.log)<br>[MC_hunt_scenario4.log](MC_hunt_scenario4.log) |
| C7-records | PASS | `git diff --check`<br>`python3 -m json.tool spec/generation-checks/results.json >/dev/null` | [records.log](records.log)<br>[scope-preservation.log](scope-preservation.log) |

C1 uses the original sender close immediately after successful send in
`valid.ndjson`. C2 also runs the unchanged original `Trace.cfg`. C3 includes
all three reviewer inputs plus the corrupt post-state, schema and timestamp
controls. C4 covers 87 cited ranges. C7 additionally checks the file inventory,
unchanged input/configuration bytes, final input hashes and recorded resource
limits. The source, reference documents and reviewer artifacts were not edited.

The revised trace schema changes only the observer representation of slot
origins and queue owners. The full base actions and mandatory post-state
checks remain active. `scope-preservation.log` records unchanged executable MC
code, trace matching and 19 unaffected base operators.

Kernel execution, production instrumentation/traces, Linux runtime controls,
bug confirmation and classification remain NOT RUN. The results above are
bounded specification checks and synthetic validator tests.

## Revision 2: completing companion configurations

The preceding sections retain revision 1 results at `9573ffb`. This revision adds bounded companion configurations. A complete result applies only to its listed constants. An incomplete run is not a pass, and a union of layout subsets does not explore executions that mix layouts from different subsets.

Revision 2 used **14411.666 seconds** of TLC wall time out of 18,000 seconds, leaving 3588.334 seconds. This sum includes all probes, timeouts and completed runs. No run remains active.

Of 39 new configurations, 25 completed with no violation. The other 14 are retained diagnostic candidates. Across 43 attempts, 25 completed and 18 were time-limited. Only completed rows form the completing set.

Layout splitting was tried first. Scenario 3's capacity and fault groups
completed with every other constant unchanged. The singleton Full group
remained incomplete after both a 300-second probe and an 1800-second run.
The full run reported 16,296,831 distinct states and 7,003,470 queued states
at depth 73. A smaller nonempty layout subset cannot retain Full. Scenario 1,
cleanup and MC singleton Full probes also remained incomplete. Their
300-second results are probes, not 1800-second results.

Single-call Full companions for Scenario 1, Scenario 3 and cleanup retain
four rights and separately cover PEEK and ordinary receive. They give up
overlapping receiver calls. Scenario 3 still has overlapping receiver
publication within its completing capacity group. Cleanup retains its
original fairness and uses no symmetry in any companion.

Both standard Scenario 2 operation splits (one PEEK/two ordinary and two
PEEK/one ordinary) remained incomplete in 300-second probes. Even two PEEK
calls without an ordinary call left 1,180,166 queued states after reporting
2,436,862 distinct states at depth 70. These rates, together with the
1800-second four-right Full result, motivated three-right companions for
repeated PEEK and mixed publication. The ordinary-only companion retains
four rights and two ordinary attempts.

Scenario 4's four-right one-PEEK/one-ordinary probe also remained incomplete.
With three rights and the original one-PEEK/two-ordinary budgets, the
1800-second run still had 1,144,303 queued states after reporting 15,270,917
distinct states at depth 76. Three rights with one PEEK and one ordinary
call completed in 298.780 seconds over 2,503,446 states. Together with the
four-right, two-ordinary companion, it covers mixed PEEK/receive paths and
ordinary fault/retry paths while losing the combined three-call execution.

For MC, the first five-layout no-installation group and three-layout prefix
group reached only depths 37 and 45 in their 300-second probes. Further
layout splits retain all other constants. The Full one-PEEK/two-ordinary
and two-PEEK/one-ordinary four-right probes also remained incomplete.
The Full companions therefore separate ordinary-only, repeated-PEEK and
mixed publication. The mixed three-right companion uses one PEEK and one
ordinary call. This choice uses Scenario 4's measured three-right,
one-PEEK/two-ordinary timeout: the main configuration additionally permits
send faults and reuse, so it contains those reachable behaviors. This is a
configuration-selection inference. Each actual outcome is recorded below.

Every three-right configuration sends A, B, A. It retains two objects and
one duplicate reference, and loses the fourth entry and second B reference.
Four-right fault companions retain the original later-fault cleanup case
with an additional uncopied fourth entry. All operation splits retain two
receiver threads. Layout partitions omit executions mixing layouts from
different subsets, and operation partitions omit requests beyond their
listed budgets. No completing companion establishes a timed-out original
configuration or the original combined four-call Full state space.

The smaller MC layout-only groups Null/Zero/Short, HeaderOnly/NoInteger,
and One/OnePadded completed with the original rights and operation budgets.
SpaceOne alone still timed out after 1800 seconds, reporting 15,276,518
states, depth 94 and 1,706,685 queued states. Its operation companions keep
four rights and split the budgets into two PEEK/one ordinary and one
PEEK/two ordinary attempts. They omit the combined four-call execution.
Their actual outcomes are listed in the execution table.

### Constants and coverage limits

Every companion keeps `Threads = {r1, r2}`, `AttemptSlots = 2`, `ObjectA = fileA`, `ObjectB = fileB`, `SharedTable = TRUE`, `SetupFDCount = 5`, `MaxFD = 22` and `PayloadSize = 1`. There are 16 free receiver slots beyond the seven setup/object descriptors. All original invariants, specification, view, constraint, symmetry and deadlock entries are preserved. Cleanup companions retain `MCLiveSpec` and omit symmetry.

The following original constants define each companion before applying its exact differences in the second table. No other constant differs.

| Original | AllowedLayouts | RightsCount | SendFaultLimit | PayloadFaultLimit | OutputFaultLimit | PeekLimit | RecvLimit | ReuseLimit |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `MC.cfg` | `{"Full", "Null", "Zero", "Short", "HeaderOnly", "NoInteger", "One", "OnePadded", "SpaceOne", "FirstFault", "LaterFault", "PartialFault", "HeaderFault", "HeaderPartial"}` | `4` | `1` | `1` | `1` | `2` | `2` | `1` |
| `MC_hunt_scenario1.cfg` | `{"Full", "Null"}` | `4` | `1` | `0` | `0` | `1` | `1` | `1` |
| `MC_hunt_scenario2.cfg` | `{"Full"}` | `4` | `0` | `0` | `0` | `2` | `2` | `0` |
| `MC_hunt_scenario3.cfg` | `{"Full", "Null", "Zero", "Short", "HeaderOnly", "NoInteger", "One", "OnePadded", "SpaceOne", "FirstFault", "LaterFault", "PartialFault", "HeaderFault", "HeaderPartial"}` | `4` | `0` | `0` | `1` | `1` | `1` | `0` |
| `MC_hunt_scenario4.cfg` | `{"Full"}` | `4` | `0` | `1` | `0` | `1` | `2` | `0` |
| `MC_cleanup.cfg` | `{"Full", "LaterFault", "Null"}` | `4` | `1` | `1` | `1` | `1` | `1` | `1` |

| Companion | Supports | Exact changed constants | Coverage retained | Coverage given up |
| --- | --- | --- | --- | --- |
| [MC_cleanup_layout_full.cfg](../MC_cleanup_layout_full.cfg) | `MC_cleanup.cfg` | `AllowedLayouts = {"Full"}` | Checks full ancillary publication. | Other layouts and their mixtures are excluded. |
| [MC_cleanup_layout_full_peek0_recv1.cfg](../MC_cleanup_layout_full_peek0_recv1.cfg) | `MC_cleanup.cfg` | `AllowedLayouts = {"Full"}`<br>`PeekLimit = 0` | Checks full ancillary publication. Permits up to 0 PEEK calls and 1 ordinary call across two receiver threads. | Other layouts and their mixtures are excluded. Executions exceeding either operation budget are excluded. Receiver calls cannot overlap in this companion. |
| [MC_cleanup_layout_full_peek1_recv0.cfg](../MC_cleanup_layout_full_peek1_recv0.cfg) | `MC_cleanup.cfg` | `AllowedLayouts = {"Full"}`<br>`RecvLimit = 0` | Checks full ancillary publication. Permits up to 1 PEEK call and 0 ordinary calls across two receiver threads. | Other layouts and their mixtures are excluded. Executions exceeding either operation budget are excluded. Receiver calls cannot overlap in this companion. |
| [MC_cleanup_layout_later_fault.cfg](../MC_cleanup_layout_later_fault.cfg) | `MC_cleanup.cfg` | `AllowedLayouts = {"LaterFault"}` | Checks two delivered entries followed by an installed third entry whose number copy fails. | Other layouts are excluded. The single output-fault budget permits only one receive attempt. |
| [MC_cleanup_layout_null.cfg](../MC_cleanup_layout_null.cfg) | `MC_cleanup.cfg` | `AllowedLayouts = {"Null"}` | Checks queue ownership, temporary drops and NULL-control cleanup. | No receiver FD is installed. |
| [MC_hunt_scenario1_layout_full.cfg](../MC_timelimited_scenario1_layout_full.cfg) | `MC_hunt_scenario1.cfg` | `AllowedLayouts = {"Full"}` | Checks full ancillary publication. | Other layouts and their mixtures are excluded. |
| [MC_hunt_scenario1_layout_full_peek0_recv1.cfg](../MC_hunt_scenario1_layout_full_peek0_recv1.cfg) | `MC_hunt_scenario1.cfg` | `AllowedLayouts = {"Full"}`<br>`PeekLimit = 0` | Checks full ancillary publication. Permits up to 0 PEEK calls and 1 ordinary call across two receiver threads. | Other layouts and their mixtures are excluded. Executions exceeding either operation budget are excluded. Receiver calls cannot overlap in this companion. |
| [MC_hunt_scenario1_layout_full_peek1_recv0.cfg](../MC_hunt_scenario1_layout_full_peek1_recv0.cfg) | `MC_hunt_scenario1.cfg` | `AllowedLayouts = {"Full"}`<br>`RecvLimit = 0` | Checks full ancillary publication. Permits up to 1 PEEK call and 0 ordinary calls across two receiver threads. | Other layouts and their mixtures are excluded. Executions exceeding either operation budget are excluded. Receiver calls cannot overlap in this companion. |
| [MC_hunt_scenario1_layout_null.cfg](../MC_hunt_scenario1_layout_null.cfg) | `MC_hunt_scenario1.cfg` | `AllowedLayouts = {"Null"}` | Checks queue ownership, temporary drops and NULL-control cleanup. | No receiver FD is installed. |
| [MC_hunt_scenario2_peek0_recv2.cfg](../MC_hunt_scenario2_peek0_recv2.cfg) | `MC_hunt_scenario2.cfg` | `PeekLimit = 0` | Permits up to 0 PEEK calls and 2 ordinary calls across two receiver threads. | Executions exceeding either operation budget are excluded. |
| [MC_hunt_scenario2_peek1_recv2.cfg](../MC_timelimited_scenario2_peek1_recv2.cfg) | `MC_hunt_scenario2.cfg` | `PeekLimit = 1` | Permits up to 1 PEEK call and 2 ordinary calls across two receiver threads. | Executions exceeding either operation budget are excluded. |
| [MC_hunt_scenario2_peek2_recv0.cfg](../MC_timelimited_scenario2_peek2_recv0.cfg) | `MC_hunt_scenario2.cfg` | `RecvLimit = 0` | Permits up to 2 PEEK calls and 0 ordinary calls across two receiver threads. | Executions exceeding either operation budget are excluded. |
| [MC_hunt_scenario2_peek2_recv1.cfg](../MC_timelimited_scenario2_peek2_recv1.cfg) | `MC_hunt_scenario2.cfg` | `RecvLimit = 1` | Permits up to 2 PEEK calls and 1 ordinary call across two receiver threads. | Executions exceeding either operation budget are excluded. |
| [MC_hunt_scenario2_rights3_peek1_recv2.cfg](../MC_hunt_scenario2_rights3_peek1_recv2.cfg) | `MC_hunt_scenario2.cfg` | `RightsCount = 3`<br>`PeekLimit = 1` | Permits up to 1 PEEK call and 2 ordinary calls across two receiver threads. Captures A, B, A, preserving two objects and a duplicate reference. | Executions exceeding either operation budget are excluded. The fourth entry and second B reference are excluded. |
| [MC_hunt_scenario2_rights3_peek2_recv0.cfg](../MC_hunt_scenario2_rights3_peek2_recv0.cfg) | `MC_hunt_scenario2.cfg` | `RightsCount = 3`<br>`RecvLimit = 0` | Permits up to 2 PEEK calls and 0 ordinary calls across two receiver threads. Captures A, B, A, preserving two objects and a duplicate reference. | Executions exceeding either operation budget are excluded. The fourth entry and second B reference are excluded. |
| [MC_hunt_scenario3_layout_full.cfg](../MC_timelimited_scenario3_layout_full.cfg) | `MC_hunt_scenario3.cfg` | `AllowedLayouts = {"Full"}` | Checks full ancillary publication. | Other layouts and their mixtures are excluded. |
| [MC_hunt_scenario3_layout_full_peek0_recv1.cfg](../MC_hunt_scenario3_layout_full_peek0_recv1.cfg) | `MC_hunt_scenario3.cfg` | `AllowedLayouts = {"Full"}`<br>`PeekLimit = 0` | Checks full ancillary publication. Permits up to 0 PEEK calls and 1 ordinary call across two receiver threads. | Other layouts and their mixtures are excluded. Executions exceeding either operation budget are excluded. Receiver calls cannot overlap in this companion. |
| [MC_hunt_scenario3_layout_full_peek1_recv0.cfg](../MC_hunt_scenario3_layout_full_peek1_recv0.cfg) | `MC_hunt_scenario3.cfg` | `AllowedLayouts = {"Full"}`<br>`RecvLimit = 0` | Checks full ancillary publication. Permits up to 1 PEEK call and 0 ordinary calls across two receiver threads. | Other layouts and their mixtures are excluded. Executions exceeding either operation budget are excluded. Receiver calls cannot overlap in this companion. |
| [MC_hunt_scenario3_layouts_capacity.cfg](../MC_hunt_scenario3_layouts_capacity.cfg) | `MC_hunt_scenario3.cfg` | `AllowedLayouts = {"Null", "Zero", "Short", "HeaderOnly", "NoInteger", "One", "OnePadded", "SpaceOne"}` | Checks NULL, short-capacity, one/two-entry prefix and padding cases. | Full output and output faults are excluded. |
| [MC_hunt_scenario3_layouts_fault.cfg](../MC_hunt_scenario3_layouts_fault.cfg) | `MC_hunt_scenario3.cfg` | `AllowedLayouts = {"FirstFault", "LaterFault", "PartialFault", "HeaderFault", "HeaderPartial"}` | Checks first/later integer faults, partial writes and header faults. | Only one receive attempt can start because every layout consumes the output-fault budget. Cross-layout publication races are excluded. |
| [MC_hunt_scenario4_peek0_recv2.cfg](../MC_hunt_scenario4_peek0_recv2.cfg) | `MC_hunt_scenario4.cfg` | `PeekLimit = 0` | Permits up to 0 PEEK calls and 2 ordinary calls across two receiver threads. | Executions exceeding either operation budget are excluded. |
| [MC_hunt_scenario4_peek1_recv1.cfg](../MC_timelimited_scenario4_peek1_recv1.cfg) | `MC_hunt_scenario4.cfg` | `RecvLimit = 1` | Permits up to 1 PEEK call and 1 ordinary call across two receiver threads. | Executions exceeding either operation budget are excluded. |
| [MC_hunt_scenario4_rights3.cfg](../MC_timelimited_scenario4_rights3.cfg) | `MC_hunt_scenario4.cfg` | `RightsCount = 3` | Captures A, B, A, preserving two objects and a duplicate reference. | The fourth entry and second B reference are excluded. |
| [MC_hunt_scenario4_rights3_peek1_recv1.cfg](../MC_hunt_scenario4_rights3_peek1_recv1.cfg) | `MC_hunt_scenario4.cfg` | `RightsCount = 3`<br>`RecvLimit = 1` | Permits up to 1 PEEK call and 1 ordinary call across two receiver threads. Captures A, B, A, preserving two objects and a duplicate reference. | Executions exceeding either operation budget are excluded. The fourth entry and second B reference are excluded. |
| [MC_layout_full.cfg](../MC_layout_full.cfg) | `MC.cfg` | `AllowedLayouts = {"Full"}` | Checks full ancillary publication. | Other layouts and their mixtures are excluded. |
| [MC_layout_full_peek0_recv2.cfg](../MC_layout_full_peek0_recv2.cfg) | `MC.cfg` | `AllowedLayouts = {"Full"}`<br>`PeekLimit = 0` | Checks full ancillary publication. Permits up to 0 PEEK calls and 2 ordinary calls across two receiver threads. | Other layouts and their mixtures are excluded. Executions exceeding either operation budget are excluded. |
| [MC_layout_full_peek1_recv2.cfg](../MC_layout_full_peek1_recv2.cfg) | `MC.cfg` | `AllowedLayouts = {"Full"}`<br>`PeekLimit = 1` | Checks full ancillary publication. Permits up to 1 PEEK call and 2 ordinary calls across two receiver threads. | Other layouts and their mixtures are excluded. Executions exceeding either operation budget are excluded. |
| [MC_layout_full_peek2_recv1.cfg](../MC_layout_full_peek2_recv1.cfg) | `MC.cfg` | `AllowedLayouts = {"Full"}`<br>`RecvLimit = 1` | Checks full ancillary publication. Permits up to 2 PEEK calls and 1 ordinary call across two receiver threads. | Other layouts and their mixtures are excluded. Executions exceeding either operation budget are excluded. |
| [MC_layout_full_rights3_peek1_recv1.cfg](../MC_layout_full_rights3_peek1_recv1.cfg) | `MC.cfg` | `RightsCount = 3`<br>`AllowedLayouts = {"Full"}`<br>`PeekLimit = 1`<br>`RecvLimit = 1` | Checks full ancillary publication. Permits up to 1 PEEK call and 1 ordinary call across two receiver threads. Captures A, B, A, preserving two objects and a duplicate reference. | Other layouts and their mixtures are excluded. Executions exceeding either operation budget are excluded. The fourth entry and second B reference are excluded. |
| [MC_layout_full_rights3_peek2_recv0.cfg](../MC_layout_full_rights3_peek2_recv0.cfg) | `MC.cfg` | `RightsCount = 3`<br>`AllowedLayouts = {"Full"}`<br>`RecvLimit = 0` | Checks full ancillary publication. Permits up to 2 PEEK calls and 0 ordinary calls across two receiver threads. Captures A, B, A, preserving two objects and a duplicate reference. | Other layouts and their mixtures are excluded. Executions exceeding either operation budget are excluded. The fourth entry and second B reference are excluded. |
| [MC_layout_space_one.cfg](../MC_layout_space_one.cfg) | `MC.cfg` | `AllowedLayouts = {"SpaceOne"}` | Checks a two-entry prefix. | Full output, one-entry and zero-entry layouts, and output faults are excluded. |
| [MC_layout_space_one_peek1_recv2.cfg](../MC_layout_space_one_peek1_recv2.cfg) | `MC.cfg` | `AllowedLayouts = {"SpaceOne"}`<br>`PeekLimit = 1` | Checks a two-entry prefix. Permits up to 1 PEEK call and 2 ordinary calls across two receiver threads. | Full output, one-entry and zero-entry layouts, and output faults are excluded. Executions exceeding either operation budget are excluded. |
| [MC_layout_space_one_peek2_recv1.cfg](../MC_layout_space_one_peek2_recv1.cfg) | `MC.cfg` | `AllowedLayouts = {"SpaceOne"}`<br>`RecvLimit = 1` | Checks a two-entry prefix. Permits up to 2 PEEK calls and 1 ordinary call across two receiver threads. | Full output, one-entry and zero-entry layouts, and output faults are excluded. Executions exceeding either operation budget are excluded. |
| [MC_layouts_empty.cfg](../MC_layouts_empty.cfg) | `MC.cfg` | `AllowedLayouts = {"Null", "Zero", "Short", "HeaderOnly", "NoInteger"}` | Checks layouts that install no receiver FD. | Ancillary FD publication is excluded. |
| [MC_layouts_fault.cfg](../MC_layouts_fault.cfg) | `MC.cfg` | `AllowedLayouts = {"FirstFault", "LaterFault", "PartialFault", "HeaderFault", "HeaderPartial"}` | Checks first/later integer faults, partial writes and header faults. | Only one receive attempt can start because every layout consumes the output-fault budget. Cross-layout publication races are excluded. |
| [MC_layouts_no_integer.cfg](../MC_layouts_no_integer.cfg) | `MC.cfg` | `AllowedLayouts = {"HeaderOnly", "NoInteger"}` | Checks layouts that install no receiver FD. | Ancillary FD publication is excluded. |
| [MC_layouts_null_zero_short.cfg](../MC_layouts_null_zero_short.cfg) | `MC.cfg` | `AllowedLayouts = {"Null", "Zero", "Short"}` | Checks layouts that install no receiver FD. | Ancillary FD publication is excluded. |
| [MC_layouts_one.cfg](../MC_layouts_one.cfg) | `MC.cfg` | `AllowedLayouts = {"One", "OnePadded"}` | Checks one-entry prefixes with capacities of 20 and 21 bytes. | Two-entry and full output, zero-entry layouts, and output faults are excluded. |
| [MC_layouts_prefix.cfg](../MC_layouts_prefix.cfg) | `MC.cfg` | `AllowedLayouts = {"One", "OnePadded", "SpaceOne"}` | Checks one- and two-entry prefixes and padding. | Full output, zero-entry layouts and output faults are excluded. |

### Reproduce a companion

Use the Java binary and both jars from revision 1 `run_checks.py`. Run one TLC process at a time from `spec/`. Each recorded command and working directory is in its log and in `revision2.runs` of `results.json`. The original runner uses a 5400-second timeout and must not be used for these 1800-second checks. For a replay, choose fresh metadata and log names so existing evidence is not overwritten.

```sh
cd spec
JAVA=/nix/store/vymiz4fvnc1s8k19kz2lqvkv3g2k0ys6-openjdk-headless-21.0.12.1+1/bin/java
CP=/home/chin39/Documents/play/Specula/lib/tla2tools.jar:/home/chin39/Documents/play/Specula/lib/CommunityModules-deps.jar
name=MC_hunt_scenario3_layouts_fault
set -C
timeout 1800 "$JAVA" -Xmx3g -XX:MaxDirectMemorySize=512m -XX:+UseParallelGC \
  -DTLA-Library=. -cp "$CP" tlc2.TLC -workers 2 -noGenerateSpecTE \
  -metadir "../states-r2/r2-${name}-replay" -config "$name.cfg" MC.tla \
  > "generation-checks/r2-${name}-replay.log" 2>&1
```

The executed revision used an exclusive lock and refused to start a run whose full timeout plus a five-second accounting margin exceeded the remaining budget. The metadata path for every run is recorded. Only metadata belonging to a completed, error-free run was removed. All incomplete metadata and revision 1 `states/` remain. `states-r2/` is Git-ignored.

### Execution results

Counts for incomplete runs are the last reported progress values. Depth means complete graph depth only when the run completed. A completed 300-second probe is a complete bounded result.

| Companion run | Outcome | Distinct states | Depth | Queue | Wall seconds | Log |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| `MC_hunt_scenario3_layouts_fault.cfg` | Complete with no violation | 28,908 | 52 | 0 | 4.724 | [r2-MC_hunt_scenario3_layouts_fault.log](r2-MC_hunt_scenario3_layouts_fault.log) |
| `MC_cleanup_layout_null.cfg` | Complete with no violation | 14,330 | 51 | 0 | 10.437 | [r2-MC_cleanup_layout_null.log](r2-MC_cleanup_layout_null.log) |
| `MC_hunt_scenario3_layouts_capacity.cfg` | Complete with no violation | 546,254 | 70 | 0 | 71.423 | [r2-MC_hunt_scenario3_layouts_capacity.log](r2-MC_hunt_scenario3_layouts_capacity.log) |
| `MC_cleanup_layout_later_fault.cfg` | Complete with no violation | 40,062 | 55 | 0 | 35.941 | [r2-MC_cleanup_layout_later_fault.log](r2-MC_cleanup_layout_later_fault.log) |
| `MC_hunt_scenario3_layout_full.cfg` (300 s probe) | Incomplete | 2,551,044 | 70 | 1,037,233 | 300.083 | [r2-MC_hunt_scenario3_layout_full-probe.log](r2-MC_hunt_scenario3_layout_full-probe.log) |
| `MC_hunt_scenario3_layout_full.cfg` | Incomplete | 16,296,831 | 73 | 7,003,470 | 1800.186 | [r2-MC_hunt_scenario3_layout_full.log](r2-MC_hunt_scenario3_layout_full.log) |
| `MC_layouts_fault.cfg` | Complete with no violation | 44,454 | 55 | 0 | 7.230 | [r2-MC_layouts_fault.log](r2-MC_layouts_fault.log) |
| `MC_hunt_scenario1_layout_null.cfg` | Complete with no violation | 3,630 | 51 | 0 | 1.116 | [r2-MC_hunt_scenario1_layout_null.log](r2-MC_hunt_scenario1_layout_null.log) |
| `MC_hunt_scenario4_peek0_recv2.cfg` | Complete with no violation | 125,158 | 59 | 0 | 13.994 | [r2-MC_hunt_scenario4_peek0_recv2.log](r2-MC_hunt_scenario4_peek0_recv2.log) |
| `MC_hunt_scenario2_peek1_recv2.cfg` (300 s probe) | Incomplete | 2,636,850 | 69 | 588,719 | 300.185 | [r2-MC_hunt_scenario2_peek1_recv2-probe.log](r2-MC_hunt_scenario2_peek1_recv2-probe.log) |
| `MC_hunt_scenario2_peek2_recv1.cfg` (300 s probe) | Incomplete | 2,508,522 | 66 | 188,314 | 300.184 | [r2-MC_hunt_scenario2_peek2_recv1-probe.log](r2-MC_hunt_scenario2_peek2_recv1-probe.log) |
| `MC_hunt_scenario4_peek1_recv1.cfg` (300 s probe) | Incomplete | 2,543,414 | 70 | 920,346 | 300.131 | [r2-MC_hunt_scenario4_peek1_recv1-probe.log](r2-MC_hunt_scenario4_peek1_recv1-probe.log) |
| `MC_hunt_scenario1_layout_full.cfg` (300 s probe) | Incomplete | 2,605,170 | 70 | 994,932 | 300.130 | [r2-MC_hunt_scenario1_layout_full-probe.log](r2-MC_hunt_scenario1_layout_full-probe.log) |
| `MC_cleanup_layout_full.cfg` (300 s probe) | Incomplete | 303,354 | 49 | 67,134 | 300.131 | [r2-MC_cleanup_layout_full-probe.log](r2-MC_cleanup_layout_full-probe.log) |
| `MC_layout_full.cfg` (300 s probe) | Incomplete | 2,478,326 | 57 | 459,788 | 300.235 | [r2-MC_layout_full-probe.log](r2-MC_layout_full-probe.log) |
| `MC_layouts_empty.cfg` (300 s probe) | Incomplete | 2,231,068 | 37 | 365,101 | 300.131 | [r2-MC_layouts_empty-probe.log](r2-MC_layouts_empty-probe.log) |
| `MC_layouts_prefix.cfg` (300 s probe) | Incomplete | 2,205,483 | 45 | 301,166 | 300.196 | [r2-MC_layouts_prefix-probe.log](r2-MC_layouts_prefix-probe.log) |
| `MC_hunt_scenario3_layout_full_peek1_recv0.cfg` | Complete with no violation | 36,723 | 56 | 0 | 5.176 | [r2-MC_hunt_scenario3_layout_full_peek1_recv0.log](r2-MC_hunt_scenario3_layout_full_peek1_recv0.log) |
| `MC_hunt_scenario3_layout_full_peek0_recv1.cfg` | Complete with no violation | 16,536 | 53 | 0 | 2.920 | [r2-MC_hunt_scenario3_layout_full_peek0_recv1.log](r2-MC_hunt_scenario3_layout_full_peek0_recv1.log) |
| `MC_hunt_scenario1_layout_full_peek1_recv0.cfg` | Complete with no violation | 51,208 | 59 | 0 | 6.379 | [r2-MC_hunt_scenario1_layout_full_peek1_recv0.log](r2-MC_hunt_scenario1_layout_full_peek1_recv0.log) |
| `MC_hunt_scenario1_layout_full_peek0_recv1.cfg` | Complete with no violation | 22,924 | 56 | 0 | 3.322 | [r2-MC_hunt_scenario1_layout_full_peek0_recv1.log](r2-MC_hunt_scenario1_layout_full_peek0_recv1.log) |
| `MC_cleanup_layout_full_peek1_recv0.cfg` | Complete with no violation | 102,686 | 59 | 0 | 129.876 | [r2-MC_cleanup_layout_full_peek1_recv0.log](r2-MC_cleanup_layout_full_peek1_recv0.log) |
| `MC_cleanup_layout_full_peek0_recv1.cfg` | Complete with no violation | 46,118 | 56 | 0 | 53.836 | [r2-MC_cleanup_layout_full_peek0_recv1.log](r2-MC_cleanup_layout_full_peek0_recv1.log) |
| `MC_hunt_scenario2_peek0_recv2.cfg` | Complete with no violation | 53,669 | 58 | 0 | 7.282 | [r2-MC_hunt_scenario2_peek0_recv2.log](r2-MC_hunt_scenario2_peek0_recv2.log) |
| `MC_hunt_scenario4_rights3.cfg` | Incomplete | 15,270,917 | 76 | 1,144,303 | 1800.236 | [r2-MC_hunt_scenario4_rights3.log](r2-MC_hunt_scenario4_rights3.log) |
| `MC_hunt_scenario4_rights3_peek1_recv1.cfg` | Complete with no violation | 2,503,446 | 75 | 0 | 298.780 | [r2-MC_hunt_scenario4_rights3_peek1_recv1.log](r2-MC_hunt_scenario4_rights3_peek1_recv1.log) |
| `MC_hunt_scenario2_peek2_recv0.cfg` (300 s probe) | Incomplete | 2,436,862 | 70 | 1,180,166 | 300.185 | [r2-MC_hunt_scenario2_peek2_recv0-probe.log](r2-MC_hunt_scenario2_peek2_recv0-probe.log) |
| `MC_layout_full_peek1_recv2.cfg` (300 s probe) | Incomplete | 2,322,385 | 60 | 309,752 | 300.236 | [r2-MC_layout_full_peek1_recv2-probe.log](r2-MC_layout_full_peek1_recv2-probe.log) |
| `MC_layout_full_peek2_recv1.cfg` (300 s probe) | Incomplete | 2,327,726 | 58 | 377,895 | 300.235 | [r2-MC_layout_full_peek2_recv1-probe.log](r2-MC_layout_full_peek2_recv1-probe.log) |
| `MC_layouts_null_zero_short.cfg` (300 s probe) | Incomplete | 2,249,680 | 51 | 124,497 | 300.190 | [r2-MC_layouts_null_zero_short-probe.log](r2-MC_layouts_null_zero_short-probe.log) |
| `MC_layouts_no_integer.cfg` (300 s probe) | Complete with no violation | 851,768 | 77 | 0 | 85.954 | [r2-MC_layouts_no_integer-probe.log](r2-MC_layouts_no_integer-probe.log) |
| `MC_layouts_one.cfg` (300 s probe) | Incomplete | 2,421,436 | 61 | 132,584 | 300.188 | [r2-MC_layouts_one-probe.log](r2-MC_layouts_one-probe.log) |
| `MC_layout_space_one.cfg` (300 s probe) | Incomplete | 2,238,658 | 72 | 263,859 | 300.185 | [r2-MC_layout_space_one-probe.log](r2-MC_layout_space_one-probe.log) |
| `MC_layout_full_peek0_recv2.cfg` | Complete with no violation | 170,529 | 62 | 0 | 18.956 | [r2-MC_layout_full_peek0_recv2.log](r2-MC_layout_full_peek0_recv2.log) |
| `MC_hunt_scenario2_rights3_peek2_recv0.cfg` | Complete with no violation | 2,613,962 | 77 | 0 | 325.140 | [r2-MC_hunt_scenario2_rights3_peek2_recv0.log](r2-MC_hunt_scenario2_rights3_peek2_recv0.log) |
| `MC_layout_full_rights3_peek2_recv0.cfg` | Complete with no violation | 3,728,008 | 80 | 0 | 486.902 | [r2-MC_layout_full_rights3_peek2_recv0.log](r2-MC_layout_full_rights3_peek2_recv0.log) |
| `MC_layout_full_rights3_peek1_recv1.cfg` | Complete with no violation | 3,540,671 | 78 | 0 | 437.938 | [r2-MC_layout_full_rights3_peek1_recv1.log](r2-MC_layout_full_rights3_peek1_recv1.log) |
| `MC_layouts_null_zero_short.cfg` | Complete with no violation | 3,348,370 | 77 | 0 | 359.472 | [r2-MC_layouts_null_zero_short.log](r2-MC_layouts_null_zero_short.log) |
| `MC_layouts_one.cfg` | Complete with no violation | 5,598,310 | 92 | 0 | 597.400 | [r2-MC_layouts_one.log](r2-MC_layouts_one.log) |
| `MC_hunt_scenario2_rights3_peek1_recv2.cfg` | Complete with no violation | 6,987,879 | 80 | 0 | 808.166 | [r2-MC_hunt_scenario2_rights3_peek1_recv2.log](r2-MC_hunt_scenario2_rights3_peek1_recv2.log) |
| `MC_layout_space_one.cfg` | Incomplete | 15,276,518 | 94 | 1,706,685 | 1800.135 | [r2-MC_layout_space_one.log](r2-MC_layout_space_one.log) |
| `MC_layout_space_one_peek2_recv1.cfg` | Complete with no violation | 5,374,349 | 98 | 0 | 641.395 | [r2-MC_layout_space_one_peek2_recv1.log](r2-MC_layout_space_one_peek2_recv1.log) |
| `MC_layout_space_one_peek1_recv2.cfg` | Complete with no violation | 912,541 | 79 | 0 | 94.725 | [r2-MC_layout_space_one_peek1_recv2.log](r2-MC_layout_space_one_peek1_recv2.log) |

### Layout and property witnesses

Scenario 3 layouts still lacking completion with all other constants unchanged: `Full`. The run table records their incomplete attempts. A result with reduced operation budgets or rights does not close this gap.

| Original | Layouts complete with every other constant unchanged | Layouts still missing that result |
| --- | --- | --- |
| `MC_hunt_scenario3.cfg` | 13/14 | `Full` |
| `MC.cfg` | 12/14 | `Full`, `SpaceOne` |
| `MC_cleanup.cfg` | 2/3 | `Full` |
| `MC_hunt_scenario1.cfg` | 1/2 | `Full` |

The following table selects representative completing witnesses. The common constants and original/difference tables above list their complete bounds. All qualifying witnesses are indexed in the JSON. The JSON additionally records each companion's full constant map. A zero-PEEK companion is not counted as a witness for `PeekPreservesQueueRights`. Ordinary-consumption witnesses allow two ordinary attempts.

| Property | Completing companion witnesses |
| --- | --- |
| `OwnershipConserved` | `MC_layouts_fault.cfg`<br>`MC_layout_full_rights3_peek1_recv1.cfg` |
| `CapturedObjectIdentity` | `MC_hunt_scenario1_layout_full_peek1_recv0.cfg`<br>`MC_hunt_scenario3_layouts_fault.cfg` |
| `OrdinaryConsumeAtMostOnce` | `MC_hunt_scenario4_peek0_recv2.cfg`<br>`MC_hunt_scenario2_rights3_peek1_recv2.cfg` |
| `PeekPreservesQueueRights` | `MC_hunt_scenario2_rights3_peek2_recv0.cfg`<br>`MC_hunt_scenario2_rights3_peek1_recv2.cfg` |
| `DeliveredPrefixSurvives` | `MC_hunt_scenario3_layouts_fault.cfg` |
| `OperationOwnersDrained` | `MC_hunt_scenario1_layout_full_peek0_recv1.cfg`<br>`MC_hunt_scenario3_layouts_fault.cfg` |
| `BoundedCleanupProgress` | `MC_cleanup_layout_null.cfg`<br>`MC_cleanup_layout_later_fault.cfg`<br>`MC_cleanup_layout_full_peek1_recv0.cfg`<br>`MC_cleanup_layout_full_peek0_recv1.cfg` |

The cleanup witnesses completed the final temporal check over the complete state space. Their success is stronger than a periodic temporal check during an incomplete run. Protocol safety checks retain `TypeOK` (or `MCTypeOK`). The three expected compatibility counterexamples and all original incomplete results remain exactly as recorded in revision 1.

### Criteria

| Criterion | Status | Command and evidence |
| --- | --- | --- |
| `R2-1-unchanged` | PASS | The three model files, every existing configuration, revision 1 logs and read-only inputs match 9573ffb byte for byte. Run `git diff 9573ffb -- spec/base.tla spec/MC.tla spec/Trace.tla` and the self-contained preservation command in [r2-audit.log](r2-audit.log). |
| `R2-2-layouts` | PASS | The requested documented-gap alternative is satisfied. Thirteen of fourteen Scenario 3 layouts complete with every other constant unchanged. Full remains time-limited at those constants, and its exact counts and the reason further layout splitting cannot help are recorded. Exact TLC commands are in the linked execution logs and `revision2.criteria[].commands` in [results.json](results.json). |
| `R2-3-properties` | PASS | Every required protocol property and BoundedCleanupProgress has a completing witness. Constants are listed in the companion tables and JSON. PEEK witnesses enable PEEK, and ordinary-consumption witnesses permit two ordinary attempts. Exact TLC commands are in the linked execution logs and `revision2.criteria[].commands` in [results.json](results.json). |
| `R2-4-results` | PASS | Every executed attempt has an exact command, separate log, outcome, distinct-state count, depth, queue size and wall time. No unexpected violation occurred. Exact TLC commands are in the linked execution logs and `revision2.criteria[].commands` in [results.json](results.json). |
| `R2-5-records` | PASS | README, results JSON, brief coverage and the appended Revision 2 section agree. The file inventory and budget are audited. git diff --check is clean. Run `git diff --check` and `python3 -m json.tool spec/generation-checks/results.json >/dev/null`. See [r2-audit.log](r2-audit.log). |

The audit log includes its self-contained command, preservation checks, input hashes, resource and budget checks, and record consistency checks. `git diff --check` is clean. Kernel execution, production trace validation, Linux runtime controls, confirmation and classification remain NOT RUN. No commit was made.

## Revision 3: review findings 5 and 6

The two P2 findings in [the second review](../review-specgen.md) were the only
input to revision 3, based on `d0f61706adb18e168f4af622770dc4adfc52fcc2`.
The pinned source and requested check fixtures supplied references and
validation evidence. Earlier results above remain historical records. The
current commands, input hashes, acceptance decisions and state comparisons
are under `revision3` in [results.json](results.json).

### Repairs and preservation

Finding 5 changes only PEEK's observer snapshots and their evaluation order.
`AuxiliaryDataGenerateControlPeek` first binds its unchanged post-transition
queue, then saves `queue'.rights` and `queue'.msg` in the after-snapshots.
The source-faithful clone and reference increments remain unchanged.
Per-operation history survives a later ordinary dequeue. The definition and
configuration wiring of `PeekPreservesQueueRights` are unchanged.

[generation-checks/PeekProbe.tla](PeekProbe.tla) adapts the reviewer's probe to
these snapshots. Its mutant still moves references, empties the queue and
increments consumption without cloning. It assigns the mutated queue before
reading the post-state snapshots. All original reviewer probes and
configurations remain unchanged. The runner uses their configurations with
the adapted module, which imports the revised top-level `base.tla`.

Finding 6 adds `TraceNoCompleteMatch` and [TraceSearch.cfg](../TraceSearch.cfg).
A violation of this inverse invariant supplies a path that consumes all
events and satisfies terminal cleanup. The search retains all safety and
terminal invariants, full base transitions and mandatory post-state checks.
[The instrumentation guide](../instrumentation-spec.md#3-special-considerations)
defines acceptance: an error-free, nonzero-state `Trace.cfg` run passes. When
only `TraceMatched` fails, a complete witness with nonzero initial states also
accepts the input. Any other failure rejects it. A completed search without
an inverse-invariant violation means no witness and rejects the input.

`Trace.cfg`, `TraceMatched`, `MC.tla`, every existing configuration and all
bounds remain unchanged. No implementation guard, outcome, invariant or state
filter changed. Revision 1 and 2 logs and result entries, both reviews and all
reviewer fixtures remain unchanged. The pinned source was never modified.

### Reproduce revision 3

Run from the workspace root:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 spec/generation-checks/run_r3_checks.py parse peek trace compat regression
python3 spec/generation-checks/run_r3_checks.py audit
```

The runner uses the Java binary and both jars from `run_checks.py`, at most
two TLC workers, `-Xmx3g -XX:MaxDirectMemorySize=512m`, `-XX:+UseParallelGC`
and `timeout 1800` per run. It shares the original runner's exclusive lock
and starts one TLC process at a time. Each log records its working directory,
exact command, available memory, exit code and wall time. Metadata is under
`states-r3/<name>`, which is Git-ignored. Only a completed run's own metadata
was removed. New logs use `r3-` names. Replays select fresh numbered names.
The audit refuses to replace its existing log.

For an individual trace, run the logged `r3-trace-<input>` command from
`spec/`, then the logged `r3-search-<input>` command if required. Both select
the same reviewer NDJSON through `JSON`. Choose fresh log and metadata names.
The search's specific inverse-invariant violation is the witness. Its nonzero
exit code must not be confused with a safety failure or with acceptance of an
arbitrary TLC error. A check row marked PASS below means the expected outcome
occurred, including expected rejection of negative fixtures.

### PEEK oracle and ordinary-consumption regressions

The unmutated control completes with 37 distinct states and no violation.
Both `peek-mutant.cfg` and `peek-mutant-oracle.cfg` now fail
`PeekPreservesQueueRights` at state 17. That state records a nonempty
`peekBefore`, an empty `peekAfter`, `peekMessageBefore = "message1"` and
`peekMessageAfter = "NoMessage"`. The mutant still conserves ownership by
moving the references. The failure comes from the repaired PEEK oracle.

The regression selection strips configuration comments and selects every
revision-2 companion that completed and enables `PeekPreservesQueueRights`.
There are five, including both explicitly requested zero-PEEK ordinary
controls. Each completes without a violation and with the same distinct-state
count as revision 2. No reduced bounds were introduced.

| Configuration | Revision 2 distinct states | Revision 3 distinct states | Difference | Wall seconds | Log |
| --- | ---: | ---: | ---: | ---: | --- |
| `MC_hunt_scenario4_peek0_recv2.cfg` | 125,158 | 125,158 | 0 | 13.875 | [r3-MC_hunt_scenario4_peek0_recv2.log](r3-MC_hunt_scenario4_peek0_recv2.log) |
| `MC_hunt_scenario2_peek0_recv2.cfg` | 53,669 | 53,669 | 0 | 6.286 | [r3-MC_hunt_scenario2_peek0_recv2.log](r3-MC_hunt_scenario2_peek0_recv2.log) |
| `MC_hunt_scenario4_rights3_peek1_recv1.cfg` | 2,503,446 | 2,503,446 | 0 | 295.833 | [r3-MC_hunt_scenario4_rights3_peek1_recv1.log](r3-MC_hunt_scenario4_rights3_peek1_recv1.log) |
| `MC_hunt_scenario2_rights3_peek2_recv0.cfg` | 2,613,962 | 2,613,962 | 0 | 302.147 | [r3-MC_hunt_scenario2_rights3_peek2_recv0.log](r3-MC_hunt_scenario2_rights3_peek2_recv0.log) |
| `MC_hunt_scenario2_rights3_peek1_recv2.cfg` | 6,987,879 | 6,987,879 | 0 | 804.395 | [r3-MC_hunt_scenario2_rights3_peek1_recv2.log](r3-MC_hunt_scenario2_rights3_peek1_recv2.log) |

### Trace acceptance and rejection

Every trace below is the unchanged reviewer input under
`spec/review-checks-20261005/`. Both modes were executed on every input.

| Input | Trace.cfg result | TraceSearch.cfg result | Decision | Logs |
| --- | --- | --- | --- | --- |
| `valid.ndjson` | Complete, 56 states | Witness at state 56 | ACCEPT | [r3-trace-valid.log](r3-trace-valid.log)<br>[r3-search-valid.log](r3-search-valid.log) |
| `overlap.ndjson` | Only TraceMatched fails, 57 states | Witness at state 56 | ACCEPT | [r3-trace-overlap.log](r3-trace-overlap.log)<br>[r3-search-overlap.log](r3-search-overlap.log) |
| `bad-source.ndjson` | Source assertion fails | Source assertion fails | REJECT | [r3-trace-bad-source.log](r3-trace-bad-source.log)<br>[r3-search-bad-source.log](r3-search-bad-source.log) |
| `unknown-event.ndjson` | Event assertion fails | Event assertion fails | REJECT | [r3-trace-unknown-event.log](r3-trace-unknown-event.log)<br>[r3-search-unknown-event.log](r3-search-unknown-event.log) |
| `truncated.ndjson` | TraceEndComplete fails at state 2 | TraceEndComplete fails at state 2 | REJECT | [r3-trace-truncated.log](r3-trace-truncated.log)<br>[r3-search-truncated.log](r3-search-truncated.log) |
| `corrupted-post.ndjson` | Only TraceMatched fails, 1 state | Complete search, 1 state, no witness | REJECT | [r3-trace-corrupted-post.log](r3-trace-corrupted-post.log)<br>[r3-search-corrupted-post.log](r3-search-corrupted-post.log) |

The valid and overlap witnesses each start from one initial state and contain
56 states. The overlap witness ends with cursors
`[s |-> 15, r1 |-> 27, r2 |-> 1, c |-> 16]`, matching each thread's exhausted
log, cleanup requested, a closed queue and both reference balances zero.
The normal overlap run explores 57 distinct states and fails only
`TraceMatched`. The corrupted-post search completes with one initial state,
one distinct state and no witness. Wrong-source and unknown-event assertions
reject before initialization completes. The truncated trace fails the
terminal invariant in both modes, so it cannot be rescued by the search.

### Compatibility and parsing

| Configuration | Expected violated property | Counterexample states | Distinct states explored | Log |
| --- | --- | ---: | ---: | --- |
| `MC_hunt_AST32_install.cfg` | `NoFailedNumberInstalled` | 31 | 12,344 | [r3-MC_hunt_AST32_install.log](r3-MC_hunt_AST32_install.log) |
| `MC_hunt_AST32_report.cfg` | `ReportedPrefixMatchesLinux` | 36 | 1,345 | [r3-MC_hunt_AST32_report.log](r3-MC_hunt_AST32_report.log) |
| `MC_hunt_AST36.cfg` | `PayloadFaultConsumptionMatchesLinux` | 18 | 346 | [r3-MC_hunt_AST36.log](r3-MC_hunt_AST36.log) |

The compatibility properties remain in their three separate configurations.
Counterexample lengths include the initial state. Explored counts before a
counterexample can vary with two workers. SANY parses `base.tla`, `MC.tla`,
`Trace.tla` and the adapted `PeekProbe.tla` without errors.

### Criteria and evidence limits

| Criterion | Status | Command from the workspace root | Logs |
| --- | --- | --- | --- |
| `R3-1-peek-oracle` | PASS | `python3 spec/generation-checks/run_r3_checks.py peek` | [r3-peek-control.log](r3-peek-control.log)<br>[r3-peek-mutant.log](r3-peek-mutant.log)<br>[r3-peek-mutant-oracle.log](r3-peek-mutant-oracle.log) |
| `R3-2-peek-regression` | PASS | `python3 spec/generation-checks/run_r3_checks.py regression` | [r3-MC_hunt_scenario4_peek0_recv2.log](r3-MC_hunt_scenario4_peek0_recv2.log)<br>[r3-MC_hunt_scenario2_peek0_recv2.log](r3-MC_hunt_scenario2_peek0_recv2.log)<br>[r3-MC_hunt_scenario4_rights3_peek1_recv1.log](r3-MC_hunt_scenario4_rights3_peek1_recv1.log)<br>[r3-MC_hunt_scenario2_rights3_peek2_recv0.log](r3-MC_hunt_scenario2_rights3_peek2_recv0.log)<br>[r3-MC_hunt_scenario2_rights3_peek1_recv2.log](r3-MC_hunt_scenario2_rights3_peek1_recv2.log) |
| `R3-3-witness` | PASS | `python3 spec/generation-checks/run_r3_checks.py trace` | [r3-trace-overlap.log](r3-trace-overlap.log)<br>[r3-search-overlap.log](r3-search-overlap.log)<br>[r3-search-corrupted-post.log](r3-search-corrupted-post.log) |
| `R3-4-compat` | PASS | `python3 spec/generation-checks/run_r3_checks.py compat` | [r3-MC_hunt_AST32_install.log](r3-MC_hunt_AST32_install.log)<br>[r3-MC_hunt_AST32_report.log](r3-MC_hunt_AST32_report.log)<br>[r3-MC_hunt_AST36.log](r3-MC_hunt_AST36.log) |
| `R3-5-parse` | PASS | `python3 spec/generation-checks/run_r3_checks.py parse` | [r3-parse-base.log](r3-parse-base.log)<br>[r3-parse-MC.log](r3-parse-MC.log)<br>[r3-parse-Trace.log](r3-parse-Trace.log)<br>[r3-parse-PeekProbe.log](r3-parse-PeekProbe.log) |
| `R3-6-records` | PASS | `python3 spec/generation-checks/run_r3_checks.py audit`<br>`git diff --check` | [r3-audit.log](r3-audit.log) |

The 23 TLC runs used 1435.061 seconds in total. Every
individual run finished within 1800 seconds. No run remains active.
The audit verifies unchanged configuration and historical evidence bytes,
current input hashes, the source pin and clean working tree, the file
inventory, result consistency and `git diff --check`.

These are bounded specification checks and synthetic trace diagnostics.
Original searches that timed out remain incomplete. Kernel execution,
production trace validation, Linux runtime controls, bug confirmation and
classification remain NOT RUN. No commit was made.

## Revision 4

This is the historical attempt-2 record at `ced2584`. Its PEEK exclusion and
window metadata were rejected by the controller. The correction below
supersedes its configuration and format conclusions. The historical commands
refer to the runner at that commit. The current runner writes `r4c-` logs and
does not stop at 900 seconds.

The inputs are the validation report's two blockers and the user's decision
to revise. The unchanged brief-bound `MC.cfg` stopped Phase 2 twice, and the
old competition inventories could not reach 20% overlap. This revision is
relative to `593a85cfa112f43df96ad6ffa3944178af60a06e`. The modeling brief,
accepted production traces and pinned instrumented source remain unchanged.

### Reproduce

Run from the workspace root:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 spec/generation-checks/run_r4_checks.py traces compat mc
PYTHONDONTWRITEBYTECODE=1 python3 spec/generation-checks/audit_r4.py coverage preservation fixtures evidence
git diff --check
```

The runner uses `timeout 1800`, two workers, `-Xmx3g`,
`-XX:MaxDirectMemorySize=512m` and `-XX:+UseParallelGC`. It holds the earlier
runners' local exclusive lock and starts one TLC process at a time. Every log
records the exact Java command, working directory, available memory, exit
code and wall time. Each completed run removes only its own
`states-r4/<name>` directory. The existing Git ignore rule covers this tree.
Existing logs are retained, and reruns choose unused names.

The `mc` selection stops its own process group after 900 seconds if exhaustive
completion is still pending. The outer timeout remains 1800 seconds. `traces` first
uses `Trace.cfg` and permits `TraceSearch.cfg` only after an isolated temporal
matching failure. `compat` requires each named expected counterexample.
`windows` checks the two saved metadata serialization fixtures. They contain
the original four-right production events and are not new guest runs.

### Selected constants and coverage limits

The final `MC.cfg` completed without a violation in **635.468
seconds**, exploring **3,596,537 distinct states** to **depth 62**
with an empty queue. See [r4-MC-rerun6.log](r4-MC-rerun6.log).
This completes the ordinary-receive scope. Trace-class coverage remains FAIL
and the redesigned competition bounds still cannot reach 20%.

The selected configuration changes only `PeekLimit` from 2 to 0 relative to
the brief bounds. It preserves four rights, two attempt slots, two ordinary
receives and sender reuse. The earlier mixed candidates below failed the
15-minute target even after reducing rights and operation budgets.

| Constant | Current `MC.cfg` |
| --- | --- |
| `Threads` | `{r1, r2}` |
| `AttemptSlots`, `RightsCount` | `2`, `4` |
| `ObjectA`, `ObjectB`, `SharedTable` | `fileA`, `fileB`, `TRUE` |
| `SetupFDCount`, `MaxFD`, `PayloadSize` | `5`, `22`, `1` |
| `AllowedLayouts` | `Full`, `Null`, `Zero`, `Short`, `HeaderOnly`, `NoInteger`, `One`, `OnePadded`, `SpaceOne`, `FirstFault`, `LaterFault`, `PartialFault`, `HeaderFault`, `HeaderPartial` |
| `SendFaultLimit`, `PayloadFaultLimit`, `OutputFaultLimit` | `1`, `1`, `1` |
| `PeekLimit`, `RecvLimit`, `ReuseLimit` | `0`, `2`, `1` |

The specification is `MCSpec`, with `Symmetry`, `MCView`,
`MessageBufferConstraint` and `CHECK_DEADLOCK FALSE` unchanged. The exact
invariants remain `MCTypeOK`, `OwnershipConserved`, `QueueStructure` and
`PublicationStructure`. There are still 16 initially free FD slots. No base
transition, invariant, guard or state filter changed.

Every candidate kept all 14 layouts and all three fault limits at 1. P/R/U
below means PeekLimit/RecvLimit/ReuseLimit. Counts for incomplete runs are
last reported progress counters, not exhaustive totals.

| Candidate | Slots / rights | P/R/U | Outcome | Distinct states | Depth | Queue | Wall seconds | Log |
| --- | --- | --- | --- | ---: | ---: | ---: | ---: | --- |
| `r4-MC` | 2 / 3 | 1/1/1 | Incomplete | 4,691,067 | 50 | 439,274 | 900.162 | [r4-MC.log](r4-MC.log) |
| `r4-MC-rerun3` | 1 / 3 | 1/2/1 | Incomplete | 7,669,287 | 62 | 646,260 | 938.140 | [r4-MC-rerun3.log](r4-MC-rerun3.log) |
| `r4-MC-rerun4` | 1 / 3 | 1/2/0 | Incomplete | 8,491,973 | 64 | 1,304,179 | 982.691 | [r4-MC-rerun4.log](r4-MC-rerun4.log) |
| `r4-MC-rerun5` | 1 / 3 | 1/1/0 | Incomplete | 7,639,980 | 64 | 1,301,409 | 900.141 | [r4-MC-rerun5.log](r4-MC-rerun5.log) |

The first three recorded candidates were stopped after missing the target.
Their stop records are [r4-MC-stop.log](r4-MC-stop.log),
[r4-MC-rerun3-stop.log](r4-MC-rerun3-stop.log) and
[r4-MC-rerun4-stop.log](r4-MC-rerun4-stop.log). The runner stopped the last
candidate at its 900-second acceptance deadline. Its one PEEK, one ordinary
call, one slot per thread, three rights and no reuse are the smallest tested
bounds retaining both call kinds and their publication competition.
Its queue still held 1,301,409 states. Thus the selected configuration gives
up PEEK and restores the other original operation/right bounds. These are
measurements on this host, not a proof about all future JVM or host timings.

The inherited [r4-MC-rerun2.log](r4-MC-rerun2.log) stops at 6,228,754 distinct
states, depth 58 and 123,807 queued states. It has neither a termination
record nor a saved configuration snapshot. It is excluded from acceptance.

The [23-row coverage table](../brief-coverage.md#revision-4-trace-coverage)
and [machine-readable mapping](r4-trace-coverage.json) identify the remaining
gap. Cases 15, 16, 18 and 21 require PEEK, so `R4-3-trace-coverage` is FAIL.
Case 15 also requires three same-thread attempts, already beyond the brief's
two-slot bound. The other 19 traces retain their exact right multiplicity,
layouts, fault kinds, ordinary competition, sender close/reuse, ordinary
fault/retry and cleanup classes. Passing Trace.cfg does not establish that a
trace fits MC.cfg. Existing PEEK hunt configurations and completing companions
retain their own scopes and are not substituted for the single-config criterion.

### Brief bounds and companion names

[MC_brief_bounds.cfg](../MC_brief_bounds.cfg) contains the old `MC.cfg`
byte for byte after an added comment header. It retains all constants,
properties and settings. It was not run in revision 4. The header cites
[MC.log](MC.log), which stopped after 5,400 seconds at 25,166,056 distinct
states, and the two validation attempts, which reported 12,442,357 and
12,670,700 distinct states at their 30-minute limits. The validation evidence
is retained in [the report](../../context/validation-report.md) and
[the controller record](../../context/CONTROLLER-DECISION-2026-10-06-phase2.md).

Only these seven revision-2 companions changed names. Every recorded attempt
for each was incomplete. The configuration bytes and original log names are
unchanged. The recorded outcomes and log paths are also under
`revision4.renames` in [results.json](results.json).

| Old name | New name |
| --- | --- |
| `MC_hunt_scenario1_layout_full.cfg` | [MC_timelimited_scenario1_layout_full.cfg](../MC_timelimited_scenario1_layout_full.cfg) |
| `MC_hunt_scenario2_peek1_recv2.cfg` | [MC_timelimited_scenario2_peek1_recv2.cfg](../MC_timelimited_scenario2_peek1_recv2.cfg) |
| `MC_hunt_scenario2_peek2_recv0.cfg` | [MC_timelimited_scenario2_peek2_recv0.cfg](../MC_timelimited_scenario2_peek2_recv0.cfg) |
| `MC_hunt_scenario2_peek2_recv1.cfg` | [MC_timelimited_scenario2_peek2_recv1.cfg](../MC_timelimited_scenario2_peek2_recv1.cfg) |
| `MC_hunt_scenario3_layout_full.cfg` | [MC_timelimited_scenario3_layout_full.cfg](../MC_timelimited_scenario3_layout_full.cfg) |
| `MC_hunt_scenario4_peek1_recv1.cfg` | [MC_timelimited_scenario4_peek1_recv1.cfg](../MC_timelimited_scenario4_peek1_recv1.cfg) |
| `MC_hunt_scenario4_rights3.cfg` | [MC_timelimited_scenario4_rights3.cfg](../MC_timelimited_scenario4_rights3.cfg) |

No completing configuration, original hunt or compatibility configuration
was renamed. The hunting glob now selects 20 configurations instead of 27.
No general hunting or cleanup-liveness run was performed in this revision.

### Trace and fixture evidence

All 23 accepted traces complete with `Trace.cfg`, without a witness fallback.
Their final replays use `r4-trace-case-00-rerun3.log` and
`r4-trace-case-01-rerun2.log` through `r4-trace-case-22-rerun2.log`. These
completed logs were already present when work resumed. The
[evidence audit](r4-evidence-resume.log) checks their commands, exits,
nonzero initial states and every recorded input hash against the current
suite and trace bytes. The three compatibility runs likewise match the
current inputs and expose exactly their expected properties:

| Configuration | Expected property | Counterexample states | Log |
| --- | --- | ---: | --- |
| `MC_hunt_AST32_install.cfg` | `NoFailedNumberInstalled` | 31 | [r4-MC_hunt_AST32_install.log](r4-MC_hunt_AST32_install.log) |
| `MC_hunt_AST32_report.cfg` | `ReportedPrefixMatchesLinux` | 36 | [r4-MC_hunt_AST32_report.log](r4-MC_hunt_AST32_report.log) |
| `MC_hunt_AST36.cfg` | `PayloadFaultConsumptionMatchesLinux` | 18 | [r4-MC_hunt_AST36.log](r4-MC_hunt_AST36.log) |

Competition case 17 keeps four rights and case 18 sends one right. Both use
Full output. Their real
receive window excludes setup/send/cleanup. Every outside event remains in
fixture metadata and executes during replay. `Trace.tla` changes only to
read these optional arrays. The decoder reads actual rights counts and
retains every event and timestamp endpoint. The other 21 fixtures preserve
all 34 event types, independently of cases 17 and 18.

| Case | Receiver events | Cross-thread pairs | Audit-style bound | Bound with point markers accounted for |
| --- | --- | ---: | --- | --- |
| 17, ordinary/ordinary | 26 successful, 5 empty | 130 | 30/130 = 23.077% | 23/130 = 17.692% |
| 18, successful PEEK/ordinary | 16 PEEK, 17 ordinary | 272 | 32/272 = 11.765% | 24/272 = 8.824% |

The original `n + m - 1` argument bounds intersections of internally disjoint
streams. Begin, queue-lock, control-report and completion markers have equal
endpoints and cannot overlap strictly. They remain in the denominator.
The tighter bounds fall below 20% by 2.308 and 11.176 percentage points.
Both inventories and source boundaries are in the
[harness guide](../../harness/INSTRUMENTATION.md#revision-4-fixture-redesign)
and [inventory JSON](r4-fixture-inventory.json). No kernel hook changed.
These are upper bounds, not measured overlap or proof of an attainable
schedule. Redesigned guest execution and the 20% qualification are NOT RUN.

The final host build used the pinned regression headers with
`-O2 -g -pthread -Wall -Werror`, as recorded in
[r4-fixture-build-final.log](r4-fixture-build-final.log). The host lacks
static libc/libpthread, so the Linux executable used dynamic linkage. The
`SCM_ASTERINAS` branch also compiled to an object. All 23 unprivileged Linux
controls completed in both [the first final-source run](r4-linux-control-final.log)
and [the second run](r4-linux-control-final-rerun2.log). Case 18's PEEK lost
selection in the first run and succeeded alongside ordinary receive in the
second. Both outcomes remain recorded. A guest trace with the losing outcome
would still fail the unchanged same-message requirement.
The two competition receivers used distinct CPUs. The
[normalizer endpoint audit](r4-normalizer-resume2.log) preserves all original
event identities and endpoints in per-thread order, including the window
metadata. Its four-right inputs do not establish new one-right guest behavior.

### Revision 4 criteria

Commands below run from the workspace root. The exact Java and compiler
commands, source/configuration snapshots, input hashes and every attempt are
indexed under `revision4` in [results.json](results.json). Earlier logs are
unchanged. The final audit checks the completed evidence against current
inputs and verifies the complete file inventory.

| Criterion | Status | Command | Evidence |
| --- | --- | --- | --- |
| `R4-1-mc-complete` | PASS | `python3 spec/generation-checks/run_r4_checks.py mc` | [r4-MC-rerun6.log](r4-MC-rerun6.log) |
| `R4-2-brief-bounds-kept` | PASS | `python3 spec/generation-checks/audit_r4.py preservation` | [r4-final-audit.log](r4-final-audit.log)<br>[r4-brief-bounds.log](r4-brief-bounds.log) |
| `R4-3-trace-coverage` | FAIL | `python3 spec/generation-checks/audit_r4.py coverage` | [r4-trace-coverage-mc6.log](r4-trace-coverage-mc6.log)<br>[brief-coverage.md](../brief-coverage.md) |
| `R4-4-traces` | PASS | `python3 spec/generation-checks/run_r4_checks.py traces` | [r4-final-audit.log](r4-final-audit.log)<br>[r4-trace-case-00-rerun3.log](r4-trace-case-00-rerun3.log)<br>[r4-trace-case-22-rerun2.log](r4-trace-case-22-rerun2.log) |
| `R4-5-compat` | PASS | `python3 spec/generation-checks/run_r4_checks.py compat` | [r4-MC_hunt_AST32_install.log](r4-MC_hunt_AST32_install.log)<br>[r4-MC_hunt_AST32_report.log](r4-MC_hunt_AST32_report.log)<br>[r4-MC_hunt_AST36.log](r4-MC_hunt_AST36.log) |
| `R4-6-renames` | PASS | `python3 spec/generation-checks/audit_r4.py preservation` | [r4-final-audit.log](r4-final-audit.log) |
| `R4-7-fixtures` | PASS | `python3 spec/generation-checks/audit_r4.py fixtures` | [r4-fixture-build-final.log](r4-fixture-build-final.log)<br>[r4-fixture-audit-final.log](r4-fixture-audit-final.log) |
| `R4-8-unchanged` | PASS | `python3 spec/generation-checks/audit_r4.py preservation` | [r4-final-audit.log](r4-final-audit.log) |
| `R4-9-records` | PASS | `git diff --check` | [r4-final-audit.log](r4-final-audit.log) |

R4-7 records compilation, inventories and both competition kinds. It does
not claim the 20% target was met. The two strict upper bounds are 17.692% and
8.824%, and guest execution is NOT RUN. R4-3 remains FAIL because PEEK is
absent from the completing default. No complete brief-bound convergence,
general hunting or cleanup-liveness result is claimed.

The completing MC run removed its own metadata directory. The three stopped
runs launched while resuming this work also had their own directories removed
after exit, as recorded in [r4-metadata-cleanup.log](r4-metadata-cleanup.log).
The inherited incomplete metadata directories remain untouched. No owned TLC
job remains active. The pinned source was not modified, and no commit was made.

### Revision 4 file inventory

The seven renames are listed above. The following files were modified or
added relative to 593a85c. Build outputs and temporary TLC metadata are ignored.

Modified files:

```text
harness/INSTRUMENTATION.md
harness/RESULTS.md
harness/src/normalize.py
harness/src/scm_rights_trace.c
spec/MC.cfg
spec/REVISION-2026-10-04.md
spec/Trace.tla
spec/brief-coverage.md
spec/generation-checks/README.md
spec/generation-checks/results.json
spec/instrumentation-spec.md
```

Added files:

```text
spec/MC_brief_bounds.cfg
spec/generation-checks/audit_r4.py
spec/generation-checks/r4-MC-rerun2.log
spec/generation-checks/r4-MC-rerun3-stop.log
spec/generation-checks/r4-MC-rerun3.log
spec/generation-checks/r4-MC-rerun4-stop.log
spec/generation-checks/r4-MC-rerun4.log
spec/generation-checks/r4-MC-rerun5.log
spec/generation-checks/r4-MC-rerun6.log
spec/generation-checks/r4-MC-stop.log
spec/generation-checks/r4-MC.log
spec/generation-checks/r4-MC_hunt_AST32_install.log
spec/generation-checks/r4-MC_hunt_AST32_report.log
spec/generation-checks/r4-MC_hunt_AST36.log
spec/generation-checks/r4-brief-bounds.log
spec/generation-checks/r4-evidence-resume.log
spec/generation-checks/r4-final-audit.log
spec/generation-checks/r4-fixture-audit-final.log
spec/generation-checks/r4-fixture-build-dynamic.log
spec/generation-checks/r4-fixture-build-final.log
spec/generation-checks/r4-fixture-build-resume.log
spec/generation-checks/r4-fixture-build.log
spec/generation-checks/r4-fixture-inventory.json
spec/generation-checks/r4-linux-control-final-rerun2.log
spec/generation-checks/r4-linux-control-final.log
spec/generation-checks/r4-linux-control-resume.log
spec/generation-checks/r4-linux-control.log
spec/generation-checks/r4-metadata-cleanup.log
spec/generation-checks/r4-normalizer-final.log
spec/generation-checks/r4-normalizer-regression.log
spec/generation-checks/r4-normalizer-resume.log
spec/generation-checks/r4-normalizer-resume2.log
spec/generation-checks/r4-preservation-and-fixtures.log
spec/generation-checks/r4-preservation-resume.log
spec/generation-checks/r4-trace-case-00-rerun2.log
spec/generation-checks/r4-trace-case-00-rerun3.log
spec/generation-checks/r4-trace-case-00.log
spec/generation-checks/r4-trace-case-01-rerun2.log
spec/generation-checks/r4-trace-case-01.log
spec/generation-checks/r4-trace-case-02-rerun2.log
spec/generation-checks/r4-trace-case-02.log
spec/generation-checks/r4-trace-case-03-rerun2.log
spec/generation-checks/r4-trace-case-03.log
spec/generation-checks/r4-trace-case-04-rerun2.log
spec/generation-checks/r4-trace-case-04.log
spec/generation-checks/r4-trace-case-05-rerun2.log
spec/generation-checks/r4-trace-case-05.log
spec/generation-checks/r4-trace-case-06-rerun2.log
spec/generation-checks/r4-trace-case-06.log
spec/generation-checks/r4-trace-case-07-rerun2.log
spec/generation-checks/r4-trace-case-07.log
spec/generation-checks/r4-trace-case-08-rerun2.log
spec/generation-checks/r4-trace-case-08.log
spec/generation-checks/r4-trace-case-09-rerun2.log
spec/generation-checks/r4-trace-case-09.log
spec/generation-checks/r4-trace-case-10-rerun2.log
spec/generation-checks/r4-trace-case-10.log
spec/generation-checks/r4-trace-case-11-rerun2.log
spec/generation-checks/r4-trace-case-11.log
spec/generation-checks/r4-trace-case-12-rerun2.log
spec/generation-checks/r4-trace-case-12.log
spec/generation-checks/r4-trace-case-13-rerun2.log
spec/generation-checks/r4-trace-case-13.log
spec/generation-checks/r4-trace-case-14-rerun2.log
spec/generation-checks/r4-trace-case-14.log
spec/generation-checks/r4-trace-case-15-rerun2.log
spec/generation-checks/r4-trace-case-15.log
spec/generation-checks/r4-trace-case-16-rerun2.log
spec/generation-checks/r4-trace-case-16.log
spec/generation-checks/r4-trace-case-17-rerun2.log
spec/generation-checks/r4-trace-case-17.log
spec/generation-checks/r4-trace-case-18-rerun2.log
spec/generation-checks/r4-trace-case-18.log
spec/generation-checks/r4-trace-case-19-rerun2.log
spec/generation-checks/r4-trace-case-19.log
spec/generation-checks/r4-trace-case-20-rerun2.log
spec/generation-checks/r4-trace-case-20.log
spec/generation-checks/r4-trace-case-21-rerun2.log
spec/generation-checks/r4-trace-case-21.log
spec/generation-checks/r4-trace-case-22-rerun2.log
spec/generation-checks/r4-trace-case-22.log
spec/generation-checks/r4-trace-coverage-final.log
spec/generation-checks/r4-trace-coverage-initial.log
spec/generation-checks/r4-trace-coverage-mc6.log
spec/generation-checks/r4-trace-coverage-resume.log
spec/generation-checks/r4-trace-coverage-selected.log
spec/generation-checks/r4-trace-coverage.json
spec/generation-checks/r4-trace-coverage.log
spec/generation-checks/r4-window-case-17.log
spec/generation-checks/r4-window-case-17.ndjson
spec/generation-checks/r4-window-case-18.log
spec/generation-checks/r4-window-case-18.ndjson
spec/generation-checks/run_r4_checks.py
```

## Revision 4 correction

The controller's independent review findings C1 and C2 are this correction's
only input. The baseline is `ced2584`. `base.tla` and `MC.tla` are unchanged.
No invariant, action guard, state constraint, state filter, kernel hook or
accepted trace was changed.
`Trace.tla` is restored byte for byte to `593a85c`. The C fixture retains the
one-right case 18, CPU pinning and `SCM_WINDOW` markers.

### Model checking and coverage

None of the three authorized PEEK candidates completed within 1,500 seconds.
`C1-mc-peek` is **FAIL**. The ordinary-receive configuration from
`r4-MC-rerun6` remains `MC.cfg`, as requested after three misses. It has
`PeekLimit = 0` and is not a PEEK convergence result. Its earlier completed
result remains 3,596,537 distinct states, depth 62 and 635.468 seconds.
The table below records the retained constants and every attempted PEEK
configuration. No fourth candidate was run.

| Constant | Retained default value |
| --- | --- |
| `Threads` | `{r1, r2}` |
| `AttemptSlots` | `2` |
| `RightsCount` | `4` |
| `ObjectA` | `fileA` |
| `ObjectB` | `fileB` |
| `SharedTable` | `TRUE` |
| `SetupFDCount` | `5` |
| `MaxFD` | `22` |
| `PayloadSize` | `1` |
| `AllowedLayouts` | `{"Full", "Null", "Zero", "Short", "HeaderOnly", "NoInteger", "One", "OnePadded", "SpaceOne", "FirstFault", "LaterFault", "PartialFault", "HeaderFault", "HeaderPartial"}` |
| `SendFaultLimit` | `1` |
| `PayloadFaultLimit` | `1` |
| `OutputFaultLimit` | `1` |
| `PeekLimit` | `0` |
| `RecvLimit` | `2` |
| `ReuseLimit` | `1` |

All three candidates use `AttemptSlots = 2`, `RightsCount = 3`,
`PeekLimit = 1`, `RecvLimit = 1`, `PayloadFaultLimit = 1` and
`OutputFaultLimit = 1`. Their threads, layouts, object identities, table and
descriptor bounds match the retained-default table above. Only reuse and
send-fault budgets vary between the candidates.

| Candidate | ReuseLimit | SendFaultLimit | Complete | Wall seconds | Distinct states | Depth | Queue | Log |
| --- | ---: | ---: | --- | ---: | ---: | ---: | ---: | --- |
| `r4c-MC` | 1 | 1 | False | 1800.078 | 9,670,740 | 63 | 1,134,816 | [r4c-MC.log](r4c-MC.log) |
| `r4c-MC-rerun2` | 0 | 1 | False | 1800.099 | 9,517,877 | 64 | 1,472,645 | [r4c-MC-rerun2.log](r4c-MC-rerun2.log) |
| `r4c-MC-rerun3` | 0 | 0 | False | 1800.087 | 9,383,290 | 64 | 1,476,973 | [r4c-MC-rerun3.log](r4c-MC-rerun3.log) |

Counts from a timed-out candidate are its last progress counters, not final
state-space totals. Only a complete run within 1,500 seconds is adopted.

The runner uses `timeout 1800`, two workers, `-Xmx3g`,
`-XX:MaxDirectMemorySize=512m`, `-XX:+UseParallelGC`, and
`states-r4/r4c-*` metadata. It no longer kills `MC.cfg` at 900 seconds.
The controller's new acceptance target is 1,500 seconds. The process may run
until the 1,800-second workflow limit, but a completion after 1,500 seconds
would not qualify. The existing workspace lock serializes TLC jobs. The
resource policy's `MemFree + Inactive(file)` reserve is recorded and checked
against 6 GiB before each launch. Completed runs remove only their own metadata.

`MC_convergence_recv_rights4.cfg` preserves the bytes of the completing
`r4-MC-rerun6` configuration. Its recorded result is 3,596,537 distinct states,
13,359,928 generated states, depth 62 and no violation in 635.468 seconds.
It keeps all 14 layouts, four rights, two ordinary calls, no PEEK and the
original fault/reuse limits. This is retained evidence, not a fresh companion
run. Base and MC module hashes remain unchanged, so restoring Trace.tla does
not change that MC result.

The corrected [R4-3 coverage table](../brief-coverage.md#revision-4-correction-trace-coverage)
records all 23 traces against the retained default. Both the traces and that
default have four rights. Cases 15, 16, 18 and 21 require PEEK, which the default
excludes. Case 15 also needs three slots on one thread. The three failed PEEK
candidates had exactly three rights and could not admit any complete four-right
trace. Four-right ordinary coverage comes from `MC_convergence_recv_rights4`.
The table names the completing
revision-2 four-right PEEK companions and their limits. Those companions do
not collectively establish a complete four-right Full mixed-call history.
`C1-coverage` passes for accurate reporting, without claiming exact admission
of every trace by the convergence configuration.

### Trace format, overlap and fixture checks

All 23 accepted traces pass `Trace.cfg` directly with nonzero initial states,
`TraceMatched`, all protocol invariants and `TraceEndComplete`. No witness
fallback was used. The two normalizer regressions reproduce those same files
byte for byte, both without markers and with synthetic analysis markers around
historical receiver intervals. Every event and its original endpoints remain
in ordinary event lines. Old `r4-window-case-*.ndjson` files are retained as
historical rejected-format evidence and are not corrected-run inputs.

The whole-trace overlap denominator includes sender setup, send and cleanup.
Window-only fractions are labelled analysis, not the guide's criterion.
The redesigned expected counts are 26/5/26 sender/r1/r2 events for case 17,
and 19/16/17 for a successful one-right case 18. Their whole-trace audit bounds
are 30/936 = 3.205% and 32/899 = 3.560%. Their window bounds are
30/130 = 23.077% and 32/272 = 11.765%. Point markers tighten the whole-trace
bounds to 2.457% and 2.670%, and the window bounds to 17.692% and 8.824%.
The serialized sender events every message needs explain the low whole-trace
bounds. No event leaves the denominator to raise the fraction.

For the historical accepted four-right batch, the measured whole/window
fractions are 2/936 = 0.214% and 2/130 = 1.538% for case 17, and
14/2384 = 0.587% and 14/650 = 2.154% for case 18. The marker-based regression
uses synthetic window annotations over unchanged production intervals.
Redesigned Asterinas whole/window measurements remain NOT RUN. The unchanged
20% guide requirement remains unmet. Full per-thread action inventories,
both structural bounds and measurement provenance are in
[the harness guide](../../harness/INSTRUMENTATION.md#revision-4-correction),
[r4c-fixture-inventory.json](r4c-fixture-inventory.json) and
[r4c-normalizer-overlap.json](r4c-normalizer-overlap.json).

The host executable and `SCM_ASTERINAS` object compile passed. The executable
uses dynamic linkage and the same pinned headers and flags as revision 4.
All 23 Linux controls reran with `SCM_DONE 0`. Case 17 delivered A,B,A,B to one
receiver while the other returned `EAGAIN`. Case 18 delivered one A to ordinary
receive and PEEK returned `EAGAIN`. Both worker CPUs were distinct and both
window markers were recorded. This is control evidence, not redesigned guest
overlap or a new successful-PEEK observation. No kernel build or guest boot ran.

### Reproduction and criteria

Run the trace and audit selections from the workspace root. The MC selection
requires a PEEK candidate snapshot and deliberately rejects the retained
ordinary default. To reproduce candidate 1, 2 or 3, first copy its exact
`config_text` from `revision4_correction.runs` in `results.json` into `MC.cfg`.
Restore `MC.cfg` from `MC_convergence_recv_rights4.cfg` after the candidate run.

```sh
python3 spec/generation-checks/run_r4_checks.py mc
python3 spec/generation-checks/run_r4_checks.py traces compat
python3 spec/generation-checks/audit_r4.py normalizer fixtures coverage
python3 spec/generation-checks/audit_r4.py evidence preservation
git diff --check
```

The runner selects unused `r4c-` log names. Normalizer regression inputs are
the saved `harness/build/r4-normalizer-resume2-{existing,window}` raw records,
whose hashes are in the correction log. The compiler commands and Linux
control command are retained verbatim in their logs. The initial normalizer
audit probe used an integer thread key instead of the decoder's string key.
Its partial log is retained, and the corrected audit passed without changing
the decoder to accommodate the failed probe.

| Criterion | Status | Command from workspace root | Evidence |
| --- | --- | --- | --- |
| `C1-mc-peek` | FAIL | `python3 spec/generation-checks/run_r4_checks.py mc` | [r4c-MC.log](r4c-MC.log)<br>[r4c-MC-rerun2.log](r4c-MC-rerun2.log)<br>[r4c-MC-rerun3.log](r4c-MC-rerun3.log) |
| `C1-companion` | PASS | `python3 spec/generation-checks/audit_r4.py preservation` | [r4c-final-audit.log](r4c-final-audit.log)<br>[r4-MC-rerun6.log](r4-MC-rerun6.log) |
| `C1-coverage` | PASS | `python3 spec/generation-checks/audit_r4.py coverage` | [r4c-coverage-final.log](r4c-coverage-final.log)<br>[r4c-trace-coverage.json](r4c-trace-coverage.json) |
| `C2-format` | PASS | `python3 spec/generation-checks/audit_r4.py normalizer`<br>`python3 spec/generation-checks/run_r4_checks.py traces` | [r4c-normalizer-rerun2.log](r4c-normalizer-rerun2.log)<br>[r4c-trace-case-00.log](r4c-trace-case-00.log)<br>[r4c-trace-case-22.log](r4c-trace-case-22.log) |
| `C2-overlap` | PASS | `python3 spec/generation-checks/audit_r4.py normalizer fixtures` | [r4c-normalizer-rerun2.log](r4c-normalizer-rerun2.log)<br>[r4c-audit-initial.log](r4c-audit-initial.log) |
| `C2-fixture` | PASS | Compiler commands in the build log.<br>`timeout 120 harness/build/r4c-linux-control` | [r4c-fixture-build.log](r4c-fixture-build.log)<br>[r4c-linux-control.log](r4c-linux-control.log) |
| `Compat` | PASS | `python3 spec/generation-checks/run_r4_checks.py compat` | [r4c-MC_hunt_AST32_install.log](r4c-MC_hunt_AST32_install.log)<br>[r4c-MC_hunt_AST32_report.log](r4c-MC_hunt_AST32_report.log)<br>[r4c-MC_hunt_AST36.log](r4c-MC_hunt_AST36.log) |
| `Records` | PASS | `python3 spec/generation-checks/audit_r4.py evidence preservation`<br>`git diff --check` | [r4c-final-audit.log](r4c-final-audit.log)<br>[r4c-records.log](r4c-records.log) |

`C2-overlap` passes for corrected accounting and documented bounds, with the
redesigned guest measurements explicitly NOT RUN and the guide's 20% target
unmet. Existing compatibility violations retain their AST-32/AST-36 attribution.
No broader hunting, cleanup-liveness or brief-bound completion is claimed.
No owned TLC process remains active. No commit was made.

### Correction run statistics

| Check | Distinct states | Depth | Counterexample states | Wall seconds | Log |
| --- | ---: | ---: | ---: | ---: | --- |
| `r4c-MC` | 9,670,740 | 63 | — | 1800.078 | [r4c-MC.log](r4c-MC.log) |
| `r4c-MC-rerun2` | 9,517,877 | 64 | — | 1800.099 | [r4c-MC-rerun2.log](r4c-MC-rerun2.log) |
| `r4c-MC-rerun3` | 9,383,290 | 64 | — | 1800.087 | [r4c-MC-rerun3.log](r4c-MC-rerun3.log) |
| `r4c-trace-case-00` | 53 | 53 | — | 0.709 | [r4c-trace-case-00.log](r4c-trace-case-00.log) |
| `r4c-trace-case-01` | 56 | 56 | — | 0.686 | [r4c-trace-case-01.log](r4c-trace-case-01.log) |
| `r4c-trace-case-02` | 34 | 34 | — | 0.640 | [r4c-trace-case-02.log](r4c-trace-case-02.log) |
| `r4c-trace-case-03` | 36 | 36 | — | 0.648 | [r4c-trace-case-03.log](r4c-trace-case-03.log) |
| `r4c-trace-case-04` | 36 | 36 | — | 0.632 | [r4c-trace-case-04.log](r4c-trace-case-04.log) |
| `r4c-trace-case-05` | 36 | 36 | — | 0.648 | [r4c-trace-case-05.log](r4c-trace-case-05.log) |
| `r4c-trace-case-06` | 36 | 36 | — | 0.663 | [r4c-trace-case-06.log](r4c-trace-case-06.log) |
| `r4c-trace-case-07` | 41 | 41 | — | 0.648 | [r4c-trace-case-07.log](r4c-trace-case-07.log) |
| `r4c-trace-case-08` | 41 | 41 | — | 0.662 | [r4c-trace-case-08.log](r4c-trace-case-08.log) |
| `r4c-trace-case-09` | 45 | 45 | — | 0.656 | [r4c-trace-case-09.log](r4c-trace-case-09.log) |
| `r4c-trace-case-10` | 41 | 41 | — | 0.681 | [r4c-trace-case-10.log](r4c-trace-case-10.log) |
| `r4c-trace-case-11` | 49 | 49 | — | 0.670 | [r4c-trace-case-11.log](r4c-trace-case-11.log) |
| `r4c-trace-case-12` | 49 | 49 | — | 0.682 | [r4c-trace-case-12.log](r4c-trace-case-12.log) |
| `r4c-trace-case-13` | 37 | 37 | — | 0.641 | [r4c-trace-case-13.log](r4c-trace-case-13.log) |
| `r4c-trace-case-14` | 37 | 37 | — | 0.643 | [r4c-trace-case-14.log](r4c-trace-case-14.log) |
| `r4c-trace-case-15` | 119 | 119 | — | 0.881 | [r4c-trace-case-15.log](r4c-trace-case-15.log) |
| `r4c-trace-case-16` | 82 | 82 | — | 0.744 | [r4c-trace-case-16.log](r4c-trace-case-16.log) |
| `r4c-trace-case-17` | 61 | 58 | — | 0.709 | [r4c-trace-case-17.log](r4c-trace-case-17.log) |
| `r4c-trace-case-18` | 102 | 86 | — | 0.775 | [r4c-trace-case-18.log](r4c-trace-case-18.log) |
| `r4c-trace-case-19` | 23 | 23 | — | 0.596 | [r4c-trace-case-19.log](r4c-trace-case-19.log) |
| `r4c-trace-case-20` | 59 | 59 | — | 0.732 | [r4c-trace-case-20.log](r4c-trace-case-20.log) |
| `r4c-trace-case-21` | 59 | 59 | — | 0.723 | [r4c-trace-case-21.log](r4c-trace-case-21.log) |
| `r4c-trace-case-22` | 27 | 27 | — | 0.616 | [r4c-trace-case-22.log](r4c-trace-case-22.log) |
| `r4c-MC_hunt_AST32_install` | 11,876 | 32 | 31 | 2.526 | [r4c-MC_hunt_AST32_install.log](r4c-MC_hunt_AST32_install.log) |
| `r4c-MC_hunt_AST32_report` | 1,360 | 36 | 36 | 1.002 | [r4c-MC_hunt_AST32_report.log](r4c-MC_hunt_AST32_report.log) |
| `r4c-MC_hunt_AST36` | 320 | 19 | 18 | 0.691 | [r4c-MC_hunt_AST36.log](r4c-MC_hunt_AST36.log) |

### Correction changed files

The complete change set relative to `ced2584` is listed below. Build outputs
and `states-r4/` metadata are ignored. Earlier tracked logs are unchanged.

```text
harness/INSTRUMENTATION.md
harness/RESULTS.md
harness/src/normalize.py
spec/MC_convergence_recv_rights4.cfg
spec/REVISION-2026-10-04.md
spec/Trace.tla
spec/brief-coverage.md
spec/generation-checks/README.md
spec/generation-checks/audit_r4.py
spec/generation-checks/r4c-MC-rerun2.log
spec/generation-checks/r4c-MC-rerun3.log
spec/generation-checks/r4c-MC.log
spec/generation-checks/r4c-MC_hunt_AST32_install.log
spec/generation-checks/r4c-MC_hunt_AST32_report.log
spec/generation-checks/r4c-MC_hunt_AST36.log
spec/generation-checks/r4c-audit-initial.log
spec/generation-checks/r4c-coverage-final.log
spec/generation-checks/r4c-final-audit.log
spec/generation-checks/r4c-fixture-build.log
spec/generation-checks/r4c-fixture-inventory.json
spec/generation-checks/r4c-linux-control.log
spec/generation-checks/r4c-normalizer-overlap.json
spec/generation-checks/r4c-normalizer-rerun2.log
spec/generation-checks/r4c-normalizer.log
spec/generation-checks/r4c-records.log
spec/generation-checks/r4c-trace-case-00.log
spec/generation-checks/r4c-trace-case-01.log
spec/generation-checks/r4c-trace-case-02.log
spec/generation-checks/r4c-trace-case-03.log
spec/generation-checks/r4c-trace-case-04.log
spec/generation-checks/r4c-trace-case-05.log
spec/generation-checks/r4c-trace-case-06.log
spec/generation-checks/r4c-trace-case-07.log
spec/generation-checks/r4c-trace-case-08.log
spec/generation-checks/r4c-trace-case-09.log
spec/generation-checks/r4c-trace-case-10.log
spec/generation-checks/r4c-trace-case-11.log
spec/generation-checks/r4c-trace-case-12.log
spec/generation-checks/r4c-trace-case-13.log
spec/generation-checks/r4c-trace-case-14.log
spec/generation-checks/r4c-trace-case-15.log
spec/generation-checks/r4c-trace-case-16.log
spec/generation-checks/r4c-trace-case-17.log
spec/generation-checks/r4c-trace-case-18.log
spec/generation-checks/r4c-trace-case-19.log
spec/generation-checks/r4c-trace-case-20.log
spec/generation-checks/r4c-trace-case-21.log
spec/generation-checks/r4c-trace-case-22.log
spec/generation-checks/r4c-trace-coverage.json
spec/generation-checks/results.json
spec/generation-checks/run_r4_checks.py
spec/instrumentation-spec.md
```
