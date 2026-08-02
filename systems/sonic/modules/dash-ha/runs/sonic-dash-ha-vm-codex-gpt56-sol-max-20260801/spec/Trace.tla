--------------------------- MODULE Trace ----------------------------
\* Linear NDJSON trace replay for Category A dash-ha actors/bridges.
\* Every implementation-visible base action has one event and directly calls
\* the corresponding base operator.  No unconstrained silent action is used.

EXTENDS base, Json, IOUtils, Sequences, TLC

\* Required default and per-run override from the spec-generation workflow.
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

TraceLog == TLCEval(
    LET all == ndJsonDeserialize(JsonFile)
    IN SelectSeq(all, LAMBDA entry :
        /\ "tag" \in DOMAIN entry
        /\ entry.tag = "trace"
        /\ "event" \in DOMAIN entry
        /\ "name" \in DOMAIN entry.event))

ASSUME Len(TraceLog) > 0

VARIABLE l

traceVars == <<vars, l>>

logline == TraceLog[l]

TraceNode == TLCEval(
    {TraceLog[index].event.node : index \in 1..Len(TraceLog)})

ASSUME TraceNode /= {}
ASSUME TraceNode \subseteq Node

\* The harness bootstraps after the initial epoch-1 config, HA-set/scope
\* application, and initial role ACKs have converged.  This is the same
\* bootstrap represented by base.Init.
TraceInit ==
    /\ Init
    /\ l = 1

IsEvent(name) ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = name

StepTrace == l' = l + 1

SequenceToSet(sequence) ==
    {sequence[index] : index \in 1..Len(sequence)}

\* -----------------------------------------------------------------
\* Strong post-state validation
\* -----------------------------------------------------------------
\*
\* Every event captures a complete projection for the event's node plus the
\* shared message/route state.  Arrays in JSON are converted back to sets.
\* Calling the base action already enforces that all other nodes are unchanged.

ValidateGlobalPostState ==
    LET post == logline.event.post
    IN
    /\ sys'.pendingRoleWrites = SequenceToSet(post.pendingRoleWrites)
    /\ sys'.haOwner = post.haOwner
    /\ sys'.routeCandidate = post.routeCandidate
    /\ sys'.routeCandidateEpoch = post.routeCandidateEpoch
    /\ sys'.routeCandidateTerm = post.routeCandidateTerm
    /\ sys'.routePending = post.routePending
    /\ sys'.routeOwner = post.routeOwner
    /\ sys'.routeEpoch = post.routeEpoch
    /\ sys'.routeTerm = post.routeTerm
    /\ sys'.lastRouteWriter = post.lastRouteWriter
    /\ messages' = SequenceToSet(post.messages)
    /\ ackPending' = SequenceToSet(post.ackPending)

ValidateNodePostState(node) ==
    LET post == logline.event.post
        state == post.nodeState
    IN
    /\ node = logline.event.node
    /\ sys'.processUp[node] = state.processUp
    /\ sys'.accepted[node] = state.accepted
    /\ sys'.actorApplied[node] = state.actorApplied
    /\ sys'.actorCommitted[node] = state.actorCommitted
    /\ sys'.haSetIssued[node] = state.haSetIssued
    /\ sys'.haSetApplied[node] = state.haSetApplied
    /\ sys'.prereqReady[node] = state.prereqReady
    /\ sys'.scopeIssued[node] = state.scopeIssued
    /\ sys'.scopeApplied[node] = state.scopeApplied
    /\ sys'.queuedHaSetWrite[node] = state.queuedHaSetWrite
    /\ sys'.queuedHaSetState[node] = state.queuedHaSetState
    /\ sys'.haSetStateInFlight[node] = state.haSetStateInFlight
    /\ sys'.producerHaSetPending[node] = state.producerHaSetPending
    /\ sys'.queuedScopeWrite[node] = state.queuedScopeWrite
    /\ sys'.queuedScopeRole[node] = state.queuedScopeRole
    /\ sys'.queuedScopeTerm[node] = state.queuedScopeTerm
    /\ sys'.queuedScopePairEpoch[node] = state.queuedScopePairEpoch
    /\ sys'.producerScopePending[node] = state.producerScopePending
    /\ sys'.producerScopeRole[node] = state.producerScopeRole
    /\ sys'.producerScopeTerm[node] = state.producerScopeTerm
    /\ sys'.producerScopePairEpoch[node] = state.producerScopePairEpoch
    /\ sys'.cpState[node] = state.cpState
    /\ sys'.asicRole[node] = state.asicRole
    /\ sys'.ackedRole[node] = state.ackedRole
    /\ sys'.term[node] = state.term
    /\ sys'.ackedTerm[node] = state.ackedTerm
    /\ sys'.ackedPairEpoch[node] = state.ackedPairEpoch
    /\ sys'.currentPeer[node] = state.currentPeer
    /\ sys'.pairEpoch[node] = state.pairEpoch
    /\ sys'.peerConnected[node] = state.peerConnected
    /\ sys'.lastPeerEvent[node] = state.lastPeerEvent
    /\ sys'.peerGeneration[node] = state.peerGeneration
    /\ sys'.maxPeerGeneration[node] = state.maxPeerGeneration
    /\ sys'.peerTerm[node] = state.peerTerm
    /\ sys'.peerCachedState[node] = state.peerCachedState
    /\ sys'.peerCachedAckRole[node] = state.peerCachedAckRole
    /\ sys'.peerCachedOwner[node] = state.peerCachedOwner
    /\ sys'.peerCacheEpoch[node] = state.peerCacheEpoch
    /\ sys'.peerCacheSource[node] = state.peerCacheSource
    /\ sys'.foreignApplied[node] = state.foreignApplied
    /\ sys'.transitionAuthorized[node] = state.transitionAuthorized
    /\ sys'.authorizationTerm[node] = state.authorizationTerm
    /\ sys'.authorizationEpoch[node] = state.authorizationEpoch
    /\ sys'.persistedPhase[node] = state.persistedPhase
    /\ sys'.durableIntent[node] = SequenceToSet(state.durableIntent)
    /\ sys'.queuedActions[node] = SequenceToSet(state.queuedActions)
    /\ sys'.completedActions[node] = SequenceToSet(state.completedActions)
    /\ sys'.rehydrationNeeded[node] = state.rehydrationNeeded
    /\ sys'.pendingFlagEpoch[node] = state.pendingFlagEpoch
    /\ sys'.cachedPendingFlagEpoch[node] = state.cachedPendingFlagEpoch
    /\ sys'.pendingOps[node] = SequenceToSet(state.pendingOps)
    /\ sys'.configPresent[node] = state.configPresent
    /\ sys'.configEpoch[node] = state.configEpoch
    /\ sys'.bridgeCacheEpoch[node] = state.bridgeCacheEpoch
    /\ sys'.configDeliveryPending[node] = state.configDeliveryPending
    /\ sys'.actorPhase[node] = state.actorPhase
    /\ sys'.exactRouteEpoch[node] = state.exactRouteEpoch
    /\ sys'.registrations[node] = state.registrations
    /\ sys'.parentCacheEpoch[node] = state.parentCacheEpoch
    /\ sys'.ignoredSet[node] = state.ignoredSet
    /\ sys'.queuedHaSetDelete[node] = state.queuedHaSetDelete
    /\ sys'.producerHaSetDeletePending[node] = state.producerHaSetDeletePending
    /\ sys'.sharedRetry[node] = state.sharedRetry
    /\ sys'.retryByProtocol[node] = state.retryByProtocol
    /\ sys'.retryIsolationBroken[node] = state.retryIsolationBroken
    /\ sys'.peerLost[node] = state.peerLost
    /\ inbox'[node] = post.inbox
    /\ ValidateGlobalPostState

LoggedNodeAction(name, action) ==
    /\ IsEvent(name)
    /\ logline.event.node \in Node
    /\ action
    /\ ValidateNodePostState(logline.event.node)
    /\ StepTrace

LoggedGlobalAction(name, action) ==
    /\ IsEvent(name)
    /\ action
    /\ ValidateGlobalPostState
    /\ StepTrace

\* -----------------------------------------------------------------
\* One wrapper per base action
\* -----------------------------------------------------------------

ConsumerBridgeConfigSetIfLogged ==
    LoggedNodeAction("ConsumerBridgeConfigSet",
        ConsumerBridgeConfigSet(logline.event.node, logline.event.epoch))

ActorCreatorHandleReceivedMessageIfLogged ==
    LoggedNodeAction("ActorCreatorHandleReceivedMessage",
        ActorCreatorHandleReceivedMessage(logline.event.node))

ActorDriverHandleSwbusMessageIfLogged ==
    LoggedNodeAction("ActorDriverHandleSwbusMessage",
        ActorDriverHandleSwbusMessage(logline.event.node))

ActorDriverHandleSetWhileDeletingIfLogged ==
    LoggedNodeAction("ActorDriverHandleSetWhileDeleting",
        ActorDriverHandleSetWhileDeleting(logline.event.node))

ActorDriverHandleActorMessageIfLogged ==
    LoggedNodeAction("ActorDriverHandleActorMessage",
        ActorDriverHandleActorMessage(logline.event.node))

HaSetActorUpdateDashHaSetTableIfLogged ==
    LoggedNodeAction("HaSetActorUpdateDashHaSetTable",
        HaSetActorUpdateDashHaSetTable(logline.event.node))

ActorDriverCommitChangesIfLogged ==
    LoggedNodeAction("ActorDriverCommitChanges",
        ActorDriverCommitChanges(logline.event.node))

ActorDriverSendQueuedHaSetWriteIfLogged ==
    LoggedNodeAction("ActorDriverSendQueuedHaSetWrite",
        ActorDriverSendQueuedHaSetWrite(logline.event.node))

ActorDriverSendQueuedHaSetStateIfLogged ==
    LoggedNodeAction("ActorDriverSendQueuedHaSetState",
        ActorDriverSendQueuedHaSetState(logline.event.node))

ProducerBridgeApplyHaSetIfLogged ==
    LoggedNodeAction("ProducerBridgeApplyHaSet",
        ProducerBridgeApplyHaSet(logline.event.node))

HaScopeHandleHaSetStateIfLogged ==
    LoggedNodeAction("HaScopeHandleHaSetState",
        HaScopeHandleHaSetState(logline.event.node))

ActorRegistrationHandleIfLogged ==
    LoggedNodeAction("ActorRegistrationHandle",
        ActorRegistrationHandle(logline.event.node))

NpuUpdateDpuHaScopeTableIfLogged ==
    LoggedNodeAction("NpuUpdateDpuHaScopeTable",
        NpuUpdateDpuHaScopeTable(logline.event.node))

ActorDriverSendQueuedScopeWriteIfLogged ==
    LoggedNodeAction("ActorDriverSendQueuedScopeWrite",
        ActorDriverSendQueuedScopeWrite(logline.event.node))

ProducerBridgeApplyScopeIfLogged ==
    LoggedNodeAction("ProducerBridgeApplyScope",
        ProducerBridgeApplyScope(logline.event.node))

DpuAsicAcknowledgeRoleIfLogged ==
    LoggedNodeAction("DpuAsicAcknowledgeRole",
        DpuAsicAcknowledgeRole(logline.event.write))

ConsumerBridgeConfigDeleteIfLogged ==
    LoggedNodeAction("ConsumerBridgeConfigDelete",
        ConsumerBridgeConfigDelete(logline.event.node))

HaSetActorDoCleanupIfLogged ==
    LoggedNodeAction("HaSetActorDoCleanup",
        HaSetActorDoCleanup(logline.event.node))

ActorDriverSendQueuedHaSetDeleteIfLogged ==
    LoggedNodeAction("ActorDriverSendQueuedHaSetDelete",
        ActorDriverSendQueuedHaSetDelete(logline.event.node))

ProducerBridgeApplyHaSetDeleteIfLogged ==
    LoggedNodeAction("ProducerBridgeApplyHaSetDelete",
        ProducerBridgeApplyHaSetDelete(logline.event.node))

ActorDriverFinishDeleteIfLogged ==
    LoggedNodeAction("ActorDriverFinishDelete",
        ActorDriverFinishDelete(logline.event.node))

ActorDriverCleanupTimeoutIfLogged ==
    LoggedNodeAction("ActorDriverCleanupTimeout",
        ActorDriverCleanupTimeout(logline.event.node))

OutgoingSendHaScopeStateIfLogged ==
    LoggedNodeAction("OutgoingSendHaScopeState",
        OutgoingSendHaScopeState(
            logline.event.node,
            logline.event.sourcePeer,
            logline.event.requestId,
            logline.event.generation,
            logline.event.peerState,
            logline.event.ackedRole,
            logline.event.owner))

IncomingHandleRequestIfLogged ==
    LoggedNodeAction("IncomingHandleRequest",
        IncomingHandleRequest(logline.event.node, logline.event.requestId))

NpuHandleHaStateChangeIfLogged ==
    LoggedNodeAction("NpuHandleHaStateChange",
        NpuHandleHaStateChange(logline.event.node))

OutgoingHandleResponseIfLogged ==
    LoggedNodeAction("OutgoingHandleResponse",
        OutgoingHandleResponse(logline.event.requestId))

OutgoingHandleLateResponseIfLogged ==
    LoggedNodeAction("OutgoingHandleLateResponse",
        OutgoingHandleLateResponse(logline.event.requestId))

NetworkLoseAckIfLogged ==
    LoggedNodeAction("NetworkLoseAck",
        NetworkLoseAck(logline.event.requestId))

OutgoingDriveMaintenanceLoopIfLogged ==
    LoggedNodeAction("OutgoingDriveMaintenanceLoop",
        OutgoingDriveMaintenanceLoop(logline.event.requestId))

OutgoingDropExpiredIfLogged ==
    LoggedNodeAction("OutgoingDropExpired",
        OutgoingDropExpired(logline.event.requestId))

NpuHandleHaSetStateUpdateRePairResolvedIfLogged ==
    LoggedNodeAction("NpuHandleHaSetStateUpdateRePairResolved",
        NpuHandleHaSetStateUpdateRePairResolved(logline.event.node))

NpuHandleHaSetStateUpdateRePairUnresolvedIfLogged ==
    LoggedNodeAction("NpuHandleHaSetStateUpdateRePairUnresolved",
        NpuHandleHaSetStateUpdateRePairUnresolved(logline.event.node))

NpuDriveStateMachinePeerAckIfLogged ==
    LoggedNodeAction("NpuDriveStateMachinePeerAck",
        NpuDriveStateMachinePeerAck(logline.event.node))

NpuDriveStateMachineIfLogged ==
    LoggedNodeAction("NpuDriveStateMachine",
        NpuDriveStateMachine(logline.event.node, logline.event.nextState))

ActorDriverSendQueuedActionIfLogged ==
    LoggedNodeAction("ActorDriverSendQueuedAction",
        ActorDriverSendQueuedAction(logline.event.node, logline.event.action))

CrashIfLogged ==
    LoggedNodeAction("Crash", Crash(logline.event.node))

RecoverIfLogged ==
    LoggedNodeAction("Recover", Recover(logline.event.node))

NpuApplyRehydrationSideEffectsIfLogged ==
    LoggedNodeAction("NpuApplyRehydrationSideEffects",
        NpuApplyRehydrationSideEffects(logline.event.node))

DpuHandlePendingOperationIfLogged ==
    LoggedNodeAction("DpuHandlePendingOperation",
        DpuHandlePendingOperation(logline.event.node,
                                  logline.event.epoch,
                                  logline.event.operationId))

NpuApprovePendingOperationIfLogged ==
    LoggedNodeAction("NpuApprovePendingOperation",
        NpuApprovePendingOperation(logline.event.node,
                                   logline.event.operationId))

HaSetComputeRouteFromScopeIfLogged ==
    LoggedNodeAction("HaSetComputeRouteFromScope",
        HaSetComputeRouteFromScope(logline.event.node))

HaSetComputeRouteFromConfigIfLogged ==
    LoggedGlobalAction("HaSetComputeRouteFromConfig",
        HaSetComputeRouteFromConfig)

HaSetComputeRouteFromReplayIfLogged ==
    LoggedNodeAction("HaSetComputeRouteFromReplay",
        HaSetComputeRouteFromReplay(logline.event.node))

ProducerBridgeApplyRouteIfLogged ==
    LoggedGlobalAction("ProducerBridgeApplyRoute",
        ProducerBridgeApplyRoute)

NpuHandleVoteRequestRetryIfLogged ==
    LoggedNodeAction("NpuHandleVoteRequestRetry",
        NpuHandleVoteRequestRetry(logline.event.node))

NpuHandleVoteRequestFinalIfLogged ==
    LoggedNodeAction("NpuHandleVoteRequestFinal",
        NpuHandleVoteRequestFinal(logline.event.node))

NpuHandleSwitchoverRstIfLogged ==
    LoggedNodeAction("NpuHandleSwitchoverRst",
        NpuHandleSwitchoverRst(logline.event.node))

NpuHandleSwitchoverFinIfLogged ==
    LoggedNodeAction("NpuHandleSwitchoverFin",
        NpuHandleSwitchoverFin(logline.event.node))

NpuCheckPeerConnectionAndRetryIfLogged ==
    LoggedNodeAction("NpuCheckPeerConnectionAndRetry",
        NpuCheckPeerConnectionAndRetry(logline.event.node))

NpuCheckPeerConnectionLostIfLogged ==
    LoggedNodeAction("NpuCheckPeerConnectionLost",
        NpuCheckPeerConnectionLost(logline.event.node))

NpuPeerConnectedResetIfLogged ==
    LoggedNodeAction("NpuPeerConnectedReset",
        NpuPeerConnectedReset(logline.event.node))

\* No silent transitions are required: instrumentation-spec.md places an
\* event at every externally scheduled boundary represented by base.tla.
TraceNext ==
    \/ ConsumerBridgeConfigSetIfLogged
    \/ ActorCreatorHandleReceivedMessageIfLogged
    \/ ActorDriverHandleSwbusMessageIfLogged
    \/ ActorDriverHandleSetWhileDeletingIfLogged
    \/ ActorDriverHandleActorMessageIfLogged
    \/ HaSetActorUpdateDashHaSetTableIfLogged
    \/ ActorDriverCommitChangesIfLogged
    \/ ActorDriverSendQueuedHaSetWriteIfLogged
    \/ ActorDriverSendQueuedHaSetStateIfLogged
    \/ ProducerBridgeApplyHaSetIfLogged
    \/ HaScopeHandleHaSetStateIfLogged
    \/ ActorRegistrationHandleIfLogged
    \/ NpuUpdateDpuHaScopeTableIfLogged
    \/ ActorDriverSendQueuedScopeWriteIfLogged
    \/ ProducerBridgeApplyScopeIfLogged
    \/ DpuAsicAcknowledgeRoleIfLogged
    \/ ConsumerBridgeConfigDeleteIfLogged
    \/ HaSetActorDoCleanupIfLogged
    \/ ActorDriverSendQueuedHaSetDeleteIfLogged
    \/ ProducerBridgeApplyHaSetDeleteIfLogged
    \/ ActorDriverFinishDeleteIfLogged
    \/ ActorDriverCleanupTimeoutIfLogged
    \/ OutgoingSendHaScopeStateIfLogged
    \/ IncomingHandleRequestIfLogged
    \/ NpuHandleHaStateChangeIfLogged
    \/ OutgoingHandleResponseIfLogged
    \/ OutgoingHandleLateResponseIfLogged
    \/ NetworkLoseAckIfLogged
    \/ OutgoingDriveMaintenanceLoopIfLogged
    \/ OutgoingDropExpiredIfLogged
    \/ NpuHandleHaSetStateUpdateRePairResolvedIfLogged
    \/ NpuHandleHaSetStateUpdateRePairUnresolvedIfLogged
    \/ NpuDriveStateMachinePeerAckIfLogged
    \/ NpuDriveStateMachineIfLogged
    \/ ActorDriverSendQueuedActionIfLogged
    \/ CrashIfLogged
    \/ RecoverIfLogged
    \/ NpuApplyRehydrationSideEffectsIfLogged
    \/ DpuHandlePendingOperationIfLogged
    \/ NpuApprovePendingOperationIfLogged
    \/ HaSetComputeRouteFromScopeIfLogged
    \/ HaSetComputeRouteFromConfigIfLogged
    \/ HaSetComputeRouteFromReplayIfLogged
    \/ ProducerBridgeApplyRouteIfLogged
    \/ NpuHandleVoteRequestRetryIfLogged
    \/ NpuHandleVoteRequestFinalIfLogged
    \/ NpuHandleSwitchoverRstIfLogged
    \/ NpuHandleSwitchoverFinIfLogged
    \/ NpuCheckPeerConnectionAndRetryIfLogged
    \/ NpuCheckPeerConnectionLostIfLogged
    \/ NpuPeerConnectedResetIfLogged
    \/ /\ l > Len(TraceLog)
       /\ UNCHANGED <<vars, l>>

TraceSpec ==
    /\ TraceInit
    /\ [][TraceNext]_traceVars
    /\ WF_traceVars(TraceNext)

TraceMatched == <>(l > Len(TraceLog))

TraceView == <<vars, l>>

TraceAlias ==
    [cursor |-> l,
     length |-> Len(TraceLog),
     event |-> IF l <= Len(TraceLog) THEN logline.event.name ELSE "DONE",
     node |-> IF l <= Len(TraceLog) THEN logline.event.node ELSE "DONE",
     routeOwner |-> sys.routeOwner,
     routeEpoch |-> sys.routeEpoch]

=====================================================================
