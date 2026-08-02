# SREGym trace instrumentation

Category A is used: one process-global `RLock` protects each shadow update plus
NDJSON serialization. Every event is flushed and `fsync`ed with a real
`time.time_ns()` timestamp. Tracing is inactive unless `tla_trace.initialize()`
or `SREGYM_TRACE_FILE` enables it.

## Files and post-apply locations

| Area | Instrumented locations |
|---|---|
| Full shadow recorder | `sregym/tla_trace.py`; initialization at line 304, run setup at 448, transport at 622, evaluation at 816, cleanup at 944, noise at 1125, external/crash effects at 1276 |
| Run/evaluation/cleanup | `sregym/conductor/conductor.py:91,234,311,336-407,461,496-560,572-618,839` |
| HTTP and MCP transport | `sregym/conductor/conductor_api.py:44-53,139-149` |
| Client send boundaries | `clients/tierzero/driver.py:191-195`; `clients/stratus/tools/submit_tool.py:73-80,171-178` |
| Baseline/reconciliation | `sregym/service/cluster_state.py:138-196,235-359,385-544,573,620,660` |
| Noise lifecycle | `sregym/generators/noise/manager.py:81-129,174-182,231` |
| Driver exit/crash | `main.py:414-430,566` |
| Khaos restart/reattach | `sregym/conductor/problems/khaos_faults.py:178,187` |
| Scenarios | `tests/specula/test_trace_scenarios.py:580,596,618,649` |

All events use the full capture level. The recorder owns trace-only generations,
request provenance, cleanup PCs, baseline provenance, abstract resource
ownership, and noise epoch ledgers. It also checks directly observable
Conductor fields at key boundaries. Shadow values never feed back into a
Conductor guard or result.

`AdvanceStageAfterEvaluation` is emitted after diagnosis advances normally. For
mitigation it is emitted immediately before `_advance_to_next_stage`, because
that call synchronously enters evaluator cleanup; emitting after return would
place the cleanup actions before the model action that requests cleanup.

One model noise epoch represents one injection cycle. `NoiseManager` may apply
two concrete catalog templates in that cycle, so only the first concrete apply
emits the epoch's `BeginNoiseApply`/`CompleteNoiseApply` pair.

## Adjusting an event

- Add or change a field in `harness/src/tla_trace.py`, in both the recorder's
  initial `state` and `snapshot` representation. Then update the corresponding
  transition function and `harness/src/check_traces.py::STATE_FIELDS`.
- Add an event by copying an existing transition function in `tla_trace.py`,
  inserting its call at the real semantic boundary, and adding its exact name
  to `INSTRUMENTED_EVENTS` and the checker.
- Move a capture by moving only the `tla_trace.*` call around the real mutation.
  Keep the shadow transition and serialization together under
  `boundary_lock()` when a newly spawned thread could race the caller.
- Request IDs must be declared at recorder initialization so every earlier
  snapshot has the exact `TraceRequestIds` function domain.

After a source adjustment, regenerate
`harness/patches/instrumentation.patch` from the source worktree diff and copy
the corresponding complete module/test file back into `harness/src/`.

## Coverage

The four default traces cover 41 of 49 instrumented event types. The following
are intentionally untriggered rather than synthesized:

- `RetrySubmission`: requires holding the narrow completed-before-advance API
  race window or waiting through the endpoint retry path.
- `AgentExit`, `AgentExitAfterEvaluation`, `AgentExitWaitTimeout`: require a
  real launched agent process and, for the timeout case, a 300-second wait.
- `NoiseManagerJoinTimeout`: requires a real blocking `kubectl apply` to remain
  alive past the five-second join; forcing it would deliberately violate
  quiescence in this smoke batch.
- `ReplaceCluster`: requires provisioning a genuinely new cluster identity
  while preserving the home cache.
- `RestartPod`, `ReattachFault`: require a Khaos-enabled cluster, a real
  container-ID change, host-PID resolution, and successful eBPF reinjection.

## Rebuild and rerun

From `.specula-output/`:

```bash
bash harness/run.sh
```

This reapplies the patch idempotently, compiles all modified Python files, runs
four timeout-bounded real-code scenarios, writes one trace per scenario, checks
schema/timestamps/coverage, and prints line counts. `harness/clean.sh` reverses
only this patch and removes the two copied harness files; those files remain
recoverable from `harness/src/`.
