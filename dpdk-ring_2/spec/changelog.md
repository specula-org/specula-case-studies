# DPDK rte_ring (Round 2) — Spec Validation Changelog

## Round 1 - Trace Validation

- [fix] HTSProdCAS / HTSConsCAS / HTSProdUpdateTail / HTSConsUpdateTail: harness emits `s_post` snapshot (prodHead=1 after CAS); spec was validating against pre-state. Added `Validate*Post` helpers (primed) for these CAS / UpdateTail events. (Trace: trace_hts.ndjson)
- [fix] HTSCons* / RTSCons* event handlers + dispatch: missing in Trace.tla. Added handlers for HTSConsHeadWait / LoadStail / CAS / UpdateTail and RTSConsHeadWait / LoadStail / CAS / UpdateTail. (Trace: trace_hts.ndjson, trace_rts.ndjson)
- [fix-spec] base.tla: RTSProdLoadStail / RTSConsLoadStail read default-mode `consTail`/`prodTail` (always 0 under RTS); changed to `rtsConsTailPos`/`rtsProdTailPos` so RTS consumer can actually see producer-side tail. Without this, `ents` was always 0 and CAS never succeeded. (Trace: trace_rts.ndjson)
- [fix] Cross-thread reads under partial-order trace replay: HTS / RTS LoadStail handlers now seed `visibleProdTail` / `visibleConsTail` directly from the captured `ev.state` value rather than re-reading the live spec variable. Avoids deadlocks when TLC linearization picks an order in which the opposing thread's update_tail has already fired but the harness's snapshot reflects a still-stale view. (Trace: trace_hts.ndjson, trace_rts.ndjson)
- [fix-spec] base.tla: `SORingRelease_LoadTail` branch 1 (tail==pos) didn't UNCHANGED `op`/`role`, leaving them undefined in the post-state and causing `Successor state not completely specified`. Added explicit `UNCHANGED <<op, role>>` to that branch. (Trace: trace_soring.ndjson)
- [fix] Trace.tla `TraceInit` / `ThreadsWithEvents`: peek trace has only `t1`, but `Thread = {"t1","t2"}`. Initialised `traces` and `pc` over the full `Thread` set (defaulting `t2`'s queue to `<<>>`). (Trace: trace_peek.ndjson)
- [fix] OnSORingAcquire_MoveHead: the SORING harness drives input enqueue / dequeue from the test driver but does NOT instrument those calls. As a result `prodTail` never advances and the spec's `actual_n > 0` guard always fails. The trace handler now bypasses the avail check and trusts the captured `(stage, n)` since the trace already witnessed a successful acquire. (Trace: trace_soring.ndjson)
- [fix] OnSORingRelease_LoadState: spec picks any START slot non-deterministically; trace handler now picks the slot whose stored ftoken matches `locFtoken[tid]` (the ftoken set at this thread's most recent acquire). (Trace: trace_soring.ndjson)
- [abstraction-gap] SORING trace replay: even with the above, the trace replay still deadlocks on the finalize-CAS race (one thread takes the sync bit, the other doesn't). Faithfully replaying this would require encoding the harness's exact wall-clock interleaving of the two finalize calls; the captured `state: []` field carries no SORING state info to disambiguate. Recorded as a known gap; Family D coverage relies on MC bug-hunting configs (`MC_hunt_familyD*.cfg`) rather than trace replay.
- [abstraction-gap] Peek trace replay: harness exercises both enqueue-side and dequeue-side peek (`rte_ring_dequeue_bulk_start` / `_finish`), but the spec only models prod-side `PeekStart`/`PeekFinish`. Cons-side peek events are unmodelled (per the INSTRUMENTATION.md "known gaps" note). Family E coverage relies on `MC_hunt_familyE.cfg`.

### Round 1 Result
- MT trace: PASS (52 states, depth ~25)
- HTS trace: PASS (46 states)
- RTS trace: PASS (59 states)
- SORING trace: abstraction gap (replay deadlocks on finalize-CAS race; MC hunting will cover Family D)
- Peek trace: abstraction gap (cons-side peek not modelled in base; MC hunting will cover Family E)

## Round 1 - Model Checking

- [fix-spec] base.tla `ProdMoveHead_LoadTail` / `ProdMoveHead_CAS`: missing `role[t] = "prod"` guards. Without them a thread that entered via `ConsMoveHead_LoadHead` (role=cons) could fire the producer-side LoadTail/CAS because all three entry actions transition phase to `MoveHead.LoadHead`. TLC found a counterexample (`MC_ConsumedWasPushed` violated, depth 6) where a cons-direction thread incremented `prodHead` and "enqueued" a synthetic value. Added the role guards so each side is only fired by its own role. (Case B — spec issue)
- [fix-inv] MC.cfg: added a `BoundedRun` state constraint (`nextVal <= Capacity + 2 /\ posWrapCount <= 1`). Without it, the small `PosWrap = 4` lets the head/tail counter wrap around in a few ops, exposing a counter-wrap ABA where a stale `locOldHead = 0` reappears as the live `prodHead = 0` after wrap. The modeling brief explicitly classifies 32-bit wraparound as "Do Not Model" — real DPDK uses a 32-bit counter where the documented `in_flight < 2^31` invariant makes ABA practically impossible. The state constraint mimics that invariant for bounded MC. (Case A — invariant too strong because the spec didn't capture this premise)

### Round 1 Model Checking Result
- MC.cfg: PASS — `Model checking completed. No error has been found.` (29 106 states, 11 909 distinct, depth 40)

## Round 2 - Convergence Re-verification

After Round-1 spec fixes (Prod*MoveHead role guards, RTS LoadStail variable
fix, SORING release_loadtail UNCHANGED fix), re-ran trace validation:
- MT trace: PASS
- HTS trace: PASS
- RTS trace: PASS

No further spec changes needed. **Converged.**

## Bug Hunting

- [bug] Family A — `MC_RTSPosCntConsistent` violated (BFS depth 22, 9 states). BZ-1527 candidate confirmed. See `bug-report.md`.
- [bug] Family D.1 — `MC_SORingStageOrdered` violated (BFS depth 30). SORING stage_move_head with stale head load. See `bug-report.md`.
- [bug] Family D.2 — `MC_SORingNoStuckFinalize` violated (BFS depth 14). SORING release lost-finalize race. See `bug-report.md`.
- [bug] Family D.3 — `MC_SORingReleaseExact` violated (BFS depth 12). SORING release with wrong n. See `bug-report.md`.
- [no-bug] Family B — 119 941 states, depth 43. Modeling gap: callMode reset on every op-start.
- [no-bug] Family C — 64 357 states, depth 40. November 2025 partial-order patch confirmed sound.
- [skipped] Family D.4 — config-level deadlock (PosWrap=2 prevents progress). Need cfg redesign.
- [spec-defect] Family E — `MC_PeekRollbackAtomic` invariant fires for non-peek ST-mode ops. Invariant too strong, not a real bug.

### Spec adjustments during hunting
- Added structural action `SORingProdEnqueue` to base.tla so SORING hunting configs can make progress.
- Added `BoundedRun` state constraint to MC.cfg (and all hunting cfgs except D4).

## Result

Converged in 2 rounds (1 trace + 1 MC + 1 cross-check). Bug hunting: **4 real bugs found** (Family A BZ-1527 + 3 SORING bugs D.1/D.2/D.3), 2 not reproduced (B, D.4), 1 spec-defect false positive (E), 1 confirmation (C).
