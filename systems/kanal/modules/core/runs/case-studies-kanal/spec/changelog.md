# Changelog: kanal Spec Validation

## Round 0 - Initialization
- [fix] Trace.cfg: changed from SPECIFICATION to INIT/NEXT for deadlock-based completion checking
- [fix] Trace.cfg: added t4 to Thread set (trace_contention.json has 4 threads)

## Round 1 - Trace Validation
- [fix-spec] SignalWaitSuccess: receiver now copies signalData to threadData on wakeup (needed for data recycling)
- [fix-spec] ThreadReset: recycles consumed receiver data from LOC_RECEIVER back to LOC_SENDER (allows finite Data set to cover many send/recv cycles)
- [fix] Trace.tla signal_write_data: added no-op counterpart case (threadDone=TRUE → UNCHANGED vars) since write_data is emitted by the COUNTERPART thread, not the blocking thread; spec already models it atomically in send/recv actions
- [fix] Trace.tla SilentThreadReset: restricted to only fire when thread has NO remaining events (prevents premature reset before wait_timeout, signal_write_data, etc.)
- [fix] Trace.tla: added SilentWaitTimeoutRecheck silent action for timed-out threads checking resolved signals
- [fix] Created Trace_rendezvous.cfg (Capacity=0) for trace_direct_handoff
- [abstraction-gap] trace_contention: fails due to Category B timebox ambiguity — t4.send_direct_handoff has wide timebox [8-54] causing TLC to explore infeasible orderings. Not a spec error. 3/4 traces pass.

## Round 1 - Model Checking
- No violations. 695,290 states, 164,696 distinct, depth 21. All 8 invariants pass.

## Bug Hunting
- [bug] K-1: CapacityBound violated — ReceiveFuture::drop push_front exceeds capacity on bounded channels (future.rs:246-249)
- [bug] K-2: NoDataLoss violated — ReceiveFuture::drop on rendezvous channel silently drops data (future.rs:239-244, documented limitation)
- MC_hunt_signal_race: PASS (BFS 27K states + simulation 1.35B states)
- MC_hunt_close: PASS (BFS 17K states + simulation 1.58B states)

## Result
Converged in 1 round. Bug hunting: 2 bugs found (1 undocumented capacity violation, 1 documented cancel-unsafety).
