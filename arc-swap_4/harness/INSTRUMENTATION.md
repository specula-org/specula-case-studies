# arc-swap Trace Harness — Round 4

This guide is for the Phase-3 (validation) agent that needs to adjust
instrumentation when trace validation reveals issues.  The structure of the
harness is **copy-and-patch** — `apply.sh` copies the harness's
`tla_trace.rs` and `tla_trace_scenarios.rs` into the artifact, then patches
`debt/list.rs` with the F5 split point.

## Layout

```
harness/
├── apply.sh                     copy + patch into artifact
├── run.sh                       apply, build, run, collect traces
├── INSTRUMENTATION.md           THIS FILE
└── src/
    ├── tla_trace.rs             trace emission module (overwrites
    │                            artifact/src/tla_trace.rs)
    └── tla_trace_scenarios.rs   round-4 test scenarios (overwrites
                                 artifact/tests/tla_trace_scenarios.rs)
```

The artifact is at `case-studies/arc-swap_4/artifact/arc-swap` (a symlink to
the shared arc-swap artifact).  Source files **already** contain the round-3
emit calls (e.g. `crate::tla_trace::emit_writer_swap(...)` in lib.rs:486);
those are tracked as untracked changes in the artifact.  Round 4 only adds:

* **One new in-source emit**: `emit_reader_fallback_discard_node()` after
  `self.node.take()` in `debt/list.rs:296` (inside `LocalNode::new_helping`).
* **Two new emit functions** in `tla_trace.rs`:
  `emit_reader_fallback_discard_node()` and `emit_guard_clone()`.
* **Updated state fields** on existing events: `pendingHelpingTx` on fallback
  events, `localNode` on `ClaimNode`.
* **One new test scenario**: `family_2_guard_clone`.

## Instrumentation point map

After `apply.sh` runs, every spec action has the following emit site (file:line
references are post-apply, in the artifact source tree):

| Spec action | File:line | Function (in tla_trace.rs) |
|---|---|---|
| `ReaderFastLoad` | strategy/hybrid.rs:45 | `emit_reader_fast_load(ptr)` |
| `ReaderFastSlotAcquire` | debt/fast.rs:59 | `emit_reader_fast_slot_acquire(slot, 8)` |
| `ReaderFastConfirmLoad` | strategy/hybrid.rs:53 | `emit_reader_fast_confirm_load(confirm)` |
| `ReaderFastBranchHit` | strategy/hybrid.rs:55 | `emit_reader_fast_branch_hit()` |
| `ReaderFastResolve` | strategy/hybrid.rs:62, :67 | `emit_reader_fast_resolve()` |
| `ReaderFallbackActiveAddr` | debt/helping.rs:204 | `emit_reader_fallback_active_addr()` |
| `ReaderFallbackControlSwap` | debt/helping.rs:213 | `emit_reader_fallback_control_swap(8)` |
| `ReaderFallbackDiscardNode` (NEW) | debt/list.rs:297 | `emit_reader_fallback_discard_node()` |
| `ReaderFallbackCandidate` | strategy/hybrid.rs:84 | `emit_reader_fallback_candidate(ptr)` |
| `ReaderFallbackSlotStore` | debt/helping.rs:317 | `emit_reader_fallback_slot_store(ptr)` |
| `ReaderFallbackConfirmOK` | strategy/hybrid.rs:90 | `emit_reader_fallback_confirm_ok()` |
| `ReaderFallbackConfirmHelped` | strategy/hybrid.rs:99 | `emit_reader_fallback_confirm_helped()` |
| `ReaderFallbackResolveEnvelope` | strategy/hybrid.rs:105 | `emit_reader_fallback_resolve_envelope()` |
| `WriterSwap` | lib.rs:486 | `emit_writer_swap(new)` |
| `WriterPayInit` | debt/mod.rs:92 | `emit_writer_pay_init()` |
| `WriterTraverseLoad` | debt/list.rs:103 | `emit_writer_traverse_load()` |
| `WriterReserveNode` | debt/list.rs:150 | `emit_writer_reserve_node(node, prev+1)` |
| `WriterHelpNode` | debt/mod.rs:99 | `emit_writer_help_node()` |
| `WriterScanSlot` | debt/mod.rs:113 | `emit_writer_scan_slot(node, slot_idx)` |
| `WriterReleaseNode` | debt/list.rs:57 | `emit_writer_release_node(node, prev-1)` |
| `WriterPayDone` | debt/mod.rs:119 | `emit_writer_pay_done()` |
| `WriterReturn` | (test harness) | `emit_writer_return()` |
| `DropGuard` | strategy/hybrid.rs:122 | `emit_drop_guard()` |
| `GuardIntoInner` | strategy/hybrid.rs:161 | `emit_guard_into_inner()` |
| `GuardClone` (NEW) | (test harness) | `emit_guard_clone()` |
| `SendGuard` | (test harness) | `emit_send_guard(src, dst)` |
| `DropArcSwap` | lib.rs:346 | `emit_drop_arc_swap()` |
| `CASBegin` | strategy/hybrid.rs:240 | `emit_cas_begin(kind, cur, new)` |
| `CASCompareNotEqual` | strategy/hybrid.rs:243 | `emit_cas_compare_not_equal()` |
| `CASExchangeOk` | strategy/hybrid.rs:251 | `emit_cas_exchange_ok(new)` |
| `CASExchangeFail` | strategy/hybrid.rs:260 | `emit_cas_exchange_fail()` |
| `ClaimNode` | debt/list.rs:170 | `emit_claim_node(node)` |
| `CheckCooldown` | debt/list.rs:141 | `emit_check_cooldown(node)` |
| `PickRelaxSite` | (test harness) | `emit_pick_relax_site(site)` |

## NDJSON event schema

Every event has the envelope:

```json
{"tag": "trace", "ts": <epoch nanos>, "seq": <int>, "event": "<ActionName>", "thread": "tN", "state": { ... }}
```

`tag` is mandatory — Trace.tla filters on it.  The `seq` field is a per-process
monotonic counter assigned at emit time under the global state mutex; replays
process events in `seq` order.  This is a Category-A trace (single global
cursor) even though arc-swap is concurrent — the emit critical section
serializes events at observable atomic boundaries.

State fields per event are documented in `instrumentation-spec.md` §2.  The
most important round-4 fields:

* `localNode`: `"t1"` / `"t2"` / `"t3"` / `"NONE"` — current value of the
  thread's `LocalNode::node` cell, mapped via the address registry.
* `pendingHelpingTx`: BOOLEAN — TRUE iff the reader has set control to
  `gen | GEN_TAG` and the slot is not yet stored.

## How to add a new field to an existing event

1. Update the `format!` line in the corresponding `emit_*` function in
   `harness/src/tla_trace.rs`.  Make sure the field is **inside** `state`
   (not a sibling of `event`).
2. Update the `TR_*` wrapper in `Trace.tla` to call `Validate*` (or a new
   `logline.state.<field>` check).
3. Re-run `apply.sh` and `run.sh`.

Example: adding `helpGen` to `ReaderFallbackConfirmOK`:

```rust
let line = format!(
    r#"{{"tag":"trace","ts":{ts},"seq":{seq},"event":"ReaderFallbackConfirmOK","thread":"{t}","state":{{"rPC":"r_idle","helpControl":"IDLE","pendingHelpingTx":false,"helpGen":{help_gen}}}}}"#
);
```

## How to add a new event type

1. Define the new event name in `Trace.tla` (a new `TR_*` wrapper) and add it
   to the `TraceNext` disjunction.
2. Add a corresponding base-spec action in `base.tla`.
3. Add an `emit_*` function in `harness/src/tla_trace.rs` matching the
   schema, with the same field names as the spec validates.
4. Add a call site:
   * If implementation-driven: insert `crate::tla_trace::emit_*()` in the
     source code at the trigger point, and update `apply.sh` if the patch is
     non-trivial (sed/python).  The round-3 emits live in the artifact's
     working tree (untracked); a new patch should follow the same pattern.
   * If harness-only: call from `tla_trace_scenarios.rs` directly in the
     test scenario.

## How to move a capture point (before → after or vice versa)

The most common reason: the spec action's post-state captured a field whose
value differs depending on whether the emit fires before or after a memory
op.

1. Edit the source file's emit call to be on the desired side of the op.
2. Adjust state-field values inside the `format!` to match what the spec
   sees in the post-state.
3. If the artifact source needs editing, do it in the artifact source tree
   directly — re-running `apply.sh` overwrites only `tla_trace.rs` and
   `tla_trace_scenarios.rs`, and patches `list.rs:296` idempotently.

## How to rebuild and re-run after changes

```bash
cd .specula-output
bash harness/run.sh
```

The script builds, runs each scenario in its own `cargo test --exact`
invocation (so each starts with a clean LIST_HEAD), and copies the resulting
NDJSON files into `traces/`.

To skip applying instrumentation (when iterating only on test scenarios):

```bash
cd artifact/arc-swap
ARC_SWAP_TRACE_OUT=/tmp/traces \
  cargo test --test tla_trace_scenarios -- --test-threads=1
```

To validate a single trace:

```bash
cd .specula-output/spec
JSON=../traces/basic_read_write.ndjson tlc Trace -config Trace.cfg
```

## Captured state coverage levels

This harness uses the **specialized** capture level (per `guide.md` §3): each
event captures exactly the fields its spec action modifies, not the full
state.  This is intentional to keep traces small and validation fast.

Examples:
* `WriterSwap` captures `wPC`, `storageAddr` — not the whole writer state.
* `ReaderFastLoad` captures `rPC`, `rOpAddr`, `rPath` — not all reader vars.
* `ClaimNode` captures `nodeState`, `localNode` — not the full node state.

The `TR_*` wrappers in `Trace.tla` only call `Validate*` for fields the
harness actually emits.  Fields not emitted are not validated; the spec
relies on the action's post-condition for those.

## Test scenarios

| Scenario | What it exercises | Notes |
|---|---|---|
| `basic_read_write` | sequential 1 reader + 1 writer | phase barrier |
| `concurrent_readers_writer` | 2 readers (parallel) + 1 writer | readers serialize before writer |
| `family_2_into_inner` | reader does `load_full` → bare Arc | phase barrier sequences r→w |
| `family_2_send_guard` | reader sends Guard via mpsc to another thread | consumer-done barrier sequences r→w |
| `family_2_guard_clone` | NEW: reader forks Guard via `Arc::clone(&*g) + Guard::from_inner` | exercises the F2 fork primitive |
| `family_2_cas_arc` | `compare_and_swap(&Arc, ...)` | self-contained — CAS does the swap |
| `family_2_cas_raw_stale` | `compare_and_swap(*const T, ...)` (RawFresh kind) | F2 caller-misuse |
| `family_5_fallback_path` | uses `FillFastSlots` strategy → all loads via fallback | requires `internal-test-strategies` feature |

The phase barriers are intentional: they make traces deterministic so
Trace.tla (single linear cursor) can replay them.  Without barriers, the
real-time order of cross-thread atomic ops is not preserved by the harness
mutex (which serializes only `emit_*` calls, not the underlying atomics
themselves).  Concurrency-bug-finding is delegated to MC (`MC_hunt_*.cfg`)
in Phase 4, where the spec actions are interleaved by TLC.

## Event-type coverage

Round-4 traces exercise 24 of 33 spec actions.  The 9 uncovered actions:

| Action | Why uncovered |
|---|---|
| `ReaderFastResolve` | requires `ptr != confirm` mid-load race |
| `ReaderFallbackConfirmHelped`, `ReaderFallbackResolveEnvelope` | require writer to help mid-fallback |
| `ReaderFallbackDiscardNode` | requires generation wrap (2^62 fallback calls) — F5 hunted by MC, not trace replay |
| `CASCompareNotEqual`, `CASExchangeFail` | require concurrent CAS racing with another writer |
| `ClaimNode` | happens during scenario warm-up before `enable()` |
| `CheckCooldown` | requires the cooldown state machine to drain — rare under our deterministic scenarios |
| `DropArcSwap` | main test thread is unregistered (see Known Limitation 1 below) |
| `PickRelaxSite` | harness-only event, only fires when a fault-injection scenario deliberately relaxes a memory-ordering site |

These are not gaps in the harness — most are race-dependent or hunted via
MC.  The trace harness's job is to validate the **deterministic** subset of
the spec; non-deterministic / adversarial behaviors are explored by TLC
state-space search.

## Known limitations

1. **Main test thread is unregistered**: the cargo-test main thread does not
   call `register_thread()`, so any spec-action emit triggered there (notably
   `DropArcSwap` from the implicit ArcSwap drop at scope end) is silently
   suppressed.  Tests must therefore avoid dropping the ArcSwap explicitly,
   or move that drop into a registered worker thread.

2. **`WriterReturn` is harness-emitted**: there is no implementation hook for
   the spec's `WriterReturn` (the writer's `T::dec` on `old` happens inside
   the destructor of the returned `Arc`, which is too noisy to instrument).
   Test scenarios call `tla_trace::emit_writer_return()` immediately after
   their `swap()` or `compare_and_swap()` returns.

3. **F5 (generation wraparound) is not trace-reachable**: the implementation's
   raw `local.generation.wrapping_add(4)` requires 2^62 fallback calls to
   wrap on 64-bit.  `emit_reader_fallback_discard_node()` is wired in for
   completeness, but real-test executions will never trigger it.  F5 is
   hunted via `MC_hunt_family5.cfg` with `MaxHelpGen=4`, not via trace
   replay (per instrumentation-spec §3.4).

4. **Family-1 relaxation adversary is harness-only**: `PickRelaxSite` is
   not wired to any source emit; the implementation uses fixed orderings.
   To hunt F1 bugs, use `MC_hunt_family1.cfg`.

5. **CAS-OK refcount semantics**: the spec's `CASExchangeOk` does not model a
   guard transfer to the caller — the implementation's `T::dec(old.as_ptr())`
   inside `compare_and_swap` already balances the refcount.  Test scenarios
   use `std::mem::forget(prev)` to avoid emitting an unmatched `DropGuard`.
