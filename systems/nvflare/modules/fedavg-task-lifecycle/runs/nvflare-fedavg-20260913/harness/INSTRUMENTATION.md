# NVFlare FedAvg trace harness

Run from `.specula-output/`:

```bash
bash harness/run.sh
```

This applies pinned source insertions, compiles the Python harness, runs 24 pytest scenarios, audits event/state coverage, and replays every collected trace with the installed Specula validation handler. Each TLC process uses `-m 1G -M 1G -w 1`; runs are sequential and time bounded. `reports/validation-summary.json` binds each result to trace/spec hashes. The supplied `base.tla`, `Trace.tla`, and `Trace.cfg` are unchanged.

Source: `/home/ubuntu/nvflare-runs-20260913/source-fedavg`, head `53ba7ee567468ea7971dad4faccef13c6cb35dc2`. `apply.sh` delegates to `src/instrument_source.py`; it checks the pin, builds `patches/instrumentation.patch`, and copies `src/trace_observer.py` to `nvflare/_specula_trace.py`. Reapplication accepts pristine files or the exact previously applied hashes in `applied.json`; unrelated edits are rejected, without reset/checkout. Harness hooks are inactive when `ACTIVE` is unset. To adjust instrumentation, edit the harness sources, then reapply; editing the installed source directly causes the ownership check to reject reapplication.

Optional `bash harness/clean.sh` restores only the exact source files owned by this harness and removes its installed observer module, after checking every current hash. It preserves unrelated source changes, traces and reports. It is supplied for later use; the delivered source remains instrumented.

## Capture points

Exact **post-apply** locations for every hook are generated in [reports/source-hooks.tsv](reports/source-hooks.tsv). Paths below are relative to the pinned source. Dynamic hook aliases select an event from actual local branch outcomes.

| Source file | Capture points after apply | Events / aliases |
|---|---|---|
| `nvflare/app_common/workflows/fedavg.py` | 198, 216, 229–234, 245, 267–271, 282, 309, 332–342, 363–386 | Round entry/reset; standing/abort polls; update/save/advance; consumer entry; metric decision; stats/results/build. |
| `nvflare/app_common/workflows/base_model_controller.py` | 232, 275–306, 319, 392 | Prepare; preliminary decision; conversion; actual callback return/failure; acceptance publication; reference clearing; unknown result; initial metadata. |
| `nvflare/app_common/aggregators/weighted_aggregation_helper.py` | 171, 221, 231 | `helper_stats`, `helper_value`, `helper_history` distinguish real parameter/metric helpers; capture each key separately. |
| `nvflare/apis/impl/wf_comm_server.py` | 189, 281–351, 443–533, 587, 826, 910, 1040–1142, 1213, 1260 | Task request/preparation/protection; dispatch/receipt; scheduling; cancellation/finalization; monitor/dead-policy/removal. |
| `nvflare/private/fed/server/server_runner.py` | 169, 302–395, 474–489, 597–622 | Workflow closure; request activity/admission/publication/filter; submission admission/activity/return; heartbeat/task-check. |
| `nvflare/private/fed/client/client_runner.py` | 228, 237, 598, 637 | Decoded assignment; executor reply with restored identity; actual retry loop; observed delivery/ACK outcome. |
| `harness/src/fedavg_trace_test.py` | `Suite.retrieve`, clock advances | Explicit local envelope-loss and FakeClock interfaces. These are transport/clock observations, not server protocol implementations. |

`src/trace_observer.py:Observer.observe` maps hook locals to snapshots. Real counterpart values include task membership/status, headers, completed LRU, dead reports/times, acceptance property, helper history/counts/totals, received count, aggregate metadata, exposed model and saved file. Ghost fields retain statement PCs, normalized UUIDs, version labels and ordered contribution provenance. Successful key additions are checked against real helper counts and totals; history is read from the helper, not reconstructed after an exception. Applied provenance is preserved before actual helper reset. Unexpected broadcast content receives an out-of-model version instead of the expected label, making it visible to replay.

Every event includes the complete state, contiguous `seq`, and a real monotonic timestamp in the outer envelope. `event` has exactly `name/nid/args/seq/state`, as required by `Trace.tla`. Diagnostics use a separate tag and omit `None`: the installed JSON reader rejects JSON `null` even in otherwise ignored records. No trace data is authored or repaired offline.

## Scheduler and boundaries

Category A: a short mutex protects serialization, snapshot updates and sequence numbers. Real FedAvg and monitor threads pause at gates outside this writer mutex. Test clients call the real server/client runners, communicator, broadcast manager and aggregation helpers. The fixture replaces engine services and Cell delivery only; it reuses upstream `controller_test.py`'s `FakeClock` and module time-patching list. It does not replace task management or aggregation.

At the admitted-callback gate, the submission thread still holds the real runner, communicator, callback and helper locks. Another thread invokes real `cancel_task`; it marks status without releasing those locks or rolling back contributions. Other gates exercise a checked submission waiting across retirement/reset or closure, and a task request between activity and its second runner-lock acquisition.

Receipt is observed at its real assignment, then emitted after the runner/communicator return. Monitor removal is emitted before resource cleanup; cleanup/no-exit events are emitted after the communicator returns. Normal callback count emission follows the actual successful consumer return. The scheduler does not interleave operations inside these grouped return/unlock intervals. For dead-client checks, the real loop visits reported clients only; the observer adds explicit absent-entry reads for the model's full-client scan, without mutating production state. No clock/recovery operations interleave inside that scan in this suite. These are declared observation groupings, not evidence for every production interleaving.

## Configuration and evidence limits

Two cooperative clients, fixed selected cohort, one or two rounds, two FULL scalar parameter keys (`w1`, `w2`), one scalar metric (`loss`), unit weights, no early stopping, no task timeout, all-selected response policy, no custom aggregator. Real file persistence uses FedAvg's FOBS save and is reloaded; copies survive under `reports/models/<scenario>/round-N.fobs`. Python/package versions, source/spec/harness hashes and actual per-scenario configuration are recorded in `reports/provenance.json` and the trace metadata.

The normal completed-task capacity is 10000. Only `late_evicted_retry` explicitly sets the real module capacity to 1, publishes `HistoryLimit=1`, and restores it through pytest's monkeypatch fixture. It establishes eviction behavior at capacity 1, not execution of 10000 entries.

Allocation/conversion tests use one-shot ordinary `MemoryError` at the declared pre-value or conversion/metric-preparation boundary; before-send and filter fixtures raise ordinary `RuntimeError`. Actual exception handlers and built-in consumer code then execute. This is controlled local fault-injection evidence, not evidence that those allocation failures occur at a measured production frequency. No malformed payload or replacement aggregation callback is used.

Tensor disk offload is disabled and no active Cell is created. Local FOBS encoding/decoding delivers conventional payloads; adapter losses and queued sends are explicit. Streamed PyTorch/lazy materialization, native partial-arithmetic failures, multi-process RPC, actual client crashes, chunk completion/transport abort latency, natural unconstrained scheduling, HA, numerical accuracy and model convergence are untested. All 80 action names can be covered through this configuration and allocation-failure alternatives; this does not cover every alternative implementation path for those actions.

## Adjustments for Phase 3

- **New field:** read it at the relevant real mutation/return in `Observer.observe`, extend the initial/snapshot layout, and add its check to the model/trace schema. Keep diagnostics outside `event`; do not add unchecked state fields.
- **New event:** add one exact source insertion in `instrument_source.py`, a local observation branch in `Observer.observe`, and a pytest scenario. Add the corresponding base/Trace action through the specification workflow. The audit rejects unknown or uncovered action names.
- **Move a capture:** move the insertion anchor in `instrument_source.py`; preserve before/after and lock ownership. Update its PC/ghost bookkeeping only after verifying the real boundary. Do not advance real protocol state from the observer.
- **Replay after edits:** run `bash harness/run.sh`. For a single replay, use the experiment's `tools/trace_debugger/.venv/bin/python harness/src/validate_traces.py <scenario>` from `.specula-output/`. The local validation-handler adapter changes only TLC launch to use the experiment's resource-budgeted wrapper.
- **Failure:** preserve the NDJSON and its TLC log/result. Inspect the first failing cursor/action and actual locals/source before changing instrumentation. Full post-state equality and `TraceMatched` must remain enabled.

See [reports/coverage.md](reports/coverage.md) for all 80 events and their generating scenarios, [RESULTS.md](RESULTS.md) for priority-question observations, and `reports/upstream-tests.log` for separate tests with instrumentation inactive.
