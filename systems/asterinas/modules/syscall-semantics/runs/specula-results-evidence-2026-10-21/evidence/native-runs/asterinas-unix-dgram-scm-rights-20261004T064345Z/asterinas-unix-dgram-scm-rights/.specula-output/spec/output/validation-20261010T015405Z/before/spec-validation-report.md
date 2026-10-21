# Specification validation result

Attempt `validation-20261006T023358Z` remains incomplete at Phase 2. All 23
supplied traces passed the unchanged `Trace.cfg`. The original-bound
`MC.cfg` ran for its prescribed 30 minutes without a reported violation,
then reached its budget with states still queued. Convergence is
unestablished, and all 27 hunting configurations remain unexecuted in this
invocation. The harness's separate overlap qualification remains incomplete.

## Inputs and trace validation

The source pin is `0c60537098f4c2949ad2d382aaf499de72263d76`, with committed
tree `4693fdec88cd7da14bed4f1541eba593f123059c`. The checkout contains the
existing instrumentation. This invocation changed only validation records.
The receiver held the shared heavy-stage and run locks. Initial inputs and
previous reports are retained in [the attempt directory](output/validation-20261006T023358Z/).

The [input audit](output/validation-20261006T023358Z/phase0-audit.json) found
every required file, 27 hunting configurations, all 34 mapped action names,
and all 34 mandatory receiver fields. `Trace.cfg` enables `TraceMatched`;
`ValidatePostState` invokes full base actions and compares the captured
fields. The canonical traces still match harness attempt
`20261005T220019Z`, which was accepted under the earlier controller decision.

All 23 canonical traces passed again in this invocation. The initial direct
replay generated 54 states. The required batch-validation tool ran in singleton
batches because each invocation uses a fixed 4 GiB heap. Host MemAvailable
exceeded 6 GiB immediately before each launch. No spec change, invariant
revision, regression, or witness fallback was needed. The
[MCP results](output/validation-20261006T023358Z/round1-trace-mcp.json) retain
every outcome. Trace cleanup found no generated files to remove.

The [prior-replay audit](output/validation-20261006T023358Z/attributed-prior-replay-audit.json)
also verified the saved full logs and input hashes for the canonical and fresh
batches. Each of those 46 earlier replays had nonzero initial states and
completed without errors. Those earlier executions retain their own attempt
identities; only the 23 canonical traces were replayed afresh here.

## Original-bound model checking

Task `4fead067c67b4df8b4f627a482eaddc3` ran `MC.tla` with `MC.cfg`,
two workers, a 3 GiB heap, 512 MiB off-heap memory, and a 30-minute budget.
The starting MemAvailable was 8,849,816 kB. The configuration retains two
receiver threads, two attempt slots per thread, four rights, all 14 control
layouts, two PEEK and two ordinary-receive attempts, the configured fault
budgets, and at least 16 initially free FD slots.

The enabled checks were `MCTypeOK`, `OwnershipConserved`, `QueueStructure`,
and `PublicationStructure`. TLC initialized with one state and exited 124
at the configured limit, at 2026-10-06 11:05:54 Asia/Shanghai. The full log
contains no reported invariant violation, evaluation error, or memory error.
It contains no exhaustive-completion result.

The last progress record, at 11:04:57 Asia/Shanghai, reported:

| Measurement | Last reported value |
| --- | ---: |
| Search depth | 32 |
| States generated | 28,939,128 |
| Distinct states found | 12,670,700 |
| States left on the queue | 3,248,457 |

These are last reported counters, not final totals. Previous searches of the
same configuration are retained separately; their counts are not added to
this search. A normal budget ending is not an implementation failure and
does not establish exhaustive coverage.

The [TLC log](output/validation-20261006T023358Z/MC-round1.log),
[launcher log](output/validation-20261006T023358Z/MC-round1-launcher.log),
[task result](output/validation-20261006T023358Z/MC-round1-result.json), and
[final evidence record](output/validation-20261006T023358Z/final-result.json)
retain the executable command and outcome. The wrapper removed its temporary
checkpoint directory. No counterexample was produced, so no Case A/B/C
classification or corresponding model/invariant fix was made.

## Harness qualification and retained contract

Fresh harness attempt `20261006T022240Z` is still
`INCOMPLETE_OVERLAP_REQUIREMENT`. Its production traces replay successfully,
but neither competition fixture meets the unmodified 20% cross-thread overlap
criterion. This invocation did not promote that batch or declare Phase 2.5
complete.

| Fresh competition fixture | Strict overlaps | Whole-trace fraction | Structural upper bound |
| --- | ---: | ---: | ---: |
| Two ordinary receivers, case 17 | 2/936 | 0.214% | 3.205% |
| PEEK and ordinary receive, case 18 | 15/2384 | 0.629% | 2.097% |

The [independent overlap audit](output/validation-20261006T023358Z/overlap-bound-audit.json)
confirmed that setup and cleanup lie outside the receiver window. With these
event inventories, two internally nonoverlapping receiver streams have at most
`n + m - 1` strict intersections. Scheduling alone cannot reach 20%.
No timestamps, event inventory, or acceptance threshold were changed.
[Harness results](../harness/RESULTS.md) retain the successful build, clock
qualification, Linux controls, and the unresolved criterion.

Source readback confirmed the modeled ownership boundaries: sender capture
owns references before enqueue; ordinary receive moves rights while PEEK
clones them under the queue lock; each file-table insertion ends before
number copying; temporary and removed-FD owners remain explicit until their
actual drops. The source anchors are in `base.tla` and
[instrumentation-spec.md](instrumentation-spec.md).

The existing AST-32 installation/publication lead and AST-36 payload-fault
control remain visible in their separate compatibility configurations and
prior harness observations. They were not reclassified as new findings.
No confirmation, severity-classification, repair, or shared-catalog phase
was executed here.

## Phase boundary and remaining work

The [validation-workflow skill](/home/chin39/.codex/plugins/cache/specula/specula-codex/1.2.0/skills/validation-workflow/SKILL.md)
delegates to its [guide](/home/chin39/.codex/plugins/cache/specula/specula-codex/1.2.0/skills/validation-workflow/guide.md),
which specifies `MC.cfg` only for Phase 2 and requires:
“Complete each phase fully before switching.” It permits hunting after
convergence. The original configuration has not completed, so the current
attempt cannot enter hunting under that unmodified workflow.

The [recorded controller decision](CONTROLLER-DECISION-2026-10-06-phase2.md)
instead permits convergence over completing companion configurations.
That substitution was not applied because the current request explicitly
requires the unmodified workflow. The receiver must reconcile that scope
decision before a subsequent invocation can use the companion set.
The original-bound search must remain marked incomplete either way.

The [hunting inventory](output/validation-20261006T023358Z/hunting-plan.json)
records all 27 configurations as `NOT_RUN` in this invocation. Cleanup
liveness was also not run. `bug-report.md` and `findings.json` were not
emitted before their hunting prerequisite. In particular, an empty findings
list would not describe a completed zero-finding hunt. No new candidate was
established in the work performed.

The [final input check](output/validation-20261006T023358Z/final-input-check.json)
confirms that all 109 hashed source, harness, model, configuration, and
canonical-trace inputs are unchanged. The TLC task has exited, and no job
launched by this invocation remains active. [validation-status.json](validation-status.json)
and [changelog.md](changelog.md) record the current result.
