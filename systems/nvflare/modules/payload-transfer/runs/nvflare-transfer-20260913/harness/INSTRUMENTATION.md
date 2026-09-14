# NVFlare transfer trace harness

Source pin: `53ba7ee567468ea7971dad4faccef13c6cb35dc2`. Category A: one mutex-protected writer per scenario, real epoch-nanosecond timestamps, and observations at individual source boundaries. No model interpreter is used to emit states or compute outcomes.

Run from `.specula-output/`:

```bash
bash harness/run.sh
```

The script applies the patch, compiles the Python modules, runs each scenario in a fresh pytest process, runs separate caller/legacy profile tests, normalizes every trace, runs the original `Trace.tla`/`Trace.cfg`, runs three rejection controls, and audits current hashes and complete cursor consumption. All test/build commands have outer timeouts. TLC uses the experiment-local task API and blocking waits, with 2 GiB heap, 1 GiB direct memory and one worker per sequential check. Scratch stays under `scratch/transfer/`. Existing supplied Python and TLC environments are used; the build receipt records their versions.

## Files and capture points

- `src/specula_trace.py`: writer, typed JSON encoding, observed source projection, continuation/callback ledger, and a proxy around the **original queue of a dedicated real CheckedExecutor**. The proxy observes actual `put` and `get`; it does not replace the executor algorithm or fabricate work items.
- `src/build_patch.py`: reproducibly creates `patches/instrumentation.patch` from the pinned Git blobs. Source changes are observation calls, expression wrappers preserving actual return values, and a caller observation decorator. `apply.sh` is idempotent and uses `git apply --check`; it never resets a checkout.
- `src/test_transfer_traces.py`: real Cell/Consumer/DownloadService scenarios, integral test clock, ordinary one-byte source plugin, and bounded local fault injection. Its `OwnedSource.release` captures its real `base_obj = None` mutation under the plugin source lock.
- `src/test_profiles.py`: separate real Cell argument capture for ordinary broadcast, pass-through broadcast, and fire-and-forget. It writes JSON evidence, not a confirmed-mode trace.
- `POINTS.md` and `logs/instrumentation-points.json`: exact **after-apply file/line locations** of physical probes and recorder emit calls. `../spec/action-map.json` retains each action's semantic source ranges and required fields. `../spec/instrumentation-spec.md` is unchanged.

Important physical boundaries:

| Source boundary | Recorder hook(s) |
|---|---|
| `_Transaction.begin_op`, `end_op`, `_drain_ops` under operation lock | `op_begin`, `op_end`, `drain_begin`, `drain_empty`, `drain_expired` |
| `_Ref.mark_receiver_active`, separate progress/stats locks | `ref_active`, `tx_receiver_active` |
| `_Ref.obj_served`, `_finalize_receiver`, under progress lock | `served`, `served_final`, `finalizer_commit`, `finalizer_reject` |
| Progress construction under progress lock; callbacks outside it | `progress_request`, `progress_made`, `terminal_batch`, `progress_callback`, `progress_returned` |
| Consumer request entry, actual received payload, callback return/exception | `request_start`, `consumer_*`, `pipeline_submit` |
| Actual constructed confirm/cancel Message, before dispatch | `control_message`; `confirm_skip` and `confirm_lost` distinguish no-send/failure |
| Budget stats snapshot, actual failure list, freshness recheck | `budget_snapshot`, `budget_nonfailures`, `budget_select`, `budget_recheck`, `budget_advance` |
| Atomic retirement, unsuccessful completion scan, shutdown ownership | `finish`, `finish_scan_missing`, `finish_missing`, `delete`, `monitor_*`, `shutdown` |
| Independent settlement snapshots and hook calls | `snapshot_ref`, `computed`, `terminal_batch`, `base_object`, `*_callback`, `*_returned` |
| Owner-guarded insertion and waiter resolution under outcome lock | `record`, `record_drop`, `late_waiter`, `expire` |
| Final marker synchronization, with separate sampled operation state | `marker_read`, `marker_write`, `marker_reap` |
| Actual `CellClientAPI._wait_for_result_transfers` invocation | `caller_observed` decorator in `nvflare/client/cell/api.py` |

The bootstrap is captured after all refs and the first waiter exist, before any download starts. It reads actual service membership, receiver configuration, timestamps and empty receiver maps; continuation/observer ledgers are initialized because no corresponding operation/hook has yet run. The supported Consumer type is explicitly checked for pipelining. No expected invariant is used to fill an observed field.

## Trace envelope compatibility

The supplied Trace module requires the custom tag `nvflare-transfer`, a string `event`, and an exact six-key event envelope that excludes timestamps. The skill requires raw `tag: trace`, a real timestamp and a structured event. Both artifacts are retained:

- `../traces/<scenario>.ndjson`: original runtime file; config header plus `tag: trace`, `ts`, `event.name`, `event.state`, `event.msg`, and thread identity.
- `../traces/normalized/<scenario>.ndjson`: the input module's exact envelope and lossless tagged set/function encodings.

`normalize.py` preserves **every** event, argument and post-state in its original order. It only translates the envelope; real time and thread metadata remain in the hashed raw file. It rejects unknown names, wrong sequence/transaction IDs, empty event files and missing/extra state fields. It never inserts events or changes state values.

`validate.py` creates per-scenario directories with symlinks to the unchanged input modules and to the selected normalized trace at `../traces/trace.ndjson`. This avoids changing `Trace.tla` or sharing one mutable default trace. The TLC wrapper's `-j` flag means **output counterexample JSON**, not input trace selection.

## Adjusting probes for Phase 3

1. **Add/correct a captured field:** find the source hook in `POINTS.md`, then the matching branch in `Recorder.observe`. Read the actual owning object or local at that source boundary; update only that field's observed slice. Preserve full function domains, including unchanged entries. If the model schema changes, update its generator/typed decoder/required-field mapping together; do not remove a check to accept a source discrepancy.
2. **Add an event:** insert one `_trace.point("hook", locals())` using `build_patch.py`, add its source-observation handler, and add a pytest scenario that reaches it. `Recorder.emit` checks action arguments and emits exactly the fields declared by `action-map.json`. Unknown hooks fail with `TraceError`, a harness error that ordinary production `except Exception` handlers cannot hide.
3. **Move a capture point:** edit the corresponding replacement in `build_patch.py`. For lock-owned mutation, capture before releasing that original lock. For callbacks, keep entry, source mutation, and return/exception separate. The failed finish scan is observed at the missing-ref read while its progress lock is held.
4. **Regenerate a changed patch:** reverse only the current harness patch using `git apply --reverse --check` followed by `git apply --reverse`, run `python harness/src/build_patch.py "$NVFLARE_SOURCE"`, then run `bash harness/run.sh`. Do not use `git checkout -- .`. Direct recorder changes need only rerun `run.sh`.
5. **Investigate mismatch:** inspect the named task's `tlc.log`, its last cursor `l`, the corresponding raw row and source probe. Keep the raw failing trace. Correct instrumentation only when the source observation was captured/normalized incorrectly; otherwise retain the discrepancy for model review.

No weak post-state wrappers are used. Each emitted action checks the exact required field domain and every captured value. Unchanged fields within a captured function come from previous observations, not unlocked scans of unrelated objects. The recorder lock never spans produce, user callbacks, operation draining, executor acknowledgement, or gaps between separate semantic events. Scenario gates run after the recorder lock is released; a gate at a source-lock-owned hook must not block (the drain test uses only an event notification there).

The emitted header's clock units are actual fixture seconds: receiver budgets 3, transaction inactivity normally 10 (timeout scenario 5), drain 2, receipt retention 4, finished-ref retention 9. Production drain is 60 seconds; the fixture explicitly overrides it to 2 and records that value. `AdvanceTime` observes a real integral test-clock increment; its raw `ts` is always real wall time, never the abstract clock/event rank.
