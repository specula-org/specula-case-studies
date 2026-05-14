# DPDK rte_ring — Instrumentation Spec (Round 2)

This document maps each TLA+ spec action in `base.tla` to the C source
location where the harness must emit a trace event. Use it together with
`harness-generation` to instrument `dpdk/lib/ring/`.

## 1. Trace Event Schema

Per Category B (concurrent / lock-free), the trace is a per-thread event
sequence with `[start, end]` timestamps captured around the atomic
operation, plus a state snapshot captured **outside** the interval.

### Event envelope

```json
{
  "tid":   "<thread id, e.g. lcore0>",
  "name":  "<spec action name, e.g. ProdMoveHead_LoadHead>",
  "start": <rdtsc tick>,
  "end":   <rdtsc tick>,
  "state": { ... post-state snapshot, see below ... },
  "args":  { ... action arguments, e.g. n, stage ... }
}
```

The harness preprocessor groups events by `tid` and emits a JSON object
`{ tid: [event...] }` consumed by `Trace.tla`.

### State fields (captured at every event)

| Field                | C source                                    | Spec variable        |
|----------------------|---------------------------------------------|----------------------|
| `prodHead`           | `r->prod.head` (`rte_ring_core.h:66`)       | `prodHead`           |
| `prodTail`           | `r->prod.tail` (`rte_ring_core.h:67`)       | `prodTail`           |
| `consHead`           | `r->cons.head`                              | `consHead`           |
| `consTail`           | `r->cons.tail`                              | `consTail`           |
| `rtsProdHeadCnt`     | `r->rts_prod.head.val.cnt` (`core.h:81`)    | `rtsProdHeadCnt`     |
| `rtsProdHeadPos`     | `r->rts_prod.head.val.pos` (`core.h:82`)    | `rtsProdHeadPos`     |
| `rtsProdTailCnt`     | `r->rts_prod.tail.val.cnt`                  | `rtsProdTailCnt`     |
| `rtsProdTailPos`     | `r->rts_prod.tail.val.pos`                  | `rtsProdTailPos`     |
| `rtsConsHead{Cnt,Pos}`, `rtsConsTail{Cnt,Pos}` | `r->rts_cons.*`           | analogous            |
| `sStageHead[s]`      | `r->stage[s].sht.head` (`soring.h:78`)      | `sStageHead[s]`      |
| `sStageTailPos[s]`   | `r->stage[s].sht.tail.pos` (`soring.h:71`)  | `sStageTailPos[s]`   |
| `sStageTailSync[s]`  | `r->stage[s].sht.tail.sync` (`soring.h:70`) | `sStageTailSync[s]`  |
| `sStateStnum[s][i]`  | `r->state[i].stnum` (`soring.h:37`)         | `sStateStnum[s][i]`  |
| `sStateFtoken[s][i]` | `r->state[i].ftoken` (`soring.h:36`)        | `sStateFtoken[s][i]` |

### Args (event-specific)

- `n`: requested batch size (for `*MoveHead*`, `Acquire`, `Release`, `PeekStart`)
- `stage`: SORING stage index (for SORING events)
- `ftoken`: SORING ftoken returned by acquire / passed to release

## 2. Action-to-Code Mapping

Each entry: spec action — code location — trigger point — event name — fields.

### Default mode (rte_ring_c11_pvt.h)

| Spec action              | Code location                        | Trigger point                         | Event name              | Fields              |
|--------------------------|--------------------------------------|----------------------------------------|-------------------------|---------------------|
| `ProdMoveHead_LoadHead`  | `rte_ring_c11_pvt.h:92-93`           | After acquire-load of `d->head`        | `ProdMoveHead_LoadHead` | `n`, state          |
| `ProdMoveHead_LoadTail`  | `rte_ring_c11_pvt.h:104-105`         | After acquire-load of `s->tail`        | `ProdMoveHead_LoadTail` | state               |
| `ProdMoveHead_CAS`       | `rte_ring_c11_pvt.h:137-140`         | After CAS attempt (success or fail)    | `ProdMoveHead_CAS`      | success flag, state |
| `ProdWriteRing`          | `rte_ring_elem.h __rte_ring_enqueue_elems` | After memcpy completes           | `ProdWriteRing`         | state               |
| `ProdUpdateTail`         | `rte_ring_c11_pvt.h:36-44`           | After release-store of `ht->tail`      | `ProdUpdateTail`        | state               |
| `ConsMoveHead_*`         | mirrors of prod side, cons paths     | analogous                              | `ConsMoveHead_*`        | analogous           |
| `ConsUpdateTail`         | `rte_ring_c11_pvt.h:36-44`           | analogous                              | `ConsUpdateTail`        | state               |

### HTS mode (rte_ring_hts_elem_pvt.h)

| Spec action          | Code location                              | Trigger point                       | Event name           |
|----------------------|--------------------------------------------|--------------------------------------|----------------------|
| `HTSProdHeadWait`    | `hts_elem_pvt.h:119` (after `head_wait`)  | After head_wait returns              | `HTSProdHeadWait`    |
| `HTSProdLoadStail`   | `hts_elem_pvt.h:126`                      | After acquire-load of `s->tail`      | `HTSProdLoadStail`   |
| `HTSProdCAS`         | `hts_elem_pvt.h:155-158`                  | After CAS attempt                    | `HTSProdCAS`         |
| `HTSProdUpdateTail`  | `hts_elem_pvt.h:42`                       | After release-store of `ht->ht.pos.tail` | `HTSProdUpdateTail` |
| `HTSCons*`           | mirrors                                    | analogous                            | `HTSCons*`           |

### RTS mode (rte_ring_rts_elem_pvt.h) — **Family A target**

| Spec action                      | Code location                | Trigger point                         | Event name                       | Notes |
|----------------------------------|------------------------------|----------------------------------------|----------------------------------|-------|
| `RTSProdHeadWait`                | `rts_elem_pvt.h:133`         | After `__rte_ring_rts_head_wait` returns | `RTSProdHeadWait`              | captures `rtsProdHead{Cnt,Pos}` |
| `RTSProdLoadStail`               | `rts_elem_pvt.h:140`         | After acquire-load of `s->tail`        | `RTSProdLoadStail`               |       |
| `RTSProdCAS`                     | `rts_elem_pvt.h:169-172`     | After CAS attempt (success or fail)    | `RTSProdCAS`                     |       |
| `RTSProdUpdateTail_LoadTail`     | `rts_elem_pvt.h:45`          | After A0.a acquire-load of `ht->tail.raw` | `RTSProdUpdateTail_LoadTail`  | captures local `ot.{cnt,pos}` |
| `RTSProdUpdateTail_LoadHead`     | `rts_elem_pvt.h:49`          | After **relaxed** load of `ht->head.raw` | `RTSProdUpdateTail_LoadHead`   | **Family A residual** — capture observed `h.{cnt,pos}` and the actually-current `ht->head.raw` separately so a stale view can be detected post-hoc |
| `RTSProdUpdateTail_Compute`      | `rts_elem_pvt.h:51-53`       | After computing `nt`                   | `RTSProdUpdateTail_Compute`      |       |
| `RTSProdUpdateTail_CAS`          | `rts_elem_pvt.h:59-61`       | After CAS attempt                      | `RTSProdUpdateTail_CAS`          | captures success/fail |
| `RTSCons*`                       | mirrors                       | analogous                              | `RTSCons*`                       |       |

### SORING (soring.c) — **Family D target**

| Spec action                  | Code location          | Trigger point                                   | Event name                  |
|------------------------------|------------------------|-------------------------------------------------|------------------------------|
| `SORingAcquire_MoveHead`     | `soring.c:228-247`     | After CAS in `__rte_soring_stage_move_head`    | `SORingAcquire_MoveHead`    |
| `SORingAcquire_UpdateState`  | `soring.c:362-378`     | After relaxed-store of state at line 376       | `SORingAcquire_UpdateState` |
| `SORingRelease_LoadState`    | `soring.c:461-462`     | After relaxed-load of state                    | `SORingRelease_LoadState`    |
| `SORingRelease_StoreFinish`  | `soring.c:476-480`     | After fence + relaxed-store of FINISH state    | `SORingRelease_StoreFinish`  |
| `SORingRelease_LoadTail`     | `soring.c:483`         | After relaxed-load of `stg->sht.tail.pos`      | `SORingRelease_LoadTail`     |
| `SORingFinalize_LoadTail`    | `soring.c:77-78`       | After acquire-load of `sht->tail.raw`          | `SORingFinalize_LoadTail`    |
| `SORingFinalize_CAS`         | `soring.c:86-88`       | After CAS to grab sync bit                     | `SORingFinalize_CAS`         |
| `SORingFinalize_StoreTail`   | `soring.c:122-124`     | After release-store of new tail.pos + sync=0   | `SORingFinalize_StoreTail`   |

### Peek API (rte_ring_peek_elem_pvt.h, rte_ring_peek_zc.h)

| Spec action  | Code location                        | Trigger point                           | Event name  |
|--------------|--------------------------------------|------------------------------------------|-------------|
| `PeekStart`  | `peek_elem_pvt.h:113-140`            | After head move (ST or HTS branch)       | `PeekStart` |
| `PeekFinish` | `peek_elem_pvt.h:30-63` + zc finish  | After `__rte_ring_*_set_head_tail`       | `PeekFinish`|

### Family-B caller misuse (no instrumentation needed)

Family B is enforced by the **harness driver**, not by ring-internal
instrumentation. The harness chooses an API entry-point and a ring
sync_type non-deterministically. Mismatches are recorded by the harness
via a top-level `MisuseAPI` event before the body of the call.

## 3. Special Considerations

### State capture timing for the stale-head load (Family A)

`RTSProdUpdateTail_LoadHead` is the most delicate event. The harness
must:

1. Capture `local_h_observed = h.raw` **inside** the relaxed load
   (`rts_elem_pvt.h:49`) and emit it as `args.h_observed_{cnt,pos}`.
2. Capture `current_head = ht->head.raw` **outside** the interval (after
   the load returns) using a **separate acquire-load** that is *not*
   inside the producer-thread's timing window.
3. The trace post-processor then knows whether the observed value was
   stale (different from `current_head` at the same wall-clock
   instant). The Trace spec's `OnRTSProdUpdateTail_LoadHead` only checks
   that `ev.state.rtsProdHead{Cnt,Pos}` is consistent with what the spec
   action would assign at default; under stale-head injection, TLC
   explores prior-value branches via `MCStaleHeadRTS`.

### State capture timing for SORING release (Family D.2)

The release event sequence is: write ring → fence → store FINISH → load
tail.pos. Because the FINISH store is relaxed, peers may not observe it
when the next thread loads tail.pos. The harness should:

- Emit `SORingRelease_StoreFinish` immediately after the relaxed store.
- Emit `SORingRelease_LoadTail` immediately after the relaxed tail.pos
  load, capturing both the loaded value and the actual current value of
  tail.pos for diagnostic purposes (the harness can use a separate
  acquire-load to read the "true" tail.pos for the trace state field).

### Family D.3 (wrong release n) instrumentation

This is harness-driven misuse: the test program calls `rte_soring_release`
with `n` deliberately differing from the value returned by the most
recent `rte_soring_acquire_*`. Capture both `n_acquired` (from the
`SORingAcquire_UpdateState` event) and `n_released` (from the call into
`rte_soring_release`) so post-hoc analysis can detect the mismatch.

### Family D.4 (ftoken wrap) instrumentation

The 32-bit pos counter wraps at 2^32. Real-world wrap takes ~10s of
seconds at 100 Mops; for testing, the harness can build with a custom
small `pos_mask` (or run a billion-element synthetic burst). Capture
`pos` and `ftoken` on every acquire so a wrap collision can be detected
across the captured trace.

### Bootstrap state

`TraceInit` must match the initial ring state set by `rte_ring_init`:

- All head/tail = 0
- `sync_type` = the configured mode
- All SORING state slots `EMPTY` (raw = 0)
- All ring slots = 0

### Concurrent threads

The DPDK ring is invoked from multiple lcores. Each lcore has a unique
`tid` value; the preprocessor groups by `tid`. The harness must not
emit events for lcores running *outside* the ring API (those events
would have no spec correspondent and would cause `TraceMatched` to
fail).

### Per-mode trace files

Generate separate trace runs per mode: `trace_mt.ndjson`,
`trace_hts.ndjson`, `trace_rts.ndjson`, `trace_soring.ndjson`,
`trace_peek.ndjson`. Run `Trace.cfg` once per mode by setting `Mode`
in the config and the `JSON` IO env var to the matching trace file.

### Field-omission on zero values

The DPDK `rte_log` JSON encoder may omit zero-valued fields. The
harness should always emit numeric fields explicitly (using `"%u"` not
`"%d"`) so the trace post-processor can parse them without ambiguity.
