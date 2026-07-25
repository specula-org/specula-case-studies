# Instrumentation Spec — arc-swap (round 4)

This document specifies how to instrument the arc-swap implementation so it
produces traces compatible with `Trace.tla`.  Every spec action has exactly
one trace event type; every event captures the fields that `Trace.tla`
validates.

The hooks are inserted at the source-code positions cited from each entry.
The implementation already contains many `crate::tla_trace::emit_*` calls
(see `src/tla_trace.rs` for the helper module); this document is the
authoritative specification for what each hook must capture.

Round 4 changes vs round 3:

* New hook `emit_reader_fallback_discard_node()` at `debt/list.rs:296` for
  Family 5's split between `new_helping`'s control swap and the
  `start_cooldown + self.node.take()` pair.
* New hook `emit_guard_clone()` at the test-harness's `Arc::clone(&*g) +
  Guard::from_inner` site (Family 2).
* Existing events extended to capture `localNode`, `pendingHelpingTx`, and
  per-node `inflightHelp` membership where the spec validates those fields.

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

The `seq` field provides the total order over events.  The harness emits
events in a single contiguous critical section so `seq` reflects program
order.

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
| `localNode` | `localNode[t]` | string ("t1"/.../"NONE") — F5 NEW |
| `pendingHelpingTx` | `pendingHelpingTx[t]` | bool — F5 NEW (TRUE iff helping transaction in flight; the impl's `gen \| GEN_TAG` is non-zero by virtue of GEN_TAG, so this maps to the `control != IDLE` predicate) |

### 1.3 Address mapping

The harness assigns a stable string id (`a1`, `a2`, ...) to each
`*const T::Base` the first time it is observed.  The map is stored in
`tla_trace.rs` as a `Mutex<HashMap<usize, String>>`.  The id is emitted in
trace events; spec constants match the same set.

The same scheme maps thread ids (rust `ThreadId` → `t1`/`t2`/...) and node
pointers (`*const Node` → `t1`/`t2`/... — registered via `register_node`
from `Node::get`).

### 1.4 Round-4 note: localNode capture

`localNode[t]` corresponds to the implementation's `LocalNode::node` cell
(`debt/list.rs:222`).  At every event, the harness emits the node id that
`self.node.get()` would return on the current thread.  After
`self.node.take()` (list.rs:296) localNode is `"NONE"`; subsequent events
on this thread until the next `Node::get()` call observe `localNode = "NONE"`.

## Section 2: Action-to-Code Mapping

### 2.1 Reader fast path (strategy/hybrid.rs:42-72)

| Spec Action | Code Location | Trigger | Event | Fields |
|---|---|---|---|---|
| `ReaderFastLoad` | `strategy/hybrid.rs:45` | after `storage.load(Relaxed)` returns | `ReaderFastLoad` | `state.rPC`, `state.rOpAddr` |
| `ReaderFastSlotAcquire` | `debt/fast.rs:59` | after `slot.0.swap(ptr, SeqCst)` returns | `ReaderFastSlotAcquire` | `state.rPC`, `state.rDebtSlot` |
| `ReaderFastConfirmLoad` | `strategy/hybrid.rs:53` | after `storage.load(SeqCst)` returns | `ReaderFastConfirmLoad` | `state.rPC`, `state.rConfirmAddr` |
| `ReaderFastBranchHit` | `strategy/hybrid.rs:55` | after `if ptr == confirm` taken (success branch) | `ReaderFastBranchHit` | `state.rPC` |
| `ReaderFastResolve` | `strategy/hybrid.rs:62, :67` | after `debt.pay::<T>(ptr)` returns (either leg) | `ReaderFastResolve` | `state.rPC` |

### 2.2 Reader fallback path (strategy/hybrid.rs:75-111 + helping.rs:191-339 + list.rs:288-319)

| Spec Action | Code Location | Trigger | Event | Fields |
|---|---|---|---|---|
| `ReaderFallbackActiveAddr` | `debt/helping.rs:204` (after `active_addr.store`) | after `active_addr.store(ptr, SeqCst)` | `ReaderFallbackActiveAddr` | `state.rPC`, `state.rPath` |
| `ReaderFallbackControlSwap` | `debt/helping.rs:213` | after `control.swap(gen, SeqCst)` returns | `ReaderFallbackControlSwap` | `state.rPC`, `state.helpControl`, `state.helpGen`, `state.pendingHelpingTx` |
| `ReaderFallbackDiscardNode` (NEW F5) | `debt/list.rs:296` | after `start_cooldown + self.node.take()` | `ReaderFallbackDiscardNode` | `state.rPC`, `state.localNode` (= "NONE") |
| `ReaderFallbackCandidate` | `strategy/hybrid.rs:84` | after `storage.load(SeqCst)` returns | `ReaderFallbackCandidate` | `state.rPC`, `state.rConfirmAddr` |
| `ReaderFallbackSlotStore` | `debt/helping.rs:317` | after `slot.0.swap(ptr, SeqCst)` | `ReaderFallbackSlotStore` | `state.rPC`, `state.helpSlot` |
| `ReaderFallbackConfirmOK` | `debt/helping.rs:325` (success branch, control == gen) | after `control.swap(IDLE, SeqCst)` when `prev == gen` | `ReaderFallbackConfirmOK` | `state.rPC`, `state.helpControl`, `state.pendingHelpingTx` (= 0) |
| `ReaderFallbackConfirmHelped` | `debt/helping.rs:328` (Err branch) | after `control.swap(IDLE, SeqCst)` when `prev == REPL` | `ReaderFallbackConfirmHelped` | `state.rPC`, `rGotEnvelope=true` (implicit) |
| `ReaderFallbackResolveEnvelope` | `strategy/hybrid.rs:99-110` | after caller-side cleanup (pay_back / T::dec) | `ReaderFallbackResolveEnvelope` | `state.rPC` |

#### F5 instrumentation rationale

Round 3 emitted a single `ReaderFallbackControlSwap` event covering both
the control swap AND the conditional cooldown+take.  Round 4 splits these:

```rust
// debt/list.rs (round 4 instrumentation)
pub(crate) fn new_helping(&self, ptr: usize) -> usize {
    let node = &self.node.get().expect("LocalNode::with ensures it is set");
    debug_assert_eq!(node.in_use.load(Relaxed), NODE_USED);
    let (gen, discard) = node.helping.get_debt(ptr, &self.helping);
    // get_debt itself emits ReaderFallbackControlSwap from helping.rs:213
    if discard {
        node.start_cooldown();
        self.node.take();
        crate::tla_trace::emit_reader_fallback_discard_node();   // (F5 NEW)
    }
    gen
}
```

The new event captures the post-state where `localNode[t] = NoneGid` while
the (still-unmoved) `pendingHelpingTx[t]` field carries the wrapped
generation.  TLC sees the brief window before the panic at the next
`confirm_helping`.

### 2.3 Guard / client harness (Family 2)

| Spec Action | Code Location | Trigger | Event | Fields |
|---|---|---|---|---|
| `DropGuard` | `strategy/hybrid.rs:122` | first line of `Drop::drop` | `DropGuard` | `thread` |
| `GuardIntoInner` | `strategy/hybrid.rs:161` | inside `into_inner`, only when guard had a real debt | `GuardIntoInner` | `thread` |
| `GuardClone` (NEW F2) | harness only | when test harness does `Arc::clone(&*g) + Guard::from_inner` | `GuardClone` | `thread` |
| `SendGuard` | harness only | when test harness moves a Guard between threads | `SendGuard` | `src`, `dst` |

`GuardClone` and `SendGuard` are **test-harness-only** events.  There is no
implementation hook for either:
* `Arc::clone(&*g)` is just `Arc::clone` — no arc-swap-specific code path.
* `Guard::from_inner` (lib.rs:212) is a public API, but a normal `load()`
  call doesn't go through it; only the test harness invokes it explicitly.
* `SendGuard` happens via channel send / `std::thread::spawn` move — it is
  a Rust ownership transfer with no runtime hook.

The Family-2 test harness in `tla_trace.rs` records these events when it
performs the corresponding fork / move.  Implementation users who do not
exercise Family 2 patterns will produce traces with no `GuardClone` /
`SendGuard` events, and the spec wraps those branches as no-ops at the
trace cursor.

### 2.4 Writer (lib.rs / debt/mod.rs)

| Spec Action | Code Location | Trigger | Event | Fields |
|---|---|---|---|---|
| `WriterSwap` | `lib.rs:486` | after `self.ptr.swap(new, SeqCst)` returns | `WriterSwap` | `state.wPC`, `state.storageAddr` |
| `WriterPayInit` | `debt/mod.rs:92` | after `T::inc(&val)` returns | `WriterPayInit` | `state.wPC` |
| `WriterTraverseLoad` | `debt/list.rs:103` | after `LIST_HEAD.load(SeqCst)` returns | `WriterTraverseLoad` | `state.wPC` |
| `WriterReserveNode` | `debt/list.rs:150` | after `active_writers.fetch_add(1, Acquire)` returns | `WriterReserveNode` | `state.wPC`, `state.wCurNode`, `state.activeWriters` |
| `WriterHelpNode` | `debt/mod.rs:99` | after `local.help(node, ...)` returns | `WriterHelpNode` | `state.wPC` |
| `WriterScanSlot` | `debt/mod.rs:113` | after each `slot.pay::<T>(ptr)` returns (per slot) | `WriterScanSlot` | `node`, `slot_idx`, `result` (true/false) |
| `WriterReleaseNode` | `debt/list.rs:57` | inside `Drop for NodeReservation`, after `fetch_sub` | `WriterReleaseNode` | `node`, `prev` (active_writers value) |
| `WriterPayDone` | `debt/mod.rs:119` | after `pay_all` closure returns | `WriterPayDone` | `state.wPC` |
| `WriterReturn` | `lib.rs:489-490` | after `wait_for_readers` returns (T::from_ptr completes) | `WriterReturn` | `state.wPC` |

### 2.5 CompareAndSwap (Family 2 — strategy/hybrid.rs:227-263)

| Spec Action | Code Location | Trigger | Event | Fields |
|---|---|---|---|---|
| `CASBegin` | `strategy/hybrid.rs:240` | first line of `loop {}` body, after `kind`/`new_raw` materialized | `CASBegin` | `state.casKind`, `state.casCurAddr`, `state.casNewAddr`, `state.rPC=cas_after_load` |
| `CASCompareNotEqual` | `strategy/hybrid.rs:243` | after `if old.as_ptr() != current.as_raw()` returns true | `CASCompareNotEqual` | (no extra) |
| `CASExchangeOk` | `strategy/hybrid.rs:251` | after `compare_exchange_weak` succeeds | `CASExchangeOk` | `state.storageAddr` |
| `CASExchangeFail` | `strategy/hybrid.rs:260` | after `compare_exchange_weak` fails (bottom of loop) | `CASExchangeFail` | (no extra) |

### 2.6 Node lifecycle (debt/list.rs)

| Spec Action | Code Location | Trigger | Event | Fields |
|---|---|---|---|---|
| `ClaimNode` | `debt/list.rs:170` | after `compare_exchange(NODE_UNUSED, NODE_USED, SeqCst, SeqCst)` succeeds | `ClaimNode` | `node`, `state.nodeState`, `state.localNode` |
| `CheckCooldown` | `debt/list.rs:141` | after `compare_exchange(NODE_COOLDOWN, NODE_UNUSED, ...)` succeeds | `CheckCooldown` | `node`, `state.nodeState` |

These events fire inside `Node::get` and `Node::check_cooldown` respectively.
The harness must register the node pointer the first time it's observed (via
`crate::tla_trace::register_node`) so the `node` field in subsequent events
maps to the spec constant.

### 2.7 Object lifecycle (Family 2)

| Spec Action | Code Location | Trigger | Event | Fields |
|---|---|---|---|---|
| `DropArcSwap` | `lib.rs:346` | inside `Drop::drop`, after `wait_for_readers` returns | `DropArcSwap` | (no extra; thread-implicit) |
| `PickRelaxSite` | harness-only | when test harness injects an ordering relaxation | `PickRelaxSite` | `site` (one of `RelaxSites`) |

`PickRelaxSite` is harness-only — it does not correspond to an
implementation hook, but it lets a fault-injection harness drive the spec's
relaxation adversary deterministically (e.g., to recreate a specific bug).

## Section 3: Special Considerations

### 3.1 Thread → spec-thread mapping

The harness maintains a thread-local string id assigned at the first
observation of `std::thread::current().id()`.  IDs are stable across the
test, but the mapping must be consistent across threads.  The mapping
table is logged in the trace preamble so the spec consumer can audit it.

### 3.2 Address registration

Addresses are typically `*const T::Base` values.  Multiple observations of
the same numeric value must map to the same string id within an allocation
generation, but when an Arc is deallocated and a different Arc is later
allocated at the same numeric address, the harness mints a fresh string id
(e.g., `a3` after `a2` freed).  This matches Family 3's allocator-reuse
ABA modeling — the spec's `addrGen` advances on each `WriterSwap` to a
freed address.

### 3.3 LocalNode emission timing

The harness must capture `state.localNode` AT THE TIME the trace event
fires.  Particularly important for round 4:

* `ReaderFallbackDiscardNode` runs **after** `self.node.take()`, so
  `state.localNode = "NONE"`.
* `ReaderFallbackCandidate` after wrap+discard is the only event where the
  spec allows `localNode = "NONE"` post-precondition; subsequent events
  (SlotStore / ConfirmOK / ConfirmHelped) require `localNode # NoneGid`.
* `ClaimNode` sets `localNode[t] = n` just after the SeqCst CAS succeeds.

Failure to capture localNode correctly causes `ValidateLocalNode` (in
`Trace.tla`) to mismatch and trace replay to fail with `ValidatePostState`
errors.

### 3.4 PendingHelpingTx emission timing

`pendingHelpingTx[t]` is a BOOLEAN: TRUE between `ReaderFallbackControlSwap`
and the next `ReaderFallbackConfirm{OK,Helped}`.  The harness emits its
current value in `ReaderFallbackControlSwap` (TRUE — control set to GEN tag)
and in `ReaderFallbackConfirm{OK,Helped}` (FALSE — control cleared to IDLE).
Other fallback-path events do not need to capture it but may include it for
audit.

The implementation has `gen | GEN_TAG` as the in-flight control value; even
when gen wraps to 0, the tagged value is non-zero (the GEN_TAG bits ensure
non-IDLE).  We model this with a boolean to avoid the encoding pitfall
where wrapped gen=0 would be conflated with "no transaction".

The bug-detection signal in F5 is reachable purely through MC (with
`MaxHelpGen=4`), not through trace replay — the implementation does not
hit wrap in production-scale runs.  Trace replay should NOT exhibit this
state on real executions; if it does, it indicates an instrumentation bug
(e.g., `pendingHelpingTx` never cleared) rather than an implementation bug.

### 3.5 SendGuard / harness-only events

The four harness-only events (`SendGuard`, `GuardClone`, `PickRelaxSite`,
and `DropArcSwap` in some test patterns) are emitted by adversarial test
code, not by the standard implementation path.  The trace spec does not
distinguish them syntactically; both real and harness-only events use the
same `event` field name.

### 3.6 Bootstrap state

The base spec's `Init` requires:

* `storageAddr = InitAddr` (the first-stored Arc)
* All nodes start `NODE_USED` with `nodeOwner[t] = t` and `localNode[t] = t`
* `pendingHelpingTx[t] = 0`, `inflightHelp[n] = {}` for all t, n
* `relaxSite = NoneSite`, `arcSwapDropped = FALSE`

The harness must arrange that the first `tla_trace.rs` event corresponds to
this initial state.  In practice, the harness initializes the ArcSwap with
a known starting Arc, registers it as `a1` (= `InitAddr`), and instruments
`THREAD_HEAD` initialization to ensure `nodeOwner` and `localNode` match
the thread's spec id.

### 3.7 Concurrent threads & event ordering

The trace cursor `l` walks the log linearly.  arc-swap operations are
ns-level, but each event represents exactly one observable atomic op; the
harness's per-process atomic `seq` counter assigns a total order at hook
time.  This serializes events globally — sufficient for a Category A-style
trace replay.

If state-space search becomes prohibitive, switch to the Category B
timebox pattern (`pc[tid]` + `ViablePIDs`) per `trace-spec-pattern.md`.

### 3.8 NDJSON serialization quirks

* Boolean fields with default `false` are sometimes omitted in JSON.  Use
  `serde_json::to_string` defaults — do NOT emit `null` for `false`.
* Integer fields may be emitted as either int or string; `Trace.tla` calls
  `MapAddr` / `MapThread` to canonicalize.
* The `state` object MUST contain ALL fields the corresponding TR_* wrapper
  validates; missing fields cause `ValidatePostState` to fail.

### 3.9 Round-4 emphasis: F2 + F5 harness composition

Per the task brief, this round emphasizes adversarial caller behavior +
stale-snapshot.  The harness should:

1. Spawn 2-3 reader threads + 1 writer thread on a shared `ArcSwap<T>`.
2. Have at least one reader call `Guard::into_inner` while a writer is
   mid-`pay_all` (F2).
3. Have at least one reader **fork a Guard via `Arc::clone(&*g) +
   Guard::from_inner`** (NEW for round 4) — emit `GuardClone`.
4. Have at least one reader hold a guard across a thread boundary
   (`std::sync::mpsc` or `crossbeam-channel`) — emit `SendGuard`.
5. Have at least one CAS use a raw pointer obtained from a `Guard` that
   has been dropped (F2).
6. Optionally, drop the `ArcSwap` at the end of the test while a reader
   holds a guard — this is a documented caller-precondition violation; the
   trace should NOT include this as a normal load event but the harness
   can emit it for negative-test purposes (F2).

For F5, the harness has no production-reachable trigger (2^62 fallback
calls).  The F5 hunt relies entirely on `MC_hunt_family5.cfg` with tight
`MaxHelpGen=4`; trace replay cannot exercise this path.  No additional
harness composition is required for F5 beyond the standard fallback flow
(any test that exercises `HybridProtection::fallback` will fire
`ReaderFallbackControlSwap` + `ReaderFallbackDiscardNode` if wrap occurs).
