# Besu QBFT Spec Changelog

## Round 1 - Trace Validation
- [fix] TraceProposer: Derived proposer from trace events instead of hardcoded round-robin formula. If trace contains HandleProposal, use msg.from as proposer; otherwise, the BlockTimerExpiry node is proposer. Falls back to round-robin for untouched rounds.
- [fix] SelfPrepareIfLogged: Added new action for HandlePrepare(from=self, to=self). Implementation calls `peerIsPrepared(localPrepareMessage)` locally — not a network message. Handles prepare addition and quorum transition without message bag lookup.
- [fix] HandlePrepareIfLogged: Excluded self-prepares (`msg.from /= i`) since those are handled by SelfPrepareIfLogged.
- [fix] Silent actions: Added `NeedRemoteMessage` guard and `Server \ {TracedNode}` constraint. Only fire when the current trace event needs a message from a remote server. Removed SilentHandleCommit (commits don't produce messages needed by traced node). Prevents state space explosion from irrelevant interleavings.
- [fix] RoundExpiryIfLogged: Changed from ValidatePostState to ValidatePreState. Implementation emits trace at handler entry, before round increment.
- [fix] HandleCommitIfLogged: Force import-succeeds when commit quorum is reached (`blockImported'[i] = TRUE`). Removes non-deterministic import failure branch that would block subsequent NewChainHead.
- [fix] Trace.cfg: Added `PROPERTIES TraceMatched` and `CHECK_DEADLOCK FALSE`.
- Traces: basic.ndjson (203 states), remote_proposer.ndjson (458 states), round_change.ndjson (4 states) — all PASSED.

## Round 1 - Model Checking
- MC.cfg BFS: 227M states generated, 51.7M distinct, depth 38, ~12 min. All invariants hold, all temporal properties hold. No spec modifications needed.

## Round 2 - Spec Fix (Case A)
- [fix] RoundExpiry: Removed `~committed[s]` guard. Implementation's `roundExpired()` (QbftBlockHeightManager.java:268-288) has no `isCommitted()` check. A committed node with failed import CAN round-change (losing committed seals). The original guard was stricter than implementation (Case A: spec-implementation mismatch).
- [reclassify] MC-5: Downgraded from "liveness bug" to "Case A spec-impl mismatch". The committed-stuck state is still reachable but is no longer permanent — node escapes via RoundExpiry.
- Updated CommittedStuckDetector invariant comment to reflect reclassification.
- MC.cfg BFS: 227M states generated, 51.7M distinct, depth 38. All invariants hold, all temporal properties hold. No new bugs introduced by the fix.

## Result
Converged in 2 rounds. Bug hunting: 1 confirmed bug (MC-1), 1 reclassified (MC-5 → Case A).
