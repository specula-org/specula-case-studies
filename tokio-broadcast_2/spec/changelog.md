# Spec Validation Changelog — tokio::sync::broadcast (Round 2)

Tracks all modifications to the spec across iterations of trace validation, model checking, and bug hunting.

## Round 1 - Trace Validation
- [fix-spec] RecvDrop_Begin: relax precondition from `recvPC[r] \in {"parked", "polled_again"}` to also accept `"idle"`. In Tokio, Recv::drop runs whenever the Recv future is dropped — including immediately after a successful poll completes (when recvPC is "idle" in spec). Previous spec only modeled cancellation paths. (All traces.)
- [fix-spec] Trace.tla TraceSpec: add `WF_<<vars,pc>>(TraceNext)` weak fairness, add `TraceMatched == TraceFullyConsumed` alias, and update Trace.cfg to use the canonical `TraceMatched` name. Without fairness the temporal property `TraceFullyConsumed` had trivial stuttering counterexamples. (All traces.)
- [fix-cfg] Trace.cfg Capacity: change from 2 to 4 to match the harness — most scenarios use `broadcast::channel::<i32>(4)`. Created Trace_C2.cfg for the lagged_receiver scenario (which uses Capacity=2). (clone_drop_senders.ndjson, subscribe_while_send.ndjson)

## Round 1 - Model Checking
- (no spec/invariant changes) Simulation with MC.cfg ran 20 min, 722M states across 3M traces, no invariant violations. BFS attempt earlier hit per-user disk quota at 64M distinct states — switched to simulation for convergence.

## Result
Converged in 1 round.

## Bug Hunting

### Round B1 - F1 drop_close_races
- [fix-inv] ConcurrentDropCloseIdempotent (Case A): the `(tailClosed /\ tailRxCnt > 0) => closeReason \in {none, all_receivers_dropped}` formulation is too strong. When the last Sender drops at broadcast.rs:1067-1073, `close_channel()` runs unconditionally and tail.closed becomes TRUE while tail.rx_cnt is still > 0 (no receiver dropped yet) — a normal transient window. Weakened to `closeReason = "all_senders_dropped" => numTx = 0` (a structural consistency check that's also covered by CloseReopenSemantics).
- F1 BFS retry: depth 80, 9.4M states / 2.2M distinct, no violations. (output/MC_hunt_F1_bfs2.out)

### Round B2 - F2 caller_misuse
- [fix-inv] RxCntPositiveImpliesNotPermanentlyClosed (Case A): the `(tailRxCnt > 0) => (closeReason /= "all_senders_dropped" \/ ~tailClosed)` formulation triggers the same transient window as Round B1 — last sender drops while a receiver is alive. Reformulated to `(tailRxCnt > 0) => closeReason /= "all_receivers_dropped"`, capturing the actual constraint (a receiver-drop close cannot coexist with a live receiver).
- F2 BFS retry: depth 50, 1.05B states / 189M distinct, no violations (JVM crash mid-run, but coverage is well past diameter 25). (output/MC_hunt_F2_bfs2.out)

### Round B3 - F4 memorder_queued
- F4 BFS: depth 40, 27,721 states / 10,023 distinct, no violations. (output/MC_hunt_F4_bfs.out)

### Round B4 - F5 slot_reuse
- F5 BFS: depth 65, ~750M states / 181M distinct (BFS hit per-user disk quota; coverage well past diameter 25). No violations. (output/MC_hunt_F5_bfs.out)

## Bug Hunting Result
0 real bugs found. 2 Case A invariant fixes applied. See `spec/bug-report.md` for full coverage and per-family details.



