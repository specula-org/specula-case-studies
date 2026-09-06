# Bug Report — vsr-rs

## Summary

- Revision: `3ac0104a567092139534c9022205d02281a2da41`.
- Scenarios tested: **0 targeted protocol scenarios**, as selected by the modeling brief; **1 baseline hunting profile**, run once with BFS.
- Model-checking bugs found: **0**. No Case A/B/C counterexamples or spec/invariant fixes were required.
- Configs run: `MC.cfg` for convergence; `MC_hunt_baseline.cfg` for post-convergence hunting. All input spec/config bounds remain unchanged.
- All **4 supplied implementation traces / 186 events** matched the complete trace contract. The workflow converged in **1 round** within its prescribed time budget.
- **Coverage limitation:** the broader `MC.cfg` search stopped at its 30-minute budget with a large remaining queue. TLC reported a complete baseline hunting graph within its original finite constraints. Neither result is a general protocol proof, an example-integration validation, or a liveness result.
- The five priority maintainer candidates remain independent Phase 4 handoffs. The empty [findings.json](findings.json) covers MC findings only; downstream confirmation must also consume [modeling-brief.md](../modeling-brief.md).

## Trace validation and convergence

Phase 0 verified all 37 retained harness-manifest entries and exact adoption of all three harness modules in the instrumented checkout. Independent completion records matched 163 native callbacks across 186 total events. No harness regeneration was needed. `Trace.cfg` enables `TraceMatched`; all 19 event wrappers compare complete replica/client/owner state, the network multiset, and exact drained outputs. No comparison field, guard, invariant, or fairness condition was relaxed.

The session did not expose TLA MCP endpoints. [run_trace_round.py](output/run_trace_round.py) invokes the installed `ParallelTraceValidationHandler` directly and only adds raw-log retention. All four traces passed against the supplied `Trace.cfg`, including its seven invariants and `TraceMatched`:

| Implementation trace | Events | TLC generated / distinct states | Result |
|---|---:|---:|---|
| normal_retry_duplicates | 54 | 55 / 54 | Matched; [log](output/trace-round1/normal_retry_duplicates.log) |
| state_transfer_reordering | 49 | 50 / 49 | Matched; [log](output/trace-round1/state_transfer_reordering.log) |
| view_change_after_crash | 36 | 37 / 36 | Matched; [log](output/trace-round1/view_change_after_crash.log) |
| recovery_stale_responses | 47 | 48 / 47 | Matched; [log](output/trace-round1/recovery_stale_responses.log) |

The extra generated state is the terminal replay stutter; distinct-state counts equal the supplied event counts. [Parallel result](output/trace-round1/result.json) and [input manifest](output/validation-input-manifest.json) retain run identity. Generation-time synthetic fixtures were not counted as implementation traces. The installed `clean_traces` handler was called after replay and found zero generated diagnostic files to remove; captured traces and prior evidence were preserved.

The subsequent `MC.cfg` run used only its existing five standard safety checks plus `MCTypeOK` and `DurableViewConsistent`. No specification or invariant modification was needed, so the workflow's convergence decision did not require another trace round. This is convergence within the prescribed 30-minute checking window; exhaustive verification of `MC.cfg` remains **LIMITED**.

## Model-checking coverage

| Purpose / config | Mode and budget | Generated states | Distinct states discovered | Queue / depth | Result |
|---|---|---:|---:|---|---|
| Convergence: `MC.cfg` | BFS, 30 minutes | 964,252,906* | 219,874,256* | 160,519,720 queued*; last reported BFS layer 14 | No violation reported; watchdog exit 124, non-exhaustive |
| Hunting: `MC_hunt_baseline.cfg` | BFS, 30-minute budget; natural completion in 20 min 10 s | 646,763,167 | 74,772,829 | 0 queued; complete graph depth 27 | Completed, exit 0; no violations found |

\* Convergence counters are the **last progress sample**, at 2026-09-05 19:22:24 UTC, before the watchdog ended the run at approximately 19:23:17 UTC. TLC emitted no final statistics on termination. They are not exact final totals; discovered states include queued states that had not been expanded. Layer 14 is not the diameter of a completed graph. The [launcher log](output/MC_round1_bfs_retry.launcher.log) explicitly records the timeout; this expected budget exit is not a system-under-test deadlock.

The hunting graph completed with depth **27 > 25**. The workflow therefore makes simulation optional; no simulation was run. No bound was reduced to achieve this depth. All TLC output is retained: [convergence](output/MC_round1_bfs_retry.out), [hunting](output/MC_hunt_baseline_bfs.out), and their separate launcher logs/exit records. An initial background launch exited before parsing/exploration and produced no valid check; its [partial output](output/MC_round1_bfs.out) is retained and excluded from the coverage counts. A foreground process session with the same resource guard resolved execution retention.

“Complete” above means TLC reported an exhausted constrained graph using its fingerprint-based state set. Its hunting log estimates the probability of missed states from fingerprint collisions as **0.0023** by the optimistic calculation and **2.4×10⁻⁴** based on actual fingerprints. These are TLC's estimates, not a collision-free proof or independently calibrated confidence levels. [Machine-readable results](output/validation-results.json) distinguish final hunting totals from convergence progress samples; the [artifact manifest](output/validation-artifact-manifest.json) binds retained files by SHA-256.

Both valid runs used TLC `2026.09.04.170753`, revision `b123b22`, 32 explicit workers, and the Specula resource guard within the configured 128-GiB / 32-worker run budget. Convergence used 24-GiB heap plus 72-GiB off-heap; hunting used 12-GiB heap plus 36-GiB off-heap. Exact TLC seeds/fingerprint parameters are in each log's second line. The wrapper supplied its 30-minute watchdog; an outer `timeout --kill-after=15s 31m` bounded wrapper failure. State spill used the workspace volume and was cleaned by the wrapper after each run.

Reproduction commands, from this `spec/` directory with this run's `SPECULA_ROOT` and resource-budget environment:

```sh
timeout 6m "$SPECULA_ROOT/tools/trace_debugger/.venv/bin/python" output/run_trace_round.py trace-replay-new
TLC_STATE_DIR="$PWD/output/tlc-state" timeout --kill-after=15s 31m "$SPECULA_ROOT/scripts/infra/run_model_check.sh" -s MC.tla -c MC.cfg -m 24G -M 72G -w 32 -t 30 -o output/MC_replay.out -j output/MC_replay.json
TLC_STATE_DIR="$PWD/output/tlc-state" timeout --kill-after=15s 31m "$SPECULA_ROOT/scripts/infra/run_model_check.sh" -s MC.tla -c MC_hunt_baseline.cfg -m 12G -M 36G -w 32 -t 30 -o output/MC_hunt_replay.out -j output/MC_hunt_replay.json
```

These repeat the configuration and duration; TLC selects a new seed/fingerprint polynomial unless its direct invocation is supplied the retained parameters. Do not reuse output names when preserving an earlier run.

## Not Reproduced

“Not modeled” below preserves existing prior-phase observations and their independent confirmation routes; it does not retract them or mean that they were tested and passed here. Source anchors refer to the uninstrumented pinned revision.

| Scenario / candidate | Config / states | Result and retained route |
|---|---|---|
| Baseline replication, retry, and reply safety | `MC_hunt_baseline.cfg`; 74,772,829 distinct | No violations in the completed finite graph. No crashes; one idle is insufficient to trigger a fresh timeout-driven view change. |
| EX-START — old identity selects `Replica::new` after view-file read/parse failure | Not modeled | Independent Phase 4 startup and conflicting-slot API verification retained. `examples/kvstore/main.rs:683-701`; `lib.rs:14-21,646-694,716-730,737-765`. Subsequent persistence must succeed before outputs are released. |
| LIB-SINGLE — accepted self-quorum never triggers commit | Not modeled; baseline assumes `N >= 2` | Independent singleton progress/support-or-rejection regression retained. `lib.rs:74-98,682-694,737-765`; `simulator/lib.rs:258-259`. The model's restriction does not declare singleton unsupported by the API. |
| EX-WRITER — blocking write stalls other destinations | Not modeled | Independent unchanged-sender socket test retained. `examples/kvstore/main.rs:31-35,342-392`. Post-error reconnect backoff in retained #9/#10 evidence does not absorb an unreturned blocking write. |
| EX-FSYNC — rename without parent-directory sync | Not modeled | Independent filesystem-contract, syscall-order, and crash-harness route retained. `examples/kvstore/main.rs:569-579,749-750`. System/filesystem-crash consequences remain conditional; process-only crashes do not establish them. |
| EX-NONCE — wall-clock recovery token freshness | Not modeled | Independent allocator/clock audit and repeated-clock test retained. `examples/kvstore/main.rs:692-697`; `lib.rs:505-510,1166-1193`. A stale-state safety claim additionally needs an actual stale-response path through the example's TCP/FIFO/reconnect behavior. Separate from known client-ID reuse. |
| AS-01 — incremental oracle skips previously checked history | Baseline uses a full-history observer; simulator oracle not tested | Independent oracle mutation test retained. `simulator/properties.rs:89,185,233,277,324-331`. Assurance gap, not a library bug. |
| AS-02 — batch observation omits transient states | Model observes every atomic handler; simulator batching not tested | Independent transient-mutation/per-handler oracle route retained. `simulator/lib.rs:711-719,907-927`. Assurance gap, not a library bug. |
| AS-03 — replies bypass simulated fault transport | Replies use the model/harness fault network; stock simulator not tested | Independent reply-loss/delay/duplication and client-restart test route retained. `simulator/lib.rs:950-961`. Assurance gap, not a library bug. |
| Other retained handoffs | Not targeted | EX-PORT, EX-WIRE, API-CONFIG, AS-04/05/06, AS-LEAN, and AS-TUI remain in the modeling brief; no new disposition is assigned by this MC pass. |

[Candidate audit](output/phase0-candidate-audit.md) preserves exact duplicate filtering from the retained #9/#10 snapshot, pinned anchors, and confirmation routes. No live GitHub status or new Phase 4 confirmation is claimed. No simulator reproduction occurred in this validation phase, so no new simulator regression seed or source commit is asserted.

## Scope and changes

The baseline assumes authentic messages, fixed membership, one owner call per step, successful durable-view publication before outputs, recovery for every reused replica identity, fresh recovery nonces and client identities, and one outstanding request per client. Application semantics are the actual integer accumulator used by the harness. The finite configs retain their original request/idle/retry/crash/loss/duplication budgets and message/view constraints. See [brief coverage](brief-coverage.md) for each exact bound.

The four supplied traces cover memberships 3/4 and views 0/1. Recovery is observed only at view 0 with fresh nonces; the corpus supplies no combined recovery/view-change or membership-2 witness. Event-type coverage is not branch or behavior completeness. `DurableViewConsistent` is publication bookkeeping under an assumption, not evidence of filesystem durability. `ClientProgress` remains disabled because the finite environment has no assumption-satisfying stabilization/fair-delivery witness.

Static source correspondence audits found no concrete mismatch in the reviewed [normal/client/state-transfer paths](output/fidelity-normal-audit.md) or [view-change/recovery/timer paths](output/fidelity-recovery-audit.md). They supplement observed traces and finite checking; they are not equivalence proofs. Source instrumentation, protocol specifications, configs, harness, traces, and the original handoffs were preserved. Only validation records and helper artifacts were added; [changelog.md](changelog.md) records the complete iteration history.
