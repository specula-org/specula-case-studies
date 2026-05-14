# arc-swap Trace Harness — Instrumentation Guide

This guide is for the Phase 3 (validation) agent.  Use it to make small
adjustments to the trace harness when validation surfaces missing fields,
mis-mapped events, or under-covered actions.

## Layout

| Path | Purpose |
|---|---|
| `harness/src/tla_trace.rs` | Trace emission module — all `emit_*` functions, thread/addr/node mapping, `IN_CAS`/`IN_PAY_ALL`/`InternalIntoInnerScope` flags. |
| `harness/src/tla_trace_scenarios.rs` | The 6 cargo `#[test]`s that exercise the protocol. |
| `harness/patches/instrumentation.patch` | Inserts `crate::tla_trace::emit_*` calls into the 6 instrumented source files (`lib.rs`, `strategy/hybrid.rs`, `debt/{fast,helping,list,mod}.rs`). |
| `harness/apply.sh` | Reset artifact + copy harness sources + apply patch. |
| `harness/run.sh` | One-command: apply, build, run tests, collect traces. |

## Hook map (event → file:hook)

| Spec action / Trace event | Source location (post-apply) |
|---|---|
| `ReaderFastLoad` | `src/strategy/hybrid.rs` after `storage.load(Relaxed)` |
| `ReaderFastSlotAcquire` | `src/debt/fast.rs` after `slot.0.swap(ptr, SeqCst)` |
| `ReaderFastConfirmLoad` | `src/strategy/hybrid.rs` after `storage.load(SeqCst)` |
| `ReaderFastBranchHit` | `src/strategy/hybrid.rs` (success branch of `if ptr == confirm`) |
| `ReaderFastResolve` | `src/strategy/hybrid.rs` (both legs of `else if debt.pay`) |
| `ReaderFallbackActiveAddr` | `src/debt/helping.rs` after `active_addr.store(SeqCst)` |
| `ReaderFallbackControlSwap` | `src/debt/helping.rs` after `control.swap(gen, SeqCst)` |
| `ReaderFallbackCandidate` | `src/strategy/hybrid.rs` after `storage.load(SeqCst)` (fallback) |
| `ReaderFallbackSlotStore` | `src/debt/helping.rs` after `slot.0.swap(ptr, SeqCst)` |
| `ReaderFallbackConfirmOK` | `src/strategy/hybrid.rs` (Ok branch of `confirm_helping`) |
| `ReaderFallbackConfirmHelped` | `src/strategy/hybrid.rs` (Err branch of `confirm_helping`) |
| `ReaderFallbackResolveEnvelope` | `src/strategy/hybrid.rs` after envelope cleanup |
| `DropGuard` | `src/strategy/hybrid.rs` first line of `Drop::drop` |
| `GuardIntoInner` | `src/strategy/hybrid.rs` inside `into_inner`, only when debt is `Some` (no-debt case is a spec no-op). |
| `WriterSwap` | `src/lib.rs` after `self.ptr.swap(new, SeqCst)` |
| `WriterPayInit` | `src/debt/mod.rs` after `T::inc(&val)` |
| `WriterTraverseLoad` | `src/debt/list.rs` after `LIST_HEAD.load(SeqCst)` |
| `WriterReserveNode` | `src/debt/list.rs` after `active_writers.fetch_add(1, Acquire)` |
| `WriterHelpNode` | `src/debt/mod.rs` after `local.help(node, ...)` |
| `WriterScanSlot` | `src/debt/mod.rs` after each `slot.pay::<T>(ptr)` |
| `WriterReleaseNode` | `src/debt/list.rs` inside `Drop for NodeReservation` |
| `WriterPayDone` | `src/debt/mod.rs` after `pay_all` closure |
| `WriterReturn` | Test code — `tla_trace::emit_writer_return()` after the call returns |
| `CASBegin` | `src/strategy/hybrid.rs` after the inner `load()` (with `IN_CAS` suppressing the inner load's reader events) |
| `CASCompareNotEqual` | `src/strategy/hybrid.rs` taken branch of `if old.as_ptr() != current.as_raw()` |
| `CASExchangeOk` | `src/strategy/hybrid.rs` after successful `compare_exchange_weak` |
| `CASExchangeFail` | `src/strategy/hybrid.rs` bottom of loop on retry |
| `ClaimNode` | `src/debt/list.rs` after `compare_exchange(NODE_UNUSED, NODE_USED)` succeeds |
| `CheckCooldown` | `src/debt/list.rs` after `compare_exchange(NODE_COOLDOWN, NODE_UNUSED)` succeeds |
| `DropArcSwap` | `src/lib.rs` inside `Drop::drop`, after `wait_for_readers` |
| `SendGuard` | Test code only — emitted when test moves a Guard between threads |
| `PickRelaxSite` | Test code only — fault injection (currently unused) |

## Common Adjustments

### Add a field to an event

1. Edit `harness/src/tla_trace.rs` — find the `emit_<name>` function and add
   the field to the `format!` line.
2. If the spec's `TR_<name>` wrapper validates this field, also update the
   wrapper in `Trace.tla`.
3. Re-run `bash harness/run.sh`.

### Move a capture point (before → after)

1. Edit `harness/patches/instrumentation.patch` to move the `emit_*` call.
2. Re-run `harness/apply.sh` to apply the new patch.

### Add a new event type

1. Add a new `emit_<name>` function in `harness/src/tla_trace.rs` mirroring an
   existing one (envelope, `seq`, `ts`, `event` field).
2. Add a `TR_<name>` wrapper in `Trace.tla` and add it to the `TraceNext`
   disjunction.
3. Add the `crate::tla_trace::emit_<name>(...)` call in the source code by
   editing `harness/patches/instrumentation.patch` (or hand-editing the
   artifact and regenerating the patch with
   `git -C ../../artifact/arc-swap diff -- src/ > harness/patches/instrumentation.patch`).

### Suppress an emit conditionally

The trace module already supports thread-local suppression scopes:
- `PayAllScope::enter()` — set true while inside `Debt::pay_all` so writer
  scan events fire only on the writer path.
- `CasScope::enter()` — set true inside `compare_and_swap`'s loop so the
  inner load's reader events are suppressed (the spec collapses the inner
  load into `CASBegin`).
- `InternalIntoInnerScope::enter()` — set true around the fallback's
  `Self::new(...).into_inner()` so it doesn't emit `GuardIntoInner` (it's
  an implementation detail of the load transition, not a user action).

To add a new suppression, define a `Cell<bool>` thread-local and an RAII
guard following the pattern of `PayAllScope`.

### Rebuild and re-run

```bash
cd /home/ubuntu/Specula/case-studies/arc-swap_3/.specula-output
bash harness/run.sh
```

Traces land in `traces/<scenario>.ndjson`.  Each test scenario writes its
own trace.

## Spec Adjustments Made During Harness Generation

While building the harness I had to adjust **two** small things in the spec
to make traces validate.  Phase 3 should treat these as flagged-for-review:

1. **`Trace.tla` — added `WF_allVars(TraceNext)`.**  Without weak fairness,
   the spec allows stuttering at the very first state, making the temporal
   property `<>(l > Len(TraceLog))` vacuously fail.
   ```tla
   TraceSpec == TraceInit /\ [][TraceNext]_allVars /\ WF_allVars(TraceNext)
   ```

2. **`base.tla` — relaxed `ReaderFallbackActiveAddr`'s precondition.**  The
   original guard required `\A s \in FastSlotIx : fastSlot[t][s] # NullPtr`
   (all 8 fast slots full), but the implementation also enters fallback when
   a fast attempt's confirm-load disagrees and the reader paid back its own
   debt (`hybrid.rs:60-66`, `198-203` — `ReaderFastResolve`'s CAS-succeeds
   leg returns `None` which triggers `HybridProtection::fallback`).  I
   removed the slot-full guard.

3. **`Trace.tla` — added `casCurAddr` and `casNewAddr` validation in
   `TR_CASBegin`.**  Without these, `CASBegin`'s `\E newAddr, curAddr`
   non-determinism explored branches that didn't match the trace, producing
   spurious deadlocks at later steps.

## Known Spec/Impl Gap (CAS-returned Guard)

The spec's `CASExchangeOk` does **not** add a Guard to `guards[t]` for the
caller's `prev` value.  The impl returns a Guard with a debt slot that the
caller is expected to drop.  We work around this by `mem::forget`-ing the
returned Guard in the `family_c_cas_*` test scenarios — the impl's
explicit `T::dec(old.as_ptr())` already balances refcounts; the leak is
test-only.  Phase 3 may want to extend `CASExchangeOk` to add a no-debt
guard so the caller's drop fires `DropGuard` cleanly.

## Known Limitations

### Probe-effect ordering (Relaxed loads)

The instrumented `storage.load(Relaxed)` returns a value at some point in
time; the `emit_reader_fast_load` call later grabs the global `SEQ`
counter.  Between those two events, another thread's `storage.swap` +
`emit_writer_swap` can sneak in.  The result: the trace's `SEQ` order has
the writer's swap **before** the reader's load event, but the reader's
`rOpAddr` field shows the **pre-swap** value.  The strict spec deadlocks
on this.

To avoid this, all scenarios use **phase barriers** that force readers to
finish their loads before the writer swaps.  See
`concurrent_readers_writer` for the `readers_done` barrier pattern.  A
truly free-running concurrent test is left for future work (it would need
either Category-B timebox traces or a global lock around the operation
itself, both of which add probe effect of their own).

### Suppression flags

Three thread-local flags suppress emits where the spec collapses an impl's
internal helper into a single action:

| Flag | Set by | Suppresses |
|---|---|---|
| `IN_PAY_ALL` | `PayAllScope::enter()` in `Debt::pay_all` | All Reader fast/fallback events + `DropGuard` + `GuardIntoInner` (inside the writer's `local.help` replacement) |
| `IN_CAS` | `CasScope::enter()` in `compare_and_swap` | All Reader fast/fallback events (the spec's `CASBegin` collapses the inner load) |
| `INTERNAL_INTO_INNER` | `InternalIntoInnerScope::enter()` in `fallback()` | `GuardIntoInner` (the fallback's `Self::new(...).into_inner()` is an impl helper) |

### Uncovered events

The current scenarios do not exercise these spec actions (they are
defined in `Trace.tla` but no `TR_*` wrapper fires in any of the 6
traces):

- `ReaderFastResolve` (writer-during-read race; suppressed by phase
  barriers)
- `ReaderFallback*` (filling all 8 fast slots is not deterministic from
  these scenarios)
- `CASCompareNotEqual`, `CASExchangeFail` (need contended CAS — multiple
  threads racing CAS on the same `ArcSwap`)
- `ClaimNode`, `CheckCooldown` (need gen-wrap which is unreachable in
  short tests, or thread teardown across tests)
- `DropArcSwap` (we deliberately avoid dropping the `ArcSwap` from the
  main thread, which isn't registered)

To add a scenario for any of these, copy an existing test, change the
operations, and run `bash harness/run.sh`.

## Quick Validation Check

```bash
cd /home/ubuntu/Specula/case-studies/arc-swap_3/.specula-output
JSON=traces/basic_read_write.ndjson \
  java -DTLA-Library=/home/ubuntu/SysMoBench/lib/CommunityModules-deps.jar \
       -cp /home/ubuntu/SysMoBench/lib/tla2tools.jar:/home/ubuntu/SysMoBench/lib/CommunityModules-deps.jar \
       tlc2.TLC -config spec/Trace.cfg spec/Trace.tla 2>&1 | tail -5
```

Expected: `Finished checking temporal properties` (no `Error: Deadlock` or
`TraceMatched was violated`).
