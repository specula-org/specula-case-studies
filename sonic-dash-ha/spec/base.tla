---- MODULE base ----
(*
 * SmartSwitch HA State Machine Specification
 * System: sonic-net/sonic-dash-ha (hamgrd daemon)
 *
 * Models the HA protocol from HLD design documents with extensions for:
 *   Family 1: Actor lifecycle — deletion notification gaps
 *   Family 2: Message ordering — missing prerequisite state
 *   Family 3: Crash recovery — non-atomic commit/send
 *   Family 4: HA state machine — election, switchover, standalone
 *   Family 5: Health monitoring — inconsistent criteria
 *
 * Family 4 is modeled from the HLD spec (not the current code, which has
 * stubs/TODOs for election, switchover, and brainsplit recovery).
 *
 * References:
 *   HLD: invariants/smart-switch-ha-hld.md (Sections 7.1-7.4, 8.2, 10.1)
 *   Code: crates/hamgrd/src/actors/{ha_scope,ha_set,dpu}.rs
 *   Driver: crates/swbus-actor/src/driver.rs
 *)

EXTENDS Integers, FiniteSets

\* ===========================================================================
\* Constants
\* ===========================================================================

CONSTANTS
    Node,           \* Set of HA nodes, typically {n1, n2}
    MaxTerm,        \* Maximum term value (state space bound)
    MaxRetries      \* Maximum election retry count

\* ===========================================================================
\* State Constants
\* ===========================================================================

\* HA state machine states (HLD Section 7.1, Table 7-1)
Dead               == "Dead"
Connecting         == "Connecting"
Connected          == "Connected"
InitToActive       == "InitializingToActive"
InitToStandby      == "InitializingToStandby"
Active             == "Active"
Standby            == "Standby"
Standalone         == "Standalone"
SwitchingToActive  == "SwitchingToActive"
SwitchingToStandby == "SwitchingToStandby"
Destroying         == "Destroying"

AllHAStates == {Dead, Connecting, Connected, InitToActive, InitToStandby,
                Active, Standby, Standalone, SwitchingToActive,
                SwitchingToStandby, Destroying}

\* States that can make flow decisions (HLD Table 7-1, "Make Decision" = Yes)
DecisionMakerStates == {Active, SwitchingToActive, Standalone}

\* Desired states (proto DesiredHaState enum, db_structs.rs)
DsUnspecified == "Unspecified"
DsActive      == "DsActive"
DsStandby     == "DsStandby"
DsDead        == "DsDead"
AllDesiredStates == {DsUnspecified, DsActive, DsStandby, DsDead}

\* Vote responses (HLD Section 7.3 election algorithm)
VBecomeActive     == "BecomeActive"
VBecomeStandby    == "BecomeStandby"
VBecomeStandalone == "BecomeStandalone"
VRetryLater       == "RetryLater"

\* Message types
MRequestVote    == "RequestVote"
MVoteResponse   == "VoteResponse"
MHAStateChanged == "HAStateChanged"
MSwitchOver     == "SwitchOver"
MBulkSyncDone   == "BulkSyncDone"

\* Actor hierarchy levels (ha_actor_messages.rs)
\* Physical hierarchy: DPU -> VDPU -> HASet -> HAScope
LvlDPU     == "DPU"
LvlVDPU    == "VDPU"
LvlHASet   == "HASet"
LvlHAScope == "HAScope"
AllLevels  == {LvlDPU, LvlVDPU, LvlHASet, LvlHAScope}

\* Parent mapping for actor hierarchy (ha_actor_messages.rs:170-175)
ParentLevel == [l \in {"VDPU", "HASet", "HAScope"} |->
    CASE l = "VDPU"    -> LvlDPU
      [] l = "HASet"   -> LvlVDPU
      [] l = "HAScope" -> LvlHASet]

\* ===========================================================================
\* Variables
\* ===========================================================================

VARIABLES
    \* --- Core HA protocol (Family 4: HA state machine) ---
    haState,        \* [Node -> AllHAStates]: current HA state
    haTerm,         \* [Node -> 0..MaxTerm]: current term
    desiredState,   \* [Node -> AllDesiredStates]: SDN controller desired state
    retryCount,     \* [Node -> 0..MaxRetries]: election retry counter

    \* --- Health monitoring (Family 5) ---
    dpuUp,          \* [Node -> BOOLEAN]: DPU health (pmon + BFD combined)

    \* --- Actor lifecycle (Family 1) ---
    actorAlive,     \* [Node -> SUBSET AllLevels]: alive actor levels per node

    \* --- Message ordering (Family 2) ---
    configReady,    \* [Node -> BOOLEAN]: HA scope config received
    vdpuReady,      \* [Node -> BOOLEAN]: vDPU state received
    hasetReady,     \* [Node -> BOOLEAN]: HA set state received

    \* --- Crash recovery (Family 3) ---
    pendingOut,     \* [Node -> SUBSET msg]: committed but unsent messages

    \* --- Network ---
    messages        \* SUBSET msg: in-flight messages (unordered bag)

\* Variable groups for UNCHANGED
coreVars      == <<haState, haTerm, desiredState, retryCount>>
healthVars    == <<dpuUp>>
lifecycleVars == <<actorAlive>>
orderingVars  == <<configReady, vdpuReady, hasetReady>>
crashVars     == <<pendingOut>>
msgVars       == <<messages>>
extVars       == <<healthVars, lifecycleVars, orderingVars>>
vars == <<coreVars, healthVars, lifecycleVars, orderingVars, crashVars, msgVars>>

\* ===========================================================================
\* Helpers
\* ===========================================================================

\* Peer node in the HA pair (assumes exactly 2 nodes)
Peer(n) == CHOOSE m \in Node : m /= n

\* HA scope actor is operational from its own perspective.
\* Note: does NOT check parent liveness — orphan actors continue operating
\* without knowing their parent is dead (Bug Family 1).
\* ha_scope.rs:641-666 (message dispatcher returns early if no config)
\* ha_scope.rs:539-545 (vdpu_is_managed check before activation)
HaScopeOperational(n) ==
    /\ LvlHAScope \in actorAlive[n]
    /\ configReady[n]
    /\ vdpuReady[n]

\* Queue a message for deferred delivery (Family 3: crash recovery)
\* Models driver.rs:149-150 — commit_changes() then send_queued_messages()
QueueMsg(n, m) ==
    pendingOut' = [pendingOut EXCEPT ![n] = @ \cup {m}]

\* Queue multiple messages
QueueMsgs(n, ms) ==
    pendingOut' = [pendingOut EXCEPT ![n] = @ \cup ms]

\* ===========================================================================
\* Election Algorithm (Family 4)
\* HLD Section 7.3 — RequestVote evaluation
\* ===========================================================================

\* Evaluate a RequestVote at receiver node n.
\* Returns what the SENDER should become.
\* smart-switch-ha-hld.md Section 7.3: Election Algorithm
EvaluateVote(n, remoteTerm, remoteDesired) ==
    \* Step 3: Already Active — tell sender to be Standby
    \* HLD 7.3: "If CurrentState == Active: return BecomeStandby"
    IF haState[n] = Active THEN VBecomeStandby

    \* Step 4: Dead+DesiredDead or Destroying — tell sender to go Standalone
    \* HLD 7.3: "If (Dead AND DesiredDead) OR Destroying: BecomeStandalone"
    ELSE IF (haState[n] = Dead /\ desiredState[n] = DsDead)
         \/ haState[n] = Destroying THEN VBecomeStandalone

    \* Step 5: Not yet ready (Dead/Connecting) — retry or give up
    \* HLD 7.3: "If CurrentState in {Dead, Connecting}"
    ELSE IF haState[n] \in {Dead, Connecting} THEN
        IF retryCount[n] < MaxRetries THEN VRetryLater
        ELSE VBecomeStandalone

    \* Step 6: Term comparison — higher term wins
    \* HLD 7.3: "If ourTerm > remoteTerm: BecomeStandby"
    ELSE IF haTerm[n] > remoteTerm THEN VBecomeStandby
    ELSE IF haTerm[n] < remoteTerm THEN VBecomeActive

    \* Step 7: Equal terms — desired state tiebreaker
    \* HLD 7.3: "If DesiredState specified..."
    ELSE IF desiredState[n] = DsActive /\ remoteDesired /= DsActive
        THEN VBecomeStandby
    ELSE IF desiredState[n] = DsActive /\ remoteDesired = DsActive
        THEN VRetryLater   \* MC-8: both desired Active → livelock
    ELSE IF remoteDesired = DsActive /\ desiredState[n] /= DsActive
        THEN VBecomeActive

    \* Step 8: Default — retry later
    ELSE VRetryLater

\* How the RECEIVER transitions based on the vote it issued.
\* Only Connected nodes transition; others stay in current state.
\* HLD Section 7.1: Connected → InitToActive/InitToStandby/Standalone
ReceiverTransition(currentState, voteResponse) ==
    IF currentState = Connected THEN
        CASE voteResponse = VBecomeActive  -> InitToStandby    \* sender active, we standby
          [] voteResponse = VBecomeStandby -> InitToActive     \* sender standby, we active
          [] voteResponse = VBecomeStandalone -> Standalone
          [] voteResponse = VRetryLater    -> Connected
    ELSE currentState

\* ===========================================================================
\* Core Protocol Actions (Family 4)
\* ===========================================================================

\* --- Startup Transitions ---

\* Dead → Connecting: DPU comes up, prerequisites met
\* HLD Section 7.1: "Start connecting to peer"
\* ha_scope.rs:539-580 (handle_vdpu_state_update activates HA scope)
\* Requires: DPU health + config + vDPU state (Family 2 prerequisites)
StartConnecting(n) ==
    /\ haState[n] = Dead
    /\ dpuUp[n]                          \* dpu.rs:255-266 (health check)
    /\ desiredState[n] /= DsDead         \* won't connect if desired dead
    /\ HaScopeOperational(n)             \* Family 2: config + vDPU ready
    /\ haState' = [haState EXCEPT ![n] = Connecting]
    /\ UNCHANGED <<haTerm, desiredState, retryCount>>
    /\ UNCHANGED <<extVars, crashVars, msgVars>>

\* Connecting → Connected: peer is reachable
\* HLD Section 7.1: "Successfully connected to peer"
\* Modeled via BFD-inferred connectivity (both DPUs healthy)
BecomeConnected(n) ==
    /\ haState[n] = Connecting
    /\ dpuUp[Peer(n)]                    \* peer reachable via BFD
    /\ haState' = [haState EXCEPT ![n] = Connected]
    /\ retryCount' = [retryCount EXCEPT ![n] = 0]
    /\ UNCHANGED <<haTerm, desiredState>>
    /\ UNCHANGED <<extVars, crashVars, msgVars>>

\* --- Primary Election Protocol (HLD Section 7.3) ---

\* Connected node sends RequestVote to peer
\* HLD Section 7.3: election initiation
SendRequestVote(n) ==
    /\ haState[n] = Connected
    /\ HaScopeOperational(n)
    /\ QueueMsg(n, [type    |-> MRequestVote,
                    from    |-> n,
                    to      |-> Peer(n),
                    term    |-> haTerm[n],
                    desired |-> desiredState[n]])
    /\ UNCHANGED <<coreVars, extVars, msgVars>>

\* Receive RequestVote, evaluate, respond, and transition self
\* HLD Section 7.3: RequestVote handler
\* Receiver evaluates election algorithm and both transitions + responds
HandleRequestVote(n) ==
    \E m \in messages :
        /\ m.type = MRequestVote
        /\ m.to = n
        /\ LET resp == EvaluateVote(n, m.term, m.desired) IN
           \* Receiver transitions based on vote outcome
           \* HLD 7.1: Connected → InitToActive/InitToStandby/Standalone
           /\ haState' = [haState EXCEPT ![n] =
                ReceiverTransition(haState[n], resp)]
           /\ UNCHANGED haTerm
           \* Increment retryCount on RetryLater (capped), reset otherwise
           /\ retryCount' = IF resp = VRetryLater
                            THEN [retryCount EXCEPT ![n] = IF @ < MaxRetries THEN @ + 1 ELSE @]
                            ELSE [retryCount EXCEPT ![n] = 0]
           /\ UNCHANGED desiredState
           \* Consume request, queue response
           /\ messages' = messages \ {m}
           /\ QueueMsg(n, [type     |-> MVoteResponse,
                           from     |-> n,
                           to       |-> m.from,
                           response |-> resp,
                           term     |-> haTerm[n]])
           /\ UNCHANGED extVars

\* Receive vote response and transition
\* HLD Section 7.3: response handler
HandleVoteResponse(n) ==
    \E m \in messages :
        /\ m.type = MVoteResponse
        /\ m.to = n
        /\ haState[n] = Connected   \* only process if still Connected
        \* Transition based on response
        /\ haState' = [haState EXCEPT ![n] =
            CASE m.response = VBecomeActive    -> InitToActive
              [] m.response = VBecomeStandby   -> InitToStandby
              [] m.response = VBecomeStandalone -> Standalone
              [] m.response = VRetryLater      -> Connected]
        /\ UNCHANGED haTerm
        /\ retryCount' = IF m.response = VRetryLater
                         THEN [retryCount EXCEPT ![n] = IF @ < MaxRetries THEN @ + 1 ELSE @]
                         ELSE [retryCount EXCEPT ![n] = 0]
        /\ UNCHANGED desiredState
        /\ messages' = messages \ {m}
        /\ UNCHANGED <<crashVars, extVars>>

\* --- Initialization Phase ---

\* Active-to-be completes initialization, sends BulkSyncDone to peer
\* HLD Section 7.1: InitializingToActive → Active
\* Term increments when becoming Active (inline sync channel established)
CompleteInitToActive(n) ==
    /\ haState[n] = InitToActive
    /\ haTerm[n] < MaxTerm
    /\ haState' = [haState EXCEPT ![n] = Active]
    /\ haTerm' = [haTerm EXCEPT ![n] = @ + 1]
    /\ UNCHANGED <<desiredState, retryCount>>
    /\ QueueMsg(n, [type |-> MBulkSyncDone,
                    from |-> n,
                    to   |-> Peer(n),
                    term |-> haTerm[n] + 1])
    /\ UNCHANGED <<extVars, msgVars>>

\* Standby-to-be receives BulkSyncDone, completes initialization
\* HLD Section 7.1: InitializingToStandby → Standby
HandleBulkSyncDone(n) ==
    \E m \in messages :
        /\ m.type = MBulkSyncDone
        /\ m.to = n
        /\ haState[n] = InitToStandby
        /\ haState' = [haState EXCEPT ![n] = Standby]
        /\ haTerm' = [haTerm EXCEPT ![n] = m.term]   \* sync term with active
        /\ UNCHANGED <<desiredState, retryCount>>
        /\ messages' = messages \ {m}
        /\ UNCHANGED <<crashVars, extVars>>

\* --- Switchover Protocol (HLD Section 8.2) ---

\* Standby initiates switchover when SDN sets desired state to Active
\* HLD Section 8.2 Step 3: Standby → SwitchingToActive
\* ha_scope.rs:257-258 (TODO: switchover operation)
InitiateSwitchover(n) ==
    /\ haState[n] = Standby
    /\ desiredState[n] = DsActive        \* SDN controller wants this node active
    /\ HaScopeOperational(n)
    /\ haState' = [haState EXCEPT ![n] = SwitchingToActive]
    /\ UNCHANGED <<haTerm, desiredState, retryCount>>
    /\ QueueMsg(n, [type |-> MSwitchOver, from |-> n, to |-> Peer(n)])
    /\ UNCHANGED <<extVars, msgVars>>

\* Active receives SwitchOver, transitions to SwitchingToStandby
\* HLD Section 8.2 Step 4: Active → SwitchingToStandby
\* Rejects if our desired state is also Active (conflict)
HandleSwitchOver(n) ==
    \E m \in messages :
        /\ m.type = MSwitchOver
        /\ m.to = n
        /\ haState[n] = Active
        /\ desiredState[n] /= DsActive   \* HLD: reject if both desired Active
        /\ haState' = [haState EXCEPT ![n] = SwitchingToStandby]
        /\ UNCHANGED <<haTerm, desiredState, retryCount>>
        /\ messages' = messages \ {m}
        /\ QueueMsg(n, [type     |-> MHAStateChanged,
                        from     |-> n,
                        to       |-> m.from,
                        newState |-> SwitchingToStandby,
                        newTerm  |-> haTerm[n]])
        /\ UNCHANGED extVars

\* Active rejects SwitchOver (desired state conflict)
\* HLD Section 8.2: "Rejection if DPU0 desired state also Active"
RejectSwitchOver(n) ==
    \E m \in messages :
        /\ m.type = MSwitchOver
        /\ m.to = n
        /\ haState[n] = Active
        /\ desiredState[n] = DsActive    \* conflict: both want active
        /\ messages' = messages \ {m}    \* consume and discard
        /\ UNCHANGED <<coreVars, crashVars, extVars>>

\* SwitchingToActive receives confirmation → Active
\* HLD Section 8.2 Step 5: SwitchingToActive → Active
\* Term increments (new active, inline sync re-established)
CompleteSwitchoverToActive(n) ==
    \E m \in messages :
        /\ m.type = MHAStateChanged
        /\ m.to = n
        /\ m.newState = SwitchingToStandby   \* peer confirmed switchover
        /\ haState[n] = SwitchingToActive
        /\ haTerm[n] < MaxTerm
        /\ haState' = [haState EXCEPT ![n] = Active]
        /\ haTerm' = [haTerm EXCEPT ![n] = @ + 1]
        /\ UNCHANGED <<desiredState, retryCount>>
        /\ messages' = messages \ {m}
        /\ QueueMsg(n, [type     |-> MHAStateChanged,
                        from     |-> n,
                        to       |-> Peer(n),
                        newState |-> Active,
                        newTerm  |-> haTerm[n] + 1])
        /\ UNCHANGED extVars

\* SwitchingToStandby receives confirmation → Standby
\* HLD Section 8.2 Step 6: SwitchingToStandby → Standby
CompleteSwitchoverToStandby(n) ==
    \E m \in messages :
        /\ m.type = MHAStateChanged
        /\ m.to = n
        /\ m.newState = Active               \* peer is now active
        /\ haState[n] = SwitchingToStandby
        /\ haState' = [haState EXCEPT ![n] = Standby]
        /\ haTerm' = [haTerm EXCEPT ![n] = m.newTerm]   \* sync term
        /\ UNCHANGED <<desiredState, retryCount>>
        /\ messages' = messages \ {m}
        /\ UNCHANGED <<crashVars, extVars>>

\* Switchover failed: SwitchingToActive reverts to Standby
\* HLD Section 8.2: "Peer rejected switchover (not in Active state)"
\* Fires when no confirmation message is available (lost or rejected)
SwitchoverFailed(n) ==
    /\ haState[n] = SwitchingToActive
    \* No pending confirmation from peer
    /\ ~\E m \in messages : m.type = MHAStateChanged
                          /\ m.to = n
                          /\ m.newState = SwitchingToStandby
    /\ haState' = [haState EXCEPT ![n] = Standby]
    /\ UNCHANGED <<haTerm, desiredState, retryCount>>
    /\ UNCHANGED <<extVars, crashVars, msgVars>>

\* --- Standalone Operations (HLD Section 10.1) ---

\* Enter Standalone when peer DPU is down
\* HLD Section 10.1: "Peer DPU lost", "Peer DPU dead"
\* Term increments (decision-making state, inline sync lost)
EnterStandalone(n) ==
    /\ haState[n] \in {Active, Standby, InitToActive, InitToStandby,
                        Connected, SwitchingToActive, SwitchingToStandby}
    /\ dpuUp[n]                           \* own DPU must be healthy
    /\ ~dpuUp[Peer(n)]                   \* peer DPU is down
    /\ HaScopeOperational(n)
    /\ haTerm[n] < MaxTerm
    /\ haState' = [haState EXCEPT ![n] = Standalone]
    /\ haTerm' = [haTerm EXCEPT ![n] = @ + 1]
    /\ UNCHANGED <<desiredState, retryCount>>
    /\ UNCHANGED <<extVars, crashVars, msgVars>>

\* Active receives HAStateChanged(Destroying) from peer → Standalone
\* HLD Section 10.1: "Active → Standalone: Peer planned shutdown"
HandlePeerDestroying(n) ==
    \E m \in messages :
        /\ m.type = MHAStateChanged
        /\ m.to = n
        /\ m.newState = Destroying
        /\ haState[n] = Active
        /\ haTerm[n] < MaxTerm
        /\ haState' = [haState EXCEPT ![n] = Standalone]
        /\ haTerm' = [haTerm EXCEPT ![n] = @ + 1]
        /\ UNCHANGED <<desiredState, retryCount>>
        /\ messages' = messages \ {m}
        /\ UNCHANGED <<crashVars, extVars>>

\* Exit Standalone: peer recovers, re-enter Connected for re-election
\* HLD Section 10.1: "Standalone → Connected (recovery)"
ExitStandalone(n) ==
    /\ haState[n] = Standalone
    /\ dpuUp[Peer(n)]                    \* peer recovered
    /\ haState' = [haState EXCEPT ![n] = Connected]
    /\ retryCount' = [retryCount EXCEPT ![n] = 0]
    /\ UNCHANGED <<haTerm, desiredState>>
    /\ UNCHANGED <<extVars, crashVars, msgVars>>

\* InitToStandby timeout: peer lost during initialization → Standalone
\* HLD Section 7.1: "InitializingToStandby → Standalone: Peer lost"
InitToStandbyTimeout(n) ==
    /\ haState[n] = InitToStandby
    /\ dpuUp[n]                           \* own DPU must be healthy
    /\ ~dpuUp[Peer(n)]
    /\ haTerm[n] < MaxTerm
    /\ haState' = [haState EXCEPT ![n] = Standalone]
    /\ haTerm' = [haTerm EXCEPT ![n] = @ + 1]
    /\ UNCHANGED <<desiredState, retryCount>>
    /\ UNCHANGED <<extVars, crashVars, msgVars>>

\* --- Destroying / Dead Transitions ---

\* Standby → Destroying: planned shutdown
\* HLD Section 7.1: "Standby → Destroying: Desired state Dead"
StartDestroying(n) ==
    /\ haState[n] = Standby
    /\ desiredState[n] = DsDead
    /\ haState' = [haState EXCEPT ![n] = Destroying]
    /\ UNCHANGED <<haTerm, desiredState, retryCount>>
    /\ QueueMsg(n, [type     |-> MHAStateChanged,
                    from     |-> n,
                    to       |-> Peer(n),
                    newState |-> Destroying,
                    newTerm  |-> haTerm[n]])
    /\ UNCHANGED <<extVars, msgVars>>

\* Destroying → Dead: cleanup complete
\* HLD Section 7.1: "Destroying → Dead: Traffic drained"
CompleteDestroy(n) ==
    /\ haState[n] = Destroying
    /\ haState' = [haState EXCEPT ![n] = Dead]
    /\ UNCHANGED <<haTerm, desiredState, retryCount>>
    /\ UNCHANGED <<extVars, crashVars, msgVars>>

\* Any (non-Dead/Destroying) → Dead: DPU failure or desired Dead
\* HLD Section 7.1: various → Dead transitions
\* ha_scope.rs:221-228 (do_cleanup on config deletion)
GoToDead(n) ==
    /\ haState[n] \notin {Dead, Destroying}
    /\ \/ desiredState[n] = DsDead
       \/ ~dpuUp[n]                       \* local DPU failed
    /\ haState' = [haState EXCEPT ![n] = Dead]
    /\ UNCHANGED <<haTerm, desiredState, retryCount>>
    /\ UNCHANGED <<extVars, crashVars, msgVars>>

\* ===========================================================================
\* Extension: Actor Lifecycle (Family 1)
\* ===========================================================================

\* Create actor at a level for a node.
\* Requires parent to be alive (except DPU which is the root).
\* Models: actors.rs actor spawning, ha_set.rs HA set creation
CreateActor(n, level) ==
    /\ level \notin actorAlive[n]
    /\ IF level /= LvlDPU
       THEN ParentLevel[level] \in actorAlive[n]
       ELSE TRUE
    /\ actorAlive' = [actorAlive EXCEPT ![n] = @ \cup {level}]
    /\ UNCHANGED <<coreVars, healthVars, orderingVars, crashVars, msgVars>>

\* Delete actor at a level — does NOT notify children.
\* Bug Family 1: deletion notification gaps
\* dpu.rs:137-140 (DPU deletion skips vDPU notification)
\* dpu.rs:376-378 (remote DPU deletion skips all cleanup)
\* ha_set.rs:154-170 (HA set deletion skips HA scope notification)
\* ha_actor_messages.rs:145 (new_actor_msg ignores up parameter)
\* ha_actor_messages.rs:194-207 (stale registrations persist without GC)
DeleteActor(n, level) ==
    /\ level \in actorAlive[n]
    /\ actorAlive' = [actorAlive EXCEPT ![n] = @ \ {level}]
    \* Children are NOT removed — this is the bug (MC-1, MC-2)
    /\ UNCHANGED <<coreVars, healthVars, orderingVars, crashVars, msgVars>>

\* ===========================================================================
\* Extension: Message Ordering (Family 2)
\* ===========================================================================

\* Receive HA scope config from Redis consumer bridge.
\* Config can arrive before or after vDPU state — non-deterministic.
\* ha_scope.rs:478-537 (handle_dash_ha_scope_config_table_message)
\* ha_scope.rs:511-513 (config before vDPU → HA state fields stale, MC-3)
ReceiveConfig(n) ==
    /\ ~configReady[n]
    /\ LvlHAScope \in actorAlive[n]
    /\ configReady' = [configReady EXCEPT ![n] = TRUE]
    /\ UNCHANGED <<coreVars, healthVars, lifecycleVars>>
    /\ UNCHANGED <<vdpuReady, hasetReady, crashVars, msgVars>>

\* Receive vDPU state update.
\* vdpu.rs:143-145 (vDPU drops ALL messages before config arrives, MC-4)
\* ha_scope.rs:539-580 (handle_vdpu_state_update — lazy initialization)
ReceiveVdpuState(n) ==
    /\ ~vdpuReady[n]
    /\ LvlVDPU \in actorAlive[n]
    /\ vdpuReady' = [vdpuReady EXCEPT ![n] = TRUE]
    /\ UNCHANGED <<coreVars, healthVars, lifecycleVars>>
    /\ UNCHANGED <<configReady, hasetReady, crashVars, msgVars>>

\* Receive HA set state update.
\* ha_scope.rs:585-599 (handle_haset_state_update — VIP derivation)
\* ha_set.rs:561-569 (first config skips BFD/VNet creation, MC-5)
ReceiveHasetState(n) ==
    /\ ~hasetReady[n]
    /\ LvlHASet \in actorAlive[n]
    /\ hasetReady' = [hasetReady EXCEPT ![n] = TRUE]
    /\ UNCHANGED <<coreVars, healthVars, lifecycleVars>>
    /\ UNCHANGED <<configReady, vdpuReady, crashVars, msgVars>>

\* ===========================================================================
\* Extension: Crash Recovery (Family 3)
\* ===========================================================================

\* Deliver pending outgoing messages (normal operation).
\* Models: driver.rs:150 — send_queued_messages() succeeds
FlushOutgoing(n) ==
    /\ pendingOut[n] /= {}
    /\ messages' = messages \cup pendingOut[n]
    /\ pendingOut' = [pendingOut EXCEPT ![n] = {}]
    /\ UNCHANGED <<coreVars, extVars>>

\* Crash between commit and send — queued messages lost.
\* Bug Family 3: driver.rs:149-150 crash window (MC-6)
\* commit_changes() wrote to Redis, send_queued_messages() never ran.
\* State is preserved (already persisted) but messages are lost.
\* Peer actors never learn about this node's state change.
CrashNode(n) ==
    /\ pendingOut[n] /= {}
    /\ pendingOut' = [pendingOut EXCEPT ![n] = {}]
    /\ UNCHANGED <<coreVars, extVars, msgVars>>

\* ===========================================================================
\* Extension: Health Monitoring (Family 5)
\* ===========================================================================

\* DPU health state change.
\* Models: dpu.rs:235-269 (calculate_dpu_state)
\* pmon: midplane + control plane + data plane all Up required
\* BFD: at least one IPv4 or IPv6 session up required
\* dpu.rs:289-290 (handle_pmon_transition checks only 2 signals vs 3)
DpuHealthChange(n, newUp) ==
    /\ dpuUp[n] /= newUp
    /\ dpuUp' = [dpuUp EXCEPT ![n] = newUp]
    /\ UNCHANGED <<coreVars, lifecycleVars, orderingVars, crashVars, msgVars>>

\* ===========================================================================
\* Fault Injection
\* ===========================================================================

\* SDN controller changes desired state for a node.
\* Models: ha_scope.rs:478-537 (config table with new desired_ha_state)
ChangeDesiredState(n, ds) ==
    /\ desiredState[n] /= ds
    /\ desiredState' = [desiredState EXCEPT ![n] = ds]
    /\ UNCHANGED <<haState, haTerm, retryCount>>
    /\ UNCHANGED <<extVars, crashVars, msgVars>>

\* Message lost in transit (fire-and-forget delivery, consumer bridge failure).
\* Models: consumer.rs:96-102 (fire-and-forget consumer bridge)
\* outgoing.rs:121-122 (unacked messages silently dropped after 1 hour)
LoseMessage ==
    /\ messages /= {}
    /\ \E m \in messages :
        messages' = messages \ {m}
    /\ UNCHANGED <<coreVars, extVars, crashVars>>

\* ===========================================================================
\* Init and Spec
\* ===========================================================================

Init ==
    /\ haState      = [n \in Node |-> Dead]
    /\ haTerm       = [n \in Node |-> 0]
    /\ desiredState = [n \in Node |-> DsUnspecified]
    /\ retryCount   = [n \in Node |-> 0]
    /\ dpuUp        = [n \in Node |-> FALSE]
    /\ actorAlive   = [n \in Node |-> {}]
    /\ configReady  = [n \in Node |-> FALSE]
    /\ vdpuReady    = [n \in Node |-> FALSE]
    /\ hasetReady   = [n \in Node |-> FALSE]
    /\ pendingOut   = [n \in Node |-> {}]
    /\ messages     = {}

Next ==
    \/ \E n \in Node :
        \* Core protocol actions (Family 4)
        \/ StartConnecting(n)
        \/ BecomeConnected(n)
        \/ SendRequestVote(n)
        \/ HandleRequestVote(n)
        \/ HandleVoteResponse(n)
        \/ CompleteInitToActive(n)
        \/ HandleBulkSyncDone(n)
        \/ InitiateSwitchover(n)
        \/ HandleSwitchOver(n)
        \/ RejectSwitchOver(n)
        \/ CompleteSwitchoverToActive(n)
        \/ CompleteSwitchoverToStandby(n)
        \/ EnterStandalone(n)
        \/ HandlePeerDestroying(n)
        \/ ExitStandalone(n)
        \/ InitToStandbyTimeout(n)
        \/ SwitchoverFailed(n)
        \/ StartDestroying(n)
        \/ CompleteDestroy(n)
        \/ GoToDead(n)
        \* Extension: Actor lifecycle (Family 1)
        \/ \E level \in AllLevels : CreateActor(n, level)
        \/ \E level \in AllLevels : DeleteActor(n, level)
        \* Extension: Message ordering (Family 2)
        \/ ReceiveConfig(n)
        \/ ReceiveVdpuState(n)
        \/ ReceiveHasetState(n)
        \* Extension: Crash recovery (Family 3)
        \/ FlushOutgoing(n)
        \/ CrashNode(n)
        \* Extension: Health (Family 5)
        \/ DpuHealthChange(n, TRUE)
        \/ DpuHealthChange(n, FALSE)
        \* Fault injection
        \/ \E ds \in AllDesiredStates : ChangeDesiredState(n, ds)
    \/ LoseMessage

Spec == Init /\ [][Next]_vars

\* ===========================================================================
\* Invariants
\* ===========================================================================

\* --- Type Invariant ---
TypeOK ==
    /\ haState      \in [Node -> AllHAStates]
    /\ haTerm       \in [Node -> 0..MaxTerm]
    /\ desiredState \in [Node -> AllDesiredStates]
    /\ retryCount   \in [Node -> 0..MaxRetries]
    /\ dpuUp        \in [Node -> BOOLEAN]
    /\ actorAlive   \in [Node -> SUBSET AllLevels]
    /\ configReady  \in [Node -> BOOLEAN]
    /\ vdpuReady    \in [Node -> BOOLEAN]
    /\ hasetReady   \in [Node -> BOOLEAN]

\* --- Standard Safety Invariants (Family 4) ---

\* At most one decision maker per HA pair at any time.
\* HLD Section 7.1: "only 1 DPU can make flow decisions"
\* Targets: MC-10 (switchover during concurrent DPU failure)
\* NOTE: Strict version — violated during DPU health change race (MC-9).
\* Use EffectiveSingleDecisionMaker for convergence testing.
SingleDecisionMaker ==
    Cardinality({n \in Node : haState[n] \in DecisionMakerStates}) <= 1

\* Effective decision maker: only counts nodes with healthy DPUs.
\* A node with dpuUp=FALSE cannot actually serve traffic even if in
\* a decision-making state (GoToDead will fire in a subsequent step).
\* Safe for convergence testing — the DPU health race is expected.
EffectiveSingleDecisionMaker ==
    Cardinality({n \in Node : haState[n] \in DecisionMakerStates /\ dpuUp[n]}) <= 1

\* Both nodes cannot be in Active simultaneously.
\* Weaker form of SingleDecisionMaker for high-confidence checking.
NoDoubleActive ==
    Cardinality({n \in Node : haState[n] = Active}) <= 1

\* Both nodes cannot be Standalone simultaneously.
\* HLD Section 10.1: "Only Standalone-Standby pairs allowed"
\* Targets: MC-9 (peer down detection race)
\* NOTE: Violated when both DPUs go down — known design gap. Use in hunting only.
NoStandaloneStandalone ==
    ~(\E n1, n2 \in Node : n1 /= n2
        /\ haState[n1] = Standalone
        /\ haState[n2] = Standalone)

\* --- Extension Invariants ---

\* No orphan actors: if parent is dead, child should also be dead.
\* Bug Family 1: deletion notification gaps
\* Targets: MC-1 (DPU deletion orphans vDPU), MC-2 (HA set orphans HA scope)
NoOrphanActors ==
    \A n \in Node :
        /\ (LvlVDPU    \in actorAlive[n]) => (LvlDPU  \in actorAlive[n])
        /\ (LvlHASet   \in actorAlive[n]) => (LvlVDPU \in actorAlive[n])
        /\ (LvlHAScope \in actorAlive[n]) => (LvlHASet \in actorAlive[n])

\* HA protocol requires prerequisites before transitions.
\* Bug Family 2: message ordering dependency
\* Targets: MC-3 (config before vDPU), MC-4 (vDPU drops before config)
PrerequisiteRespected ==
    \A n \in Node :
        haState[n] \notin {Dead, Connecting} =>
            (configReady[n] /\ vdpuReady[n])

\* After crash, peer eventually learns about state change.
\* Bug Family 3: crash recovery consistency
\* Targets: MC-6 (crash between commit and send → split-brain)
\* Checked via hunting config with CrashNode enabled.
NoPendingWhileDeciding ==
    \A n \in Node :
        haState[n] \in DecisionMakerStates =>
            pendingOut[n] = {}

\* --- Structural Invariants ---

\* Every in-flight message has valid sender and receiver
MessageWellFormed ==
    \A m \in messages :
        /\ m.from \in Node
        /\ m.to \in Node
        /\ m.from /= m.to

\* Both nodes cannot be in InitializingToActive simultaneously.
\* Election should produce at most one active-to-be.
NoDoubleInitActive ==
    Cardinality({n \in Node : haState[n] = InitToActive}) <= 1

\* Terms are non-negative (structural sanity check)
TermNonNegative ==
    \A n \in Node : haTerm[n] >= 0

\* ===========================================================================
\* Temporal Properties
\* ===========================================================================

\* Election convergence: Connected nodes eventually reach a stable state.
\* Targets: MC-8 (equal terms + both desired Active → livelock)
\* Requires fairness (WF) on all actions.
ElectionConvergence ==
    \A n \in Node :
        haState[n] = Connected ~>
            haState[n] \in {Active, Standby, Standalone, Dead}

\* Switchover liveness: SwitchingToActive eventually reaches Active or Standby.
SwitchoverConvergence ==
    \A n \in Node :
        haState[n] = SwitchingToActive ~>
            haState[n] \in {Active, Standby, Standalone, Dead}

====
