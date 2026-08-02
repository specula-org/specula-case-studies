----------------------------- MODULE MC -----------------------------
\* Counter-bounded model-checking wrapper for dash-ha/base.tla.
\* Normal/reactive implementation actions are never bounded away; only
\* external inputs, timers, crash/loss injection, and abstract event choices
\* consume counters.

EXTENDS base

\* Original operators remain reachable when cfg operator replacement maps a
\* base fault/input action to its MC wrapper.
B == INSTANCE base

CONSTANTS
    ConfigSetLimit,
    ConfigDeleteLimit,
    PeerSendLimit,
    AckLossLimit,
    MaintenanceLimit,
    RePairLimit,
    CrashLimit,
    CleanupLimit,
    PendingEdgeLimit,
    TransitionLimit,
    RouteComputeLimit,
    RetryEventLimit,
    MaxMsgBufferLimit,
    MaxRoleWriteLimit

ASSUME
    /\ ConfigSetLimit \in Nat
    /\ ConfigDeleteLimit \in Nat
    /\ PeerSendLimit \in Nat
    /\ AckLossLimit \in Nat
    /\ MaintenanceLimit \in Nat
    /\ RePairLimit \in Nat
    /\ CrashLimit \in Nat
    /\ CleanupLimit \in Nat
    /\ PendingEdgeLimit \in Nat
    /\ TransitionLimit \in Nat
    /\ RouteComputeLimit \in Nat
    /\ RetryEventLimit \in Nat
    /\ MaxMsgBufferLimit \in Nat
    /\ MaxRoleWriteLimit \in Nat

VARIABLE constraintCounters

faultVars == <<constraintCounters>>
mcVars == <<vars, faultVars>>

\* A reactive action carries the counter record unchanged.
Reactive(action) ==
    /\ action
    /\ UNCHANGED constraintCounters

\* -----------------------------------------------------------------
\* Counter-bounded external/fault actions
\* -----------------------------------------------------------------

MCConsumerBridgeConfigSet(node, epoch) ==
    /\ constraintCounters.configSet < ConfigSetLimit
    /\ B!ConsumerBridgeConfigSet(node, epoch)
    /\ constraintCounters' =
        [constraintCounters EXCEPT !.configSet = @ + 1]

MCConsumerBridgeConfigDelete(node) ==
    /\ constraintCounters.configDelete < ConfigDeleteLimit
    /\ B!ConsumerBridgeConfigDelete(node)
    /\ constraintCounters' =
        [constraintCounters EXCEPT !.configDelete = @ + 1]

MCOutgoingSendHaScopeState(destination, sourcePeer, id, generation,
                           peerState, ackedRole, owner) ==
    /\ constraintCounters.peerSend < PeerSendLimit
    /\ B!OutgoingSendHaScopeState(destination, sourcePeer, id, generation,
                                  peerState, ackedRole, owner)
    /\ constraintCounters' =
        [constraintCounters EXCEPT !.peerSend = @ + 1]

MCNetworkLoseAck(id) ==
    /\ constraintCounters.ackLoss < AckLossLimit
    /\ B!NetworkLoseAck(id)
    /\ constraintCounters' =
        [constraintCounters EXCEPT !.ackLoss = @ + 1]

MCOutgoingDriveMaintenanceLoop(id) ==
    /\ constraintCounters.maintenance < MaintenanceLimit
    /\ B!OutgoingDriveMaintenanceLoop(id)
    /\ constraintCounters' =
        [constraintCounters EXCEPT !.maintenance = @ + 1]

MCNpuHandleHaSetStateUpdateRePairResolved(node) ==
    /\ constraintCounters.rePair < RePairLimit
    /\ B!NpuHandleHaSetStateUpdateRePairResolved(node)
    /\ constraintCounters' =
        [constraintCounters EXCEPT !.rePair = @ + 1]

MCNpuHandleHaSetStateUpdateRePairUnresolved(node) ==
    /\ constraintCounters.rePair < RePairLimit
    /\ B!NpuHandleHaSetStateUpdateRePairUnresolved(node)
    /\ constraintCounters' =
        [constraintCounters EXCEPT !.rePair = @ + 1]

MCCrash(node) ==
    /\ constraintCounters.crash < CrashLimit
    /\ B!Crash(node)
    /\ constraintCounters' =
        [constraintCounters EXCEPT !.crash = @ + 1]

MCActorDriverCleanupTimeout(node) ==
    /\ constraintCounters.cleanup < CleanupLimit
    /\ B!ActorDriverCleanupTimeout(node)
    /\ constraintCounters' =
        [constraintCounters EXCEPT !.cleanup = @ + 1]

MCDpuHandlePendingOperation(node, epoch, id) ==
    /\ constraintCounters.pendingEdge < PendingEdgeLimit
    /\ B!DpuHandlePendingOperation(node, epoch, id)
    /\ constraintCounters' =
        [constraintCounters EXCEPT !.pendingEdge = @ + 1]

MCNpuDriveStateMachine(node, nextState) ==
    /\ constraintCounters.transition < TransitionLimit
    /\ B!NpuDriveStateMachine(node, nextState)
    /\ constraintCounters' =
        [constraintCounters EXCEPT !.transition = @ + 1]

MCHaSetComputeRouteFromScope(node) ==
    /\ constraintCounters.routeCompute < RouteComputeLimit
    /\ B!HaSetComputeRouteFromScope(node)
    /\ constraintCounters' =
        [constraintCounters EXCEPT !.routeCompute = @ + 1]

MCHaSetComputeRouteFromConfig ==
    /\ constraintCounters.routeCompute < RouteComputeLimit
    /\ B!HaSetComputeRouteFromConfig
    /\ constraintCounters' =
        [constraintCounters EXCEPT !.routeCompute = @ + 1]

MCHaSetComputeRouteFromReplay(node) ==
    /\ constraintCounters.routeCompute < RouteComputeLimit
    /\ B!HaSetComputeRouteFromReplay(node)
    /\ constraintCounters' =
        [constraintCounters EXCEPT !.routeCompute = @ + 1]

MCNpuHandleVoteRequestRetry(node) ==
    /\ constraintCounters.retryEvent < RetryEventLimit
    /\ B!NpuHandleVoteRequestRetry(node)
    /\ constraintCounters' =
        [constraintCounters EXCEPT !.retryEvent = @ + 1]

MCNpuHandleVoteRequestFinal(node) ==
    /\ constraintCounters.retryEvent < RetryEventLimit
    /\ B!NpuHandleVoteRequestFinal(node)
    /\ constraintCounters' =
        [constraintCounters EXCEPT !.retryEvent = @ + 1]

MCNpuHandleSwitchoverRst(node) ==
    /\ constraintCounters.retryEvent < RetryEventLimit
    /\ B!NpuHandleSwitchoverRst(node)
    /\ constraintCounters' =
        [constraintCounters EXCEPT !.retryEvent = @ + 1]

MCNpuHandleSwitchoverFin(node) ==
    /\ constraintCounters.retryEvent < RetryEventLimit
    /\ B!NpuHandleSwitchoverFin(node)
    /\ constraintCounters' =
        [constraintCounters EXCEPT !.retryEvent = @ + 1]

MCNpuCheckPeerConnectionAndRetry(node) ==
    /\ constraintCounters.retryEvent < RetryEventLimit
    /\ B!NpuCheckPeerConnectionAndRetry(node)
    /\ constraintCounters' =
        [constraintCounters EXCEPT !.retryEvent = @ + 1]

\* -----------------------------------------------------------------
\* Initialization and transition relation
\* -----------------------------------------------------------------

MCInit ==
    /\ Init
    /\ constraintCounters = [
        configSet    |-> 0,
        configDelete |-> 0,
        peerSend     |-> 0,
        ackLoss      |-> 0,
        maintenance  |-> 0,
        rePair       |-> 0,
        crash        |-> 0,
        cleanup      |-> 0,
        pendingEdge  |-> 0,
        transition   |-> 0,
        routeCompute |-> 0,
        retryEvent   |-> 0]

MCNext ==
    \* Scenario 1/5 external config and reactive effect pipeline.
    \/ \E node \in Node, epoch \in Epoch : MCConsumerBridgeConfigSet(node, epoch)
    \/ \E node \in Node : Reactive(B!ActorCreatorHandleReceivedMessage(node))
    \/ \E node \in Node : Reactive(B!ActorDriverHandleSwbusMessage(node))
    \/ \E node \in Node : Reactive(B!ActorDriverHandleSetWhileDeleting(node))
    \/ \E node \in Node : Reactive(B!ActorDriverHandleActorMessage(node))
    \/ \E node \in Node : Reactive(B!HaSetActorUpdateDashHaSetTable(node))
    \/ \E node \in Node : Reactive(B!ActorDriverCommitChanges(node))
    \/ \E node \in Node : Reactive(B!ActorDriverSendQueuedHaSetWrite(node))
    \/ \E node \in Node : Reactive(B!ActorDriverSendQueuedHaSetState(node))
    \/ \E node \in Node : Reactive(B!ProducerBridgeApplyHaSet(node))
    \/ \E node \in Node : Reactive(B!HaScopeHandleHaSetState(node))
    \/ \E node \in Node : Reactive(B!ActorRegistrationHandle(node))
    \/ \E node \in Node : Reactive(B!NpuUpdateDpuHaScopeTable(node))
    \/ \E node \in Node : Reactive(B!ActorDriverSendQueuedScopeWrite(node))
    \/ \E node \in Node : Reactive(B!ProducerBridgeApplyScope(node))
    \/ \E write \in sys.pendingRoleWrites : Reactive(B!DpuAsicAcknowledgeRole(write))
    \/ \E node \in Node : MCConsumerBridgeConfigDelete(node)
    \/ \E node \in Node : Reactive(B!HaSetActorDoCleanup(node))
    \/ \E node \in Node : Reactive(B!ActorDriverSendQueuedHaSetDelete(node))
    \/ \E node \in Node : Reactive(B!ProducerBridgeApplyHaSetDelete(node))
    \/ \E node \in Node : Reactive(B!ActorDriverFinishDelete(node))
    \/ \E node \in Node : MCActorDriverCleanupTimeout(node)
    \* Scenario 2/3 bounded network inputs/faults and reactive handlers.
    \/ \E destination \in Node,
          sourcePeer \in Peer,
          id \in RequestId,
          generation \in Generation,
          peerState \in PeerWireStates,
          ackedRole \in PeerWireRoles,
          owner \in Node \cup {NoOwner} :
            MCOutgoingSendHaScopeState(destination, sourcePeer, id, generation,
                                       peerState, ackedRole, owner)
    \/ \E node \in Node, id \in RequestId : Reactive(B!IncomingHandleRequest(node, id))
    \/ \E node \in Node : Reactive(B!NpuHandleHaStateChange(node))
    \/ \E id \in RequestId : Reactive(B!OutgoingHandleResponse(id))
    \/ \E id \in RequestId : Reactive(B!OutgoingHandleLateResponse(id))
    \/ \E id \in RequestId : MCNetworkLoseAck(id)
    \/ \E id \in RequestId : MCOutgoingDriveMaintenanceLoop(id)
    \/ \E id \in RequestId : Reactive(B!OutgoingDropExpired(id))
    \/ \E node \in Node : MCNpuHandleHaSetStateUpdateRePairResolved(node)
    \/ \E node \in Node : MCNpuHandleHaSetStateUpdateRePairUnresolved(node)
    \/ \E node \in Node : Reactive(B!NpuDriveStateMachinePeerAck(node))
    \* Scenario 4 bounded event/crash cuts and reactive completion.
    \/ \E node \in Node, nextState \in CPStates : MCNpuDriveStateMachine(node, nextState)
    \/ \E node \in Node, action \in ProtocolActions :
        Reactive(B!ActorDriverSendQueuedAction(node, action))
    \/ \E node \in Node : MCCrash(node)
    \/ \E node \in Node : Reactive(B!Recover(node))
    \/ \E node \in Node : Reactive(B!NpuApplyRehydrationSideEffects(node))
    \/ \E node \in Node, epoch \in Epoch, id \in OperationId :
        MCDpuHandlePendingOperation(node, epoch, id)
    \/ \E node \in Node, id \in OperationId :
        Reactive(B!NpuApprovePendingOperation(node, id))
    \* Scenario 6 handler inputs are bounded; producer apply is reactive.
    \/ \E node \in Node : MCHaSetComputeRouteFromScope(node)
    \/ MCHaSetComputeRouteFromConfig
    \/ \E node \in Node : MCHaSetComputeRouteFromReplay(node)
    \/ Reactive(B!ProducerBridgeApplyRoute)
    \* Scenario 7 external/timer events and reactive terminal branches.
    \/ \E node \in Node : MCNpuHandleVoteRequestRetry(node)
    \/ \E node \in Node : MCNpuHandleVoteRequestFinal(node)
    \/ \E node \in Node : MCNpuHandleSwitchoverRst(node)
    \/ \E node \in Node : MCNpuHandleSwitchoverFin(node)
    \/ \E node \in Node : MCNpuCheckPeerConnectionAndRetry(node)
    \/ \E node \in Node : Reactive(B!NpuCheckPeerConnectionLost(node))
    \/ \E node \in Node : Reactive(B!NpuPeerConnectedReset(node))

MCSpec == MCInit /\ [][MCNext]_mcVars

\* PreferredNode is fixed, so only permutations preserving it are valid.
Symmetry == {perm \in Permutations(Node) : perm[PreferredNode] = PreferredNode}

\* Counter record is excluded from state fingerprint projection.
ModelView == vars

MsgBufferConstraint ==
    Cardinality(messages) <= MaxMsgBufferLimit

RoleWriteConstraint ==
    Cardinality(sys.pendingRoleWrites) <= MaxRoleWriteLimit

\* Additional structural checks for the MC assembly.
CounterTypeOK ==
    /\ constraintCounters.configSet \in 0..ConfigSetLimit
    /\ constraintCounters.configDelete \in 0..ConfigDeleteLimit
    /\ constraintCounters.peerSend \in 0..PeerSendLimit
    /\ constraintCounters.ackLoss \in 0..AckLossLimit
    /\ constraintCounters.maintenance \in 0..MaintenanceLimit
    /\ constraintCounters.rePair \in 0..RePairLimit
    /\ constraintCounters.crash \in 0..CrashLimit
    /\ constraintCounters.cleanup \in 0..CleanupLimit
    /\ constraintCounters.pendingEdge \in 0..PendingEdgeLimit
    /\ constraintCounters.transition \in 0..TransitionLimit
    /\ constraintCounters.routeCompute \in 0..RouteComputeLimit
    /\ constraintCounters.retryEvent \in 0..RetryEventLimit

QueueMetadataConsistent ==
    \A node \in Node :
        /\ sys.queuedScopeWrite[node] = NoEpoch => sys.queuedScopeRole[node] = "None"
        /\ sys.producerScopePending[node] = NoEpoch => sys.producerScopeRole[node] = "None"

MessageBufferBoundInv == Cardinality(messages) <= MaxMsgBufferLimit
RoleWriteBoundInv == Cardinality(sys.pendingRoleWrites) <= MaxRoleWriteLimit

=====================================================================
