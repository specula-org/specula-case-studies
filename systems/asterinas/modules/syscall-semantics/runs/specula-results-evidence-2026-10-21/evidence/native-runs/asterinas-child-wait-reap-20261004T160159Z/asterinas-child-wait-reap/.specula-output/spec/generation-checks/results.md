# Revision validation results

Revision r2 resolves only R4 from the r1 review. D1-capture, D2-fixtures,
D3-parse, and D5-records pass. D4-mc is **NOT RUN** because every TLA+ module
and configuration is byte-identical to r1, so no reachable behavior is
affected. The repair changes the documented capture timing and adds synthetic
evidence. It does not change an action, guard, invariant, or expected post-state.
The review finding was the only revision input. R1-R3 remain closed.

## Revision r2 criteria

Run the commands from the workspace root. Expanded Java commands, timestamps,
input hashes, exit codes, and outcomes are in [results.json](results.json) and
the per-run logs. The MC entries remain r1 results. SANY and all six synthetic
trace checks were rerun for r2, serially, with the supplied Java and jars,
`-Xmx3g`, `-XX:MaxDirectMemorySize=1g`, two TLC workers, metadata under
`states/`, and a 60-second limit per parse or trace check.

| Criterion | Status | Evidence | Command and log |
| --- | --- | --- | --- |
| D1-capture | PASS | The true branch saves the actual load but records post-state and end after callback return and runqueue guard release. The false branch still records under the guard before dequeue. Resume is exclusive to the dequeued path. Source excerpts and unchanged 41-action correspondence are retained. | Inspect [instrumentation-spec.md](../instrumentation-spec.md), mapping rows and branch timing. `python3 spec/generation-checks/audit_suite.py`; [audit.log](audit.log). |
| D2-fixtures | PASS | Park true/false, overlap, and sequential have complete witnesses. Corrupted is rejected by exhausted search. | `python3 spec/generation-checks/generate_fixtures.py` then `python3 spec/generation-checks/run_checks.py traces`; [true](trace-search-park-true.log), [false](trace-search-park-false.log), [overlap](trace-search-overlap.log), [sequential](trace-search-sequential.log), [corrupted](trace-search-corrupted.log). `python3 spec/generation-checks/audit_suite.py`; [witness audit](audit.log). |
| D3-parse | PASS | SANY parses and semantically checks `base.tla`, `MC.tla`, and `Trace.tla`. The audit also parses all ten configurations. | `python3 spec/generation-checks/run_checks.py parse`; [base](sany-base.log), [MC](sany-MC.log), [Trace](sany-Trace.log). |
| D4-mc | NOT RUN | No MC configuration is affected. The model, MC wrappers, trace wrapper, and all configurations are unchanged from the reviewed r1 suite. The prior time-limited liveness results remain incomplete. | No TLC MC command was needed or run. `python3 spec/generation-checks/audit_suite.py` verifies byte identity in [audit.log](audit.log). The driver now sets an explicit 1200-second limit for any future MC run. |
| D5-records | PASS | The R4-only inventory, coverage, results, and manifest record this correction and preserve prior evidence. | `python3 spec/generation-checks/audit_suite.py > spec/generation-checks/audit.log 2>&1` and `git diff --check`; [audit.log](audit.log), [revision inventory](../REVISION-2026-10-05-r2.md), [manifest](../generation-manifest.json). |

## R4 capture and witness evidence

The false hook follows the load at `ostd/src/task/scheduler/mod.rs:455`, before
the operations at lines 469-470. The true branch returns `DoNothing` at lines
455-456. The guard in `kernel/core/src/sched/sched_class/mod.rs:255-259` outlives
the callback. `reschedule` receives its return at
`ostd/src/task/scheduler/mod.rs:577-579` and returns at lines 581-584. The true
hook records post-state and end after that return at line 485, before the next
swap at `ostd/src/sync/wait.rs:273`. Saving the load result at line 274 and
deferring only this branch's post-state/end preserves both the actual atomic
result and the model's exact `{pc: "token", rqHeld: FALSE, observedToken: TRUE}`.
There is no dequeue on this path and no `ParkCurrentResume` event. A separate
release action is unnecessary for this existing projection: the waiter does
not change the token before the return, and other wakes leave a true token set.

The true fixture performs a failed `WakerConsumeToken`, a child wake swap,
then a true check over interval `[22,24]`. The false fixture checks at 16,
allows the wake swap at 21 while holding the guard, then dequeues over
`[22,24]`. Both overlap the notifier's unpark interval `[23,25]`. In the false
witness the unpark action follows dequeue/release, and resume follows unpark.
No spurious return is needed. Both fixtures subsequently consume the saved
wake permission, re-enqueue and reap, clear signal registration, close the
waiter, and return 41. The other parent call returns -10, and the notifier
finishes both its signal and queue paths. Closed queue residue is permitted
by the unchanged final-state contract.

The true fixture has 54 events and 55 witness states, ending with cursors
`T1=35, T2=7, child=15`. The false fixture has 56 events and 57 witness states,
ending with `T1=37, T2=7, child=15`. [audit.log](audit.log) checks every cursor,
final cleanup, numeric returns, and the decisive park/wake/dequeue ordering.
These are synthetic checker fixtures. They do not establish that the new
capture hooks have been implemented or exercised in a kernel.

The unchanged universal overlap diagnostic again reports
`Error: Temporal property TraceMatched was violated.` Its counterexample is
retained in [trace-universal-overlap.trace.json](trace-universal-overlap.trace.json).
It has the same R2 speculative-ordering explanation recorded below, rather
than being a candidate kernel behavior or a new R4 model error. Each accepted
existential search intentionally violates only `TraceNoCompleteMatch` after
the other invariants and complete final-state checks pass. No other invariant
or evaluation failure occurred.

## Historical r1 criteria

R1-R3 are implemented. C1, C2, C4, and C6 pass. C3 and C5 remain
**TIME-LIMITED** as verification results: every requested MC configuration was
rerun, but only the publication configuration exhausted its state graph.
No MC run reported an invariant or temporal-property violation. The unchanged
universal trace check reports the expected R2 `TraceMatched` counterexample.

These are local model/checker results for source
`0c60537098f4c2949ad2d382aaf499de72263d76`. The synthetic fixtures are not
implementation traces. Linux controls, guest execution, harness collection,
WR-SQ, WR-CF, and independent acceptance of the revised suite are **NOT RUN**.

The table below retains the r1 criteria. The full expanded Java
commands and per-run input hashes are retained in [results.json](results.json)
and the individual logs. Original r1 versions of refreshed parse, trace, and
audit records remain in Git at `49ee3c3`. The aggregate status does not turn a timeout into a
pass merely because every requested invocation was executed.

| Criterion | Status | Evidence | Command and log |
| --- | --- | --- | --- |
| C1-typeok | PASS | The wakeup search passes the former depth-18 abort and reaches recorded depth 49. Both complete synthetic witnesses contain numeric returns 41 and -10 under `TypeOK`. The publication search also completes through depth 77. | `python3 spec/generation-checks/run_checks.py MC_hunt_3_wakeup.cfg`; [wakeup log](MC_hunt_3_wakeup.log). `python3 spec/generation-checks/audit_suite.py`; [completed-call and definition audit](audit.log). |
| C2-trace-search | PASS | Overlap and sequential inputs have complete witnesses. The corrupted input is rejected after exhaustion. Accepted, rejected, and inconclusive outcomes are documented and implemented. | `python3 spec/generation-checks/generate_fixtures.py` then `python3 spec/generation-checks/run_checks.py traces`; [overlap](trace-search-overlap.log), [sequential](trace-search-sequential.log), [corrupted](trace-search-corrupted.log), [universal diagnostic](trace-universal-overlap.log). |
| C3-liveness | TIME-LIMITED | The general fair configuration admits WNOWAIT and repeated invocations through four total calls. It records 274,877 distinct states and depth 22 before its limit. The restricted two-consumer fixture still enables and executes both completion properties, recording 259,862 states and depth 49. Neither search completes. | `python3 spec/generation-checks/run_checks.py MC_hunt_3_blocking.cfg MC_hunt_3_wakeup.cfg`; [general log](MC_hunt_3_blocking.log), [restricted log](MC_hunt_3_wakeup.log). |
| C4-parse | PASS | All three modules parse and pass SANY semantic checks. `ModelConfig.parse` also accepts all ten cfg files. | `python3 spec/generation-checks/run_checks.py parse`; [base](sany-base.log), [MC](sany-MC.log), [Trace](sany-Trace.log). `python3 spec/generation-checks/audit_suite.py`; [cfg parser log](audit.log). |
| C5-mc | TIME-LIMITED | All seven configurations are rerun. Publication completes. The other six searches reach their limits with no reported violations. | Each command and log is listed in the MC table below. |
| C6-records | PASS | Coverage, instrumentation guidance, results, revision inventory, and manifest reflect these results. The 41-action correspondence, unchanged old configurations/actions, source pin, and read-only references are checked. | `python3 spec/generation-checks/audit_suite.py > spec/generation-checks/audit.log 2>&1` and `git diff --check`; [audit log](audit.log), [revision inventory](../REVISION-2026-10-05.md), [manifest](../generation-manifest.json). |

## R1 definitions and completion evidence

The changed definitions are `PendingRet` at `base.tla:19`, `NewCall` at
`base.tla:47` (return initialization at line 54), and `CallType` at
`base.tla:398` (return domain at line 410). `TypeOK` still applies `CallType`
to every generation. The marker is -9999, outside every permitted result
because `ChildPid` is positive and the other results are 0 and -10.
`SysWaitReturn` and `ApiOutcomeCorrect` are unchanged. `MC.tla` and the
existing trace wrappers inherit the marker. Their completion checks use
`pc = "done"`, so no independent string-return comparison needed replacement.
The instrumentation document explains the internal marker and preserves the
numeric `SysWaitReturn` post-state mapping.

The reviewer aborted at successful return 41 in state 18 of its wakeup
search. The same configuration now explores beyond that depth without an
evaluation error. The complete 28-state trace witnesses independently retain
completed calls with returns 41 and -10, after all enabled invariants and
exact event checks have been evaluated. [audit.log](audit.log) records these
final calls and verifies the existing definitions against the Git baseline.

## MC results from r1, not rerun in r2

All runs use the supplied Java 21 and both supplied jars, `-Xmx3g`,
`-XX:MaxDirectMemorySize=1g`, `-XX:+UseParallelGC`, two workers, and the
reviewer's off-heap fingerprint implementation. Each recorded r1 run had an explicit
`timeout --kill-after=10s 600s`. TLC processes run serially. Metadata lives
under `states/<run-name>/` in the workspace. `-deadlock` is retained from the
review command and disables deadlock checking, consistent with every old
configuration's `CHECK_DEADLOCK FALSE`. There are no state constraints or
reduced bounds. `base.cfg` remains the unbounded reference configuration and
is parsed rather than substituted for a finite MC run.

For **TIME-LIMITED** rows, generated/distinct/queued counts and depth are the
last complete `Progress(...)` sample in the log, not a fabricated shutdown
count or completed graph diameter. The timeout exits with code 124 and may
interrupt a temporal check before another progress sample. No property pass
is inferred from the sampled counts or intermediate temporal checks.

| Configuration | Status | Generated | Distinct | Depth | Queued | Seconds | Command and log |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| [MC.cfg](../MC.cfg) | TIME-LIMITED | 1,039,613 | 395,529 | 27 | 74,457 | 600.196 | `python3 spec/generation-checks/run_checks.py MC.cfg`; [MC.log](MC.log). |
| [MC_hunt_1_unique_consume.cfg](../MC_hunt_1_unique_consume.cfg) | TIME-LIMITED | 2,013,440 | 764,469 | 44 | 44,584 | 600.160 | `python3 spec/generation-checks/run_checks.py MC_hunt_1_unique_consume.cfg`; [MC_hunt_1_unique_consume.log](MC_hunt_1_unique_consume.log). |
| [MC_hunt_2_observation.cfg](../MC_hunt_2_observation.cfg) | TIME-LIMITED | 1,749,083 | 666,519 | 42 | 72,163 | 600.248 | `python3 spec/generation-checks/run_checks.py MC_hunt_2_observation.cfg`; [MC_hunt_2_observation.log](MC_hunt_2_observation.log). |
| [MC_hunt_3_blocking.cfg](../MC_hunt_3_blocking.cfg) | TIME-LIMITED | 741,094 | 274,877 | 22 | 71,983 | 600.231 | `python3 spec/generation-checks/run_checks.py MC_hunt_3_blocking.cfg`; [MC_hunt_3_blocking.log](MC_hunt_3_blocking.log). |
| [MC_hunt_3_wakeup.cfg](../MC_hunt_3_wakeup.cfg) | TIME-LIMITED | 676,745 | 259,862 | 49 | 14,682 | 600.249 | `python3 spec/generation-checks/run_checks.py MC_hunt_3_wakeup.cfg`; [MC_hunt_3_wakeup.log](MC_hunt_3_wakeup.log). |
| [MC_hunt_4_publication.cfg](../MC_hunt_4_publication.cfg) | PASS | 2,782,297 | 1,005,898 | 77 | 0 | 520.783 | `python3 spec/generation-checks/run_checks.py MC_hunt_4_publication.cfg`; [MC_hunt_4_publication.log](MC_hunt_4_publication.log). |
| [MC_hunt_5_api_results.cfg](../MC_hunt_5_api_results.cfg) | TIME-LIMITED | 2,046,411 | 773,613 | 32 | 90,436 | 600.156 | `python3 spec/generation-checks/run_checks.py MC_hunt_5_api_results.cfg`; [MC_hunt_5_api_results.log](MC_hunt_5_api_results.log). |

R3 uses `Hunt = "all"`, `CallLimit = 4`, and `SpuriousLimit = 1`. This keeps
the brief's two observations, consume, and fresh post-reap call reachable
within the admission bound, while permitting all API/option combinations.
Existing weak exit/thread fairness, first-admission fairness, and strong
lock-acquisition fairness are reused unchanged. Reactive transitions remain
uncapped. Both temporal configurations omit symmetry. Existing safety
configurations retain it. The bound was not narrowed after the search timed
out. Configured coverage is repaired, but the general completion obligation
and the restricted competing-consumer property are not proved by these runs.

## Trace search results rerun in r2

Each trace run has a 60-second timeout and the same heap, direct-memory, worker,
and metadata limits. `TraceSearch.cfg` retains all existing safety, structural,
and final-state checks. It intentionally violates `TraceNoCompleteMatch` only
when all events have matched and `TraceEndOK` holds. Exit 12 with that exact
invariant and a retained complete counterexample is **ACCEPTED**. Exhaustion
of a nonempty initialized graph without that witness or any checker error is
**REJECTED**. Timeout, interruption, initialization/evaluation errors, a different
invariant violation, or an incomplete witness are **INCONCLUSIVE**. A generic
TLC failure or successful parsing alone is never trace acceptance.

| Input and configuration | Criterion result | TLC exit | Distinct | Depth | Evidence |
| --- | --- | ---: | ---: | ---: | --- |
| [overlap.json](overlap.json), `TraceSearch.cfg` | PASS / ACCEPTED | 12 | 34 | 28 | [Log](trace-search-overlap.log), [complete witness](trace-search-overlap.trace.json). |
| [sequential.json](sequential.json), `TraceSearch.cfg` | PASS / ACCEPTED | 12 | 28 | 28 | [Log](trace-search-sequential.log), [complete witness](trace-search-sequential.trace.json). |
| [park-true.json](park-true.json), `TraceSearch.cfg` | PASS / ACCEPTED | 12 | 56 | 55 | [Log](trace-search-park-true.log), [complete witness](trace-search-park-true.trace.json). |
| [park-false.json](park-false.json), `TraceSearch.cfg` | PASS / ACCEPTED | 12 | 57 | 57 | [Log](trace-search-park-false.log), [complete witness](trace-search-park-false.trace.json). |
| [corrupted.json](corrupted.json), `TraceSearch.cfg` | PASS / REJECTED by exhaustion | 0 | 19 | 19 | [Log with zero queued states](trace-search-corrupted.log). |
| [overlap.json](overlap.json), unchanged `Trace.cfg` | FAIL of the stricter universal property, expected R2 diagnostic | 13 | 34 | 28 | [Log](trace-universal-overlap.log), [counterexample](trace-universal-overlap.trace.json). |

The overlap and sequential witnesses each contain 28 states for 27 events. Final cursors are
T1=15, T2=7, child=8. Both calls are done, the notifier is done, the children
mutex is released, signal registrations are clear, and no park runqueue lock
is held. The corrupted fixture differs only at T1 event 12,
`SysWaitCopyout.post.out.status`: 9472 becomes 9473. Its search stops before
that event can match and exhausts all alternatives.

The universal counterexample reaches state 11 with T2 owning the mutex,
T1's lock event `[10,20]` still pending, and T2's next event beginning at 101.
T1 cannot acquire while T2 owns the mutex, and T2 is blocked by the pending
T1 event's earlier end. The behavior then stutters. This is the review's
speculative-ordering/quantifier mismatch, not a candidate kernel behavior.
At the fixed source, `ostd/src/sync/mutex.rs:35-36,62-69` permits T1 to acquire
and release before T2's blocking acquisition completes.
`kernel/core/src/process/wait.rs:293-319,344-374` holds the children lock
through selection and consuming cleanup. The accepted T1-first witness
respects those boundaries. No base action or expected outcome was changed
to suppress the universal failure.

## Expanded commands

Each entry below is the command actually executed, with its log path. MC
commands are retained from r1, while parse and trace commands were rerun in r2. The
working directory is `spec/` at this workspace. The JSON record also retains
the absolute working directory, start time, elapsed time, and input hashes.

### sany-base

Log: [sany-base.log](sany-base.log).

```sh
timeout --kill-after=10s 60s /nix/store/vymiz4fvnc1s8k19kz2lqvkv3g2k0ys6-openjdk-headless-21.0.12.1+1/bin/java -Xmx3g -XX:MaxDirectMemorySize=1g -XX:+UseParallelGC -Dtlc2.tool.fp.FPSet.impl=tlc2.tool.fp.OffHeapDiskFPSet -cp /home/chin39/Documents/play/Specula/lib/tla2tools.jar:/home/chin39/Documents/play/Specula/lib/CommunityModules-deps.jar tla2sany.SANY base.tla
```

### sany-MC

Log: [sany-MC.log](sany-MC.log).

```sh
timeout --kill-after=10s 60s /nix/store/vymiz4fvnc1s8k19kz2lqvkv3g2k0ys6-openjdk-headless-21.0.12.1+1/bin/java -Xmx3g -XX:MaxDirectMemorySize=1g -XX:+UseParallelGC -Dtlc2.tool.fp.FPSet.impl=tlc2.tool.fp.OffHeapDiskFPSet -cp /home/chin39/Documents/play/Specula/lib/tla2tools.jar:/home/chin39/Documents/play/Specula/lib/CommunityModules-deps.jar tla2sany.SANY MC.tla
```

### sany-Trace

Log: [sany-Trace.log](sany-Trace.log).

```sh
timeout --kill-after=10s 60s /nix/store/vymiz4fvnc1s8k19kz2lqvkv3g2k0ys6-openjdk-headless-21.0.12.1+1/bin/java -Xmx3g -XX:MaxDirectMemorySize=1g -XX:+UseParallelGC -Dtlc2.tool.fp.FPSet.impl=tlc2.tool.fp.OffHeapDiskFPSet -cp /home/chin39/Documents/play/Specula/lib/tla2tools.jar:/home/chin39/Documents/play/Specula/lib/CommunityModules-deps.jar tla2sany.SANY Trace.tla
```

### MC_hunt_3_wakeup

Log: [MC_hunt_3_wakeup.log](MC_hunt_3_wakeup.log).

```sh
timeout --kill-after=10s 600s /nix/store/vymiz4fvnc1s8k19kz2lqvkv3g2k0ys6-openjdk-headless-21.0.12.1+1/bin/java -Xmx3g -XX:MaxDirectMemorySize=1g -XX:+UseParallelGC -Dtlc2.tool.fp.FPSet.impl=tlc2.tool.fp.OffHeapDiskFPSet -cp /home/chin39/Documents/play/Specula/lib/tla2tools.jar:/home/chin39/Documents/play/Specula/lib/CommunityModules-deps.jar tlc2.TLC -workers 2 -deadlock -checkpoint 10 -metadir /home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/wait-reap/spec-fix-ws/states/MC_hunt_3_wakeup -noGenerateSpecTE -dumpTrace json generation-checks/MC_hunt_3_wakeup.trace.json -config MC_hunt_3_wakeup.cfg MC.tla
```

### trace-search-overlap

Log: [trace-search-overlap.log](trace-search-overlap.log).

```sh
JSON=/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/wait-reap/spec-fix-ws/spec/generation-checks/overlap.json timeout --kill-after=10s 60s /nix/store/vymiz4fvnc1s8k19kz2lqvkv3g2k0ys6-openjdk-headless-21.0.12.1+1/bin/java -Xmx3g -XX:MaxDirectMemorySize=1g -XX:+UseParallelGC -Dtlc2.tool.fp.FPSet.impl=tlc2.tool.fp.OffHeapDiskFPSet -cp /home/chin39/Documents/play/Specula/lib/tla2tools.jar:/home/chin39/Documents/play/Specula/lib/CommunityModules-deps.jar tlc2.TLC -workers 2 -deadlock -checkpoint 10 -metadir /home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/wait-reap/spec-fix-ws/states/trace-search-overlap -noGenerateSpecTE -dumpTrace json generation-checks/trace-search-overlap.trace.json -config TraceSearch.cfg Trace.tla
```

### trace-search-sequential

Log: [trace-search-sequential.log](trace-search-sequential.log).

```sh
JSON=/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/wait-reap/spec-fix-ws/spec/generation-checks/sequential.json timeout --kill-after=10s 60s /nix/store/vymiz4fvnc1s8k19kz2lqvkv3g2k0ys6-openjdk-headless-21.0.12.1+1/bin/java -Xmx3g -XX:MaxDirectMemorySize=1g -XX:+UseParallelGC -Dtlc2.tool.fp.FPSet.impl=tlc2.tool.fp.OffHeapDiskFPSet -cp /home/chin39/Documents/play/Specula/lib/tla2tools.jar:/home/chin39/Documents/play/Specula/lib/CommunityModules-deps.jar tlc2.TLC -workers 2 -deadlock -checkpoint 10 -metadir /home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/wait-reap/spec-fix-ws/states/trace-search-sequential -noGenerateSpecTE -dumpTrace json generation-checks/trace-search-sequential.trace.json -config TraceSearch.cfg Trace.tla
```

### trace-search-corrupted

Log: [trace-search-corrupted.log](trace-search-corrupted.log).

```sh
JSON=/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/wait-reap/spec-fix-ws/spec/generation-checks/corrupted.json timeout --kill-after=10s 60s /nix/store/vymiz4fvnc1s8k19kz2lqvkv3g2k0ys6-openjdk-headless-21.0.12.1+1/bin/java -Xmx3g -XX:MaxDirectMemorySize=1g -XX:+UseParallelGC -Dtlc2.tool.fp.FPSet.impl=tlc2.tool.fp.OffHeapDiskFPSet -cp /home/chin39/Documents/play/Specula/lib/tla2tools.jar:/home/chin39/Documents/play/Specula/lib/CommunityModules-deps.jar tlc2.TLC -workers 2 -deadlock -checkpoint 10 -metadir /home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/wait-reap/spec-fix-ws/states/trace-search-corrupted -noGenerateSpecTE -dumpTrace json generation-checks/trace-search-corrupted.trace.json -config TraceSearch.cfg Trace.tla
```

### trace-universal-overlap

Log: [trace-universal-overlap.log](trace-universal-overlap.log).

```sh
JSON=/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/wait-reap/spec-fix-ws/spec/generation-checks/overlap.json timeout --kill-after=10s 60s /nix/store/vymiz4fvnc1s8k19kz2lqvkv3g2k0ys6-openjdk-headless-21.0.12.1+1/bin/java -Xmx3g -XX:MaxDirectMemorySize=1g -XX:+UseParallelGC -Dtlc2.tool.fp.FPSet.impl=tlc2.tool.fp.OffHeapDiskFPSet -cp /home/chin39/Documents/play/Specula/lib/tla2tools.jar:/home/chin39/Documents/play/Specula/lib/CommunityModules-deps.jar tlc2.TLC -workers 2 -deadlock -checkpoint 10 -metadir /home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/wait-reap/spec-fix-ws/states/trace-universal-overlap -noGenerateSpecTE -dumpTrace json generation-checks/trace-universal-overlap.trace.json -config Trace.cfg Trace.tla
```

### MC_hunt_3_blocking

Log: [MC_hunt_3_blocking.log](MC_hunt_3_blocking.log).

```sh
timeout --kill-after=10s 600s /nix/store/vymiz4fvnc1s8k19kz2lqvkv3g2k0ys6-openjdk-headless-21.0.12.1+1/bin/java -Xmx3g -XX:MaxDirectMemorySize=1g -XX:+UseParallelGC -Dtlc2.tool.fp.FPSet.impl=tlc2.tool.fp.OffHeapDiskFPSet -cp /home/chin39/Documents/play/Specula/lib/tla2tools.jar:/home/chin39/Documents/play/Specula/lib/CommunityModules-deps.jar tlc2.TLC -workers 2 -deadlock -checkpoint 10 -metadir /home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/wait-reap/spec-fix-ws/states/MC_hunt_3_blocking -noGenerateSpecTE -dumpTrace json generation-checks/MC_hunt_3_blocking.trace.json -config MC_hunt_3_blocking.cfg MC.tla
```

### MC_hunt_4_publication

Log: [MC_hunt_4_publication.log](MC_hunt_4_publication.log).

```sh
timeout --kill-after=10s 600s /nix/store/vymiz4fvnc1s8k19kz2lqvkv3g2k0ys6-openjdk-headless-21.0.12.1+1/bin/java -Xmx3g -XX:MaxDirectMemorySize=1g -XX:+UseParallelGC -Dtlc2.tool.fp.FPSet.impl=tlc2.tool.fp.OffHeapDiskFPSet -cp /home/chin39/Documents/play/Specula/lib/tla2tools.jar:/home/chin39/Documents/play/Specula/lib/CommunityModules-deps.jar tlc2.TLC -workers 2 -deadlock -checkpoint 10 -metadir /home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/wait-reap/spec-fix-ws/states/MC_hunt_4_publication -noGenerateSpecTE -dumpTrace json generation-checks/MC_hunt_4_publication.trace.json -config MC_hunt_4_publication.cfg MC.tla
```

### MC_hunt_1_unique_consume

Log: [MC_hunt_1_unique_consume.log](MC_hunt_1_unique_consume.log).

```sh
timeout --kill-after=10s 600s /nix/store/vymiz4fvnc1s8k19kz2lqvkv3g2k0ys6-openjdk-headless-21.0.12.1+1/bin/java -Xmx3g -XX:MaxDirectMemorySize=1g -XX:+UseParallelGC -Dtlc2.tool.fp.FPSet.impl=tlc2.tool.fp.OffHeapDiskFPSet -cp /home/chin39/Documents/play/Specula/lib/tla2tools.jar:/home/chin39/Documents/play/Specula/lib/CommunityModules-deps.jar tlc2.TLC -workers 2 -deadlock -checkpoint 10 -metadir /home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/wait-reap/spec-fix-ws/states/MC_hunt_1_unique_consume -noGenerateSpecTE -dumpTrace json generation-checks/MC_hunt_1_unique_consume.trace.json -config MC_hunt_1_unique_consume.cfg MC.tla
```

### MC_hunt_2_observation

Log: [MC_hunt_2_observation.log](MC_hunt_2_observation.log).

```sh
timeout --kill-after=10s 600s /nix/store/vymiz4fvnc1s8k19kz2lqvkv3g2k0ys6-openjdk-headless-21.0.12.1+1/bin/java -Xmx3g -XX:MaxDirectMemorySize=1g -XX:+UseParallelGC -Dtlc2.tool.fp.FPSet.impl=tlc2.tool.fp.OffHeapDiskFPSet -cp /home/chin39/Documents/play/Specula/lib/tla2tools.jar:/home/chin39/Documents/play/Specula/lib/CommunityModules-deps.jar tlc2.TLC -workers 2 -deadlock -checkpoint 10 -metadir /home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/wait-reap/spec-fix-ws/states/MC_hunt_2_observation -noGenerateSpecTE -dumpTrace json generation-checks/MC_hunt_2_observation.trace.json -config MC_hunt_2_observation.cfg MC.tla
```

### MC_hunt_5_api_results

Log: [MC_hunt_5_api_results.log](MC_hunt_5_api_results.log).

```sh
timeout --kill-after=10s 600s /nix/store/vymiz4fvnc1s8k19kz2lqvkv3g2k0ys6-openjdk-headless-21.0.12.1+1/bin/java -Xmx3g -XX:MaxDirectMemorySize=1g -XX:+UseParallelGC -Dtlc2.tool.fp.FPSet.impl=tlc2.tool.fp.OffHeapDiskFPSet -cp /home/chin39/Documents/play/Specula/lib/tla2tools.jar:/home/chin39/Documents/play/Specula/lib/CommunityModules-deps.jar tlc2.TLC -workers 2 -deadlock -checkpoint 10 -metadir /home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/wait-reap/spec-fix-ws/states/MC_hunt_5_api_results -noGenerateSpecTE -dumpTrace json generation-checks/MC_hunt_5_api_results.trace.json -config MC_hunt_5_api_results.cfg MC.tla
```

### MC

Log: [MC.log](MC.log).

```sh
timeout --kill-after=10s 600s /nix/store/vymiz4fvnc1s8k19kz2lqvkv3g2k0ys6-openjdk-headless-21.0.12.1+1/bin/java -Xmx3g -XX:MaxDirectMemorySize=1g -XX:+UseParallelGC -Dtlc2.tool.fp.FPSet.impl=tlc2.tool.fp.OffHeapDiskFPSet -cp /home/chin39/Documents/play/Specula/lib/tla2tools.jar:/home/chin39/Documents/play/Specula/lib/CommunityModules-deps.jar tlc2.TLC -workers 2 -deadlock -checkpoint 10 -metadir /home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/wait-reap/spec-fix-ws/states/MC -noGenerateSpecTE -dumpTrace json generation-checks/MC.trace.json -config MC.cfg MC.tla
```

### trace-search-park-true

Log: [trace-search-park-true.log](trace-search-park-true.log).

```sh
JSON=/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/wait-reap/spec-fix-ws/spec/generation-checks/park-true.json timeout --kill-after=10s 60s /nix/store/vymiz4fvnc1s8k19kz2lqvkv3g2k0ys6-openjdk-headless-21.0.12.1+1/bin/java -Xmx3g -XX:MaxDirectMemorySize=1g -XX:+UseParallelGC -Dtlc2.tool.fp.FPSet.impl=tlc2.tool.fp.OffHeapDiskFPSet -cp /home/chin39/Documents/play/Specula/lib/tla2tools.jar:/home/chin39/Documents/play/Specula/lib/CommunityModules-deps.jar tlc2.TLC -workers 2 -deadlock -checkpoint 10 -metadir /home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/wait-reap/spec-fix-ws/states/trace-search-park-true -noGenerateSpecTE -dumpTrace json generation-checks/trace-search-park-true.trace.json -config TraceSearch.cfg Trace.tla
```

### trace-search-park-false

Log: [trace-search-park-false.log](trace-search-park-false.log).

```sh
JSON=/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/wait-reap/spec-fix-ws/spec/generation-checks/park-false.json timeout --kill-after=10s 60s /nix/store/vymiz4fvnc1s8k19kz2lqvkv3g2k0ys6-openjdk-headless-21.0.12.1+1/bin/java -Xmx3g -XX:MaxDirectMemorySize=1g -XX:+UseParallelGC -Dtlc2.tool.fp.FPSet.impl=tlc2.tool.fp.OffHeapDiskFPSet -cp /home/chin39/Documents/play/Specula/lib/tla2tools.jar:/home/chin39/Documents/play/Specula/lib/CommunityModules-deps.jar tlc2.TLC -workers 2 -deadlock -checkpoint 10 -metadir /home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/wait-reap/spec-fix-ws/states/trace-search-park-false -noGenerateSpecTE -dumpTrace json generation-checks/trace-search-park-false.trace.json -config TraceSearch.cfg Trace.tla
```
