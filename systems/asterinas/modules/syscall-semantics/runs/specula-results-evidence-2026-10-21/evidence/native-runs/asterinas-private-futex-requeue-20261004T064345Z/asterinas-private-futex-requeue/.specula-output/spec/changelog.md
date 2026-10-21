# Validation changelog

## Phase 0 - Initialization

- The source HEAD and tree match the preparation pins. The harness exists, but Phase 2.5 stopped at the memory reserve gate and produced no implementation traces. Generation fixtures are not implementation evidence.
- Trace.cfg enables TraceMatched and the Category B reachability sentinel TraceIncomplete. ValidatePostState compares complete action-specific post-state records. A replay requires a consumed-trace witness, not a generic nonzero TLC exit.
- The receiving controller holds heavy.lock. Recheck the policy reserve before rebuilding and collecting real SMP traces.
- [fix] The normalizer omitted the required `t` argument from TimerSetClock and PauseTimeoutClock. Copy the already captured and origin-adjusted clock sample into `args.t`, as required by instrumentation-spec.md and Trace.tla. The source captures remain at timer.rs clock reads. This is a decoder correction identified before collection, not a validated trace result.
- The Phase 0 retry built OSDK, the C driver, the instrumented kernel and the ISO. The reserve gate before cargo osdk run is waiting for 10 GiB MemAvailable. Evidence is in harness/logs/run-validation-phase0.log and harness/logs/images-1.sha256.

## Attempt 1 result

Validation is blocked in Phase 0 and has not converged. The Phase 0 retry exited
with status 1 after the 1,200-second reserve wait. All 61 post-build samples were
below 10,485,760 KiB. They ranged from 9,301,136 to 10,115,804 KiB. The diagnostic
was `The kernel build reserve was unavailable during the bounded wait.`

No guest ran and no implementation trace was collected. Trace validation,
MC.cfg convergence checking, hunting, and Linux runtime calibration are
`NOT_RUN`. No Case A/B/C counterexample was analyzed. All base, MC, Trace and
hunting inputs retain their initial hashes. The completed attempt has no
running harness container or unobserved subprocess.

`validation-status.json` records the blocking gate and evidence paths.
`bug-report.md` and `findings.json` are pending the workflow's convergence and
hunting prerequisites. An empty findings index would misrepresent this
unexecuted campaign as completed bug hunting. The receiver must keep the phase
gate closed and resume real trace collection when the resource policy is met.

## Phase 0 - Resume

- Revalidated unchanged model, source, instrumentation and built image hashes. The controller still owns heavy.lock.
- [fix] The generated ISO contains only a UEFI boot entry. Supply the image-provided OVMF firmware. The default-BIOS attempt timed out without test entry and is retained as an uncovered boot attempt.
- [fix] Enable earlycon in the boot command line. Without it, the kernel disables the serial sink used by the probes (kernel/core/comps/cmdline/src/early.rs:45-48, ostd/src/arch/x86/serial.rs:110-113). The UEFI control without earlycon shut down with encoded success 33 but supplied no trace evidence.
- [fix] run.sh --reuse-kernel verifies the source diff, generated modules, harness hashes and built image hashes before using the compiled kernel. It repackages boot arguments and launches bounded SMP=2 guests directly. Fresh kernel compilation retains the 10 GiB reserve gate. This resumes completed compilation without invoking cargo osdk run.

## Round 1 - Trace Validation

- All 18 implementation traces have complete replay witnesses. Each stream cursor equals its length plus one. All WAIT/control calls completed and timer batch ownership drained. The only invariant reported was the deliberate TraceIncomplete sentinel. Detailed logs, final states and counts are under spec/output/trace-*.
- The batch tool classifies the positive reachability sentinel as an error. Individual logs and structured final-state inspection establish the replay verdict. Calls were serialized to respect the lane memory limit.
- The concurrency quality requirement remains NOT_ESTABLISHED: maximum raw overlap is 5/1309 (0.382 percent), and no same-CPU overlap or cross-CPU TSC comparability proof was captured. This is an independent evidence-quality failure, not a passed gate.

## Round 1 - Model Checking

- The first MC.cfg launch was rejected before Java started because an empty legacy auto-budget ledger conflicted with the current durable 4 GiB / 2-worker policy. Under the ledger lock, verified no live leases, archived the old record, and narrowed it to the current policy. No admission logic or policy file changed. The replacement MC.cfg task is a65730fff9a54db19f415739d1471a2d with 2 GiB heap, 1 GiB off-heap, 2 workers and a 30-minute limit.

- [fix-harness] The Linux control now checks fgets failure when sampling each waiter wchan. Its strict C build and six finite runtime cases passed. Actual runtime identity is Linux 7.2.8. The pinned v6.16.5 source is a distinct reference, and Linux bucket identity remains unobserved.

- MC.cfg BFS reached its 30-minute budget without an invariant report. The last logged sample had depth 6, 134,173,598 generated states, 30,668,839 distinct states and 30,077,421 queued states. This is incomplete exploration. The unchanged MC.cfg is also exercised with depth-100 simulation because the BFS prefix is shallow.

- The unchanged MC.cfg depth-100 simulation also reached its 30-minute budget without an invariant report. The last sample recorded 28,475,054 states checked and 114,986 random traces. Trace replay and these bounded core checks required no model or invariant change. The suite is stable for the bounded campaign. This does not establish exhaustive state-space convergence, and the concurrency quality gate remains unpassed.

## Bug hunting

- Proceed with the prepared scenario configurations on the unchanged reference model. Preserve BFS depth/frontier and simulation coverage separately for every configuration.

- [bug] RequeueWakeQuota: MC_hunt_s2_zero_wake.cfg violates the raw zero wake quota in 20 states. Dispatch converts zero to one, then FutexWakeRetain records one accepted wake and removal (Case C). The unchanged source and actual attempt 16 corroborate the path. Linux control case 4 returns zero and leaves both waiters for a later source wake.

## Validation attempt 3 - Phase 0 (fresh context, 2026-10-09)

- The user rerouted only the validate phase to Claude Opus 5.5 after the Codex policy block. This attempt starts from a fresh context and re-runs every phase on the unchanged inputs. Entries above are kept as the earlier attempts' history.
- The source is at the pinned commit and tree with the instrumentation diff applied. base.tla, MC.tla, Trace.tla, Trace.cfg and instrumentation-spec.md match the round-2 installed hashes. All 71 files recorded in spec/output/validated-inputs.json, including the 18 traces and harness logs, are unchanged.
- Trace.cfg keeps PROPERTIES TraceMatched and the TraceIncomplete sentinel. ValidatePostState compares complete action-specific records, not TRUE.
- The trace MCP tools are not available in this session. scripts/run_trace_validation.sh runs each replay through Specula's budgeted TLC wrapper with the trace path in IOEnv.JSON, one process at a time, after the 6 GiB reclaimable-memory gate. scripts/trace_verdicts.py accepts a replay only when the sole report is TraceIncomplete and the witness cursor equals every stream length plus one.

## Round 2 - Trace Validation

- All 18 traces have complete replay witnesses on the unchanged spec. No spec, trace or harness change was needed. Results are in spec/output/round2-trace-results.json.
- Cases 13 (F09) and 14 (F10) first stopped after 3 seconds when TLC's periodic check reported TraceMatched violated on a dead interleaving, with 1,264 and 903 states still queued. That universal property fails on any stuck branch, so it does not disprove the existential replay. scripts/run_trace_reachability.sh reran both with the same Trace.cfg, budget and workers, adding only `-lncheck final`. Both then reached the TraceIncomplete witness with all cursors consumed (308,963 and 328,267 states generated).
- Case 13 replays the F09 history on the implementation model: the retained closed generation 3001 is moved by REQUEUE(1,1) while live generation 5001 stays on the source key.
- The Category B overlap requirement remains unmet, as recorded in harness/coverage.md (maximum raw overlap 0.382 percent, timeboxes normalized to conservative overlap). Replay success does not close that gap.

## Round 2 - Model Checking

- MC.cfg BFS (3 GiB heap, 1 GiB off-heap, 2 workers, 30 minutes) reported no invariant violation before its budget ended. It reached only depth 6, with 138,625,741 generated states, 32,032,634 distinct states and 31,433,627 queued. Free-mode admission branches into thousands of WAIT and control variants per step, so BFS cannot reach a completed WAIT. Log: spec/output/MC-round2-bfs.out.
- MC.cfg simulation at depth 100 (same budget) also reported no violation: 29,203,838 states checked over 117,692 traces with mean length 87. Log: spec/output/MC-round2-simulation.out.
- No Case A, B or C counterexample appeared, and neither the spec nor any invariant changed.

## Convergence

- Round 2 trace validation and model checking both passed without a spec change. The suite has converged on the round-2 installed model. This is bounded convergence: the MC.cfg BFS frontier is not exhausted.

## Bug hunting (attempt 3)

- Each hunting configuration ran BFS for up to 30 minutes with 3 GiB heap, 1 GiB off-heap and 2 workers. Configurations without a violation and with diameter at most 25 (MC_hunt_s1_mismatch, MC_hunt_completion) also ran a 30-minute simulation at depth 100. Outcomes are indexed in spec/output/tlc-runs-round2.json, with logs and JSON counterexamples in spec/output/hunt-round2/.
- [bug] FutexCleanupLock/FutexRemoveByWaker: MC_hunt_s3_owner.cfg violates ResourceAccountingBalance in 56 states (Case C, MC-1). A cross-bucket REQUEUE moves a timed waiter's entry after the waiter observes expiry but before cleanup. Cleanup searches only the saved original bucket (futex.rs:124), returns 0, and the closed entry stays in the destination bucket. Traces case-11 and case-13 show the same stranded state on SMP=2.
- [bug] FutexRequeueFinish: MC_hunt_s4_live_migration.cfg violates LiveMigrationExhaustion in 93 states (Case C, same root cause as MC-1). A later REQUEUE(1,1) spends its migration slot on the stranded entry and leaves a live waiter on the old key, as trace case-13 also shows.
- [bug] SysFutexControl/FutexItemWake: MC_hunt_s2_zero_wake.cfg violates RequeueWakeQuota in 20 states (Case C, MC-2). REQUEUE's wake count goes through the WAKE conversion that raises 0 to 1 (syscall/futex.rs:106,146-151). MC_hunt_s2_quotas.cfg fails the same clause on the same-bucket path in 19 states.
- [bug] FutexUpdateItemKey: MC_hunt_s2_zero_move_same_bucket.cfg violates RequeueMoveQuota in 22 states (Case C, MC-3). update_item_keys tests the quota after rekeying the first matching entry (futex.rs:500-511).
- [bug] SysFutexControlReturn: MC_hunt_s2_return_count.cfg (30 states) and MC_hunt_s2_same_address.cfg (24 states) violate RequeueReturnCount (Case C, MC-4). REQUEUE returns only accepted wakes (futex.rs:353-355,381), while Linux counts wakes plus requeues.
- No violation in MC_hunt_s1_mismatch, s1_registration, s2_unrelated_first, s2_wake_zero_control, s2_zero_move_cross_bucket or s3_same_bucket, all exhaustive. MC_hunt_s3_opposite (depth 84) and MC_hunt_completion (BFS depth 5 plus simulation) reached their 30-minute budgets without a violation.
- MC_residual_s2_quotas.cfg, MC_residual_s3_owner.cfg and MC_residual_s4_live_migration.cfg copy their hunting configurations without the already-classified oracle. All three completed exhaustively without a violation, so PermittedWaitResult and the core invariants hold in those scenarios.
- Persistent-findings lookups for every candidate returned no records (spec/output/persistent-lookup-attempt3.json). No spec or invariant changed during hunting.

## Result

Converged in Round 2 without a spec change, on the reviewed suite installed after spec-fix round 2 (trace validation 18/18, no MC.cfg violation within its budget). Bug hunting: 4 bugs found. MC-1 strands a completed waiter's entry after cross-bucket requeue, with a Linux-visible lost migration. MC-2, MC-3 and MC-4 are ordinary REQUEUE compatibility defects in the wake quota, same-bucket migration quota and return count. The Category B concurrency quality requirement remains unmet.
