# Bug Report — asterinas-unix-dgram-scm-rights

## Summary

The trace/model-checking loop passed in one round at the supplied ordinary-receive
`MC.cfg` bounds. All 46 trace replays passed, and the default search completed
with 3,596,537 distinct states at depth 62. No specification or invariant changed.
This does not establish full-protocol convergence: the default excludes PEEK,
the three-call single-thread trace exceeds its attempt slots, and the harness's
20% whole-trace overlap gate remains unmet.

- The four protocol scenarios have 20 hunting configurations. 20 have recorded outcomes.
- 12 hunting searches completed exhaustively, 5 ended incomplete, and 3 reported known compatibility violations.
- The three compatibility counterexamples map to two existing identities, AST-32 and AST-36. No new defect candidate was established in the executed checks.

The source pin is `0c60537098f4c2949ad2d382aaf499de72263d76`.
[Input hashes](output/validation-20261010T015405Z/input-hashes.json), [configuration constants and invariants](output/validation-20261010T015405Z/hunting-config-inventory.json),
and the [execution ledger](output/validation-20261010T015405Z/hunting-results.json) identify the exact inputs and outcomes.
The ordinary default has two receiver threads, two attempt slots per thread,
four A/B/A/B rights, two ordinary attempts, no PEEK, all 14 layouts, and at least
16 initially free receiver FD slots. Hunting configurations retain their supplied bounds.

## Bug 1: AST-32: Failed SCM_RIGHTS number publication retains an installed FD

- **Scenario**: Scenario 3, including the PEEK copy from Scenario 2.
- **Severity**: Medium, as a validation-stage impact assessment.
- **Invariant violated**: `NoFailedNumberInstalled`. A second configuration also violates `ReportedPrefixMatchesLinux`.
- **Config**: `MC_hunt_AST32_install.cfg`, with `MC_hunt_AST32_report.cfg` as supporting evidence.
- **Counterexample**: [31-state installation trace](output/validation-20261010T015405Z/MC_hunt_AST32_install.log) and [36-state reporting trace](output/validation-20261010T015405Z/MC_hunt_AST32_report.log).
- **Classification**: Case C, attributed to existing AST-32. This is not a new AST identity or a fresh Phase 4 reproduction.

### Trace Summary

The installation trace captures four A/B/A/B references in states 3–6 and enqueues
the message at state 10. State 17 clones its rights for PEEK while preserving the
queue. State 22 completes the writable header. State 23 installs entry 1 as
receiver FD 7 naming fileA. Its integer copy fails in state 24. State 26 publishes
zero control length, truncation and a successful payload return. States 27–30
release every temporary reference. State 31 completes the call with entry 1
still installed and no complete FD number delivered. The queue remains an
independent owner. The final balances are four references to fileA and three
to fileB, fully accounted for by sender FDs, queue rights and the installed FD.

The reporting trace consumes the message at state 17. States 24–27 install and
publish FDs 7 and 8 for A and B. State 28 installs FD 9 for the third entry,
whose copy fails at state 29. State 31 reports zero control length while the
already written header still describes 32 bytes. After temporary cleanup,
state 36 retains all three installed FDs, including the two valid deliveries.
Linux's delivered-prefix contract reports 24 bytes for those two entries.
The earlier two FDs must survive this later fault.

[Installation analysis](output/validation-20261010T015405Z/MC_hunt_AST32_install-analysis.json) and
[reporting analysis](output/validation-20261010T015405Z/MC_hunt_AST32_report-analysis.json) retain the inspected states and source mapping.

### Root Cause

At the pinned source, `FileMessage::write_to` writes the header, inserts a
cloned file into the table, releases that insertion lock, then copies the integer.
The copy's error propagation has no compensating removal. Dropping the temporary
list releases its references but cannot remove the separately installed entry.
`ControlMessage::write_all_to` suppresses the error and breaks before adding
the failed cmsg to its reported length.

Linux reference `4645fefac0b24d509b962c096b0327e87f34b1d2` reserves a
slot, copies its number and installs only after success
(`fs/file.c:1364–1376`). Its SCM loop then reports the successfully delivered
prefix (`net/core/scm.c:348–370`). A later header fault may legitimately
retain already delivered FDs. The predicates preserve that distinction.

The impact is an unreported process FD and retained ordinary-file reference,
plus inconsistent prefix reporting. This bounded result does not establish a
global memory leak or an out-of-scope privilege escalation.

### Affected Code

These locations refer to the instrumented checkout. The corresponding committed
anchors are `ctrl_msg.rs:135–148` and `message_header.rs:109–122`.

- `kernel/core/src/net/socket/unix/ctrl_msg.rs:184` installs the file before the integer copy at line 203.
- `kernel/core/src/net/socket/util/message_header.rs:115` handles the error before the length update at line 122.

### Recommendation

Use reservation/publication semantics that leave the failed entry uninstalled,
and report the successfully delivered prefix. Preserve its FDs after later
faults. Any implementation repair still needs its own regression and review stages.

## Bug 2: AST-36: Ordinary payload faults retain the datagram

- **Scenario**: Scenario 4, the bounded payload-fault consumption/PEEK control.
- **Severity**: Medium, as a validation-stage compatibility assessment.
- **Invariant violated**: `PayloadFaultConsumptionMatchesLinux`.
- **Config**: `MC_hunt_AST36.cfg`.
- **Counterexample**: [18-state trace](output/validation-20261010T015405Z/MC_hunt_AST36.log).
- **Classification**: Case C, attributed to existing AST-36. This is not a new defect identity.

### Trace Summary

The send finishes at state 12 with the queued A/B/A/B references. States 13–15
begin an ordinary receive and select that message under the queue lock.
Payload copying fails in state 16, which records `faultRetained = TRUE`.
State 17 unlocks. State 18 completes with EFAULT, no ancillary output and no
new receiver FD. The same message and all four queue references remain.
[Structured analysis](output/validation-20261010T015405Z/MC_hunt_AST36-analysis.json) retains the inspected path.

### Root Cause

The pinned Asterinas receive path propagates payload-copy failure at
`message.rs:195` before the ordinary dequeue at line 202. Linux's
`net/core/datagram.c:183–202` unlinks an ordinary receive before copying.
The copy failure in `net/unix/af_unix.c:2558–2560` reaches the release at
lines 2598–2600. PEEK retains the queued message in both implementations.

The compatibility consequence is that a valid ordinary retry can receive the
same Asterinas message and rights after EFAULT, whereas the Linux retry is empty.
Remaining queue ownership is accounted for; this result does not assert a reference leak.

### Affected Code

- `kernel/core/src/net/socket/unix/datagram/message.rs:285` performs the payload copy whose error returns before the ordinary dequeue at line 309.

### Recommendation

Align ordinary consumption and selected-reference cleanup with the supported
Linux contract while retaining PEEK semantics. Keep the scope to the existing
normal/PEEK payload-fault controls.

## Runtime evidence and attribution

The current Phase 2.5 attempt `20261010T014248Z` separately observed the
first-number fault, later/partial-number faults and normal/PEEK payload retry
outcomes on Asterinas and Linux 7.2.8. Its saved observations agree with the
counterexample mechanisms. [The observation audit](output/validation-20261010T015405Z/reference-observation-audit.json)
identifies the original comparison file and its hash. These are inherited runtime
records read during validation, not newly executed reproductions. The
[harness report](../harness/RESULTS.md) retains binary identity and Linux source reconciliation.

Persistent-finding lookups returned no registry matches. The known identities
come from the supplied contracts and current source comparison. No shared
catalog entry, persistent finding, source repair, confirmation verdict or
severity-classification phase was changed.

## Not Reproduced

This table includes every hunting configuration, including the known violations
for completeness. Counts are per configuration and must not be summed as unique
coverage. For incomplete searches they are the last reported counters, not final
totals. Depth is the completed graph depth only for exhaustive rows.

| Configuration | Distinct states | Depth reached | Result |
| --- | ---: | ---: | --- |
| [MC_hunt_AST32_install.cfg](MC_hunt_AST32_install.cfg) | 11,953 | 31 | Known AST-32 counterexample |
| [MC_hunt_AST32_report.cfg](MC_hunt_AST32_report.cfg) | 1,358 | 36 | Known AST-32 counterexample |
| [MC_hunt_AST36.cfg](MC_hunt_AST36.cfg) | 322 | 19 | Known AST-36 counterexample |
| [MC_hunt_scenario1.cfg](MC_hunt_scenario1.cfg) | 16,020,694 | 73 | No reported violation; 30-minute budget ended |
| [MC_hunt_scenario1_layout_full_peek0_recv1.cfg](MC_hunt_scenario1_layout_full_peek0_recv1.cfg) | 22,924 | 56 | No violation; exhaustive completion |
| [MC_hunt_scenario1_layout_full_peek1_recv0.cfg](MC_hunt_scenario1_layout_full_peek1_recv0.cfg) | 51,208 | 59 | No violation; exhaustive completion |
| [MC_hunt_scenario1_layout_null.cfg](MC_hunt_scenario1_layout_null.cfg) | 3,630 | 51 | No violation; exhaustive completion |
| [MC_hunt_scenario1_separate_tables.cfg](MC_hunt_scenario1_separate_tables.cfg) | 5,873,716 | 74 | No reported violation; 30-minute budget ended |
| [MC_hunt_scenario2.cfg](MC_hunt_scenario2.cfg) | 9,452,209 | 70 | No reported violation; 30-minute budget ended |
| [MC_hunt_scenario2_peek0_recv2.cfg](MC_hunt_scenario2_peek0_recv2.cfg) | 53,669 | 58 | No violation; exhaustive completion |
| [MC_hunt_scenario2_rights3_peek1_recv2.cfg](MC_hunt_scenario2_rights3_peek1_recv2.cfg) | 6,987,879 | 80 | No violation; exhaustive completion |
| [MC_hunt_scenario2_rights3_peek2_recv0.cfg](MC_hunt_scenario2_rights3_peek2_recv0.cfg) | 2,613,962 | 77 | No violation; exhaustive completion |
| [MC_hunt_scenario3.cfg](MC_hunt_scenario3.cfg) | 5,790,772 | 61 | No reported violation; 30-minute budget ended |
| [MC_hunt_scenario3_layout_full_peek0_recv1.cfg](MC_hunt_scenario3_layout_full_peek0_recv1.cfg) | 16,536 | 53 | No violation; exhaustive completion |
| [MC_hunt_scenario3_layout_full_peek1_recv0.cfg](MC_hunt_scenario3_layout_full_peek1_recv0.cfg) | 36,723 | 56 | No violation; exhaustive completion |
| [MC_hunt_scenario3_layouts_capacity.cfg](MC_hunt_scenario3_layouts_capacity.cfg) | 546,254 | 70 | No violation; exhaustive completion |
| [MC_hunt_scenario3_layouts_fault.cfg](MC_hunt_scenario3_layouts_fault.cfg) | 28,908 | 52 | No violation; exhaustive completion |
| [MC_hunt_scenario4.cfg](MC_hunt_scenario4.cfg) | 9,192,741 | 71 | No reported violation; 30-minute budget ended |
| [MC_hunt_scenario4_peek0_recv2.cfg](MC_hunt_scenario4_peek0_recv2.cfg) | 125,158 | 59 | No violation; exhaustive completion |
| [MC_hunt_scenario4_rights3_peek1_recv1.cfg](MC_hunt_scenario4_rights3_peek1_recv1.cfg) | 2,503,446 | 75 | No violation; exhaustive completion |

Each BFS had a 30-minute maximum. No configuration, invariant, transition or
state-space bound was changed during validation. Every no-violation BFS reached at least depth 51, above the workflow's depth-25 threshold. No simulation follow-up was required or run. The execution ledger records each decision.

## Remaining scope limitations

The [spec-generation review](review-specgen.md) remains NEEDS_IMPROVEMENT:
`MC.cfg` excludes every PEEK execution. Four trace classes exercise PEEK,
and case 15 has three successive calls on one thread beyond its two attempt
slots. Hunting results must retain their own bounds and completion limits.

Cleanup liveness configurations were not run in this validation invocation.
The terminal trace checks and operation-owner safety checks do not establish
the separate fairness-based `BoundedCleanupProgress` property.

The latest competition fixtures have 3/936 and 7/899 strict cross-thread overlaps.
Their whole-trace structural bounds are only 30/936 and 32/899, below the
unchanged 20% requirement. [The independent audit](output/validation-20261010T015405Z/overlap-bound-audit.json)
confirms sender events lie outside the receiver window. No timestamps or events
were changed, and the latest batch was not promoted. Full-pipeline completion
and the later staged reviews remain with the receiving controller.
