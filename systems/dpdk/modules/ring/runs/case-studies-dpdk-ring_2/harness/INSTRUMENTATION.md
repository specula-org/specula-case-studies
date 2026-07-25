# dpdk-ring_2 — Trace Harness Instrumentation Guide

This harness instruments DPDK's `lib/ring/` to emit NDJSON traces for
TLA+ trace validation.  Generated traces validate against the round-2
spec at `spec/Trace.tla` + `spec/Trace.cfg`.

## Files

| Path | Purpose |
|------|---------|
| `src/rte_ring_tla_trace.h` | Trace emission library — copied into `dpdk/lib/ring/` by `apply.sh`. Per-lcore `FILE*` array, rdtsc timestamps, helper structs for state snapshots, all guarded by `DPDK_TLA_TRACE`. |
| `src/test_ring_trace.c`    | Test driver — exercises rte_ring API in MT, HTS, RTS, SORING, Peek modes. Uses 2 lcores per scenario. |
| `src/merge_traces.py`      | Per-thread NDJSON → per-tid JSON preprocessor; remaps tids to `t1`,`t2`,…, compresses rdtsc timestamps to dense integers. |
| `instrument.py`            | In-place line-injection patcher — adds `__tla_emit_*` calls into the ring source files. |
| `apply.sh`                 | Resets ring sources (`git checkout`), copies the trace header, runs `instrument.py`. Idempotent. |
| `run.sh`                   | Apply → build instrumented DPDK → build test driver → run → merge → report. |

## Where each instrumentation point lives (after `apply.sh`)

| Spec action(s) | C-source file | Anchor / function |
|---|---|---|
| `ProdMoveHead_LoadHead`/`LoadTail`/`CAS`, `ProdWriteRing`, `ProdUpdateTail` | `lib/ring/rte_ring_elem_pvt.h` | `__rte_ring_do_enqueue_elem` |
| `ConsMoveHead_LoadHead`/`LoadTail`/`CAS`, `ConsUpdateTail` | `lib/ring/rte_ring_elem_pvt.h` | `__rte_ring_do_dequeue_elem` |
| `HTSProd*` events                                   | `lib/ring/rte_ring_hts_elem_pvt.h` | `__rte_ring_do_hts_enqueue_elem` |
| `HTSCons*` events                                   | `lib/ring/rte_ring_hts_elem_pvt.h` | `__rte_ring_do_hts_dequeue_elem` |
| `RTSProd*` (incl. `RTSProdUpdateTail_*`)            | `lib/ring/rte_ring_rts_elem_pvt.h` | `__rte_ring_do_rts_enqueue_elem` |
| `RTSCons*`                                          | `lib/ring/rte_ring_rts_elem_pvt.h` | `__rte_ring_do_rts_dequeue_elem` |
| `PeekStart`                                         | `lib/ring/rte_ring_peek_elem_pvt.h` | `__rte_ring_do_enqueue_start` |
| `PeekFinish`                                        | `src/test_ring_trace.c`            | inline around `rte_ring_*_finish` |
| `SORingAcquire_*`, `SORingRelease_*`                | `lib/ring/soring.c`                | `soring_acquire`, `soring_release` |
| `SORingFinalize_*`                                  | `lib/ring/soring.c`                | `__rte_soring_stage_finalize` |
| Trace TLS storage definitions (`__tla_lcore_fp`, `__tla_lcore_tid`) | `lib/ring/soring.c` (top of file) | also `RTE_EXPORT_INTERNAL_SYMBOL(...)` so other DPDK libs can link |

## State snapshot timing (PRE-state vs POST-state)

The TLA+ validators (`ValidateProdHead(ev) == ev.state.prodHead = prodHead`)
use **unprimed** spec variables — they check the **PRE-state** of each
spec transition.  The harness captures multiple snapshots inside each
wrapper and emits each event with the snapshot that matches the spec
phase boundary:

```
snap(s_pre);                         // before move_head returns
n = move_prod_head(...);             // CAS happens inside, advances prodHead
emit("LoadHead", s_pre);             // pre-CAS state
emit("LoadTail", s_pre);             //
emit("CAS",      s_pre);             //
if (n) {
    enqueue_elems();
    snap(s_post);
    emit("WriteRing", s_post);
    snap(s_pretail);                 // before update_tail
    update_tail();
    emit("UpdateTail", s_pretail);   // pre-tail state
}
```

If the Phase-3 validation reports a state mismatch, the most likely fix
is moving the snapshot capture closer to (or further from) the spec
phase boundary.

## Trace shape

```json
{"tag":"trace","name":"<event>","tid":1,
 "start":<rdtsc>,"end":<rdtsc>,
 "n":1,                              // optional, for *MoveHead*/Acquire/Release
 "stage":0,                          // optional, SORING only
 "ftoken":3,                         // optional, SORING only
 "state":{"prodHead":0,"prodTail":0,"consHead":0,"consTail":0}}
```

For RTS-mode events the `state` block contains `rtsProd{Head,Tail}{Cnt,Pos}`
and `rtsCons{Head,Tail}{Cnt,Pos}` (with `prodTail`/`consTail` always `0`
since the spec leaves those vars untouched in RTS mode).

State values are wrapped to `TRACE_POS_WRAP=4` and `TRACE_CNT_WRAP=2` to
match `Trace.cfg`'s `PosWrap` and `CntWrap`.  If a test scenario must
exceed those bounds, raise `TRACE_POS_WRAP` at compile time and bump
`Trace.cfg` accordingly.

## How to add / move / remove an event

### Adding a new event type

1. Add an `__tla_emit_*` call into the appropriate wrapper in
   `instrument.py` (use one of the existing patterns as a template —
   `__tla_emit_default_with_state` for default/HTS/Peek; `__tla_emit_rts_with_state`
   for RTS; `__tla_emit_soring` for SORING).
2. Re-run `apply.sh` (or just `run.sh` which calls it).

### Moving a state-capture point (PRE↔POST)

In `instrument.py`, edit the wrapper function's snippet — change which
of `__tla_s_pre` / `__tla_s_post` / `__tla_s_pretail` is passed to the
`__tla_emit_*_with_state` call.

### Removing a redundant event

Delete (or comment out) the corresponding `__tla_emit_*` line in
`instrument.py`.  If the spec has a matching action in `SilentActions`
(see `Trace.tla`), the silent path will fire it instead — otherwise the
spec will deadlock.

### Adding/removing a field

Edit `__tla_emit_*` in `rte_ring_tla_trace.h` to write the extra field
in JSON.  If the validator uses the field, also add a `Validate*`
helper to `Trace.tla` and call it in the relevant `OnXxx` wrapper.

## Rebuilding

```bash
bash harness/run.sh       # full pipeline (apply → build → run → merge)
```

Each invocation starts from a clean tree (`git checkout -- lib/ring/`),
so re-running is safe.

## Phase 3 — Validation hand-off

The `MT` trace validates cleanly against `Trace.cfg` as shipped (Mode = "MT").
For other modes, you must:

1. **Per-mode `Trace.cfg`** — duplicate `Trace.cfg` and set `Mode` to
   `"HTS"`, `"RTS"`, `"SORING"`, or `"ST"` respectively.  Each mode's
   spec actions guard on `Mode = "<X>"`, so a wrong-mode cfg deadlocks
   immediately at the initial state.
2. **`PosWrap` / `CntWrap` / `Capacity`** may need raising for longer
   traces — bump `TRACE_POS_WRAP` in `rte_ring_tla_trace.h` to match.
3. **Silent-action guards** — `Trace.tla`'s `SilentActions` checks
   `NoPendingEvent(t, name)` and `role[t]` to avoid racing with the
   matched-event path.  If you add a new silent action, mirror the
   pattern.
4. **TraceSpec fairness** — `WF_<<allVars,traceVars>>(TraceNext)` is
   conjoined to `TraceSpec` so TLC doesn't report a stuttering
   counter-example trivially.

## Adjustments already made to the Phase-2 spec to make traces validate

These edits are documented here so the Phase-3 agent knows what
already changed (vs. what the original Phase-2 output was).

1. `Trace.cfg`: `Thread = {t1, t2}` → `Thread = {"t1", "t2"}` so JSON
   string keys from `merge_traces.py` match the constant.
2. `Trace.tla`: `SilentActions` now guarded by `NoPendingEvent(...)` (so
   silent doesn't race with explicit trace events) and `role[t] = "prod"`
   for prod-side silent actions (so they can't fire for cons threads).
3. `Trace.tla`: `NoPendingEvent` rewritten as `IF/THEN/ELSE` to avoid
   TLC indexing past the end of the trace sequence.
4. `Trace.tla`: `TraceSpec` now conjoins `WF_<<allVars, traceVars>>(TraceNext)`
   so the temporal property `<>(ThreadsWithEvents = {})` is checked
   against fair behaviors (without fairness it was vacuously violated).

## Known gaps / Phase-3 follow-ups

- HTS / RTS / SORING / Peek modes need separate cfg files (`Mode` constant).
- Peek's dequeue side (`rte_ring_dequeue_bulk_start`) is exercised by
  the test but the spec only models prod-side Peek — those events will
  need a Cons variant added to `base.tla`, or the test should drop them.
- The CAS-retry loop inside `__rte_ring_headtail_move_head` is opaque
  to the harness; we emit a single LoadHead/LoadTail/CAS triple per
  call.  Under high contention real CAS retries are not captured.
- `ProdWriteRing` is not in `SilentActions` for this round; if the spec
  expects it as silent, add the emit call to `instrument.py`.

## Quick references

- 5 trace files emitted (`trace_mt.ndjson`, `trace_hts.ndjson`,
  `trace_rts.ndjson`, `trace_soring.ndjson`, `trace_peek.ndjson`),
  each a `{tid: [event...]}` JSON object.
- `MT` trace validated cleanly against the spec (52 states, depth 25).
- Per-thread NDJSON files (`trace_<mode>-thread-<N>.ndjson`) are kept
  alongside the merged file for debugging.
