--------------------------- MODULE Update ---------------------------
(*
 * Incremental checks for the 15f927e update:
 * - append-completion callbacks now update a watch slot before LocalIO delivery;
 * - initialization returns the API response before the queued election commands.
 *)

EXTENDS MC

UpdateBridgeStructure ==
    \A s \in Server :
      /\ ioForwarded[s].vote <= ioWatch[s].vote
      /\ ioForwarded[s].log <= ioWatch[s].log
      /\ ioWatch[s].vote <= durableIO[s].vote
      /\ ioWatch[s].log <= durableIO[s].log

UpdateAckAfterFlush ==
    \A a \in ackHistory :
      /\ flushedIO[a.node].vote >= a.requiredVote
      /\ flushedIO[a.node].log >= a.requiredLog

UpdatePendingResponsesReferenceAcceptedIO ==
    \A p \in pendingResponses :
      /\ p.requiredVote <= acceptedIO[p.node].vote
      /\ p.requiredLog <= acceptedIO[p.node].log

UpdateIOBridgeNodeStep(s) ==
    \/ MCLogStoreCompleteAppend(s)
    \/ MCIOCompletionForwarder(s)
    \/ \E io \in pendingLocalIO[s] : MCRaftCoreHandleLocalIO(s, io)

UpdateInitializeElectionNodeStep(s) ==
    \/ MCHandleElectionTimeout(s)
    \/ \E c \in Server \ {s} : MCEngineHandleVoteRequest(s, c)
    \/ MCRaftCoreRunCommandSaveVote(s)
    \/ \E io \in pendingLocalIO[s] : MCRaftCoreHandleLocalIO(s, io)
    \/ MCEngineHandleVoteResponse(s)

UpdateAppendNodeStep(s) ==
    \/ \E value \in Payload : MCLeaderHandlerLeaderAppendEntries(s, value)
    \/ MCRaftCoreRunCommandAppendEntries(s)
    \/ MCLogStoreCompleteAppend(s)
    \/ MCIOCompletionForwarder(s)
    \/ \E target \in Server \ {s} :
         MCReplicationHandlerSendReplicate(s, target)
    \/ \E msg \in network : MCEngineHandleAppendEntries(s, msg)
    \/ \E msg \in network : MCReplicationHandlerUpdateProgress(s, msg)
    \/ MCRaftCoreRunCommandSaveCommittedAndApply(s)
    \/ MCSMWorkerApply(s)

UpdateRecoveryNodeStep(s) ==
    \/ MCCrash(s)
    \/ MCRestartLoadState(s)
    \/ MCStorageHelperRestoreFromSnapshot(s)
    \/ MCStorageHelperReapplyCommitted(s)
    \/ MCStorageHelperFinishRecovery(s)
    \/ MCEngineStartupRestoreLeader(s)
    \/ MCEngineStartupFollowing(s)

UpdateFocusedNodeStep(s) ==
    \/ UpdateInitializeElectionNodeStep(s)
    \/ UpdateAppendNodeStep(s)
    \/ UpdateRecoveryNodeStep(s)

UpdateFocusedGlobalStep ==
    \/ \E p \in pendingResponses : MCRaftCoreReleaseVoteResponse(p)
    \/ \E p \in pendingResponses : MCRaftCoreReleaseRPCResponse(p)
    \/ \E p \in pendingResponses : MCApplyResponderComplete(p)
    \/ \E msg \in network : MCLoseMessage(msg)
    \/ MCAdvanceClock

UpdateFocusedNext ==
    (\E s \in Server : UpdateFocusedNodeStep(s)) \/ UpdateFocusedGlobalStep

UpdateFocusedSpec == MCInit /\ [][UpdateFocusedNext]_mcVars

=================================================================
