# DPDK rte_ring — Trace Instrumentation Guide

## Overview

This harness instruments DPDK's `rte_ring` lock-free ring buffer to emit NDJSON traces for TLA+ trace validation. The instrumentation covers all three sync modes (MPMC, HTS, RTS) and captures the two-phase commit protocol: reserve head via CAS, copy data, publish tail.

## Architecture

```
harness/
├── src/
│   ├── rte_ring_tla_trace.h    # Trace emission header (copied into DPDK source)
│   └── test_ring_trace.c       # Test scenarios that exercise ring operations
├── patches/
│   └── instrumentation.patch   # Patches 3 DPDK ring headers to add trace calls
├── apply.sh                    # Applies instrumentation to DPDK source
├── run.sh                      # End-to-end: apply → build → test → report
└── INSTRUMENTATION.md          # This file
```

## Instrumentation Points

Each enqueue/dequeue function gets 3 trace events, matching the spec's two-phase commit:

| Event | Placement | State Check | Spec Action |
|-------|-----------|-------------|-------------|
| `ReserveProd` | After `move_prod_head()` returns | Weak (heads only) | `ReserveProd(t)` |
| `ReserveCons` | After `move_cons_head()` returns | Weak (heads only) | `ReserveCons(t)` |
| `WriteData` | After `enqueue_elems`/`dequeue_elems` | None | `WriteData(t)` |
| `PublishTail` | After `update_tail()` returns | Strong (all 4 positions) | `PublishTail(t)` |

### Instrumented Files

The patch modifies 3 headers in `artifact/dpdk/lib/ring/`:

1. **`rte_ring_elem_pvt.h`** — MPMC mode (`__rte_ring_do_enqueue_elem`, `__rte_ring_do_dequeue_elem`)
2. **`rte_ring_hts_elem_pvt.h`** — HTS mode (`__rte_ring_do_hts_enqueue_elem`, `__rte_ring_do_hts_dequeue_elem`)
3. **`rte_ring_rts_elem_pvt.h`** — RTS mode (`__rte_ring_do_rts_enqueue_elem`, `__rte_ring_do_rts_dequeue_elem`)

All trace calls are guarded by `#ifdef DPDK_TLA_TRACE` — zero overhead when disabled.

### Trace Header: `rte_ring_tla_trace.h`

Key design decisions:

- **Mode-aware state snapshot**: `__tla_snap_state()` reads head positions differently for RTS mode because `r->prod.head` (offset 0) overlaps with `rts_prod.tail.val.cnt` in RTS. For RTS, head position comes from `rts_prod.head.val.pos` (offset 20). Tail positions are at a consistent offset across all modes.
- **Thread ID**: Thread-local `__tla_tid` set by the test harness via `tla_trace_set_thread_id()`. Thread IDs are 1-based integers, emitted as `"t1"`, `"t2"`, `"t3"` to match `Trace.cfg` constants.
- **Serialization**: Mutex-protected FILE writes with `fflush` after each event. Simple and correct; performance is not a concern for short traces.
- **Timestamps**: Real monotonic nanoseconds from `CLOCK_MONOTONIC`. Used for ordering analysis, not by TLC.

## NDJSON Event Format

```json
{"tag":"trace","ts":"<ns>","event":"ReserveProd","thread":"t1","n":1,"state":{"prodHead":1,"prodTail":0,"consHead":0,"consTail":0}}
{"tag":"trace","ts":"<ns>","event":"WriteData","thread":"t1","state":{"prodHead":1,"prodTail":0,"consHead":0,"consTail":0}}
{"tag":"trace","ts":"<ns>","event":"PublishTail","thread":"t1","state":{"prodHead":1,"prodTail":1,"consHead":0,"consTail":0}}
```

## Test Scenarios

| Scenario | Mode | Threads | Operations | Trace File |
|----------|------|---------|------------|------------|
| `basic_mpmc` | MPMC | 1 (t1) | 3 enq + 3 deq | `basic_mpmc.ndjson` |
| `concurrent_mpmc` | MPMC | 3 (t1, t2 produce; t3 consumes) | 2 enq + 2 deq | `concurrent_mpmc.ndjson` |
| `basic_hts` | HTS | 1 (t1) | 2 enq + 2 deq | `basic_hts.ndjson` |

## Running

From the case-study root (`case-studies/dpdk-ring/`):

```bash
# Full pipeline
bash harness/run.sh

# Traces appear in traces/
ls traces/*.ndjson
```

Prerequisites: `gcc`, `meson`, `ninja`, `python3`, `pyelftools`, `libnuma-dev`.

## Trace Validation

```bash
# MPMC trace
java -jar ../../lib/tla2tools.jar \
    -config spec/Trace.cfg spec/Trace.tla \
    -DJSON=traces/basic_mpmc.ndjson

# HTS trace (uses different Mode constant)
java -jar ../../lib/tla2tools.jar \
    -config spec/Trace_hts.cfg spec/Trace.tla \
    -DJSON=traces/basic_hts.ndjson
```

Expected outcome: TLC reports "deadlock reached" after consuming all trace events — this is success (deadlock-based completion checking).

## Validation Results

| Trace | Status | States | Notes |
|-------|--------|--------|-------|
| `basic_mpmc.ndjson` | PASS | 20 generated, 2532 distinct | FIFO verified: enqueued=<<1,2,3>>, dequeued=<<1,2,3>> |
| `basic_hts.ndjson` | PASS | 14 generated, 330 distinct | FIFO verified: enqueued=<<1,2>>, dequeued=<<1,2>> |
| `concurrent_mpmc.ndjson` | KNOWN ISSUE | 6 generated | Concurrent CAS interleaving not matched by spec — see below |

### Concurrent Trace Issue

The `concurrent_mpmc` trace fails because concurrent CAS operations create state transitions invisible to a single-thread trace observer. When t1 and t2 simultaneously CAS `prodHead`, t2's `WriteData` event may observe t1's CAS effect (prodHead already advanced), but t1's `ReserveProd` event hasn't been emitted yet. The spec cannot account for this without additional silent actions.

This is expected for Phase 3 work. Solutions:
1. Add a `SilentReserveProd` silent action in Trace.tla for unobserved concurrent reservations
2. Post-process traces to reorder events by logical timestamp (old_head values)
3. Use per-thread trace buffers with happens-before merging

## Key Pitfalls

1. **RTS head position**: Never read `r->prod.head` in RTS mode — it overlaps with the tail's reference counter. Use `r->rts_prod.head.val.pos` instead.

2. **Ring capacity**: `rte_ring_create("name", count, ...)` with `RING_F_EXACT_SZ` gives capacity=count. Without that flag, capacity rounds up to next power of 2. `Trace.cfg` Capacity must match.

3. **Thread constants**: `Trace.cfg` must use string constants (`Thread = {"t1", "t2", "t3"}`), not model values (`Thread = {t1, t2, t3}`), because JSON trace values are strings.

4. **Position arithmetic**: TLA+ uses `WrapPos(x) == x % (2 * Capacity)` while DPDK uses raw uint32_t. For short traces where positions stay below `2 * Capacity`, values match directly.

5. **SilentStaleRead**: Before `ReserveCons`, the spec requires `visibleProdTail[t]` to be updated from 0 to the actual `prodTail`. The Trace.tla's `SilentStaleRead` handles this automatically.

6. **DPDK EAL**: Requires `--no-huge` for non-hugepage operation. CPU affinity via `--lcores=` must list available CPUs (check `/proc/self/status`).
