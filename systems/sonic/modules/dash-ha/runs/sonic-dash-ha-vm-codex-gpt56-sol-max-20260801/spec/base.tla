---------------------------- MODULE base ----------------------------
\* dash-ha base specification.
\*
\* Category A (distributed / message-passing).  The model deliberately
\* separates SWBus acceptance, actor application, Redis commit, producer
\* application, DPU/ASIC acknowledgement, and route application.  Each
\* extension below is tied to a numbered Scenario in modeling-brief.md.

EXTENDS Naturals, FiniteSets, Sequences, TLC

CONSTANTS
    Node,                    \* two modeled HA participants
    Peer,                    \* two abstract peer identities used by re-pair
    PreferredNode,           \* configured preferred vDPU
    MaxEpoch,
    MaxGeneration,
    MaxRequestId,
    MaxOperationId,
    MaxMessageAge,
    MaxRetry

ASSUME
    /\ Cardinality(Node) = 2
    /\ Cardinality(Peer) = 2
    /\ PreferredNode \in Node
    /\ MaxEpoch \in Nat \ {0}
    /\ MaxEpoch >= 2
    /\ MaxGeneration \in Nat \ {0}
    /\ MaxGeneration >= 2
    /\ MaxRequestId \in Nat \ {0}
    /\ MaxOperationId \in Nat \ {0}
    /\ MaxMessageAge \in Nat \ {0}
    /\ MaxRetry \in Nat \ {0}

Epoch       == 0..MaxEpoch
Generation  == 0..MaxGeneration
RequestId   == 1..MaxRequestId
OperationId == 1..MaxOperationId

NoEpoch == 0
NoOwner == "NoOwner"
NoPeer  == "NoPeer"

\* Homogeneous record sentinel: TLC cannot safely compare a string sentinel
\* with a message record while evaluating a union type.
NoMessage ==
    [id |-> 0,
     kind |-> "HaScopeState",
     sourcePeer |-> NoPeer,
     destination |-> NoOwner,
     epoch |-> 0,
     generation |-> 0,
     term |-> 0,
     peerState |-> "Dead",
     ackedRole |-> "None",
     owner |-> NoOwner,
     age |-> 0]

ActorPhases == {"Absent", "Live", "Deleting"}

CPStates == {
    "Dead",
    "Connecting",
    "Connected",
    "InitializingToActive",
    "InitializingToStandby",
    "PendingActiveActivation",
    "PendingStandbyActivation",
    "Active",
    "Standby",
    "Standalone",
    "SwitchingToActive",
    "SwitchingToStandby",
    "SwitchingToStandalone",
    "Destroying"
}

Roles == {
    "None",
    "Dead",
    "Active",
    "Standby",
    "Standalone",
    "SwitchingToActive"
}

PeerWireStates == {
    "Dead",
    "InitializingToStandby",
    "Active",
    "Standalone",
    "SwitchingToStandby"
}

PeerWireRoles == {"None", "Dead", "Active", "Standby", "Standalone"}

PeerEvents == {"None", "PeerConnected", "PeerStateChanged"}
RouteWriters == {"None", "Config", "ScopeState", "Replay"}
HaOwners == {"Switch", "Dpu"}
Protocols == {"Connect", "Vote", "Switchover"}

ProtocolActions == {
    "Heartbeat",
    "CheckPeerConnection",
    "VoteRequest",
    "ActivateRole",
    "PendingOperation",
    "BulkSyncCompleted",
    "SwitchoverRequest",
    "SwitchoverFin",
    "FailoverRequest",
    "ShutdownIntent"
}

MessageType ==
    [ id          : RequestId,
      kind        : {"HaScopeState"},
      sourcePeer  : Peer,
      destination : Node,
      epoch       : Epoch,
      generation  : Generation,
      term        : Generation,
      peerState   : PeerWireStates,
      ackedRole   : PeerWireRoles,
      owner       : Node \cup {NoOwner},
      age         : 0..MaxMessageAge ]

RoleWriteType ==
    [ node  : Node,
      epoch : Epoch,
      term  : Generation,
      role  : Roles ]

PendingOperationType ==
    [ id    : OperationId,
      epoch : Epoch ]

VARIABLES
    sys,          \* named implementation and Scenario state, grouped as a record
    messages,     \* unacknowledged at-least-once messages (Scenario 2)
    ackPending,   \* transport responses in flight, distinct from delivery
    inbox         \* receiver snapshot retained after the transport ACK is sent

vars == <<sys, messages, ackPending, inbox>>

\* -----------------------------------------------------------------
\* Helpers
\* -----------------------------------------------------------------

InitialPeer == CHOOSE peer \in Peer : TRUE

OtherPeer(peer) == CHOOSE other \in Peer : other /= peer

Max2(a, b) == IF a >= b THEN a ELSE b

TrafficRole(role) == role \in {"Active", "Standalone"}

RoleForState(state) ==
    CASE state = "Active"            -> "Active"
      [] state \in {"InitializingToStandby", "Standby", "SwitchingToStandby"}
                                        -> "Standby"
      [] state = "Standalone"        -> "Standalone"
      [] state = "SwitchingToActive" -> "SwitchingToActive"
      [] state \in {"Dead", "Destroying"} -> "Dead"
      [] OTHER                         -> "None"

\* Scenario 4: side effects required when a control-plane phase is entered.
\* npu.rs:1355-1480 (apply_pending_state_side_effects).
RequiredActions(state) ==
    CASE state = "Connecting" -> {"Heartbeat", "CheckPeerConnection"}
      [] state = "Connected" -> {"VoteRequest"}
      [] state = "InitializingToStandby" -> {"ActivateRole"}
      [] state \in {"PendingActiveActivation", "PendingStandbyActivation"}
            -> {"PendingOperation"}
      [] state = "Active" -> {"ActivateRole", "BulkSyncCompleted"}
      [] state = "Standby" -> {"ActivateRole", "SwitchoverFin"}
      [] state = "Standalone" -> {"ActivateRole"}
      [] state = "SwitchingToActive" -> {"ActivateRole", "SwitchoverRequest"}
      [] state = "SwitchingToStandby" -> {"ActivateRole"}
      [] state = "SwitchingToStandalone" -> {"FailoverRequest"}
      [] state = "Destroying" -> {"ActivateRole", "ShutdownIntent"}
      [] OTHER -> {}

\* Scenario 4: exactly the phase-derived actions reconstructed today.
\* npu.rs:1274-1349 (apply_rehydration_side_effects).  In particular,
\* BulkSyncCompleted, SwitchoverFin, ordinary failover, and shutdown intent
\* are not reconstructed by those branches.
RecoverableActions(state) ==
    CASE state = "Connecting" -> {"Heartbeat", "CheckPeerConnection"}
      [] state = "Connected" -> {"Heartbeat", "VoteRequest"}
      [] state \in {"InitializingToActive", "InitializingToStandby"}
            -> {"Heartbeat", "ActivateRole"}
      [] state \in {"PendingActiveActivation", "PendingStandbyActivation"}
            -> {"Heartbeat"}
      [] state \in {"Active", "Standby", "Standalone"}
            -> {"Heartbeat", "ActivateRole"}
      [] state = "SwitchingToActive"
            -> {"Heartbeat", "ActivateRole", "SwitchoverRequest"}
      [] state = "SwitchingToStandby" -> {"Heartbeat", "ActivateRole"}
      [] state = "Destroying" -> {"ActivateRole"}
      [] OTHER -> {}

\* npu.rs:1646-1848 (next_state).  Only transitions used by the seven
\* Scenarios are retained; every listed edge exists in that match.
AllowedTransition(from, to) ==
    \/ /\ from = "Dead"
       /\ to = "Connecting"
    \/ /\ from = "Connecting"
       /\ to \in {"Connected", "SwitchingToStandalone"}
    \/ /\ from = "Connected"
       /\ to \in {"InitializingToActive", "InitializingToStandby", "SwitchingToStandalone"}
    \/ /\ from = "InitializingToActive"
       /\ to \in {"PendingActiveActivation", "Standby", "SwitchingToStandalone"}
    \/ /\ from = "PendingActiveActivation"
       /\ to = "Active"
    \/ /\ from = "InitializingToStandby"
       /\ to \in {"PendingStandbyActivation", "Standby"}
    \/ /\ from = "PendingStandbyActivation"
       /\ to = "Standby"
    \/ /\ from = "Active"
       /\ to \in {"SwitchingToStandby", "SwitchingToStandalone"}
    \/ /\ from = "Standby"
       /\ to \in {"SwitchingToActive", "SwitchingToStandalone", "Destroying"}
    \/ /\ from = "Standalone"
       /\ to = "Active"
    \/ /\ from = "SwitchingToActive"
       /\ to \in {"Active", "Standby", "SwitchingToStandalone"}
    \/ /\ from = "SwitchingToStandby"
       /\ to \in {"Standby", "SwitchingToStandalone"}
    \/ /\ from = "SwitchingToStandalone"
       /\ to \in {"Standalone", "Active", "Standby"}
    \/ /\ from = "Destroying"
       /\ to = "Dead"

MessageIds == {m.id : m \in messages}

MessageById(id) == CHOOSE m \in messages : m.id = id

PendingOpsForEpoch(node, epoch) ==
    {op \in sys.pendingOps[node] : op.epoch = epoch}

NodeEligible(node) ==
    /\ sys.processUp[node]
    /\ sys.actorPhase[node] = "Live"
    /\ TrafficRole(sys.asicRole[node])
    /\ sys.ackedRole[node] = sys.asicRole[node]
    /\ sys.ackedTerm[node] = sys.term[node]
    /\ sys.ackedPairEpoch[node] = sys.pairEpoch[node]

PairCompatible ==
    Cardinality({node \in Node : TrafficRole(sys.asicRole[node])}) = 1

\* -----------------------------------------------------------------
\* Initialization
\* -----------------------------------------------------------------

Init ==
    \* The model starts after epoch 1 has converged; Scenario actions create
    \* epoch 2 and expose each asynchronous cut.  ha_set.rs:180-225,
    \* npu.rs:1486-1555, and npu.rs:2172-2215.
    /\ sys = [
        processUp                 |-> [node \in Node |-> TRUE],
        accepted                  |-> [node \in Node |-> 1],
        actorApplied              |-> [node \in Node |-> 1],
        actorCommitted            |-> [node \in Node |-> 1],
        haSetIssued               |-> [node \in Node |-> 1],
        haSetApplied              |-> [node \in Node |-> 1],
        prereqReady               |-> [node \in Node |-> 1],
        scopeIssued               |-> [node \in Node |-> 1],
        scopeApplied              |-> [node \in Node |-> 1],
        queuedHaSetWrite          |-> [node \in Node |-> NoEpoch],
        queuedHaSetState          |-> [node \in Node |-> NoEpoch],
        haSetStateInFlight        |-> [node \in Node |-> NoEpoch],
        producerHaSetPending      |-> [node \in Node |-> NoEpoch],
        queuedScopeWrite          |-> [node \in Node |-> NoEpoch],
        queuedScopeRole           |-> [node \in Node |-> "None"],
        queuedScopeTerm           |-> [node \in Node |-> 1],
        queuedScopePairEpoch      |-> [node \in Node |-> 1],
        producerScopePending      |-> [node \in Node |-> NoEpoch],
        producerScopeRole         |-> [node \in Node |-> "None"],
        producerScopeTerm         |-> [node \in Node |-> 1],
        producerScopePairEpoch    |-> [node \in Node |-> 1],
        pendingRoleWrites         |-> {},

        cpState                    |-> [node \in Node |-> IF node = PreferredNode THEN "Active" ELSE "Standby"],
        asicRole                   |-> [node \in Node |-> IF node = PreferredNode THEN "Active" ELSE "Standby"],
        ackedRole                  |-> [node \in Node |-> IF node = PreferredNode THEN "Active" ELSE "Standby"],
        term                       |-> [node \in Node |-> 1],
        ackedTerm                  |-> [node \in Node |-> 1],
        ackedPairEpoch             |-> [node \in Node |-> 1],

        currentPeer                |-> [node \in Node |-> InitialPeer],
        pairEpoch                  |-> [node \in Node |-> 1],
        peerConnected              |-> [node \in Node |-> FALSE],
        lastPeerEvent              |-> [node \in Node |-> "None"],
        peerGeneration             |-> [node \in Node |-> 0],
        maxPeerGeneration          |-> [node \in Node |-> 0],
        peerTerm                   |-> [node \in Node |-> 0],
        peerCachedState            |-> [node \in Node |-> "Dead"],
        peerCachedAckRole          |-> [node \in Node |-> "None"],
        peerCachedOwner            |-> [node \in Node |-> NoOwner],
        peerCacheEpoch             |-> [node \in Node |-> NoEpoch],
        peerCacheSource            |-> [node \in Node |-> NoPeer],
        foreignApplied             |-> [node \in Node |-> FALSE],
        transitionAuthorized       |-> [node \in Node |-> FALSE],
        authorizationTerm          |-> [node \in Node |-> 0],
        authorizationEpoch         |-> [node \in Node |-> NoEpoch],

        persistedPhase             |-> [node \in Node |-> IF node = PreferredNode THEN "Active" ELSE "Standby"],
        durableIntent              |-> [node \in Node |-> RecoverableActions(IF node = PreferredNode THEN "Active" ELSE "Standby")],
        queuedActions              |-> [node \in Node |-> {}],
        completedActions           |-> [node \in Node |-> RequiredActions(IF node = PreferredNode THEN "Active" ELSE "Standby")],
        rehydrationNeeded          |-> [node \in Node |-> FALSE],
        pendingFlagEpoch           |-> [node \in Node |-> NoEpoch],
        cachedPendingFlagEpoch     |-> [node \in Node |-> NoEpoch],
        pendingOps                 |-> [node \in Node |-> {}],

        configPresent              |-> [node \in Node |-> TRUE],
        configEpoch                |-> [node \in Node |-> 1],
        bridgeCacheEpoch           |-> [node \in Node |-> 1],
        configDeliveryPending      |-> [node \in Node |-> NoEpoch],
        actorPhase                 |-> [node \in Node |-> "Live"],
        exactRouteEpoch            |-> [node \in Node |-> 1],
        registrations              |-> [node \in Node |-> 1],
        parentCacheEpoch           |-> [node \in Node |-> 1],
        ignoredSet                 |-> [node \in Node |-> FALSE],
        queuedHaSetDelete          |-> [node \in Node |-> FALSE],
        producerHaSetDeletePending |-> [node \in Node |-> FALSE],

        haOwner                     |-> "Switch",
        routeCandidate              |-> PreferredNode,
        routeCandidateEpoch         |-> 1,
        routeCandidateTerm          |-> 1,
        routePending                |-> FALSE,
        routeOwner                  |-> PreferredNode,
        routeEpoch                  |-> 1,
        routeTerm                   |-> 1,
        lastRouteWriter             |-> "ScopeState",

        sharedRetry                 |-> [node \in Node |-> 0],
        retryByProtocol             |-> [node \in Node |-> [protocol \in Protocols |-> 0]],
        retryIsolationBroken        |-> [node \in Node |-> FALSE],
        peerLost                    |-> [node \in Node |-> FALSE]
        ]
    /\ messages = {}
    /\ ackPending = {}
    /\ inbox = [node \in Node |-> NoMessage]

\* =================================================================
\* Scenario 1 and Scenario 5: actor/config lifecycle and effect pipeline
\* =================================================================

\* ConsumerBridge::send_kfv merges a DB update into its cache and sends only
\* changed rows.  consumer.rs:75-102,105-121.
ConsumerBridgeConfigSet(node, epoch) ==
    \* consumer.rs:75-80 -- a changed cached row is eligible for delivery.
    /\ node \in Node
    /\ epoch \in Epoch \ {NoEpoch}
    /\ epoch > sys.bridgeCacheEpoch[node]
    \* consumer.rs:89-102 -- route the SET to the exact actor/creator path.
    /\ sys' = [sys EXCEPT
        !.configPresent[node] = TRUE,
        !.configEpoch[node] = epoch,
        !.bridgeCacheEpoch[node] = epoch,
        !.configDeliveryPending[node] = epoch]
    /\ UNCHANGED <<messages, ackPending, inbox>>

\* ActorCreator::handle_received_message creates an absent actor for SET and
\* then run() forwards that same message.  actors.rs:194-232,233-274 and
\* actors.rs:137-143.
ActorCreatorHandleReceivedMessage(node) ==
    \* actors.rs:217-232 -- only a decodable SET creates an actor.
    /\ node \in Node
    /\ sys.processUp[node]
    /\ sys.actorPhase[node] = "Absent"
    /\ sys.configPresent[node]
    /\ sys.configDeliveryPending[node] = sys.configEpoch[node]
    \* runtime.rs:17-25 and actors.rs:260-274 -- install the exact route and
    \* spawn the new driver before forwarding the row.
    /\ sys' = [sys EXCEPT
        !.actorPhase[node] = "Live",
        !.exactRouteEpoch[node] = sys.configEpoch[node],
        !.accepted[node] = sys.configEpoch[node],
        !.configDeliveryPending[node] = NoEpoch,
        !.ignoredSet[node] = FALSE]
    /\ UNCHANGED <<messages, ackPending, inbox>>

\* Normal request case of ActorDriver::handle_swbus_message.  The transport
\* response is sent before the actor callback.  driver.rs:76-129.
ActorDriverHandleSwbusMessage(node) ==
    \* driver.rs:81-103 -- deserialize a request at a live actor.
    /\ node \in Node
    /\ sys.processUp[node]
    /\ sys.actorPhase[node] = "Live"
    /\ sys.configDeliveryPending[node] = sys.configEpoch[node]
    \* driver.rs:105-125 -- incoming-table acceptance and transport OK occur
    \* before handle_actor_message at lines 127-129.
    /\ sys' = [sys EXCEPT
        !.accepted[node] = sys.configEpoch[node],
        !.configDeliveryPending[node] = NoEpoch,
        !.ignoredSet[node] = FALSE]
    /\ UNCHANGED <<messages, ackPending, inbox>>

\* Divergent deletion branch: ACK the SET but intentionally skip incoming
\* state and actor logic.  driver.rs:82-97.  This is split from the normal
\* request action because the callback and all its checks are absent.
ActorDriverHandleSetWhileDeleting(node) ==
    \* driver.rs:82-84 -- exact route still reaches an actor being drained.
    /\ node \in Node
    /\ sys.processUp[node]
    /\ sys.actorPhase[node] = "Deleting"
    /\ sys.configDeliveryPending[node] = sys.configEpoch[node]
    \* driver.rs:85-97 -- return transport OK and discard the replacement SET.
    /\ sys' = [sys EXCEPT
        !.accepted[node] = sys.configEpoch[node],
        !.configDeliveryPending[node] = NoEpoch,
        !.ignoredSet[node] = TRUE]
    /\ UNCHANGED <<messages, ackPending, inbox>>

\* ActorDriver::handle_actor_message invokes business logic after the earlier
\* transport response.  driver.rs:127-129,146-164.
ActorDriverHandleActorMessage(node) ==
    \* driver.rs:127-148 -- callback is possible only for accepted normal work.
    /\ node \in Node
    /\ sys.processUp[node]
    /\ sys.actorPhase[node] = "Live"
    /\ ~sys.ignoredSet[node]
    /\ sys.accepted[node] > sys.actorApplied[node]
    \* driver.rs:148 -- actor state changes are visible to the serialized
    \* callback before Redis commit and outgoing send.
    /\ sys' = [sys EXCEPT !.actorApplied[node] = sys.accepted[node]]
    /\ UNCHANGED <<messages, ackPending, inbox>>

\* HaSetActor::update_dash_ha_set_table queues both the producer write and the
\* dependent HaSetActorState, then marks "programmed" immediately.
\* ha_set.rs:180-225 (Scenario 1).
HaSetActorUpdateDashHaSetTable(node) ==
    \* ha_set.rs:186-197 -- prerequisites were decoded and the table SET is
    \* placed in Outgoing::queued_messages.
    /\ node \in Node
    /\ sys.processUp[node]
    /\ sys.actorPhase[node] = "Live"
    /\ sys.actorApplied[node] > sys.haSetIssued[node]
    \* ha_set.rs:199-225 -- the implementation calls this issued/programmed
    \* and immediately queues the dependent state broadcast.
    /\ sys' = [sys EXCEPT
        !.haSetIssued[node] = sys.actorApplied[node],
        !.queuedHaSetWrite[node] = sys.actorApplied[node],
        !.queuedHaSetState[node] = sys.actorApplied[node]]
    /\ UNCHANGED <<messages, ackPending, inbox>>

\* Successful ActorDriver callback commits internal Redis-backed changes
\* before any queued side effect is sent.  driver.rs:146-153.
ActorDriverCommitChanges(node) ==
    \* driver.rs:148-151 -- a successful callback has either new actor state
    \* or a new NPU phase ready to commit.
    /\ node \in Node
    /\ sys.processUp[node]
    /\ sys.actorPhase[node] = "Live"
    /\ \/ sys.actorApplied[node] > sys.actorCommitted[node]
       \/ sys.cpState[node] /= sys.persistedPhase[node]
    \* driver.rs:150-152 and npu.rs:1235-1258 -- persist callback state and
    \* the target phase; only phase-derived recoverable intent is durable.
    /\ sys' = [sys EXCEPT
        !.actorCommitted[node] = sys.actorApplied[node],
        !.persistedPhase[node] = sys.cpState[node],
        !.durableIntent[node] = RecoverableActions(sys.cpState[node])]
    /\ UNCHANGED <<messages, ackPending, inbox>>

\* First independently awaited send from Outgoing::send_queued_messages.
\* driver.rs:151-153; outgoing.rs:75-105.
ActorDriverSendQueuedHaSetWrite(node) ==
    \* outgoing.rs:75-89 -- drain and await this producer-bound message.
    /\ node \in Node
    /\ sys.processUp[node]
    /\ sys.queuedHaSetWrite[node] /= NoEpoch
    /\ sys.actorCommitted[node] >= sys.queuedHaSetWrite[node]
    \* outgoing.rs:91-105 -- retain it as unacknowledged after the send.
    /\ sys' = [sys EXCEPT
        !.producerHaSetPending[node] = sys.queuedHaSetWrite[node],
        !.queuedHaSetWrite[node] = NoEpoch]
    /\ UNCHANGED <<messages, ackPending, inbox>>

\* Second independently awaited send from the same queue: the logical
\* dependency ACK can race the producer write.  ha_set.rs:199-225 and
\* outgoing.rs:75-105.
ActorDriverSendQueuedHaSetState(node) ==
    \* outgoing.rs:75-89 -- send the HaSetActorState on its own await boundary.
    /\ node \in Node
    /\ sys.processUp[node]
    /\ sys.queuedHaSetState[node] /= NoEpoch
    /\ sys.actorCommitted[node] >= sys.queuedHaSetState[node]
    \* ha_set.rs:214-225 -- the scope-directed state is now in flight.
    /\ sys' = [sys EXCEPT
        !.haSetStateInFlight[node] = sys.queuedHaSetState[node],
        !.queuedHaSetState[node] = NoEpoch]
    /\ UNCHANGED <<messages, ackPending, inbox>>

\* ProducerBridge applies the HA-set table before returning its response.
\* producer.rs:28-70.
ProducerBridgeApplyHaSet(node) ==
    \* producer.rs:40-48 -- deserialize the queued KeyOpFieldValues and await
    \* table.apply_kfv.
    /\ node \in Node
    /\ sys.producerHaSetPending[node] /= NoEpoch
    \* producer.rs:48-70 -- application completes before the bridge ACK.
    /\ sys' = [sys EXCEPT
        !.haSetApplied[node] = sys.producerHaSetPending[node],
        !.producerHaSetPending[node] = NoEpoch]
    /\ UNCHANGED <<messages, ackPending, inbox>>

\* HA-scope receipt of HaSetActorState.  base.rs:111-123 and
\* npu.rs:1493-1511.  This logical prerequisite can arrive before the
\* producer action above has applied the parent row.
HaScopeHandleHaSetState(node) ==
    \* base.rs:111-123 -- deserialize the cached HaSetActorState.
    /\ node \in Node
    /\ sys.processUp[node]
    /\ sys.actorPhase[node] = "Live"
    /\ sys.haSetStateInFlight[node] /= NoEpoch
    \* npu.rs:1502-1511 -- presence of the message opens the scope state
    \* machine gate; no producer/ASIC acknowledgement is checked.
    /\ sys' = [sys EXCEPT
        !.prereqReady[node] = sys.haSetStateInFlight[node],
        !.parentCacheEpoch[node] = sys.haSetStateInFlight[node],
        !.haSetStateInFlight[node] = NoEpoch]
    /\ UNCHANGED <<messages, ackPending, inbox>>

\* Volatile registration stored in the parent's Incoming table.
\* ha_actor_messages.rs:267-279 and base.rs:55-69.
ActorRegistrationHandle(node) ==
    \* base.rs:65-68 -- child sends active registration after creation.
    /\ node \in Node
    /\ sys.processUp[node]
    /\ sys.actorPhase[node] = "Live"
    /\ sys.configPresent[node]
    /\ sys.registrations[node] /= sys.configEpoch[node]
    \* ha_actor_messages.rs:267-279 -- active entry becomes the parent's
    \* current subscription for this actor.
    /\ sys' = [sys EXCEPT !.registrations[node] = sys.configEpoch[node]]
    /\ UNCHANGED <<messages, ackPending, inbox>>

\* NpuHaScopeActor::update_dpu_ha_scope_table_with_params.  Each call queues
\* a scope table role write, but does not apply it or receive an ASIC ACK.
\* npu.rs:2172-2215.
NpuUpdateDpuHaScopeTable(node) ==
    \* npu.rs:2173-2185 -- config and any cached HaSetActorState are the only
    \* parent prerequisites checked (Scenario 1/5).
    /\ node \in Node
    /\ sys.processUp[node]
    /\ sys.actorPhase[node] = "Live"
    /\ sys.parentCacheEpoch[node] /= NoEpoch
    /\ \/ sys.scopeIssued[node] /= sys.parentCacheEpoch[node]
       \/ "ActivateRole" \in sys.queuedActions[node]
    \* npu.rs:2188-2213 -- serialize current role/term and queue a producer
    \* SET; consume the phase's ActivateRole side effect if present.
    /\ sys' = [sys EXCEPT
        !.scopeIssued[node] = sys.parentCacheEpoch[node],
        !.queuedScopeWrite[node] = sys.parentCacheEpoch[node],
        !.queuedScopeRole[node] = RoleForState(sys.cpState[node]),
        !.queuedScopeTerm[node] = sys.term[node],
        !.queuedScopePairEpoch[node] = sys.pairEpoch[node],
        !.queuedActions[node] = @ \ {"ActivateRole"}]
    /\ UNCHANGED <<messages, ackPending, inbox>>

\* ActorDriver's await that sends the queued scope-table SET.
\* driver.rs:151-153; outgoing.rs:75-105.
ActorDriverSendQueuedScopeWrite(node) ==
    \* outgoing.rs:75-89 -- the scope SET crosses SWBus independently.
    /\ node \in Node
    /\ sys.processUp[node]
    /\ sys.queuedScopeWrite[node] /= NoEpoch
    \* outgoing.rs:91-105 -- retain the producer request and its role metadata.
    /\ sys' = [sys EXCEPT
        !.producerScopePending[node] = sys.queuedScopeWrite[node],
        !.producerScopeRole[node] = sys.queuedScopeRole[node],
        !.producerScopeTerm[node] = sys.queuedScopeTerm[node],
        !.producerScopePairEpoch[node] = sys.queuedScopePairEpoch[node],
        !.queuedScopeWrite[node] = NoEpoch,
        !.queuedScopeRole[node] = "None"]
    /\ UNCHANGED <<messages, ackPending, inbox>>

\* ProducerBridge applies DASH_HA_SCOPE_TABLE, still before the later DPU
\* state/ASIC acknowledgement.  producer.rs:40-70.
ProducerBridgeApplyScope(node) ==
    \* producer.rs:45-49 -- await the scope-table apply.
    /\ node \in Node
    /\ sys.producerScopePending[node] /= NoEpoch
    \* producer.rs:59-70 and npu.rs:590-632 -- producer completion makes a
    \* role write outstanding; it is not an ASIC role acknowledgement.
    /\ sys' = [sys EXCEPT
        !.scopeApplied[node] = sys.producerScopePending[node],
        !.pendingRoleWrites = @ \cup {
            [node |-> node,
             epoch |-> sys.producerScopePairEpoch[node],
             term |-> sys.producerScopeTerm[node],
             role |-> sys.producerScopeRole[node]]},
        !.producerScopePending[node] = NoEpoch,
        !.producerScopeRole[node] = "None"]
    /\ UNCHANGED <<messages, ackPending, inbox>>

\* DPU callback that records the ASIC-acknowledged role and term.
\* npu.rs:588-632.
DpuAsicAcknowledgeRole(write) ==
    \* npu.rs:590-600 -- accept a valid DPU state update for this scope.
    /\ write \in sys.pendingRoleWrites
    \* npu.rs:608-617 -- overwrite local acked role/term with the arriving
    \* DPU update; pair epoch is a ghost provenance field for Scenario 3.
    /\ sys' = [sys EXCEPT
        !.asicRole[write.node] = write.role,
        !.ackedRole[write.node] = write.role,
        !.ackedTerm[write.node] = write.term,
        !.ackedPairEpoch[write.node] = write.epoch,
        !.pendingRoleWrites = @ \ {write},
        !.completedActions[write.node] = @ \cup {"ActivateRole"}]
    /\ UNCHANGED <<messages, ackPending, inbox>>

\* ConsumerBridge delivers a DEL for the current HA-set row.
\* consumer.rs:75-102 and ha_set.rs:780-788.
ConsumerBridgeConfigDelete(node) ==
    \* consumer.rs:75-80 -- the cached row changes to absent.
    /\ node \in Node
    /\ sys.configPresent[node]
    /\ sys.configDeliveryPending[node] = NoEpoch
    \* consumer.rs:89-102 -- send the DEL toward the still-live exact route.
    /\ sys' = [sys EXCEPT
        !.configPresent[node] = FALSE,
        !.configDeliveryPending[node] = sys.configEpoch[node]]
    /\ UNCHANGED <<messages, ackPending, inbox>>

\* HaSetActor cleanup marks the actor for deletion and queues parent removal,
\* but sends no child invalidation.  ha_set.rs:1005-1026 and
\* driver.rs:57-73.
HaSetActorDoCleanup(node) ==
    \* ha_set.rs:1005-1015 -- a delivered DEL begins best-effort cleanup.
    /\ node \in Node
    /\ sys.processUp[node]
    /\ sys.actorPhase[node] = "Live"
    /\ ~sys.configPresent[node]
    /\ sys.configDeliveryPending[node] = sys.configEpoch[node]
    \* ha_set.rs:1017-1026 -- queue resource removal/unregistration; there is
    \* no invalidation of the child's cached HaSetActorState.
    /\ sys' = [sys EXCEPT
        !.actorPhase[node] = "Deleting",
        !.configDeliveryPending[node] = NoEpoch,
        !.registrations[node] = NoEpoch,
        !.queuedHaSetDelete[node] = TRUE]
    /\ UNCHANGED <<messages, ackPending, inbox>>

\* Send of the queued HA-set DEL.  driver.rs:151-153 and
\* outgoing.rs:75-105.
ActorDriverSendQueuedHaSetDelete(node) ==
    \* outgoing.rs:75-89 -- removal crosses its own awaited send boundary.
    /\ node \in Node
    /\ sys.processUp[node]
    /\ sys.queuedHaSetDelete[node]
    \* outgoing.rs:103-105 -- producer request is now unacknowledged.
    /\ sys' = [sys EXCEPT
        !.queuedHaSetDelete[node] = FALSE,
        !.producerHaSetDeletePending[node] = TRUE]
    /\ UNCHANGED <<messages, ackPending, inbox>>

\* ProducerBridge applies the HA-set DEL.  producer.rs:45-49,59-70.
ProducerBridgeApplyHaSetDelete(node) ==
    \* producer.rs:45-49 -- table.apply_kfv executes the DEL.
    /\ node \in Node
    /\ sys.producerHaSetDeletePending[node]
    \* producer.rs:59-70 -- apply precedes the response.
    /\ sys' = [sys EXCEPT
        !.haSetApplied[node] = NoEpoch,
        !.producerHaSetDeletePending[node] = FALSE]
    /\ UNCHANGED <<messages, ackPending, inbox>>

\* Normal deletion completion waits until queued/unacknowledged work drains.
\* driver.rs:57-73 and driver.rs:32-35.
ActorDriverFinishDelete(node) ==
    \* driver.rs:60-72 -- the actor is marked and its modeled outgoing work is
    \* now empty.
    /\ node \in Node
    /\ sys.actorPhase[node] = "Deleting"
    /\ ~sys.queuedHaSetDelete[node]
    /\ ~sys.producerHaSetDeletePending[node]
    \* driver.rs:61-66 -- terminate and drop the exact route.
    /\ sys' = [sys EXCEPT
        !.actorPhase[node] = "Absent",
        !.exactRouteEpoch[node] = NoEpoch]
    /\ UNCHANGED <<messages, ackPending, inbox>>

\* Failsafe deletion after outgoing entries age out.  outgoing.rs:143-180
\* and driver.rs:57-73 (Scenario 5 fault action).
ActorDriverCleanupTimeout(node) ==
    \* outgoing.rs:167-180 -- stale unacknowledged work is dropped after the
    \* bounded retention window.
    /\ node \in Node
    /\ sys.actorPhase[node] = "Deleting"
    \* outgoing.rs:167-180 -- only empty the retained producer work here.
    \* ActorDriverFinishDelete remains the later main-loop termination step.
    /\ sys' = [sys EXCEPT
        !.queuedHaSetDelete[node] = FALSE,
        !.producerHaSetDeletePending[node] = FALSE]
    /\ UNCHANGED <<messages, ackPending, inbox>>

\* =================================================================
\* Scenario 2 and Scenario 3: at-least-once replay and re-pair epochs
\* =================================================================

\* HaScopeActorState is queued to a peer and retained under its request ID.
\* npu.rs:1852-1890 and outgoing.rs:37-46,75-105.  The epoch field is
\* provenance carried only by the model: the implementation wire message has
\* no pair epoch, which is precisely Scenario 3's mechanism.
OutgoingSendHaScopeState(destination, sourcePeer, id, generation, peerState, ackedRole, owner) ==
    \* npu.rs:1856-1883 -- snapshot state, term, owner, and ASIC-acked role.
    /\ destination \in Node
    /\ sourcePeer \in Peer
    /\ sourcePeer = sys.currentPeer[destination]
    /\ id \in RequestId
    /\ id \notin MessageIds
    /\ generation \in Generation \ {0}
    /\ peerState \in PeerWireStates
    /\ ackedRole \in PeerWireRoles
    /\ owner \in Node \cup {NoOwner}
    \* npu.rs:1884-1889 and outgoing.rs:37-46 -- queue a distinct request ID;
    \* outgoing retention makes delivery at-least-once.
    /\ messages' = messages \cup {
        [id |-> id,
         kind |-> "HaScopeState",
         sourcePeer |-> sourcePeer,
         destination |-> destination,
         epoch |-> sys.pairEpoch[destination],
         generation |-> generation,
         term |-> generation,
         peerState |-> peerState,
         ackedRole |-> ackedRole,
         owner |-> owner,
         age |-> 0]}
    /\ UNCHANGED <<sys, ackPending, inbox>>

\* Incoming::handle_request blindly replaces the same logical key and the
\* driver sends its transport response before actor business handling.
\* incoming.rs:49-72,147-154 and driver.rs:105-129.
IncomingHandleRequest(node, id) ==
    \* incoming.rs:62-72 -- deserialize and replace by logical key without a
    \* generation/freshness comparison.
    /\ node \in Node
    /\ id \in MessageIds
    /\ inbox[node] = NoMessage
    /\ LET msg == MessageById(id)
       IN /\ msg.destination = node
          \* driver.rs:105-125 -- retain the receiver snapshot and put the
          \* response in flight before the callback at lines 127-129.
          /\ inbox' = [inbox EXCEPT ![node] = msg]
          /\ ackPending' = ackPending \cup {id}
    /\ UNCHANGED <<sys, messages>>

\* NPU peer-state callback.  It overwrites peer facts in arrival order and
\* neither validates source identity nor a pair epoch.
\* npu.rs:708-746; base.rs:125-136.
NpuHandleHaStateChange(node) ==
    \* base.rs:125-136 and npu.rs:708-721 -- decode by message key; source and
    \* destination metadata do not guard the handler.
    /\ node \in Node
    /\ inbox[node] /= NoMessage
    /\ LET msg == inbox[node]
       IN
       \* npu.rs:723-734 -- overwrite cached state, term, and ACK in arrival
       \* order.  maxPeerGeneration is a history ghost for TermNonRegression.
       /\ sys' = [sys EXCEPT
            !.peerGeneration[node] = msg.generation,
            !.maxPeerGeneration[node] = Max2(@, msg.generation),
            !.peerTerm[node] = msg.term,
            !.peerCachedState[node] = msg.peerState,
            !.peerCachedAckRole[node] = msg.ackedRole,
            !.peerCachedOwner[node] = msg.owner,
            !.peerCacheEpoch[node] = msg.epoch,
            !.peerCacheSource[node] = msg.sourcePeer,
            !.foreignApplied[node] = @ \/
                (msg.sourcePeer /= sys.currentPeer[node]) \/
                (msg.epoch /= sys.pairEpoch[node]),
            \* npu.rs:740-745 -- the first valid-looking state is classified
            \* PeerConnected; later messages become PeerStateChanged.
            !.lastPeerEvent[node] = IF sys.peerConnected[node]
                                         THEN "PeerStateChanged"
                                         ELSE "PeerConnected",
            !.peerConnected[node] = TRUE]
       /\ inbox' = [inbox EXCEPT ![node] = NoMessage]
    /\ UNCHANGED <<messages, ackPending>>

\* Successful response removes the corresponding resend entry.
\* outgoing.rs:118-140.
OutgoingHandleResponse(id) ==
    \* outgoing.rs:126-135 -- response matches a still-unacknowledged ID.
    /\ id \in ackPending
    /\ id \in MessageIds
    \* outgoing.rs:137-140 -- OK removes the retained request.
    /\ messages' = {msg \in messages : msg.id /= id}
    /\ ackPending' = ackPending \ {id}
    /\ UNCHANGED <<sys, inbox>>

\* Divergent late-response path: the sender already dropped this ID, so the
\* implementation ignores it.  outgoing.rs:126-129.
OutgoingHandleLateResponse(id) ==
    \* outgoing.rs:126-129 -- no unacked entry exists.
    /\ id \in ackPending
    /\ id \notin MessageIds
    \* Transport consumes the late response without changing sender state.
    /\ ackPending' = ackPending \ {id}
    /\ UNCHANGED <<sys, messages, inbox>>

\* Injected response loss between receiver acceptance and sender handling
\* (Scenario 2).  The retained outgoing request therefore remains retryable.
NetworkLoseAck(id) ==
    \* driver.rs:114-125 -- response was emitted after incoming acceptance.
    /\ id \in ackPending
    \* outgoing.rs:137-140 -- because it never reaches handle_response, the
    \* unacked request is not removed.
    /\ ackPending' = ackPending \ {id}
    /\ UNCHANGED <<sys, messages, inbox>>

\* Periodic resend preserves the same request ID and old value.
\* outgoing.rs:143-180.
OutgoingDriveMaintenanceLoop(id) ==
    \* outgoing.rs:159-173 -- the retained request reaches another resend tick.
    /\ id \in MessageIds
    /\ LET msg == MessageById(id)
       IN /\ msg.age < MaxMessageAge
          \* outgoing.rs:171-180 -- resend an identical stored message.
          /\ messages' = (messages \ {msg}) \cup {[msg EXCEPT !.age = @ + 1]}
    /\ UNCHANGED <<sys, ackPending, inbox>>

\* Bounded failsafe drops a request that remained unacknowledged.
\* outgoing.rs:167-169.
OutgoingDropExpired(id) ==
    \* outgoing.rs:167-169 -- retention limit has elapsed.
    /\ id \in MessageIds
    /\ MessageById(id).age = MaxMessageAge
    \* outgoing.rs:167-169 -- delete from resend state even if a late ACK is
    \* independently in flight.
    /\ messages' = {msg \in messages : msg.id /= id}
    /\ UNCHANGED <<sys, ackPending, inbox>>

\* Re-pair branch where address resolution succeeds.  The code changes only
\* peer ID/service path and preserves peerConnected, protocol cache, and old
\* outgoing requests.  npu.rs:539-550 (Scenario 3).
NpuHandleHaSetStateUpdateRePairResolved(node) ==
    \* npu.rs:539-549 -- replace configured peer and resolve a new path.
    /\ node \in Node
    /\ sys.processUp[node]
    /\ sys.pairEpoch[node] < MaxEpoch
    \* No code field carries this ghost epoch; incrementing it exposes which
    \* preserved cache/messages came from the prior relationship.
    /\ sys' = [sys EXCEPT
        !.currentPeer[node] = OtherPeer(@),
        !.pairEpoch[node] = @ + 1]
    /\ UNCHANGED <<messages, ackPending, inbox>>

\* Divergent re-pair branch where resolution fails and peerConnected is
\* explicitly cleared.  npu.rs:546-556.
NpuHandleHaSetStateUpdateRePairUnresolved(node) ==
    \* npu.rs:546-552 -- new peer/path resolution fails.
    /\ node \in Node
    /\ sys.processUp[node]
    /\ sys.pairEpoch[node] < MaxEpoch
    \* npu.rs:553-556 -- clear connection status and schedule retry, while
    \* retaining peer protocol facts and outstanding old requests.
    /\ sys' = [sys EXCEPT
        !.currentPeer[node] = OtherPeer(@),
        !.pairEpoch[node] = @ + 1,
        !.peerConnected[node] = FALSE]
    /\ UNCHANGED <<messages, ackPending, inbox>>

\* Peer ACK/state-driven transition.  The implementation checks cached role
\* and CP state, but does not correlate them with pair epoch or the local term.
\* npu.rs:1374-1383,1685-1708,1776-1818.
NpuDriveStateMachinePeerAck(node) ==
    \* npu.rs:1374-1383 and 1776-1818 -- a standby ASIC ACK plus the matching
    \* peer CP phase enables one of these state-machine branches.
    /\ node \in Node
    /\ sys.processUp[node]
    /\ sys.peerCachedAckRole[node] = "Standby"
    /\ sys.cpState[node] \in {"InitializingToActive", "SwitchingToActive", "Standalone"}
    /\ IF sys.cpState[node] = "SwitchingToActive"
          THEN sys.peerCachedState[node] = "SwitchingToStandby"
          ELSE sys.peerCachedState[node] = "InitializingToStandby"
    \* npu.rs:1808-1817 -- Standalone accepts PeerStateChanged, not the first
    \* PeerConnected classification.
    /\ sys.cpState[node] = "Standalone" => sys.lastPeerEvent[node] = "PeerStateChanged"
    \* npu.rs:1689-1705,1779-1784,1811-1817 -- apply the branch using the
    \* uncorrelated cached ACK.  authorization fields are history ghosts.
    /\ LET nextState == IF sys.cpState[node] = "InitializingToActive"
                        THEN "PendingActiveActivation"
                        ELSE "Active"
       IN sys' = [sys EXCEPT
            !.cpState[node] = nextState,
            !.transitionAuthorized[node] = TRUE,
            !.authorizationTerm[node] = sys.peerTerm[node],
            !.authorizationEpoch[node] = sys.peerCacheEpoch[node],
            !.queuedActions[node] = @ \cup RequiredActions(nextState)]
    /\ UNCHANGED <<messages, ackPending, inbox>>

\* =================================================================
\* Scenario 4: persist/side-effect crash cuts and pending operations
\* =================================================================

\* General NPU state-machine transition at the serialized actor callback.
\* The phase change and queuing of all phase side effects happen before
\* ActorDriverCommitChanges and before any send.  npu.rs:1486-1555.
NpuDriveStateMachine(node, nextState) ==
    \* npu.rs:1488-1511 -- config, managed vDPU, and cached HA-set state gate
    \* state-machine execution.
    /\ node \in Node
    /\ nextState \in CPStates
    /\ sys.processUp[node]
    /\ sys.actorPhase[node] = "Live"
    /\ sys.parentCacheEpoch[node] /= NoEpoch
    \* npu.rs:1547-1551 and next_state at 1646-1848 -- select an actual edge.
    /\ AllowedTransition(sys.cpState[node], nextState)
    /\ nextState \in {"Active", "Standalone"} => sys.term[node] < MaxGeneration
    \* npu.rs:1551-1555 and 1355-1480 -- queue side effects, change the
    \* in-memory phase, and increment target term for Active/Standalone.
    /\ sys' = [sys EXCEPT
        !.cpState[node] = nextState,
        !.term[node] = IF nextState \in {"Active", "Standalone"}
                         THEN @ + 1
                         ELSE @,
        !.queuedActions[node] = @ \cup RequiredActions(nextState)]
    /\ UNCHANGED <<messages, ackPending, inbox>>

\* Send/perform one non-role side effect after the phase commit.  Role writes
\* use NpuUpdateDpuHaScopeTable so the producer/ASIC windows remain explicit.
\* driver.rs:151-153 and npu.rs:1364-1479.
ActorDriverSendQueuedAction(node, action) ==
    \* driver.rs:150-152 -- persisted phase precedes outgoing queue drain.
    /\ node \in Node
    /\ action \in ProtocolActions \ {"ActivateRole"}
    /\ sys.processUp[node]
    /\ sys.persistedPhase[node] = sys.cpState[node]
    /\ action \in sys.queuedActions[node]
    \* npu.rs:1364-1479 -- execute exactly one phase-specific side effect.
    /\ sys' = [sys EXCEPT
        !.queuedActions[node] = @ \ {action},
        !.completedActions[node] = @ \cup {action}]
    /\ UNCHANGED <<messages, ackPending, inbox>>

\* Process crash after any callback/commit/send cut.  Volatile queues,
\* registrations, routes, cached prerequisites, and pending-edge snapshots
\* disappear; Redis-backed phase and protocol facts survive.
\* driver.rs:146-153, outgoing.rs:19-31, and npu.rs:462-476.
Crash(node) ==
    \* driver.rs:38-74 -- actor task/process ceases executing callbacks.
    /\ node \in Node
    /\ sys.processUp[node]
    \* outgoing.rs:24-27 and ha_actor_messages.rs:267-279 -- clear volatile
    \* actor queues/registrations; recover CP phase from persisted Redis.
    /\ sys' = [sys EXCEPT
        !.processUp[node] = FALSE,
        !.queuedHaSetWrite[node] = NoEpoch,
        !.queuedHaSetState[node] = NoEpoch,
        !.queuedScopeWrite[node] = NoEpoch,
        !.queuedScopeRole[node] = "None",
        !.queuedActions[node] = {},
        !.cpState[node] = sys.persistedPhase[node],
        !.rehydrationNeeded[node] = FALSE,
        !.cachedPendingFlagEpoch[node] = NoEpoch,
        !.prereqReady[node] = NoEpoch,
        !.parentCacheEpoch[node] = NoEpoch,
        !.registrations[node] = NoEpoch,
        !.peerConnected[node] = FALSE,
        !.actorPhase[node] = "Absent",
        !.exactRouteEpoch[node] = NoEpoch,
        !.queuedHaSetDelete[node] = FALSE]
    /\ inbox' = [inbox EXCEPT ![node] = NoMessage]
    /\ UNCHANGED <<messages, ackPending>>

\* Actor/process recovery recreates exact routing but has not yet replayed
\* phase-specific side effects or registrations.  runtime.rs:17-25 and
\* npu.rs:462-478.
Recover(node) ==
    \* runtime.rs:17-25 -- recreate the actor route for a present config row.
    /\ node \in Node
    /\ ~sys.processUp[node]
    /\ sys.configPresent[node]
    \* npu.rs:462-478 -- flag Redis-backed non-dead phase for rehydration.
    /\ sys' = [sys EXCEPT
        !.processUp[node] = TRUE,
        !.actorPhase[node] = "Live",
        !.exactRouteEpoch[node] = sys.configEpoch[node],
        !.cpState[node] = sys.persistedPhase[node],
        !.rehydrationNeeded[node] =
            sys.persistedPhase[node] \notin {"Dead"}]
    /\ UNCHANGED <<messages, ackPending, inbox>>

\* Rehydration infers only the branches implemented in
\* apply_rehydration_side_effects.  npu.rs:1261-1352.
NpuApplyRehydrationSideEffects(node) ==
    \* npu.rs:1267-1274 -- run once for the persisted phase.
    /\ node \in Node
    /\ sys.processUp[node]
    /\ sys.rehydrationNeeded[node]
    \* npu.rs:1274-1349 -- requeue the modeled recoverable subset; omitted
    \* required actions remain absent after this transition.
    /\ sys' = [sys EXCEPT
        !.queuedActions[node] = @ \cup sys.durableIntent[node],
        !.rehydrationNeeded[node] = FALSE]
    /\ UNCHANGED <<messages, ackPending, inbox>>

\* DPU pending-edge handler.  A cleared volatile old snapshot after restart
\* causes the same live flag epoch to receive a fresh UUID.
\* dpu.rs:146-181 (Scenario 1/4).
DpuHandlePendingOperation(node, epoch, id) ==
    \* dpu.rs:152-163 -- compare the durable/live DPU flag against the cached
    \* old state; restart makes cached epoch zero.
    /\ node \in Node
    /\ epoch \in Epoch \ {NoEpoch}
    /\ id \in OperationId
    /\ sys.processUp[node]
    \* A new edge is possible only with no live flag.  After a crash, the
    \* volatile cached edge is absent while the same durable flag remains
    \* live, so that same epoch can be rediscovered and duplicated.
    /\ \/ sys.pendingFlagEpoch[node] = NoEpoch
       \/ /\ sys.cachedPendingFlagEpoch[node] = NoEpoch
          /\ epoch = sys.pendingFlagEpoch[node]
    /\ epoch /= sys.cachedPendingFlagEpoch[node]
    /\ id \notin {op.id : op \in sys.pendingOps[node]}
    \* dpu.rs:163-181 -- generate a new operation ID and append it to the
    \* persisted pending-operation list.
    /\ sys' = [sys EXCEPT
        !.pendingFlagEpoch[node] = epoch,
        !.cachedPendingFlagEpoch[node] = epoch,
        !.pendingOps[node] = @ \cup {[id |-> id, epoch |-> epoch]},
        !.completedActions[node] = @ \cup {"PendingOperation"}]
    /\ UNCHANGED <<messages, ackPending, inbox>>

\* Approval removes exactly the named operation.  base.rs:445-477.
NpuApprovePendingOperation(node, id) ==
    \* base.rs:464-470 -- locate and remove the approved UUID.
    /\ node \in Node
    /\ id \in {op.id : op \in sys.pendingOps[node]}
    \* base.rs:471-477 -- preserve all other pending operations.  The model
    \* clears the live flag only when its last operation is approved.
    /\ LET remaining == {op \in sys.pendingOps[node] : op.id /= id}
       IN sys' = [sys EXCEPT
            !.pendingOps[node] = remaining,
            !.pendingFlagEpoch[node] =
                IF remaining = {} THEN NoEpoch ELSE @,
            !.cachedPendingFlagEpoch[node] =
                IF remaining = {} THEN NoEpoch ELSE @]
    /\ UNCHANGED <<messages, ackPending, inbox>>

\* =================================================================
\* Scenario 6: independent VNET route writers
\* =================================================================

\* Failover/state-derived writer chooses the sole Active or Standalone cache
\* result but the cache has no ASIC ACK/term metadata.
\* ha_set.rs:512-526,576-650,961-994.
HaSetComputeRouteFromScope(node) ==
    \* ha_set.rs:603-647 -- one Active/Standalone scope becomes primary.
    /\ node \in Node
    /\ sys.cpState[node] \in {"Active", "Standalone"}
    \* ha_set.rs:512-526 -- candidate uses current aggregate facts without an
    \* ACK-correlated eligibility field.
    /\ sys' = [sys EXCEPT
        !.routeCandidate = node,
        !.routeCandidateEpoch = sys.pairEpoch[node],
        !.routeCandidateTerm = sys.term[node],
        !.routePending = TRUE,
        !.lastRouteWriter = "ScopeState"]
    /\ UNCHANGED <<messages, ackPending, inbox>>

\* Config refresh reconstructs preferred ordering and writes the same route
\* even in Switch-owned mode.  ha_set.rs:427-465,774-858.
HaSetComputeRouteFromConfig ==
    \* ha_set.rs:427-465 -- preferred vDPU is placed first independent of
    \* cached failover ownership.
    /\ sys.configPresent[PreferredNode]
    \* ha_set.rs:851-858 -- config refresh unconditionally queues route update;
    \* unlike global/vDPU paths, there is no haOwner == Dpu guard here.
    /\ sys' = [sys EXCEPT
        !.routeCandidate = PreferredNode,
        !.routeCandidateEpoch = sys.pairEpoch[PreferredNode],
        !.routeCandidateTerm = sys.term[PreferredNode],
        !.routePending = TRUE,
        !.lastRouteWriter = "Config"]
    /\ UNCHANGED <<messages, ackPending, inbox>>

\* Arrival-ordered cached peer state can independently select an older owner.
\* ha_set.rs:512-526,576-650 (Scenarios 2 and 6).
HaSetComputeRouteFromReplay(node) ==
    \* ha_set.rs:512-526 -- use the last arrival for the source logical key.
    /\ node \in Node
    /\ sys.peerCachedOwner[node] \in Node
    /\ sys.peerCachedState[node] \in {"Active", "Standalone"}
    \* ha_set.rs:603-647 -- derive primary from that cache without ACK/epoch
    \* correlation.
    /\ sys' = [sys EXCEPT
        !.routeCandidate = sys.peerCachedOwner[node],
        !.routeCandidateEpoch = sys.peerCacheEpoch[node],
        !.routeCandidateTerm = sys.peerTerm[node],
        !.routePending = TRUE,
        !.lastRouteWriter = "Replay"]
    /\ UNCHANGED <<messages, ackPending, inbox>>

\* Producer application is distinct from every computation path.
\* ha_set.rs:331-353 and producer.rs:45-70.
ProducerBridgeApplyRoute ==
    \* ha_set.rs:331-351 -- a computed VNET route SET was queued.
    /\ sys.routePending
    \* producer.rs:45-70 -- apply the last independently scheduled writer.
    /\ sys' = [sys EXCEPT
        !.routeOwner = sys.routeCandidate,
        !.routeEpoch = sys.routeCandidateEpoch,
        !.routeTerm = sys.routeCandidateTerm,
        !.routePending = FALSE]
    /\ UNCHANGED <<messages, ackPending, inbox>>

\* =================================================================
\* Scenario 7: one retry counter shared by three protocols
\* =================================================================

\* RetryLater vote branch increments the implementation counter and the
\* operation-local comparison model.  npu.rs:816-876.
NpuHandleVoteRequestRetry(node) ==
    \* npu.rs:842-875 -- an undecided vote consumes the shared retry budget.
    /\ node \in Node
    /\ sys.sharedRetry[node] < MaxRetry
    /\ sys.retryByProtocol[node]["Vote"] < MaxRetry
    \* npu.rs:851-853,870-873 -- increment both current implementation and
    \* the counterfactual vote-local budget.
    /\ sys' = [sys EXCEPT
        !.sharedRetry[node] = @ + 1,
        !.retryByProtocol[node]["Vote"] = @ + 1]
    /\ UNCHANGED <<messages, ackPending, inbox>>

\* A final vote decision resets the shared implementation counter.
\* npu.rs:878-881.
NpuHandleVoteRequestFinal(node) ==
    \* npu.rs:878-880 -- any non-RetryLater result resets retry_count.
    /\ node \in Node
    /\ sys.sharedRetry[node] > 0
    \* Resetting while another protocol has work changes its timeout horizon.
    /\ sys' = [sys EXCEPT
        !.retryIsolationBroken[node] = @ \/
            (sys.retryByProtocol[node]["Connect"] > 0) \/
            (sys.retryByProtocol[node]["Switchover"] > 0),
        !.sharedRetry[node] = 0,
        !.retryByProtocol[node]["Vote"] = 0]
    /\ UNCHANGED <<messages, ackPending, inbox>>

\* Switchover RST consumes the same implementation counter.
\* npu.rs:925-955.
NpuHandleSwitchoverRst(node) ==
    \* npu.rs:938-947 -- rejected switchover retries while the shared count is
    \* below its limit.
    /\ node \in Node
    /\ sys.sharedRetry[node] < MaxRetry
    /\ sys.retryByProtocol[node]["Switchover"] < MaxRetry
    \* npu.rs:944-947 -- consume both implementation and local comparison
    \* budget for this protocol step.
    /\ sys' = [sys EXCEPT
        !.sharedRetry[node] = @ + 1,
        !.retryByProtocol[node]["Switchover"] = @ + 1]
    /\ UNCHANGED <<messages, ackPending, inbox>>

\* Switchover FIN resets the shared count.  npu.rs:931-937.
NpuHandleSwitchoverFin(node) ==
    \* npu.rs:931-937 -- accepted FIN unconditionally resets retry_count.
    /\ node \in Node
    /\ sys.sharedRetry[node] > 0
    \* A reset with live connection/vote retries interferes with those budgets.
    /\ sys' = [sys EXCEPT
        !.retryIsolationBroken[node] = @ \/
            (sys.retryByProtocol[node]["Connect"] > 0) \/
            (sys.retryByProtocol[node]["Vote"] > 0),
        !.sharedRetry[node] = 0,
        !.retryByProtocol[node]["Switchover"] = 0]
    /\ UNCHANGED <<messages, ackPending, inbox>>

\* Connection timer retry.  npu.rs:1944-1968.
NpuCheckPeerConnectionAndRetry(node) ==
    \* npu.rs:1947-1952 -- disconnected check consults the same shared count.
    /\ node \in Node
    /\ ~sys.peerConnected[node]
    /\ sys.sharedRetry[node] < MaxRetry
    /\ sys.retryByProtocol[node]["Connect"] < MaxRetry
    \* npu.rs:1951-1968 -- increment, resolve/send heartbeat, and reschedule.
    /\ sys' = [sys EXCEPT
        !.sharedRetry[node] = @ + 1,
        !.retryByProtocol[node]["Connect"] = @ + 1]
    /\ UNCHANGED <<messages, ackPending, inbox>>

\* Connection timeout terminal branch.  npu.rs:1969-1974.
NpuCheckPeerConnectionLost(node) ==
    \* npu.rs:1969-1973 -- shared budget appears exhausted.
    /\ node \in Node
    /\ ~sys.peerConnected[node]
    /\ sys.sharedRetry[node] = MaxRetry
    \* If the operation-local connection count is smaller, other protocols
    \* caused premature PeerLost.  Reset mirrors lines 1970-1973.
    /\ sys' = [sys EXCEPT
        !.retryIsolationBroken[node] = @ \/
            (sys.retryByProtocol[node]["Connect"] < MaxRetry),
        !.peerLost[node] = TRUE,
        !.sharedRetry[node] = 0,
        !.retryByProtocol[node]["Connect"] = 0]
    /\ UNCHANGED <<messages, ackPending, inbox>>

\* Connected branch also resets the same shared counter.
\* npu.rs:1975-1978.
NpuPeerConnectedReset(node) ==
    \* npu.rs:1975-1977 -- peer is connected at the maintenance check.
    /\ node \in Node
    /\ sys.peerConnected[node]
    /\ sys.sharedRetry[node] > 0
    \* npu.rs:1976-1977 -- reset shared count; comparison Connect completes,
    \* while any vote/switchover work exposes interference.
    /\ sys' = [sys EXCEPT
        !.retryIsolationBroken[node] = @ \/
            (sys.retryByProtocol[node]["Vote"] > 0) \/
            (sys.retryByProtocol[node]["Switchover"] > 0),
        !.sharedRetry[node] = 0,
        !.retryByProtocol[node]["Connect"] = 0]
    /\ UNCHANGED <<messages, ackPending, inbox>>

\* =================================================================
\* Structural and Scenario invariants
\* =================================================================

TypeOK ==
    /\ sys.processUp \in [Node -> BOOLEAN]
    /\ sys.accepted \in [Node -> Epoch]
    /\ sys.actorApplied \in [Node -> Epoch]
    /\ sys.actorCommitted \in [Node -> Epoch]
    /\ sys.haSetIssued \in [Node -> Epoch]
    /\ sys.haSetApplied \in [Node -> Epoch]
    /\ sys.prereqReady \in [Node -> Epoch]
    /\ sys.scopeIssued \in [Node -> Epoch]
    /\ sys.scopeApplied \in [Node -> Epoch]
    /\ sys.queuedHaSetWrite \in [Node -> Epoch]
    /\ sys.queuedHaSetState \in [Node -> Epoch]
    /\ sys.haSetStateInFlight \in [Node -> Epoch]
    /\ sys.producerHaSetPending \in [Node -> Epoch]
    /\ sys.queuedScopeWrite \in [Node -> Epoch]
    /\ sys.queuedScopeRole \in [Node -> Roles]
    /\ sys.queuedScopeTerm \in [Node -> Generation]
    /\ sys.queuedScopePairEpoch \in [Node -> Epoch]
    /\ sys.producerScopePending \in [Node -> Epoch]
    /\ sys.producerScopeRole \in [Node -> Roles]
    /\ sys.producerScopeTerm \in [Node -> Generation]
    /\ sys.producerScopePairEpoch \in [Node -> Epoch]
    /\ sys.pendingRoleWrites \subseteq RoleWriteType
    /\ sys.cpState \in [Node -> CPStates]
    /\ sys.asicRole \in [Node -> Roles]
    /\ sys.ackedRole \in [Node -> Roles]
    /\ sys.term \in [Node -> Generation]
    /\ sys.ackedTerm \in [Node -> Generation]
    /\ sys.ackedPairEpoch \in [Node -> Epoch]
    /\ sys.currentPeer \in [Node -> Peer]
    /\ sys.pairEpoch \in [Node -> Epoch]
    /\ sys.peerConnected \in [Node -> BOOLEAN]
    /\ sys.lastPeerEvent \in [Node -> PeerEvents]
    /\ sys.peerGeneration \in [Node -> Generation]
    /\ sys.maxPeerGeneration \in [Node -> Generation]
    /\ sys.peerTerm \in [Node -> Generation]
    /\ sys.peerCachedState \in [Node -> PeerWireStates]
    /\ sys.peerCachedAckRole \in [Node -> PeerWireRoles]
    /\ sys.peerCachedOwner \in [Node -> Node \cup {NoOwner}]
    /\ sys.peerCacheEpoch \in [Node -> Epoch]
    /\ sys.peerCacheSource \in [Node -> Peer \cup {NoPeer}]
    /\ sys.foreignApplied \in [Node -> BOOLEAN]
    /\ sys.transitionAuthorized \in [Node -> BOOLEAN]
    /\ sys.authorizationTerm \in [Node -> Generation]
    /\ sys.authorizationEpoch \in [Node -> Epoch]
    /\ sys.persistedPhase \in [Node -> CPStates]
    /\ sys.durableIntent \in [Node -> SUBSET ProtocolActions]
    /\ sys.queuedActions \in [Node -> SUBSET ProtocolActions]
    /\ sys.completedActions \in [Node -> SUBSET ProtocolActions]
    /\ sys.rehydrationNeeded \in [Node -> BOOLEAN]
    /\ sys.pendingFlagEpoch \in [Node -> Epoch]
    /\ sys.cachedPendingFlagEpoch \in [Node -> Epoch]
    /\ sys.pendingOps \in [Node -> SUBSET PendingOperationType]
    /\ sys.configPresent \in [Node -> BOOLEAN]
    /\ sys.configEpoch \in [Node -> Epoch]
    /\ sys.bridgeCacheEpoch \in [Node -> Epoch]
    /\ sys.configDeliveryPending \in [Node -> Epoch]
    /\ sys.actorPhase \in [Node -> ActorPhases]
    /\ sys.exactRouteEpoch \in [Node -> Epoch]
    /\ sys.registrations \in [Node -> Epoch]
    /\ sys.parentCacheEpoch \in [Node -> Epoch]
    /\ sys.ignoredSet \in [Node -> BOOLEAN]
    /\ sys.queuedHaSetDelete \in [Node -> BOOLEAN]
    /\ sys.producerHaSetDeletePending \in [Node -> BOOLEAN]
    /\ sys.haOwner \in HaOwners
    /\ sys.routeCandidate \in Node \cup {NoOwner}
    /\ sys.routeCandidateEpoch \in Epoch
    /\ sys.routeCandidateTerm \in Generation
    /\ sys.routePending \in BOOLEAN
    /\ sys.routeOwner \in Node \cup {NoOwner}
    /\ sys.routeEpoch \in Epoch
    /\ sys.routeTerm \in Generation
    /\ sys.lastRouteWriter \in RouteWriters
    /\ sys.sharedRetry \in [Node -> 0..MaxRetry]
    /\ sys.retryByProtocol \in [Node -> [Protocols -> 0..MaxRetry]]
    /\ sys.retryIsolationBroken \in [Node -> BOOLEAN]
    /\ sys.peerLost \in [Node -> BOOLEAN]
    /\ messages \subseteq MessageType
    /\ ackPending \subseteq RequestId
    /\ inbox \in [Node -> MessageType \cup {NoMessage}]

\* Structural sanity: one retained value per transport request ID.
MessageIdsUnique ==
    \A left, right \in messages : left.id = right.id => left = right

\* Structural sanity: phase counters never overtake the accepted/callback
\* chain.  Deletion may reset applied parent state but not these histories.
EffectPipelineOrdered ==
    \A node \in Node :
        /\ sys.actorCommitted[node] <= sys.actorApplied[node]
        /\ sys.actorApplied[node] <= sys.accepted[node]
        /\ sys.haSetIssued[node] <= sys.actorApplied[node]

\* Structural sanity for exact route ownership.
ActorRouteConsistent ==
    \A node \in Node :
        /\ sys.actorPhase[node] = "Absent" => sys.exactRouteEpoch[node] = NoEpoch
        /\ sys.actorPhase[node] = "Live" => sys.exactRouteEpoch[node] /= NoEpoch

\* Structural sanity: operation IDs are unique within each persisted list.
PendingOperationIdsUnique ==
    \A node \in Node :
        \A left, right \in sys.pendingOps[node] :
            left.id = right.id => left = right

\* Brief §5 -- Scenario 1/3/4.
SingleDecisionMaker ==
    Cardinality({node \in Node : TrafficRole(sys.asicRole[node])}) <= 1

AllowedControlHardware(controlState, hardwareRole) ==
    CASE controlState \in {"Dead", "Destroying"}
            -> hardwareRole \in {"None", "Dead"}
      [] controlState \in {"Connecting", "Connected"}
            -> hardwareRole \in {"None", "Dead"}
      [] controlState \in {"InitializingToActive", "PendingActiveActivation"}
            -> hardwareRole \in {"None", "Dead", "Standby"}
      [] controlState \in {"InitializingToStandby", "PendingStandbyActivation"}
            -> hardwareRole \in {"None", "Dead", "Standby"}
      [] controlState = "Active" -> hardwareRole = "Active"
      [] controlState = "Standby" -> hardwareRole = "Standby"
      [] controlState = "Standalone" -> hardwareRole = "Standalone"
      [] controlState = "SwitchingToActive"
            -> hardwareRole \in {"Standby", "SwitchingToActive"}
      [] controlState = "SwitchingToStandby"
            -> hardwareRole \in {"Active", "Standby"}
      [] controlState = "SwitchingToStandalone"
            -> hardwareRole \in {"Active", "Standby", "Standalone"}
      [] OTHER -> FALSE

\* A control-plane phase is installed before its role write crosses the
\* queued-send, producer-apply, and DPU-ack boundaries.  A temporarily old
\* ASIC role is therefore legal only while the role required by the current
\* phase is visibly pending at one of those boundaries (or durably awaiting
\* rehydration after a crash).
RoleTransitionPending(node) ==
    LET requiredRole == RoleForState(sys.cpState[node])
    IN
    \/ "ActivateRole" \in sys.queuedActions[node]
    \/ /\ sys.queuedScopeWrite[node] /= NoEpoch
       /\ sys.queuedScopeRole[node] = requiredRole
    \/ /\ sys.producerScopePending[node] /= NoEpoch
       /\ sys.producerScopeRole[node] = requiredRole
    \/ \E write \in sys.pendingRoleWrites :
           /\ write.node = node
           /\ write.role = requiredRole
    \/ /\ (~sys.processUp[node] \/ sys.rehydrationNeeded[node])
       /\ sys.persistedPhase[node] = sys.cpState[node]
       /\ "ActivateRole" \in sys.durableIntent[node]

\* Brief §5 -- Scenario 1/4.
LegalRolePair ==
    \A node \in Node :
        \/ AllowedControlHardware(sys.cpState[node], sys.asicRole[node])
        \/ RoleTransitionPending(node)

\* Brief §5 -- Scenario 2/3.  maxPeerGeneration is updated monotonically even
\* though the implementation's arrival-ordered cache may regress.
TermNonRegression ==
    \A node \in Node : sys.peerGeneration[node] = sys.maxPeerGeneration[node]

\* Brief §5 -- Scenario 1/3.
AckedTransitionSafety ==
    \A node \in Node :
        sys.transitionAuthorized[node] =>
            /\ sys.authorizationTerm[node] = sys.term[node]
            /\ sys.authorizationEpoch[node] = sys.pairEpoch[node]
            /\ sys.peerCachedAckRole[node] = "Standby"

\* Brief §5 -- Scenario 1/5.
ParentBeforeScope ==
    \A node \in Node :
        sys.scopeApplied[node] = NoEpoch \/
        sys.haSetApplied[node] >= sys.scopeApplied[node]

\* Brief §5 -- Scenario 1/2/6.
RouteMatchesAckedOwner ==
    \/ sys.routeOwner = NoOwner
    \/ /\ sys.routeOwner \in Node
       /\ NodeEligible(sys.routeOwner)
       /\ sys.routeEpoch = sys.ackedPairEpoch[sys.routeOwner]
       /\ sys.routeTerm = sys.ackedTerm[sys.routeOwner]

\* Brief §5 -- Scenario 3.  foreignApplied is set only when a message from a
\* non-current peer or epoch changes receiver protocol state.
CurrentPeerIsolation ==
    \A node \in Node : ~sys.foreignApplied[node]

\* Brief §5 -- Scenario 1/4.
PendingOperationBijective ==
    \A node \in Node :
        \/ /\ sys.pendingFlagEpoch[node] = NoEpoch
           /\ sys.pendingOps[node] = {}
        \/ /\ sys.pendingFlagEpoch[node] /= NoEpoch
           /\ Cardinality(PendingOpsForEpoch(node, sys.pendingFlagEpoch[node])) = 1
           /\ \A op \in sys.pendingOps[node] : op.epoch = sys.pendingFlagEpoch[node]

\* Brief §5 -- Scenario 7 safety component.
RetryIsolation ==
    \A node \in Node : ~sys.retryIsolationBroken[node]

\* Brief §5 liveness properties.  They are defined for dedicated liveness
\* runs; standard safety convergence and hunt cfgs do not silently enable
\* them without fairness/environment assumptions.
DurableActionProgress ==
    \A node \in Node :
        (sys.processUp[node] /\ ~sys.rehydrationNeeded[node]) ~>
            (RequiredActions(sys.persistedPhase[node]) \subseteq sys.completedActions[node])

ConfiguredActorProgress ==
    \A node \in Node :
        (sys.configPresent[node] /\ sys.processUp[node]) ~>
            /\ sys.actorPhase[node] = "Live"
            /\ sys.registrations[node] = sys.configEpoch[node]
            /\ sys.parentCacheEpoch[node] = sys.configEpoch[node]

PairConvergence ==
    (\A node \in Node : sys.processUp[node] /\ sys.configPresent[node]) ~>
        PairCompatible

\* Nondecreasing history properties are safe for standard MC validation.
MaxPeerGenerationMonotonic ==
    [][\A node \in Node :
        sys.maxPeerGeneration'[node] >= sys.maxPeerGeneration[node]]_vars

ConfigEpochMonotonic ==
    [][\A node \in Node :
        sys.configEpoch'[node] >= sys.configEpoch[node]]_vars

PairEpochMonotonic ==
    [][\A node \in Node :
        sys.pairEpoch'[node] >= sys.pairEpoch[node]]_vars

\* =================================================================
\* Next-state relation
\* =================================================================

Next ==
    \* External configuration/lifecycle stimuli (Scenarios 1 and 5).
    \/ \E node \in Node, epoch \in Epoch : ConsumerBridgeConfigSet(node, epoch)
    \/ \E node \in Node : ActorCreatorHandleReceivedMessage(node)
    \/ \E node \in Node : ActorDriverHandleSwbusMessage(node)
    \/ \E node \in Node : ActorDriverHandleSetWhileDeleting(node)
    \/ \E node \in Node : ActorDriverHandleActorMessage(node)
    \/ \E node \in Node : HaSetActorUpdateDashHaSetTable(node)
    \/ \E node \in Node : ActorDriverCommitChanges(node)
    \/ \E node \in Node : ActorDriverSendQueuedHaSetWrite(node)
    \/ \E node \in Node : ActorDriverSendQueuedHaSetState(node)
    \/ \E node \in Node : ProducerBridgeApplyHaSet(node)
    \/ \E node \in Node : HaScopeHandleHaSetState(node)
    \/ \E node \in Node : ActorRegistrationHandle(node)
    \/ \E node \in Node : NpuUpdateDpuHaScopeTable(node)
    \/ \E node \in Node : ActorDriverSendQueuedScopeWrite(node)
    \/ \E node \in Node : ProducerBridgeApplyScope(node)
    \/ \E write \in sys.pendingRoleWrites : DpuAsicAcknowledgeRole(write)
    \/ \E node \in Node : ConsumerBridgeConfigDelete(node)
    \/ \E node \in Node : HaSetActorDoCleanup(node)
    \/ \E node \in Node : ActorDriverSendQueuedHaSetDelete(node)
    \/ \E node \in Node : ProducerBridgeApplyHaSetDelete(node)
    \/ \E node \in Node : ActorDriverFinishDelete(node)
    \/ \E node \in Node : ActorDriverCleanupTimeout(node)
    \* At-least-once network and re-pair (Scenarios 2 and 3).
    \/ \E destination \in Node,
          sourcePeer \in Peer,
          id \in RequestId,
          generation \in Generation,
          peerState \in PeerWireStates,
          ackedRole \in PeerWireRoles,
          owner \in Node \cup {NoOwner} :
            OutgoingSendHaScopeState(destination, sourcePeer, id, generation,
                                     peerState, ackedRole, owner)
    \/ \E node \in Node, id \in RequestId : IncomingHandleRequest(node, id)
    \/ \E node \in Node : NpuHandleHaStateChange(node)
    \/ \E id \in RequestId : OutgoingHandleResponse(id)
    \/ \E id \in RequestId : OutgoingHandleLateResponse(id)
    \/ \E id \in RequestId : NetworkLoseAck(id)
    \/ \E id \in RequestId : OutgoingDriveMaintenanceLoop(id)
    \/ \E id \in RequestId : OutgoingDropExpired(id)
    \/ \E node \in Node : NpuHandleHaSetStateUpdateRePairResolved(node)
    \/ \E node \in Node : NpuHandleHaSetStateUpdateRePairUnresolved(node)
    \/ \E node \in Node : NpuDriveStateMachinePeerAck(node)
    \* Crash/recovery and state-machine actions (Scenario 4).
    \/ \E node \in Node, nextState \in CPStates : NpuDriveStateMachine(node, nextState)
    \/ \E node \in Node, action \in ProtocolActions : ActorDriverSendQueuedAction(node, action)
    \/ \E node \in Node : Crash(node)
    \/ \E node \in Node : Recover(node)
    \/ \E node \in Node : NpuApplyRehydrationSideEffects(node)
    \/ \E node \in Node, epoch \in Epoch, id \in OperationId :
        DpuHandlePendingOperation(node, epoch, id)
    \/ \E node \in Node, id \in OperationId : NpuApprovePendingOperation(node, id)
    \* Competing route writers (Scenario 6).
    \/ \E node \in Node : HaSetComputeRouteFromScope(node)
    \/ HaSetComputeRouteFromConfig
    \/ \E node \in Node : HaSetComputeRouteFromReplay(node)
    \/ ProducerBridgeApplyRoute
    \* Shared retry workflows (Scenario 7).
    \/ \E node \in Node : NpuHandleVoteRequestRetry(node)
    \/ \E node \in Node : NpuHandleVoteRequestFinal(node)
    \/ \E node \in Node : NpuHandleSwitchoverRst(node)
    \/ \E node \in Node : NpuHandleSwitchoverFin(node)
    \/ \E node \in Node : NpuCheckPeerConnectionAndRetry(node)
    \/ \E node \in Node : NpuCheckPeerConnectionLost(node)
    \/ \E node \in Node : NpuPeerConnectedReset(node)

Spec == Init /\ [][Next]_vars

=====================================================================
