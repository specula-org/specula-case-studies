# Changelog: sonic-iccpd Spec Validation

## Round 1 - Trace Validation
- [fix] TraceInit: constrained initial nodeId and role from trace events to eliminate incompatible initial states causing false deadlocks (Trace: all)
- [fix] SilentMessageLoss: removed from TraceNext — unconstrained message loss ate messages needed by upcoming trace actions (Trace: all)
- [fix] TraceMlacpStageSendAllInfoFromExchange: added trace wrapper mapping "MlacpStageSendAllInfo" event to MlacpReceiveSyncRequestInExchange when caller is in EXCHANGE state — harness emits same event name for both cases (Trace: exchange_sync_bug.ndjson)
- [fix] SilentSetNeedToSync: added silent action to set needToSync when next event is MlacpSendSyncRequestFromExchange — test harness sets need_to_sync directly without a NAK event (Trace: exchange_sync_bug.ndjson)
- [fix] TraceMatched: commented out temporal property — TLC with INIT/NEXT produces trivial stuttering counterexamples; deadlock checking is the mechanism for detecting incomplete traces (Trace: all)

## Round 1 - Model Checking
- [fix-spec] PeerDisconnFdbHandler: clear ageFlag to {} when deleting MAC (impl frees struct). AgeFlagOnExistingMac invariant was violated (Case B)
- [fix-spec] PortChannelDown: clear ageFlag to {} when deleting MAC with both age flags (same struct-free issue)
- [fix-spec] PortChannelUp: clear ageFlag to {} when deleting MAC with pendingLocalDel (same struct-free issue)
- MC.cfg BFS run: 30 min, 705M states generated, 78.7M distinct, depth 15, no violations

## Bug Hunting
- [bug] Family 1: MACConsistency violated — wrong variable bug (mac_msg vs mac_info) in MacUpdateFromSyncd (Finding M1)
- [bug] Family 2: NoErrorState violated — sync request during EXCHANGE advances to ERROR state (Finding M4)
- [bug] Family 3: NodeIdCollisionDetected violated — both peers increment to same nodeId (Finding M6)
- [bug] Family 4: NoFalseHeartbeatTimeout violated — timer starts on TCP connect but heartbeats only sent after ICCP operational (Finding M8)
- [fix-inv] Family 5: WarmBootFdbConsistency invariant too strong — triggers in initial state (Case A). Underlying bug (Finding M7) confirmed structurally.

## Result
Converged in 1 round. Bug hunting: 4 bugs found (Findings M1, M4, M6, M8), 1 invariant fix (Family 5).
