# Instrumentation Spec — arc-swap (round 3)

This document specifies how to instrument the arc-swap implementation so it
produces traces compatible with `Trace.tla`.  Every spec action has exactly
one trace event type; every event captures the fields that `Trace.tla`
validates.

The hooks are inserted at the source-code positions cited from each entry.
The implementation already contains many `crate::tla_trace::emit_*` calls
(see `src/tla_trace.rs` for the helper module); this document is the
authoritative specification for what each hook must capture.

## Section 1: Trace Event Schema

### 1.1 Common envelope

Every event is a single NDJSON line containing:

| Field | Type | Description |
|---|---|---|
| `event` | string | one of the action names below (e.g., `"ReaderFastLoad"`) |
| `seq` | int | global monotonically-increasing per-process sequence number |
| `thread` | string | thread id, mapped to spec constant `t1`/`t2`/... |
| `state` | object | post-state snapshot of fields the spec checks |
| (event-specific) | varies | see per-event tables below |

The `seq` field provides the total order over events.  The harness must emit
events in a single contiguous critical section so `seq` reflects program
order; on multi-thread runs, the harness uses a global atomic counter and
emits the line after the operation that the event represents.

### 1.2 State snapshot fields

`state` is a record of the fields that change in the action.  Its fields
match the spec variables in the corresponding TR_* wrapper.  For brevity,
each event captures only the fields its action modifies — not the full state.

| Field | Spec variable | Type |
|---|---|---|
| `storageAddr` | `storageAddr` | string (Addr) |
| `rPC` | `rPC[t]` | string |
| `rPath` | `rPath[t]` | string |
| `rOpAddr` | `rOpAddr[t]` | string |
| `rConfirmAddr` | `rConfirmAddr[t]` | string |
| `rDebtSlot` | `rDebtSlot[t]` | int |
| `wPC` | `wPC[t]` | string |
| `wCurNode` | `wCurNode[t]` | string |
| `helpControl` | `helpControl[t]` | string ("IDLE" / "GEN" / "REPL") |
| `helpGen` | `helpGen[t]` | int |
| `helpSlot` | `helpSlot[t]` | string |
| `nodeState` | `nodeState[n]` | string ("UNUSED" / "USED" / "COOLDOWN") |
| `activeWriters` | `activeWriters[n]` | int |
| `casKind` | `casKind[t]` | string ("Arc" / "Guard" / "RawFresh" / "RawStale") |

### 1.3 Address mapping

The harness assigns a stable string id (`a1`, `a2`, ...) to each `*const T::Base`
the first time it is observed.  The map is stored in `tla_trace.rs` as a
`Mutex<HashMap<usize, String>>`.  The id is emitted in trace events; spec
constants match the same set.

The same scheme maps thread ids (rust `ThreadId` → `t1`/`t2`/...) and node
pointers (`*const Node` → `t1`/`t2`/... — registered via `register_node` from
`Node::get`).

## Section 2: Action-to-Code Mapping

The `tla_trace::emit_*` calls and `register_node` already exist in the
artifact.  This section names each spec action with its source location and
trace event type.

### 2.1 Reader fast path (strategy/hybrid.rs:42-72)

| Spec Action | Code Location | Trigger | Event | Fields |
|---|---|---|---|---|
| `ReaderFastLoad` | `strategy/hybrid.rs:45` | after `storage.load(Relaxed)` returns | `ReaderFastLoad` | `state.rPC`, `state.rOpAddr` |
| `ReaderFastSlotAcquire` | `debt/fast.rs:59` | after `slot.0.swap(ptr, SeqCst)` returns | `ReaderFastSlotAcquire` | `state.rPC`, `state.rDebtSlot` |
| `ReaderFastConfirmLoad` | `strategy/hybrid.rs:53` | after `storage.load(SeqCst)` returns | `ReaderFastConfirmLoad` | `state.rPC`, `state.rConfirmAddr` |
| `ReaderFastBranchHit` | `strategy/hybrid.rs:55` | after `if ptr == confirm` taken (success branch) | `ReaderFastBranchHit` | `state.rPC` |
| `ReaderFastResolve` | `strategy/hybrid.rs:62, :67` | after `debt.pay::<T>(ptr)` returns (either leg) | `ReaderFastResolve` | `state.rPC` |

### 2.2 Reader fallback path (strategy/hybrid.rs:75-103)

| Spec Action | Code Location | Trigger | Event | Fields |
|---|---|---|---|---|
| `ReaderFallbackActiveAddr` | `debt/helping.rs:204` (after `active_addr.store`) | after `active_addr.store(ptr, SeqCst)` | `ReaderFallbackActiveAddr` | `state.rPC`, `state.rPath` |
| `ReaderFallbackControlSwap` | `debt/helping.rs:210` | after `control.swap(gen, SeqCst)` returns | `ReaderFallbackControlSwap` | `state.rPC`, `state.helpControl`, `state.helpGen` |
| `ReaderFallbackCandidate` | `strategy/hybrid.rs:84` | after `storage.load(SeqCst)` returns | `ReaderFallbackCandidate` | `state.rPC`, `state.rConfirmAddr` |
| `ReaderFallbackSlotStore` | `debt/helping.rs:313` | after `slot.0.swap(ptr, SeqCst)` | `ReaderFallbackSlotStore` | `state.rPC`, `state.helpSlot` |
| `ReaderFallbackConfirmOK` | `debt/helping.rs:319` (success branch) | after `control.swap(IDLE, SeqCst)` when `prev == gen` | `ReaderFallbackConfirmOK` | `state.rPC`, `state.helpControl` |
| `ReaderFallbackConfirmHelped` | `debt/helping.rs:323` (Err branch) | after `control.swap(IDLE, SeqCst)` when `prev == REPL` | `ReaderFallbackConfirmHelped` | `state.rPC`, `rGotEnvelope=true` (implicit) |
| `ReaderFallbackResolveEnvelope` | `strategy/hybrid.rs:97-100` | after caller-side cleanup (pay_back / T::dec) | `ReaderFallbackResolveEnvelope` | `state.rPC` |

### 2.3 Guard / client harness (Family C)

| Spec Action | Code Location | Trigger | Event | Fields |
|---|---|---|---|---|
| `DropGuard` | `strategy/hybrid.rs:114` | first line of `Drop::drop` | `DropGuard` | `thread` |
| `GuardIntoInner` | `strategy/hybrid.rs:144` | first line of `into_inner` | `GuardIntoInner` | `thread` |
| `SendGuard` | harness only | when test harness moves a Guard between threads | `SendGuard` | `src`, `dst` |

The `SendGuard` event is *test-harness only* — there is no corresponding
implementation hook because Send is implicit in Rust ownership transfer.  The
Family-C test harness in `tla_trace.rs` records the source/dest threads when
it moves a guard manually as part of the test.

### 2.4 Writer (lib.rs / debt/mod.rs)

| Spec Action | Code Location | Trigger | Event | Fields |
|---|---|---|---|---|
| `WriterSwap` | `lib.rs:486` | after `self.ptr.swap(new, SeqCst)` returns | `WriterSwap` | `state.wPC`, `state.storageAddr` |
| `WriterPayInit` | `debt/mod.rs:92` | after `T::inc(&val)` returns | `WriterPayInit` | `state.wPC` |
| `WriterTraverseLoad` | `debt/list.rs:103` | after `LIST_HEAD.load(SeqCst)` returns | `WriterTraverseLoad` | `state.wPC` |
| `WriterReserveNode` | `debt/list.rs:146` | after `active_writers.fetch_add(1, Acquire)` returns | `WriterReserveNode` | `state.wPC`, `state.wCurNode`, `state.activeWriters` |
| `WriterHelpNode` | `debt/mod.rs:99` | after `local.help(node, ...)` returns | `WriterHelpNode` | `state.wPC` |
| `WriterScanSlot` | `debt/mod.rs:113` | after each `slot.pay::<T>(ptr)` returns (per slot) | `WriterScanSlot` | `node`, `slot_idx`, `result` (true/false) |
| `WriterReleaseNode` | `debt/list.rs:57` | inside `Drop for NodeReservation`, after `fetch_sub` | `WriterReleaseNode` | `node`, `prev` (active_writers value) |
| `WriterPayDone` | `debt/mod.rs:119` | after `pay_all` closure returns | `WriterPayDone` | `state.wPC` |
| `WriterReturn` | `lib.rs:489-490` | after `wait_for_readers` returns | `WriterReturn` | `state.wPC` |

### 2.5 CompareAndSwap (Family C — strategy/hybrid.rs:217-244)

| Spec Action | Code Location | Trigger | Event | Fields |
|---|---|---|---|---|
| `CASBegin` | `strategy/hybrid.rs:223` | first line of `loop {}` | `CASBegin` | `state.casKind`, `state.rPC=cas_after_load` |
| `CASCompareNotEqual` | `strategy/hybrid.rs:227` | after `if old.as_ptr() != current.as_raw()` returns true | `CASCompareNotEqual` | (no extra) |
| `CASExchangeOk` | `strategy/hybrid.rs:235` | after `compare_exchange_weak` succeeds | `CASExchangeOk` | `state.storageAddr` |
| `CASExchangeFail` | `strategy/hybrid.rs:243` | after `compare_exchange_weak` fails (bottom of loop) | `CASExchangeFail` | (no extra) |

### 2.6 Node lifecycle (debt/list.rs)

| Spec Action | Code Location | Trigger | Event | Fields |
|---|---|---|---|---|
| `ClaimNode` | `debt/list.rs:165` | after `compare_exchange(NODE_UNUSED, NODE_USED, SeqCst, SeqCst)` succeeds | `ClaimNode` | `node`, `state.nodeState` |
| `CheckCooldown` | `debt/list.rs:138` | after `compare_exchange(NODE_COOLDOWN, NODE_UNUSED, ...)` succeeds | `CheckCooldown` | `node`, `state.nodeState` |

These events fire inside `Node::get` and `Node::check_cooldown` respectively.
The harness must register the node pointer the first time it's observed (via
`crate::tla_trace::register_node`) so the `node` field in subsequent events
maps to the spec constant.

### 2.7 Object lifecycle (Family C)

| Spec Action | Code Location | Trigger | Event | Fields |
|---|---|---|---|---|
| `DropArcSwap` | `lib.rs:346` | inside `Drop::drop`, after `wait_for_readers` returns | `DropArcSwap` | (no extra; thread-implicit) |
| `PickRelaxSite` | harness-only | when test harness injects an ordering relaxation | `PickRelaxSite` | `site` (one of `RelaxSites`) |

`PickRelaxSite` is harness-only — it does not correspond to an implementation
hook, but it lets a fault-injection harness drive the spec's relaxation
adversary deterministically when needed (e.g., to recreate a specific bug).

## Section 3: Special Considerations

### 3.1 Thread → spec-thread mapping

The harness maintains a thread-local string id assigned at the first
observation of `std::thread::current().id()`.  IDs are stable across the
test, but the mapping must be consistent across threads (each id → exactly
one ThreadId).  The mapping table is logged in the trace preamble so the
spec consumer can audit it.

### 3.2 Address registration

Addresses are typically `*const T::Base` values.  Multiple observations of
the same numeric value must map to the same string id.  When an Arc is
deallocated and a different Arc is later allocated at the same numeric
address, this is **expected** under Family B (allocator reuse) — the harness
must NOT reuse the string id; it should mint a new id (e.g., `a3` after `a2`
freed) or emit both observations and let the spec's `addrGen` field
distinguish them.

For round 3, the harness emits a fresh string id on every observed
allocation (`alloc seq -> aN`) and the spec `addrGen` advances on each
`WriterSwap` to a freed address.  This matches the pre-`63fa111`
provenance-fix bug shape (Family B).

### 3.3 SendGuard / harness-only events

The four harness-only events (`SendGuard`, `PickRelaxSite`,
`GuardIntoInner` when not invoked from the standard load API, ...) are
emitted by adversarial test code, not by the implementation.  The trace
spec does not distinguish them syntactically; both real and harness-only
events use the same `event` field name.

### 3.4 Bootstrap state

The base spec's `Init` requires:

* `storageAddr = InitAddr` (the first-stored Arc)
* All nodes start `NODE_USED` with `nodeOwner[t] = t`
* `relaxSite = NoneSite`, `arcSwapDropped = FALSE`

The harness must arrange that the first `tla_trace.rs` event corresponds to
this initial state.  In practice, the harness initializes the ArcSwap with
a known starting Arc, registers it as `a1` (= `InitAddr`), and instruments
`THREAD_HEAD` initialization to ensure `nodeOwner` matches the thread's
spec id.

### 3.5 Concurrent threads & event ordering

The trace cursor `l` walks the log linearly.  arc-swap operations are
ns-level, but each event represents exactly one observable atomic op; the
harness's per-process atomic `seq` counter assigns a total order at hook
time.  This serializes events globally — sufficient for a Category A-style
trace replay.

If state-space search becomes prohibitive, switch to the Category B
timebox pattern (`pc[tid]` + `ViablePIDs`) per `trace-spec-pattern.md`.

### 3.6 NDJSON serialization quirks

* Boolean fields with default `false` are sometimes omitted in JSON.  Use
  the `serde_json::to_string` defaults — do NOT emit `null` for `false`.
* Integer fields may be emitted as either int or string; `Trace.tla` calls
  `MapAddr` / `MapThread` to canonicalize.
* The `state` object MUST contain ALL fields the corresponding TR_* wrapper
  validates; missing fields cause `ValidatePostState` to fail.

### 3.7 Round-3 emphasis: Family C harness coverage

Per the task brief, this round emphasizes caller-misuse + stale-snapshot
combined with an adversarial caller harness.  The harness should:

1. Spawn 2-3 reader threads + 1 writer thread on a shared `ArcSwap<T>`.
2. Have at least one reader call `Guard::into_inner` while a writer is
   mid-`pay_all` (Family C, brief §6.1 MC7).
3. Have at least one reader hold a guard across a thread boundary (`std::sync::mpsc`
   or `crossbeam-channel` to send the guard to a sibling thread that drops it).
4. Have at least one CAS use a raw pointer obtained from a `Guard` that has
   been dropped (Family C, brief §6.1 MC8).
5. Optionally, drop the `ArcSwap` at the end of the test while a reader holds
   a guard — this is a documented caller-precondition violation; the trace
   should NOT include this as a normal load event but the harness can emit
   it for negative-test purposes (Family C, brief §6.1 MC12).

The implementation hooks listed above are sufficient for these patterns;
the test harness composition lives in `harness/` and is tracked by the
`harness-generation` skill.
