# Harness and trace adoption audit

Phase 2 only, source 53ba7ee567468ea7971dad4faccef13c6cb35dc2. The supplied instrumentation patch, Python harness and scripts are preserved. They are usable starting assets, but need the adaptations below before the launcher-owned harness phase can produce fresh evidence. This audit supplements, and limits claims in, ../spec/instrumentation-spec.md and ../harness/INSTRUMENTATION.md.

## Fresh static evidence

[static-checks.json](static-checks.json) records the exact commands and outcomes. The 1002-line patch applies to all 11 affected pristine pinned files in an isolated temporary directory. Every patched file byte-matches the corresponding historical harness/build/nvflare_src file; all 11 parse as Python. Six harness Python files parse and six shell scripts pass bash -n. These checks do not execute scenarios, validate traces or establish semantic transparency.

The old reports of 393 targeted tests passing with hooks disabled/enabled-as-no-op and the broad baseline comparison are historical only. The harness transcript shows an initial seven-test failure from supplying the wrong client_name hook argument, then correction to pass objects; the adopted patch includes that correction. A no-op hook comparison does not test behavior with tracing and its locks active.

## Semantic limits requiring Phase 2.5 decisions

| Area | Observed behavior / evidence | Required treatment |
|---|---|---|
| Trace lock | tla_hooks and nvf_tracer serialize event sections globally, including some product locks and blocking calls. Patch reviewed in full. | Describe schedule restriction explicitly. Do not call tracing “observation only.” Minimize locking at independently observable boundaries; retain controls showing that injected synchronization does not implement the property being checked. |
| CP failure report and free | Real client_executor.py:648–679 sends REPORT synchronously (up to five seconds), then frees/pops. Fake network returns TIMEOUT and can defer report dispatch while trace lock is owned until after cleanup. | Split report send/handling/free where required by V04/V07. Record actual request result and delay. Historical trace proves a selected deferred schedule, not all report-before-free schedules. |
| SJ abort RPC | Stub returns immediate TIMEOUT; real abort waits up to one second. | Preserve send, reply/timeout and mark/latch ordering separately. An instantaneous stub timeout is not evidence of MC-E's real window. |
| CHECK/START waits | Fake admin transport normally waits up to 120 seconds for handlers instead of real 15/20-second budgets, with explicit hold/drop/fail policies overriding some cases. | Retain policy identity and actual effective timeout in provenance. Test ordinary deadline-triggered late requests independently of chosen gate schedules. |
| Sweeper | SweepBegin is emitted inside a global critical section spanning SweepEnd; mutating events cannot reproduce the modeled live-map failure under that lock. | Add observable begin/end windows without suppressing the target interleaving, or label SE-1 as uncovered. Include client-map and stale-token cases, not only engine.run_processes. |
| CP death | client_crash force-stops fake leaders/descendants. Model also clears them immediately. | This assumes the desired cleanup and bypasses CL-4/CL-6. Do not use it to claim parent-death liveness. Real cooperative watchdog/bootstrap route needs separate evidence. |
| Fake children | FakeSJ/FakeCJ omit OS process group, rc file, worker bootstrap, status retry and parent monitor. FakeSJ does not implement HANDLE_DEAD_JOB effects. | Trace suite is primarily real lifecycle methods with process/network edges stubbed. Real local deployment confirmation remains necessary, especially F10/F11/F17/E6/E7. |
| Resource manager | Harness ListResourceManager provides discrete units; default provisioned manager is GPUResourceManager with virtual memory bookkeeping. | Retain list-unit scope; F8/F13/F14 and supported GPU configuration need separate numeric/binding evidence, without GPU computation. Need=0 does not prove positive-resource defaults. |
| Heartbeat | Harness directly takes a snapshot and calls _sync_client_jobs under trace lock; omits full client_heartbeat authentication, transport and session-generation transitions. | Do not claim re-registration, disabled-client auth or delayed snapshot coverage from this. Add/route V06 checks explicitly. |
| Derived resource observations | alloc and starting ownership are tracked in tracer side tables driven by event names; unit values originate in calls, but owner transitions are not independent product snapshots. | Identify derived fields in mapping. Cross-check against actual pool, reservation token, run entry and launch arguments; do not treat agreement of a side table and model as independent conservation evidence. |
| Store/status observations | Persisted status and real list-pool counts are substantive checks. Deleted jobs retain ghost counters/tags; runAborted can use a cached job object after tracking removal. | Update mapping documentation to distinguish persistent, cached and absent data. Existing prose suggesting false for absent marker/ready-job sampling is not identical to tracer behavior. |
| Hidden state | No direct observations of message multiset, live OS group use, wfc retained reference, termination counters or full client registry. | These are model-inferred or projected. A matching trace cannot establish their implementation conformance. |
| Errors | Scenario process exit and error reports are separate from NDJSON fields; a trace error annotation can still match state semantics. | Require scenario success (or explicit expected-error assertion), nonempty complete trace, and replay result; do not accept only a PASS substring. |

## Replay/non-vacuity audit

Trace.cfg enables TraceMatched plus structural checks; ValidatePostState contains actual field equations, not TRUE. The cursor and fairness obligation require consumption of the nonempty accepted event sequence. That is useful finite-trace compatibility evidence.

However, TraceJson filters non-config/non-event records, takes the first config rather than verifying exactly one, and uses trace sequence fields as aliases without independently proving input contiguity. Unknown action names within retained events should fail replay, but silently filtered records can conceal missing coverage. Fresh input validation should check a single schema/config, event count, contiguous sequence, recognized event names, required fields, job/site mappings, and that no unexpected record was discarded. Keep intentionally unobserved model stuttering explicit.

Original Phase 2 ran four corruptions (wrong status, free units, publish/latch ordering and pending outcomes) on traces synthesized from the model. Those establish selected nontrivial predicates on synthetic data. Repeat targeted negative controls against fresh implementation traces, including truncation/filtered-record cases; they do not turn replay into full conformance.

## Runnable handoff requirements

The launcher-assigned harness phase must:

1. Adapt only working-copy commands to the current source, Python/runtime and output paths; verify imports resolve to a clean instrumented build of the pin. Do not run copied /home/experiment, obsolete tlc-scratch or transient /tmp paths. Do not trust the historical build as fresh.
2. Retain the supplied patch and scenarios where useful; repair instrumentation/harness semantics in that phase and keep model changes in the normal validation/repair loop. Preserve before/after diffs and classify changes as timing control, fault injection, projection or semantic correction.
3. Rerun all 30 default scenarios below, per the user's override of BYOM's default trace reuse. Write newly generated traces to ../traces, with runtime/source/patch/harness hashes, commands, timestamps, scenario policies and exit codes. Existing 30 official traces are quarantined at supplied-traces; historical stress/random files elsewhere are also historical.
4. Repair shell result propagation: run.sh currently suppresses validate.sh failure using “|| true”; validate.sh recognizes PASS from log text without requiring successful process exit. Keep scenario generation and replay verdicts distinct and make failures visible to the launcher.
5. Run meaningful passing controls and scoped no-op/instrumentation regressions. Historical 30/30, 60 stress traces and 34 later random seeds are not fresh results. Extra repeated searches need a coverage reason, not a claim of unbounded correctness.
6. Leave independent reproduction scripts under evidence/ or confirmation output separate from model traces and scenario stubs. Use public APIs and real local deployment where feasible for confirmation; label remaining stubs and timing/fault controls.

Default scenarios read from actual harness/run.sh (the older “29” prose is stale):

- normal_two_jobs; abort_running_and_queued; check_timeout_backoff_expiry; lossy_check_cant_schedule.
- start_failures; client_failure_and_sj_crash; client_crash_sweep; outcome_deadline_hb_cleanup; disable_client_outcome_wait.
- delete_held_job_kills_runner; delete_during_scan; abort_during_deploy; failrun_during_start; failrun_during_start_dup_abort.
- refresh_rmw_revert; running_after_terminal; start_timeout_late_start; concurrent_jobs_contention; expiry_before_start.
- disable_between_schedule_and_deploy; abort_before_checks; lost_report_heartbeat; double_abort_terminate.
- random_mix_s1 through random_mix_s6; wfc_stale_read_after_pop.

unsupported_app_missing is an opt-in defensive case, deliberately outside Trace.cfg's ordinary EnableUnsupported=FALSE envelope. It must not be silently added to supported-defect counts.

## Scope of adoption

The source-derived instrumentation map is present and usable to continue work, with the discrepancies above made explicit. No fresh runtime trace was produced or accepted in Phase 2. Path repair and rerun belong to the next harness invocation, followed by replay, seed fidelity, convergence, hunting and confirmation through the launcher.

