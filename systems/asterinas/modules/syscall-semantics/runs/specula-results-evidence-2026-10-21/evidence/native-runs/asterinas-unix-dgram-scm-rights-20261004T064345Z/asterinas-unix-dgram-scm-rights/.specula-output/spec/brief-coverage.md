# Brief coverage audit

This specification models the Category B ownership protocol in Asterinas
`0c60537098f4c2949ad2d382aaf499de72263d76` (tree
`4693fdec88cd7da14bed4f1541eba593f123059c`). The audit below was filled by
reading the enabled properties and setup constants in the generated cfg files.
It is a spec-generation self-audit, not the subsequent independent spec review.

## Scenarios from brief section 2

| Scenario | Model mechanisms | Targeting configuration and reachable setup |
| --- | --- | --- |
| 1. Captured ownership, reuse and release | Immutable captured objects, one FD table indexed by table/number, send/queue/receive/disposal temporary owners, pending closes and independent reference balance. Capture, queue moves, clone-on-insert/PEEK, explicit drops and controlled sender reuse preserve multiplicities. | `MC_hunt_scenario1.cfg` enables one send fault, one PEEK, one ordinary call, one reuse, full/NULL output and quiescent disposal. `MC_hunt_scenario1_separate_tables.cfg` checks distinct tables. `MC_cleanup.cfg` checks fair drainage. |
| 2. Queue order versus publication order | Per-call PCs, selected message identity, queue-lock owner, ordinary dequeue, PEEK clone, then queue unlock and borrow release before each independent insertion/copy. | `MC_hunt_scenario2.cfg` permits two PEEK and two ordinary attempts across two threads with two sequential call slots each. All output is writable. No fairness or syscall-return ordering is used as a safety assumption. |
| 3. Partial publication and reporting | Static NULL/short/prefix/full/fault layouts, selected capacity, installed objects and numbers, complete/failed integer sets, copied-byte positions, cursor, header result, internal length, msghdr writeback and destructor completion. | `MC_hunt_scenario3.cfg` includes all 14 layouts, one output-fault setup and one PEEK plus one ordinary call. Separate `MC_hunt_AST32_install.cfg` and `MC_hunt_AST32_report.cfg` keep each known compatibility mismatch enabled without terminating the protocol configuration. |
| 4. Payload fault and retry | Payload copying precedes dequeue. Fault-time queue membership is retained in the call record independently of later retry/consumption. | `MC_hunt_scenario4.cfg` permits one payload fault, one PEEK and two ordinary calls with otherwise valid output. `MC_hunt_AST36.cfg` enables the Linux consumption predicate on the same reachable paths. |

The original scenario configurations use four rights `A, B, A, B`, one nonempty
message, and at least 16 free receiver slots beyond setup descriptors. Up to
two successful PEEK calls and one ordinary consumption can create 12 entries.
Allocation exhaustion is an assertion about an inadequate model bound, never
a simulated kernel error. Attempt slots and MC counters bound new calls and
pre-call faults. No receive, publication, destructor or close-completion step
is stopped by a counter.

`MC.cfg` checks typing, ownership and structural consistency with every fault
layout reachable. It comments out the scenario properties. The hunt configs
enable their target properties plus core typing/ownership checks. They do not
include unrelated structural checks. `MC_cleanup.cfg` supplies weak fairness
for started work and requested cleanup and omits symmetry reduction.

## Safety properties from brief section 5

Every property below is defined in `base.tla` and inherited unchanged by
`MC.tla`. This table lists actual, uncommented cfg entries.

| Property | Enabled configurations |
| --- | --- |
| `TypeOK` | All eight `MC_hunt_*.cfg` files, `MC_cleanup.cfg`; `MC.cfg` also checks it through `MCTypeOK`. |
| `OwnershipConserved` | `MC.cfg`, all eight hunt cfgs, and `MC_cleanup.cfg`. |
| `CapturedObjectIdentity` | `MC_hunt_scenario1.cfg`, its separate-tables variant, and `MC_hunt_scenario3.cfg`. |
| `OrdinaryConsumeAtMostOnce` | `MC_hunt_scenario2.cfg`, `MC_hunt_scenario4.cfg`. |
| `PeekPreservesQueueRights` | `MC_hunt_scenario2.cfg`, `MC_hunt_scenario4.cfg`. |
| `DeliveredPrefixSurvives` | `MC_hunt_scenario3.cfg`. |
| `OperationOwnersDrained` | `MC_hunt_scenario1.cfg`, its separate-tables variant, `MC_hunt_scenario3.cfg`, `MC_hunt_scenario4.cfg`, `MC_cleanup.cfg`. |
| `NoFailedNumberInstalled` | `MC_hunt_AST32_install.cfg`. |
| `ReportedPrefixMatchesLinux` | `MC_hunt_AST32_report.cfg`. |
| `PayloadFaultConsumptionMatchesLinux` | `MC_hunt_AST36.cfg`. |

`BoundedCleanupProgress` is the brief's liveness property. It is enabled in
`MC_cleanup.cfg`, under `MCLiveSpec`. Final release requires closing every
actual ordinary-file FD, including unexpected failed-number installations.
A completed call alone cannot imply final release.

## Findings from brief section 6.1

Section 6.1 contains zero new model-checkable candidates. Nothing was invented
to fill it, and this did not remove any protocol scenario. The two section 6.2
leads retain their existing attribution:

| Existing lead | Reachability and oracle | Evidence boundary |
| --- | --- | --- |
| AST-32 | `FirstFault` reaches header success, insertion, then failed first number copying. `LaterFault` and `PartialFault` deliver two integers before the third fails. Installation and prefix-report checks have separate cfgs. A PEEK fault and later valid receive are possible in the installation/protocol configs. | Expected source-derived model mismatch. It is not a new finding or runtime reproduction. |
| AST-36 | An ordinary call with `payloadGood = FALSE` records the selected message still queued before returning `EFAULT`. A later valid call can consume it. PEEK is the retention control. | Expected source-derived model mismatch, bounded to the requested payload boundary. |

Compatibility properties are checked at completed-call boundaries, after
temporary drops. Neither partial output nor `MSG_CTRUNC` implies zero
installed FDs. No compatibility predicate guards an implementation action.

## Target instructions and contract cases

| Cases | Coverage and limits |
| --- | --- |
| SCM-01/02 | Sender close and controlled `dup2(B, old-A)` after send, full delivery, duplicate object references, and either shared or separate FD tables. Slot ownership is counted once. |
| SCM-03/04 | NULL, capacities 0/15/16/19, exact one-integer length 20, skipped padding at 21, `CMSG_SPACE(int)` length 24 admitting two integers, and full capacity. |
| SCM-05/06/09 | First and third integer failures, a two-byte partial third copy, preserved delivered prefix, failed-entry installation, and PEEK ownership. |
| SCM-07 | Asterinas header failure precedes all insertions. Zero-byte and partial-header faults are represented. Linux's delivered FDs surviving a later header failure are an allowed external control, not rejected by any compatibility predicate. |
| SCM-08/10/11 | Repeated PEEK, competing ordinary receivers, PEEK/ordinary selection order, and publication after queue unlock. |
| SCM-12 | Quiescent queue disposal and explicit release of every remaining ordinary-file owner, including pending closes. |
| SCM-13/14 | One bounded receive payload fault with retry/PEEK control, and send payload failure before enqueue with temporary cleanup. |

The native 16-byte header, 4-byte integer and 8-byte alignment are explicit
ABI abstractions. The harness must measure them and capture complete-copy
outcomes and raw bytes. The model does not implement page tables, instruction
level copying, pipe EOF or allocation behavior. Partial byte effects are an
abstract allowed copy result, not proof that a particular layout is achievable.

The executable transition relation is Asterinas only. Linux
`4645fefac0b24d509b962c096b0327e87f34b1d2` supplies the separate completion
predicates: reserve/copy/install with failed-reservation release, prefix
reporting after delivery, and ordinary unlink before payload copying.
Its receive `iolock` spans ancillary delivery. Importing that lock into this
Asterinas model would suppress the requested interleavings. A second complete
Linux implementation model is not generated. Same-program Linux tests remain
the evidence route for ABI behavior and the SCM-07 header-after-delivery control.

Per-insertion file-table locking is represented by one atomic insertion
transition, followed by a separate unlocked number-copy transition. Queue
locking is explicit. PEEK's list clone is grouped while holding the queue
mutex: its individual reference increments commute with independent owner
drops, and strong-count inspection is outside the contract. Temporary and
queue-disposal releases are separate per-reference transitions. The sender's
single control list is moved between local containers without changing its
owner multiplicity.

The exclusions in brief section 3.2 remain exclusions: AST-31, credentials,
other socket kinds, Unix-socket cycles, empty records, allocation/resource-limit
failures, signal/restart, shutdown races, VM mutation, unrelated FD races and
CLOEXEC. Sender reuse is deliberately restricted to the controlled interval
before the first receive. Other sender closes may interleave with receiving.

## Revision checks and phase handoff

The 2026-10-04 revision addresses findings 1–4 from
[the first spec review](review-specgen-original.md). Slot provenance now uses tagged records,
with the received operation/entry pair retained for cleanup and delivered-entry
checks. Queue owner tags use the same tuple shape as receiver operations.
`TypeOK` distinguishes string object identities from numeric FD and tuple slot
domains, and compares the mixed string/integer return domain through typed
renderings. These representation changes preserve the transition ordering and
property meanings. All twelve original configurations remain byte-identical,
including driver bounds, receiver symmetry, fairness and deadlock settings.

Trace input validation now asserts the existing metadata, source, event and
time-order predicates. Source actions and mandatory post-state comparisons are
unchanged. Both the probe wrapper and the original `Trace.cfg` accept the
55-event synthetic trace with one initial state and 56 distinct states. It
contains a successful send, original sender close, controlled reuse, four
received entries, their publication and final release. `TypeOK`,
`TraceMatched` and `TraceEndComplete` are enabled. This also exercises original,
reused and received FD provenance. A trace result requires a nonzero initial
state count and error-free completion with those checks enabled.

Wrong source, unknown event, malformed metadata and non-monotonic per-thread
timestamps produce assertion errors. The reviewer's truncated input violates
`TraceEndComplete`, and the corrupted post-state violates `TraceMatched`.
The three reviewer inputs were reused byte-for-byte. These are synthetic
validator checks, not production trace validation.

The separate compatibility configurations exhibit the expected
`NoFailedNumberInstalled`, `ReportedPrefixMatchesLinux` and
`PayloadFaultConsumptionMatchesLinux` violations. Their counterexamples have
31, 36 and 18 states, respectively. They retain the AST-32/AST-36 source-lead
attribution and do not establish a new kernel defect or runtime reproduction.

The original parser-only generation record remains in
[generation-checks.log](generation-checks.log). New commands, logs, per-run
counts, elapsed times and criterion verdicts are in
[generation-checks/README.md](generation-checks/README.md) and
[generation-checks/results.json](generation-checks/results.json).
The revision's per-file changes are listed in
[REVISION-2026-10-04.md](REVISION-2026-10-04.md).

All ten MC configurations were executed with the original bounds. The
separate-tables Scenario 1 configuration completed without a violation after
25,318,204 distinct states at depth 89. `MC.cfg`, shared-table Scenario 1,
Scenarios 2–4 and `MC_cleanup.cfg` each reached the 5400-second timeout and are
incomplete. Their final reported state counts, search depths and queue sizes
are retained in the generation-check README and results JSON. The cleanup
run's periodic temporal checks found no violation, but its complete
`BoundedCleanupProgress` result is not established. No smaller configuration
was substituted for an incomplete run.

The original `base.cfg` was also executed and timed out with 71,252,842
reported distinct states at depth 29 and 27,986,858 states left on its queue.
The original `Trace.cfg` completed on the valid synthetic fixture. Together
with the ten MC configurations, this accounts for all twelve original cfgs.
Final SANY logs for all three modules and C1–C7 verdicts are included in the
new check records. C6 passes the execution/reporting criterion while retaining
the six incomplete MC results and the unestablished cleanup liveness result.

Harness generation, production trace validation, kernel execution, Linux
runtime controls, confirmation and classification remain `NOT RUN`. The
approved brief and source analysis were not edited. The executed checks here
are the specification revision checks requested by the user.

## Revision 2 companion results

The preceding revision records describe the original configurations. New companions keep the model and all original configurations unchanged. Their exact constants, lost combinations and execution commands are in [generation-checks/README.md](generation-checks/README.md#revision-2-completing-companion-configurations), with machine-readable records in [generation-checks/results.json](generation-checks/results.json).

Every companion keeps `Threads = {r1, r2}`, `AttemptSlots = 2`, `ObjectA = fileA`, `ObjectB = fileB`, `SharedTable = TRUE`, `SetupFDCount = 5`, `MaxFD = 22` and `PayloadSize = 1`. There are 16 free receiver slots beyond the seven setup/object descriptors. All original invariants, specification, view, constraint, symmetry and deadlock entries are preserved. Cleanup companions retain `MCLiveSpec` and omit symmetry.

Scenario 3 layouts still lacking completion with all other constants unchanged: `Full`. The run table records their incomplete attempts. A result with reduced operation budgets or rights does not close this gap.

| Original | Layouts complete with every other constant unchanged | Layouts still missing that result |
| --- | --- | --- |
| `MC_hunt_scenario3.cfg` | 13/14 | `Full` |
| `MC.cfg` | 12/14 | `Full`, `SpaceOne` |
| `MC_cleanup.cfg` | 2/3 | `Full` |
| `MC_hunt_scenario1.cfg` | 1/2 | `Full` |

| Property | Completing companion witnesses |
| --- | --- |
| `OwnershipConserved` | `MC_layouts_fault.cfg`<br>`MC_layout_full_rights3_peek1_recv1.cfg` |
| `CapturedObjectIdentity` | `MC_hunt_scenario1_layout_full_peek1_recv0.cfg`<br>`MC_hunt_scenario3_layouts_fault.cfg` |
| `OrdinaryConsumeAtMostOnce` | `MC_hunt_scenario4_peek0_recv2.cfg`<br>`MC_hunt_scenario2_rights3_peek1_recv2.cfg` |
| `PeekPreservesQueueRights` | `MC_hunt_scenario2_rights3_peek2_recv0.cfg`<br>`MC_hunt_scenario2_rights3_peek1_recv2.cfg` |
| `DeliveredPrefixSurvives` | `MC_hunt_scenario3_layouts_fault.cfg` |
| `OperationOwnersDrained` | `MC_hunt_scenario1_layout_full_peek0_recv1.cfg`<br>`MC_hunt_scenario3_layouts_fault.cfg` |
| `BoundedCleanupProgress` | `MC_cleanup_layout_null.cfg`<br>`MC_cleanup_layout_later_fault.cfg`<br>`MC_cleanup_layout_full_peek1_recv0.cfg`<br>`MC_cleanup_layout_full_peek0_recv1.cfg` |

Revision 2 used **14411.666 seconds** of TLC wall time out of 18,000 seconds, leaving 3588.334 seconds. This sum includes all probes, timeouts and completed runs. No run remains active.

Layout partitions omit combinations across subsets, and operation partitions omit calls beyond each companion's budget. The completed companions do not establish any original configuration that timed out. Cleanup completion is bounded to the listed companion constants. The original AST-32/AST-36 compatibility outcomes and the phase boundary remain unchanged.

## Revision 3 review corrections

Findings 5 and 6 from [the second review](review-specgen.md) were the only
input to this revision. PEEK's after-snapshots now read the actual
post-transition queue and remain in each call's history after later ordinary
consumption. The delivered action still clones under the queue lock, as in
`net/socket/unix/ctrl_msg.rs:304-310` and
`net/socket/unix/datagram/message.rs:179-217`. Its preservation invariant is
unchanged. The reviewer's move-and-consume mutant now violates that invariant
at state 17, while the unmutated control passes.

All five completed revision-2 companions that enable
`PeekPreservesQueueRights`, including the two ordinary-consumption controls,
complete again with identical distinct-state counts. The completed mixed and
repeated-PEEK configurations retain their existing three-right bounds. This
result does not complete the earlier searches at larger combined bounds.

`TraceSearch.cfg` retains every safety, post-state and terminal check and
finds a complete witness by violating `TraceNoCompleteMatch`. The original
`Trace.cfg` and `TraceMatched` remain enabled and unchanged. The
[instrumentation guide](instrumentation-spec.md#3-special-considerations)
accepts an error-free normal run or, only after an isolated `TraceMatched`
failure, a complete witness from nonzero initial states. Other failures
reject the trace. The reviewer's overlap fixture is accepted by this rule,
valid is accepted by both modes, and wrong-source, unknown-event, truncated
and corrupted-post fixtures are rejected. The three expected AST-32/AST-36
compatibility counterexamples remain separate and reproduce.

[Revision 3 check records](generation-checks/README.md#revision-3-review-findings-5-and-6)
contain all commands, logs, state-count comparisons and the six PASS criteria.
`revision3` in [results.json](generation-checks/results.json) records current
input hashes. Earlier entries remain historical records. All existing
configuration bytes, bounds, invariants, source guards and transition outcomes
are preserved. The pinned source and reviewer evidence remain unchanged.
No kernel execution, production trace, Linux runtime control, confirmation
or classification was run. No commit was made.

## Revision 4 correction: trace coverage

The controller's independent C1/C2 review is this correction's only input.
None of the three authorized PEEK candidates completed within 1,500 seconds.
`MC.cfg` therefore retains the ordinary-receive configuration from
`r4-MC-rerun6`: four rights, all 14 layouts, two threads, two slots per thread,
no PEEK, two ordinary calls, one reuse and one fault of each kind. The
specification, invariants, symmetry, view, constraint and deadlock setting
remain unchanged. `C1-mc-peek` is FAIL.

Each failed PEEK candidate used exactly three rights, A,B,A. All 23 accepted
traces use four rights, A,B,A,B. `RightsCount` is exact, so none of those
candidates admitted the complete four-right histories. They omit the second
B reference and the fourth-right tail after entry-3 publication failure.
Candidates 2 and 3 also exclude case 01's reuse. Candidate 3 excludes case 22's
send fault. All three have one PEEK, one ordinary call and two slots, so they
also omit case 15's second PEEK/third slot and cases 17/20's second ordinary call.
The [correction record](generation-checks/README.md#revision-4-correction)
preserves their exact constants and incomplete results.

The table describes the retained default, whose rights count is again four.
P/R counts PEEK/ordinary calls, S/P/O counts send/payload/output faults, and
slots is the largest observed per-thread attempt index. Every trace performs
final cleanup. All observed FD numbers fit the retained maximum of 22.

| Trace | Layouts | P/R | S/P/O | Reuse | Trace rights / MC rights | Slots | Highest FD | Exclusion by the retained default bounds |
| --- | --- | --- | --- | ---: | --- | ---: | ---: | --- |
| `case-00.ndjson` | Full | 0/1 | 0/0/0 | 0 | 4 / 4 | 1 | 8 | None. |
| `case-01.ndjson` | Full | 0/1 | 0/0/0 | 1 | 4 / 4 | 1 | 9 | None. |
| `case-02.ndjson` | Null | 0/1 | 0/0/0 | 0 | 4 / 4 | 1 | 6 | None. |
| `case-03.ndjson` | Zero | 0/1 | 0/0/0 | 0 | 4 / 4 | 1 | 6 | None. |
| `case-04.ndjson` | Short | 0/1 | 0/0/0 | 0 | 4 / 4 | 1 | 6 | None. |
| `case-05.ndjson` | HeaderOnly | 0/1 | 0/0/0 | 0 | 4 / 4 | 1 | 6 | None. |
| `case-06.ndjson` | NoInteger | 0/1 | 0/0/0 | 0 | 4 / 4 | 1 | 6 | None. |
| `case-07.ndjson` | One | 0/1 | 0/0/0 | 0 | 4 / 4 | 1 | 6 | None. |
| `case-08.ndjson` | OnePadded | 0/1 | 0/0/0 | 0 | 4 / 4 | 1 | 6 | None. |
| `case-09.ndjson` | SpaceOne | 0/1 | 0/0/0 | 0 | 4 / 4 | 1 | 6 | None. |
| `case-10.ndjson` | FirstFault | 0/1 | 0/0/1 | 0 | 4 / 4 | 1 | 6 | None. |
| `case-11.ndjson` | LaterFault | 0/1 | 0/0/1 | 0 | 4 / 4 | 1 | 7 | None. |
| `case-12.ndjson` | PartialFault | 0/1 | 0/0/1 | 0 | 4 / 4 | 1 | 7 | None. |
| `case-13.ndjson` | HeaderFault | 0/1 | 0/0/1 | 0 | 4 / 4 | 1 | 6 | None. |
| `case-14.ndjson` | HeaderPartial | 0/1 | 0/0/1 | 0 | 4 / 4 | 1 | 6 | None. |
| `case-15.ndjson` | Full | 2/1 | 0/0/0 | 0 | 4 / 4 | 3 | 16 | Peek needs 2, PeekLimit is 0. Same-thread sequence needs 3 slots, AttemptSlots is 2. |
| `case-16.ndjson` | Full, PartialFault | 1/1 | 0/0/1 | 0 | 4 / 4 | 2 | 11 | Peek needs 1, PeekLimit is 0. |
| `case-17.ndjson` | Full | 0/2 | 0/0/0 | 0 | 4 / 4 | 1 | 8 | None. |
| `case-18.ndjson` | Full | 1/1 | 0/0/0 | 0 | 4 / 4 | 1 | 12 | Peek needs 1, PeekLimit is 0. |
| `case-19.ndjson` | No receive | 0/0 | 0/0/0 | 0 | 4 / 4 | 0 | 6 | None. |
| `case-20.ndjson` | Full | 0/2 | 0/1/0 | 0 | 4 / 4 | 2 | 8 | None. |
| `case-21.ndjson` | Full | 1/1 | 0/1/0 | 0 | 4 / 4 | 2 | 8 | Peek needs 1, PeekLimit is 0. |
| `case-22.ndjson` | Full | 0/1 | 1/0/0 | 0 | 4 / 4 | 1 | 6 | None. |

`C1-coverage` passes for accurate reporting. Cases 15, 16, 18 and 21 remain
excluded because the retained default has no PEEK. Case 15 also needs three
slots on one thread. A row with no listed exclusion records these bounds only,
not a separate proof of exact trace admission. Successful `Trace.cfg` replay
uses each trace's own metadata and is a separate result.

### Completing four-right companions

`MC_convergence_recv_rights4.cfg` is byte-identical to the configuration run
as `r4-MC-rerun6`. It completes all 14 layouts with four rights, two ordinary
calls, no PEEK, two slots per thread, one reuse and all three fault limits at
one. Its recorded result is 3,596,537 distinct states, depth 62, an empty
queue and no violation in 635.468 seconds. That completed result also applies
to the retained default. It is not presented as a fresh run.

The unchanged revision-2 four-right PEEK companions cover these bounded
parts of the protocol:

| Companion | Four-right PEEK scope | Limit relevant to these traces |
| --- | --- | --- |
| `MC_hunt_scenario1_layout_full_peek1_recv0.cfg` | Full publication, capture/identity and reuse | One PEEK, no ordinary call. |
| `MC_hunt_scenario3_layout_full_peek1_recv0.cfg` | Full publication and prefix/ownership checks | One PEEK, no ordinary call. |
| `MC_cleanup_layout_full_peek1_recv0.cfg` | Full PEEK and bounded cleanup with fairness | One PEEK, no ordinary call. |
| `MC_layouts_fault.cfg`, `MC_hunt_scenario3_layouts_fault.cfg` | First/later/partial number faults and header faults, including a fourth-right tail | Full publication is excluded. |
| `MC_layouts_null_zero_short.cfg`, `MC_layouts_no_integer.cfg`, `MC_layouts_one.cfg` | Their named capacity groups with PEEK and ordinary calls | Full publication and other groups are excluded. |
| `MC_layout_space_one_peek2_recv1.cfg`, `MC_layout_space_one_peek1_recv2.cfg` | SpaceOne publication with the named operation budgets | Full publication is excluded. |
| `MC_cleanup_layout_null.cfg`, `MC_cleanup_layout_later_fault.cfg`, `MC_hunt_scenario1_layout_null.cfg`, `MC_hunt_scenario3_layouts_capacity.cfg` | Their named capacity/fault and cleanup/identity scopes | No complete Full mixed-call execution. |

The [revision-2 tables](generation-checks/README.md#revision-2-completing-companion-configurations)
retain every constant, enabled property, state count and completed log.
These companions are not a completed four-right Full mixed PEEK/ordinary
state space. Their union does not establish the histories of cases 15, 16,
18 or 21. Case 16 mixes PartialFault with Full. Case 18 overlaps successful
Full PEEK and ordinary publication. Case 21 combines a payload-fault PEEK
with an ordinary retry. Case 15 also exceeds every two-slot companion.
`MC_brief_bounds.cfg` and the incomplete companions retain their historical
incomplete status. No new hunting or cleanup-liveness result is claimed.

Every accepted trace is replayed independently through unchanged `Trace.cfg`,
using its own metadata. All events remain ordinary trace lines. The corrected
competition whole-trace structural bounds are 3.205% for case 17 and 3.560%
for the one-right case 18. They do not meet 20%. Window fractions are analysis
only, and redesigned guest execution remains NOT RUN. See
[the harness record](../harness/RESULTS.md#revision-4-correction).
