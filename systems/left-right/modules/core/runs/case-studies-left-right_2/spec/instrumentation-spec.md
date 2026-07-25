# Instrumentation Spec — left-right Round 2

This document maps the Round-2 `Trace.tla` actions to source code locations
in `artifact/left-right/src/`.  The instrumentation already exists at
`artifact/left-right/src/tla_trace.rs`; this document records the contract
that the harness relies on.

System category: **B (Concurrent / Lock-Free)** — uses per-thread NDJSON
trace files with `[start, end]` timestamp intervals.  TLC searches viable
interleavings via `ViablePIDs` in `Trace.tla`.

---

## Section 1: Trace Event Schema

### Common envelope

Each event line is one JSON object with:

| Field | Type | Description |
|---|---|---|
| `tag` | `"trace"` | Static tag (filtered by preprocessor) |
| `event` | string | Event name; one of the names in Section 2 |
| `tid` | string | Thread identifier; must match TLA+ Reader id (e.g. `"r1"`, `"r2"`) or `"writer"` |
| `start` | uint64 | Timestamp (ns since trace init) when the operation began |
| `end` | uint64 | Timestamp when the operation completed |
| `state` | object | Post-state snapshot — fields per event (Section 2) |

### State fields

Mapping from implementation state → TLA+ variable.  Captured *outside*
the `[start, end]` interval (immediately after the operation completes)
to keep the timebox tight.

| Implementation expression | TLA+ field name | TLA+ variable | Notes |
|---|---|---|---|
| `self.epoch.load(Relaxed)` | `epoch` | `epoch[r]` | reader thread |
| `self.enters.get()` | `enters` | `enters[r]` | reader thread |
| `pointer_name(r_handle as usize)` | `pointer` | `inner_ptr` | "L"/"R"/"null" |
| `self.first` | `first` | `first` | writer thread |
| `self.second` | `second` | `second` | writer thread |
| `self.taken` | `taken` | `taken` | writer thread |
| (n/a — not captured) | `copyL` / `copyR` | `copyData[c]` | reserved for future deep-validation |

### Pointer mapping

Real pointers are mapped to symbolic `"L"` / `"R"` / `"null"` via the
static `L_ADDR` / `R_ADDR` registered at scenario init.  See
`tla_trace.rs:32-35` (`L_ADDR`, `R_ADDR`) and
`tla_trace.rs:63-66` (`set_pointer_mapping`).

Scenario harnesses must call `set_pointer_mapping(l_addr, r_addr)` once
after constructing the (`WriteHandle`, `ReadHandle`) pair, where:
- `l_addr` = the address of the *initial* read pointer (the buffer
  `inner_ptr` points to in `Init`).
- `r_addr` = the address of the *initial* `w_handle` (the buffer
  `writerCopy` is in `Init`).

These come from the trace accessor functions on the handles
(`_tla_trace_inner_addr`, `_tla_trace_w_handle_addr`).

---

## Section 2: Action-to-Code Mapping

| Spec action | Code location | Trigger | Event name | State fields | Notes |
|---|---|---|---|---|---|
| `TraceReaderEnter` | `read.rs:177-205` (fresh enter, non-NULL) | After mint of guard at `read.rs:196-199` | `ReaderEnter` | `epoch`, `enters`, `pointer` | Emit only on the non-NULL path; the NULL path emits `ReaderEnterNone`. |
| `TraceReaderEnterNone` | `read.rs:206-213` (fresh enter, NULL) | After the parity-restore `fetch_add` at `read.rs:209` | `ReaderEnterNone` | `epoch` | Do NOT emit `enters` — see comment at `tla_trace.rs:204-219` (TLC evaluates conjuncts in order; emitting `enters` would conflict with `UNCHANGED`). |
| `TraceReaderEnterNested` | `read.rs:120-148` (nested, non-NULL) | After mint of nested guard at `read.rs:135-138` | `ReaderEnterNested` | `enters`, `pointer` | Do NOT emit `epoch` — see comment at `tla_trace.rs:221-237`. The nested-NULL branch (`read.rs:146`) panics and never emits. |
| `TraceReaderExit` | `guard.rs:117-130` (`ReadGuard::Drop`) | After the parity-restore `fetch_add` at `guard.rs:124` (or after `enters.set()` at `guard.rs:121` if no `fetch_add`) | `ReaderExit` | `epoch`, `enters` | The `enters == 0` branch is the fully-released case; both fields are post-state. |
| `TraceWriterAppend` | `write.rs:497-506` (`append`) | After the inner `extend()` returns at `write.rs:501` | `WriterAppend` | `first`, `second` | Single-op append.  Bundles the first-mode direct-apply path and the post-publish oplog-push path. |
| `TraceWriterPublish` | `write.rs:370-391` (`publish`) | After `update_and_swap` returns at `write.rs:384` | `WriterPublish` | `pointer`, `first`, `second` | Bundles wait + apply + swap + fence + per-reader snap atomically. |
| `TraceWriterTryPublishOk` | `write.rs:320-362` (`try_publish` success) | After `update_and_swap` at `write.rs:354` (success branch) | `WriterTryPublishOk` | `pointer`, `first`, `second` | Same post-state shape as `WriterPublish`. |
| `TraceWriterTryPublishFail` | `write.rs:320-362` (`try_publish` fail) | At the early-return point `write.rs:342-348` | `WriterTryPublishFail` | `pointer`, `first`, `second` | No state mutation; spec validates pointer/first/second unchanged. |
| `TraceWriterTakeInner` | `write.rs:149-210` (`take_inner`) | After the `boxed_r_handle` line at `write.rs:198` (just before the `Some(Taken { ... })` construction) | `WriterTakeInner` | `pointer` (= "null"), `first`, `taken` | Bundles internal publish(es) + NULL-swap + wait + drop_first.  Note: `drop_second` (the `Taken::drop` call site at `write.rs:135`) runs AFTER this event when `WriteHandle::drop` calls `drop(inner)` at `write.rs:219`, but the spec models `releasedCopy` and `copyAlive` updates inside this single trace transition. |

### Suppression

Some public-API methods invoke other public-API methods internally; we
suppress nested emissions so each top-level call emits exactly one event:

- `WriteHandle::append` calls `extend`, which calls `enter()` in
  first-mode (`write.rs:569`).  The internal `enter()` is suppressed via
  `SuppressGuard` at `write.rs:500-502`.
- `WriteHandle::take_inner` may call `publish()` up to twice
  (`write.rs:166-171`).  These are suppressed via `SuppressGuard` at
  `write.rs:159`.

The `SuppressGuard` is RAII; it bumps `SUPPRESS_DEPTH` on construction
and drops it on `Drop` (`tla_trace.rs:101-122`).

---

## Section 3: Special Considerations

### 3.1 Snap loop is internal-only

The base spec's per-reader snap actions (`WriterPubSnapReader(r)`,
`WriterTakeInnerPubSnapReader(r)`) and the F4 invariant they support are
NOT directly observable in the trace — readers don't see the writer's
`epoch.load(Acquire)` for their slot.  The trace records the bundled
`WriterPublish` event with the post-snap state.  TLC validates the
bundled transition; per-reader snap interleavings are exercised by
`MC.tla` only.

### 3.2 take_inner emits unconditionally

`emit_writer_take_inner` (`tla_trace.rs:307-318`) does NOT check
`is_suppressed()`.  This is intentional: even if `take_inner` was called
from inside another suppressed scope (it should not be, but defense-
in-depth), we want this event to surface so the trace can validate the
critical drop sequence.

### 3.3 ReaderEnterNested cannot observe NULL

In the real implementation, the nested-enter NULL branch panics at
`read.rs:146`.  No trace event is ever emitted on that path, because
the `unreachable!()` aborts the thread.  Therefore `TraceReaderEnterNested`
in the spec only models the non-NULL branch.

The F2 panic itself is a Modeling-only concern in MC.tla; trace
validation cannot directly observe the panic (it crashes before the
trace flush).  Test-verifiable approach: see brief §6.2 TV-2.

### 3.4 Bootstrap state

`TraceInit` reuses `base!Init`, which sets:
- `inner_ptr = "L"`, `writerCopy = "R"` (matches `lib.rs:300-302`)
- All readers `registered = TRUE` with `epoch = 0`

Scenario harnesses must respect this initial mapping when calling
`set_pointer_mapping`.

### 3.5 Reader thread name registration

Each reader thread must call `set_thread_name(...)` BEFORE its first
trace emission.  The names must match the TLC `Reader` constant set
(default: `"r1"`, `"r2"`).  Without this, the per-thread NDJSON file
would be keyed by the OS thread id and the spec's `MapReader` would
return values not in `Reader`, causing a deadlock.

The writer thread must set `set_thread_name("writer")`.

### 3.6 Non-modeled events

The following emissions in `tla_trace.rs` are NOT consumed by the
trace spec:
- `try_publish` fail / ok variants are both supported, but bug-hunting
  for try_publish-specific behavior is via `MC.tla` only.

The following spec actions are NOT instrumented because they have no
public observation point:
- All `Writer*` per-stage actions (`WriterStartPublish`, `WriterWait`,
  etc.).  These exist in the base spec for the granularity required by
  MC bug hunting but are bundled in the trace.
- `ClientHoldGuardSet`/`Release` (F3 adversary; spec-only).
