# arc-swap Trace Harness — Instrumentation Guide

This document is a quick reference for the Phase 3 (validation) agent who
needs to adjust instrumentation when trace validation surfaces issues.

## Layout

```
.specula-output/harness/
├── apply.sh                # idempotent patch applicator (git checkout + sed/python3 edits)
├── run.sh                  # one-command driver: apply → build → test → postprocess
├── postprocess.py          # sorts raw NDJSON by `seq` field
├── INSTRUMENTATION.md      # this file
├── src/
│   └── tla_trace.rs        # Rust trace emission module (copied into artifact/src/)
└── tests/
    └── tla_trace_scenarios.rs  # test scenarios (copied into artifact/tests/)
```

`apply.sh` first runs `git checkout -- .` in the artifact, so it is safe to
re-run repeatedly.  The patches are written as Python heredoc transformations
inside `apply.sh` so they remain readable.

## Pipeline

```
apply.sh
   ├─ cp src/tla_trace.rs                  → artifact/src/tla_trace.rs
   ├─ patch lib.rs                          (mod decl, WriterSwap, DropArcSwap)
   ├─ patch strategy/hybrid.rs              (Reader fast path + DropGuard)
   ├─ patch debt/fast.rs                    (ReaderFastSlotAcquire)
   ├─ patch debt/list.rs                    (TraverseLoad, Reserve/ReleaseNode, register_node)
   ├─ patch debt/mod.rs                     (PayInit, HelpNode, ScanSlot, PayDone, PayAllScope)
   └─ cp tests/tla_trace_scenarios.rs       → artifact/tests/

run.sh
   ├─ apply.sh
   ├─ cargo test --no-run    --test tla_trace_scenarios
   ├─ for each scenario:
   │     ARC_SWAP_TRACE_OUT=$RAW_DIR cargo test ...
   │     postprocess.py raw/<name>.ndjson  →  ../traces/<name>.ndjson
   └─ print event-type counts
```

## Trace event format

Each event is a single NDJSON line with envelope `{"tag": "trace", ...}`.
The `seq` field is from a global `static SEQ: AtomicU64` (SeqCst) and provides
the totally-ordered logical timestamp; `postprocess.py` sorts by `seq` before
the file is fed to `Trace.tla`.

```
{"tag":"trace","ts":<epoch_nanos>,"seq":<int>,
 "event":"<ActionName>","thread":"t1",
 "state":{...post-action fields...}}
```

| Action ↔ event-name pairs | Source location after `apply.sh` |
|---|---|
| `ReaderFastLoad` | `src/strategy/hybrid.rs` after `let ptr = storage.load(Relaxed)` |
| `ReaderFastSlotAcquire` | `src/debt/fast.rs` after `slot.0.swap(ptr, SeqCst)` |
| `ReaderFastConfirmLoad` | `src/strategy/hybrid.rs` after `let confirm = storage.load(SeqCst)` |
| `ReaderFastBranchHit` | `src/strategy/hybrid.rs` `if ptr == confirm` branch |
| `ReaderFastResolve` | `src/strategy/hybrid.rs` both legs of `else if debt.pay::<T>(ptr)` |
| `DropGuard` | `src/strategy/hybrid.rs` start of `Drop for HybridProtection` |
| `WriterSwap` | `src/lib.rs` after `let old = self.ptr.swap(new, SeqCst)` |
| `WriterPayInit` | `src/debt/mod.rs::pay_all` after `T::inc(&val)` |
| `WriterTraverseLoad` | `src/debt/list.rs::Node::traverse` after `LIST_HEAD.load(SeqCst)` |
| `WriterReserveNode` | `src/debt/list.rs::reserve_writer` after `fetch_add` |
| `WriterHelpNode` | `src/debt/mod.rs::pay_all` after `local.help(...)` |
| `WriterScanSlot` | `src/debt/mod.rs::pay_all` after each `slot.pay::<T>(ptr)` |
| `WriterReleaseNode` | `src/debt/list.rs` `Drop for NodeReservation` after `fetch_sub` |
| `WriterPayDone` | `src/debt/mod.rs::pay_all` end of `LocalNode::with` closure |
| `WriterReturn` | emitted explicitly from test scenario after `drop(old)` |
| `DropArcSwap` | `src/lib.rs` `Drop for ArcSwapAny` after `T::dec(ptr)` |

## Gating: `PayAllScope`

`Node::traverse`, `reserve_writer`, and `NodeReservation::drop` are reachable
from non-`pay_all` paths (`Node::get`, `start_cooldown`, etc.).  To avoid
emitting spurious writer-pay events from those paths, the relevant emit
helpers (`emit_writer_traverse_load`, `emit_writer_reserve_node`,
`emit_writer_release_node`) check a thread-local `IN_PAY_ALL` flag set by an
RAII `PayAllScope::enter()` guard at the top of `pay_all`.

If you need to emit one of these events from a new caller, take a
`PayAllScope` first or remove the gate from the corresponding `emit_*`.

## Identity mapping

The trace module maintains three maps in a `Mutex<State>`:

| Map | Populated by | Purpose |
|---|---|---|
| `threads: ThreadId → "t1"\|...` | `register_thread(name)` from each worker | Spec-side thread name for `event.thread` |
| `addrs: usize → "a1"\|...` | `seed_init_addr(p)` for the initial Arc; lazy on first sight thereafter | Spec-side address id for `state.storageAddr`, `state.rOpAddr`, etc. |
| `nodes: usize → "tN"` | `register_node(node_ptr)` from inside `Node::get` (after the claim CAS) | Spec-side node identity for `state.wCurNode` |

Threads not registered with `register_thread` produce silently-dropped emits.
This is **deliberate** — the test main thread is intentionally unregistered
so that its drop of the Arc<ArcSwap> doesn't produce events with no spec-side
counterpart.

## Spec configuration coupling

`spec/Trace.cfg`:

```
Thread = {"t1", "t2", "t3"}
Addr   = {"a1", "a2", "a3", "a4"}
InitAddr = "a1"
NumFastSlots = 8       (matches DEBT_SLOT_CNT in src/debt/fast.rs)
MaxHelpGen = 8
MaxGuardsPerThread = 2
NullPtr = "NULL"
NoneGid = "NONE"
NoneSite = "NONE_SITE"
```

* The constants are TLA+ string values (note the quotes) so that they line up
  with the JSON strings emitted by the trace module.  The original spec used
  bare model values (`{t1, t2, t3}`); switching to strings preserves all
  existing definitions because the spec only ever uses these constants as
  set elements / function keys, never as TLA+ identifiers.
* `NumFastSlots = 8` matches `DEBT_SLOT_CNT` in `src/debt/fast.rs`.  If you
  bump one, bump the other.  The trace module also passes `8` as the second
  arg to `emit_reader_fast_slot_acquire` (see `apply.sh`).
* `MaxGuardsPerThread = 2` bounds the number of in-flight Guards per spec
  thread.  Tests must drop their `Guard` between successive `load()` calls or
  the spec will deadlock.

## Validating against the spec

```
cd .specula-output/spec
JSON=../traces/basic_read_write.ndjson \
  java -cp $TLA_JAR:$COMMUNITY_JAR tlc2.TLC -config Trace.cfg Trace.tla
```

Or via the MCP tool:

```
run_trace_validation(
    spec_file="Trace.tla",
    config_file="Trace.cfg",
    trace_file="../traces/basic_read_write.ndjson",
    work_dir="/.../arc-swap_2/.specula-output/spec",
)
```

Successful validation reports `status: success`.  A `trace_mismatch` means
the trace event at `failed_trace_line` could not be matched against any
`TR_*` wrapper; use `run_trace_debugging` with a breakpoint at the relevant
wrapper to pinpoint the precondition that failed.

## Common adjustments

### Add a new field to an existing event

1. Add the field to the `format!(...)` block inside the relevant `emit_*`
   function in `src/tla_trace.rs`.
2. Update the `apply.sh` patch only if the call site needs new arguments.
3. Update the corresponding `Validate*` operator (or the `TR_*` wrapper) in
   `spec/Trace.tla` to read and check the new field.

### Add a new event type

1. Add a new `pub fn emit_<name>(...)` helper in `src/tla_trace.rs`
   following the same pattern as the others (early-return on `!enabled()`,
   acquire `state()`, format the JSON line).
2. Add the corresponding insertion in `apply.sh` (a python3 heredoc, with
   a unique anchor string).
3. Add a new `TR_<Name>` wrapper in `spec/Trace.tla` and a disjunct in
   `TraceNext`.

### Move a capture point from "before" to "after"

Move the `emit_*` call to the other side of the operation in the patch
script in `apply.sh`.  Re-run `apply.sh` and `run.sh` to regenerate traces.

### Disable an event temporarily

Comment out the `emit_*` call inside `tla_trace.rs` (early `return;`) or
remove it from the `apply.sh` patch.  Removing it from `Trace.tla` is *not*
necessary unless you also want the spec to refuse such events.

### Rebuild after adjusting the harness

```
bash .specula-output/harness/run.sh
```

This re-applies patches, rebuilds, runs all scenarios, postprocesses, and
prints per-scenario event counts.  Each scenario gets its own
cargo-test process so that `LIST_HEAD` starts empty.

## Known limitations / coverage gaps

* **Reader fallback path is not yet exercised.**  The `attempt()` fast slot
  is essentially never full in our scenarios (DEBT_SLOT_CNT=8), so
  `HybridProtection::fallback` is not entered.  Events
  `ReaderFallback{ActiveAddr, ControlSwap, Candidate, SlotStore, ConfirmOK,
  ConfirmHelped, ResolveEnvelope}` are therefore absent from the produced
  traces.  To exercise this path, run a scenario that holds 8+ in-flight
  loads on a single thread before issuing the next `load()`.
* **`compare_and_swap` (`CASBegin`/`CASCompareNotEqual`/`CASExchangeOk`/
  `CASExchangeFail`) is not yet exercised.**  Add a scenario that calls
  `arcswap.compare_and_swap(...)`.
* **`GuardIntoInner` and `SendGuard` are not exercised.**  Add a scenario
  that calls `Guard::into_inner(...)` or moves a Guard between threads.
* **`ClaimNode` and `CheckCooldown` are not emitted.**  The instrumentation
  intentionally suppresses these because the spec's `Init` already has
  every thread's node in the `NODE_USED` state; emitting them would violate
  the action precondition.  To add them later, instrument the
  `start_cooldown`/`check_cooldown` paths and exercise a scenario where a
  `LocalNode` is dropped (thread death).
* **`DropArcSwap` is not exercised.**  The main test thread isn't registered
  with the trace module, so its drop of the `Arc<ArcSwap>` is silent.  To
  emit `DropArcSwap`, restructure the test so a registered worker thread
  performs the final drop.
* **The `WriterReleaseNode` wPC is not validated.**  The base spec's
  `WriterReleaseNode` action skips the `w_after_release` phase that the
  instrumentation table prescribed and transitions straight to
  `w_traverse_loaded` or `w_pay_done`; the trace wrapper drops that
  validation accordingly.  See `Trace.tla` near `TR_WriterReleaseNode`.
* **`PROPERTY TraceMatched` is disabled.**  Without an explicit fairness
  constraint, TLC produces trivial infinite-stutter counter-examples for
  `<>(l > Len(TraceLog))`.  We rely on TLC's default deadlock detection
  (paired with the safety invariants in `Trace.cfg`) instead.
